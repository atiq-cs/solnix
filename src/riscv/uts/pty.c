/*
 * pty.c -- pseudo-terminal pairs for the illumos riscv64 kernel (rvtty step 1).
 *
 * The illumos shape where it is cheap: opening /dev/ptmx makes a master, and
 * its slave is /dev/pts/N. ISPTM, UNLKPT and OWNERPT are the ioctls behind
 * libc's isptm/unlockpt/grantpt; ptsname comes from the minor in st_rdev.
 * A pair is two byte rings: m2s carries what the master writes (the slave
 * reads it), s2m the reverse. Each pty has its own spinlock.
 *
 * Everything here works on KERNEL buffers and never blocks: a read of an empty
 * ring returns -EAGAIN and uproc.c does the waiting, the EINTR and the user
 * copies, the same split as the pipe and socket paths.
 *
 * The line discipline applies the slave's termios: ICANON (VERASE, VKILL,
 * VEOF; a slave read returns at most one line), ECHO, and OPOST|ONLCR on
 * output. With ICANON off, input is raw. NOT here: ISIG, ctty, input maps.
 */
#define	NPTY		8
#define	PTYBUF		4096

#define	PTY_EIO		5
#define	PTY_ENXIO	6
#define	PTY_EAGAIN	11
#define	PTY_EACCES	13
#define	PTY_EFAULT	14
#define	PTY_EINVAL	22
#define	PTY_ENOTTY	25
#define	PTY_ENOSPC	28

#define	PTY_RD		0x1	/* the same bits as unixsock/inet poll */
#define	PTY_WR		0x2
#define	PTY_HUP		0x4

struct ptyring {
	unsigned long	r_rpos;		/* total bytes read */
	unsigned long	r_wpos;		/* total bytes written */
	unsigned char	r_data[PTYBUF];
};

struct pty {
	volatile int	pt_lock;
	int		pt_used;
	int		pt_mref;	/* open master descriptors */
	int		pt_sref;	/* open slave descriptors */
	int		pt_ever;	/* a slave has been opened at least once */
	int		pt_locked;	/* 1 until UNLKPT */
	unsigned int	pt_uid, pt_gid;	/* slave owner (OWNERPT / grantpt) */
	unsigned char	pt_termios[36];	/* illumos struct termios (the line discipline reads it) */
	unsigned long	pt_llen;	/* ICANON: bytes of the open line at the m2s tail */
	unsigned short	pt_winsz[4];	/* ws_row, ws_col, ws_xpixel, ws_ypixel */
	int		pt_sid;		/* session whose ctty this slave is; 0 = none */
	int		pt_pgrp;	/* foreground process group (TIOCSPGRP) */
	int		pt_sigpend;	/* ISIG: signal for pt_pgrp, posted after unlock */
	struct ptyring	pt_m2s;		/* master -> slave */
	struct ptyring	pt_s2m;		/* slave -> master */
};

extern int proc_signal_pgrp(int pgid, int sig);	/* uproc.c */
extern int proc_signal(int pid, int sig);
static struct pty ptytab[NPTY];

static void
pty_lock(struct pty *pt)
{
	int old;

	do {
		__asm__ __volatile__("amoswap.w.aq %0, %2, (%1)"
		    : "=&r"(old) : "r"(&pt->pt_lock), "r"(1) : "memory");
	} while (old != 0);
}

static void
pty_unlock(struct pty *pt)
{
	__asm__ __volatile__("amoswap.w.rl zero, zero, (%0)"
	    :: "r"(&pt->pt_lock) : "memory");
}

/* Copy up to n bytes out of ring r into kbuf; returns the count. */
static unsigned long
ring_get(struct ptyring *r, char *kbuf, unsigned long n)
{
	unsigned long i, avail = r->r_wpos - r->r_rpos;

	if (n > avail)
		n = avail;
	for (i = 0; i < n; i++)
		kbuf[i] = (char)r->r_data[(r->r_rpos + i) % PTYBUF];
	r->r_rpos += n;
	return (n);
}

/* Copy up to n bytes from kbuf into ring r; returns the count. */
static unsigned long
ring_put(struct ptyring *r, const char *kbuf, unsigned long n)
{
	unsigned long i, space = PTYBUF - (r->r_wpos - r->r_rpos);

	if (n > space)
		n = space;
	for (i = 0; i < n; i++)
		r->r_data[(r->r_wpos + i) % PTYBUF] = (unsigned char)kbuf[i];
	r->r_wpos += n;
	return (n);
}

/* illumos termios flags used for the stored default (sys/termios.h). */
#define	PTY_CS8		0000060
#define	PTY_CREAD	0000200

/* The slave's termios fields the line discipline reads (illumos offsets, LE). */
#define	PTY_OFLAG(pt)	((pt)->pt_termios[4])		/* OPOST 01, ONLCR 04 */
#define	PTY_LFLAG(pt)	((pt)->pt_termios[12])		/* ICANON 02, ECHO 010 */
#define	PTY_CC(pt, i)	((pt)->pt_termios[16 + (i)])	/* VERASE 2, VKILL 3, VEOF 4 */

/*
 * Output toward the master (slave writes, echo): with OPOST|ONLCR "\n" goes
 * out as "\r\n". Returns the bytes of kbuf taken; a "\n" only when both fit.
 */
static unsigned long
ld_out(struct pty *pt, const char *kbuf, unsigned long n)
{
	struct ptyring *r = &pt->pt_s2m;
	unsigned long i;

	if ((PTY_OFLAG(pt) & 05) != 05)
		return (ring_put(r, kbuf, n));
	for (i = 0; i < n; i++) {
		if (kbuf[i] == '\n') {
			if (PTYBUF - (r->r_wpos - r->r_rpos) < 2)
				break;
			(void) ring_put(r, "\r", 1);
		}
		if (ring_put(r, kbuf + i, 1) == 0)
			break;
	}
	return (i);
}

/* ECHO: best effort, dropped when s2m is full (a blocked echo would wedge the master). */
#define	LD_ECHO(pt, s, n)	((PTY_LFLAG(pt) & 010) ? (void) ld_out(pt, s, n) : (void) 0)
#define	LD_IS(pt, c, i)		((c) != 0 && (c) == PTY_CC(pt, i))	/* 0 = _POSIX_VDISABLE */

/*
 * Input from the master (master writes). ICANON: the open line is the last
 * pt_llen bytes of m2s; VERASE / VKILL edit it, '\n' or VEOF ends it (VEOF is
 * kept in the ring as the end mark, not echoed), and it is held to PTYBUF-1
 * bytes so the end always fits. Returns the bytes of kbuf taken.
 */
static unsigned long
ld_in(struct pty *pt, const char *kbuf, unsigned long n)
{
	struct ptyring *r = &pt->pt_m2s;
	int canon = PTY_LFLAG(pt) & 02;
	unsigned long i;
	unsigned char c;

	if (!canon || pt->pt_llen > r->r_wpos - r->r_rpos)	/* raw reads, TCSETSF */
		pt->pt_llen = canon ? r->r_wpos - r->r_rpos : 0;
	for (i = 0; i < n; i++) {
		c = (unsigned char)kbuf[i];
		if ((PTY_LFLAG(pt) & 01) && (LD_IS(pt, c, 0) || LD_IS(pt, c, 1))) {
			/* ISIG: VINTR -> SIGINT, VQUIT -> SIGQUIT; the open line is flushed */
			r->r_wpos -= canon ? pt->pt_llen : 0, pt->pt_llen = 0;
			pt->pt_sigpend = LD_IS(pt, c, 0) ? 2 : 3;
			LD_ECHO(pt, LD_IS(pt, c, 0) ? "^C\n" : "^\\\n", 3);
			continue;
		}
		if (!canon || c == '\n' || LD_IS(pt, c, 4)) {	/* raw, or a line's end */
			if (ring_put(r, kbuf + i, 1) == 0)
				break;
			pt->pt_llen = 0;
			if (!canon || c == '\n')
				LD_ECHO(pt, kbuf + i, 1);
		} else if (LD_IS(pt, c, 2)) {			/* VERASE */
			if (pt->pt_llen > 0) {
				r->r_wpos--, pt->pt_llen--;
				LD_ECHO(pt, "\b \b", 3);
			}
		} else if (LD_IS(pt, c, 3)) {			/* VKILL */
			r->r_wpos -= pt->pt_llen, pt->pt_llen = 0;
		} else if (pt->pt_llen < PTYBUF - 1) {		/* else the line is full: drop */
			if (ring_put(r, kbuf + i, 1) == 0)
				break;
			pt->pt_llen++;
			LD_ECHO(pt, kbuf + i, 1);
		}
	}
	return (i);
}

/*
 * ICANON read of the slave: whole lines only, at most one per read. The VEOF
 * end mark is consumed, not returned, so VEOF at a line's start reads 0 (EOF).
 * Returns -1 when no whole line is in yet.
 * shortcut: uproc.c pty_uio reads on after a full 256-byte chunk, so a line
 * ending exactly on a 256-byte boundary can join the next one in one read(2).
 */
static long
ld_read(struct pty *pt, char *kbuf, unsigned long len)
{
	struct ptyring *r = &pt->pt_m2s;
	unsigned long i, avail = r->r_wpos - r->r_rpos;
	unsigned char c;

	if (pt->pt_llen > avail)	/* TCSETSF flushed, or a raw read took it */
		pt->pt_llen = avail;
	if ((avail -= pt->pt_llen) == 0)
		return (len > 0 ? -1 : 0);
	for (i = 0; i < avail && i < len; i++) {
		c = r->r_data[(r->r_rpos + i) % PTYBUF];
		if (c == '\n')
			return ((long)ring_get(r, kbuf, i + 1));
		if (LD_IS(pt, c, 4)) {
			(void) ring_get(r, kbuf, i);
			r->r_rpos++;		/* drop VEOF */
			return ((long)i);
		}
	}
	return ((long)ring_get(r, kbuf, i));
}

/*
 * pty_alloc -- a new pair for a /dev/ptmx open by uid/gid. Returns its index N
 * (the slave is /dev/pts/N) holding one master reference, or -ENOSPC. The slave
 * starts locked, as on illumos: unlockpt (UNLKPT) must come before its open.
 */
int
pty_alloc(unsigned int uid, unsigned int gid)
{
	int n, i;

	for (n = 0; n < NPTY; n++) {
		struct pty *pt = &ptytab[n];

		pty_lock(pt);
		if (pt->pt_used) {
			pty_unlock(pt);
			continue;
		}
		pt->pt_used = 1;
		pt->pt_sid = 0, pt->pt_pgrp = 0;
		pt->pt_mref = 1;
		pt->pt_sref = pt->pt_ever = 0;
		pt->pt_locked = 1;
		pt->pt_uid = uid;
		pt->pt_gid = gid;
		pt->pt_m2s.r_rpos = pt->pt_m2s.r_wpos = pt->pt_llen = 0;
		pt->pt_s2m.r_rpos = pt->pt_s2m.r_wpos = 0;
		for (i = 0; i < 36; i++)
			pt->pt_termios[i] = 0;
		/* c_cflag (offset 8, LE) CS8|CREAD = 0xb0; c_lflag 0: raw until a TCSETS. */
		pt->pt_termios[8] = PTY_CS8 | PTY_CREAD;
		pt->pt_termios[16 + 0] = 3;		/* VINTR ^C */
		pt->pt_termios[16 + 2] = 0x7f;		/* VERASE DEL */
		pt->pt_termios[16 + 3] = 0x15;		/* VKILL ^U */
		pt->pt_termios[16 + 4] = 1;		/* VMIN (= VEOF slot) */
		for (i = 0; i < 4; i++)
			pt->pt_winsz[i] = 0;
		pty_unlock(pt);
		return (n);
	}
	return (-PTY_ENOSPC);
}

/*
 * pty_open_slave -- open /dev/pts/N for uid. -ENXIO when there is no such pair
 * or its master is gone, -EIO while still locked (no unlockpt yet), -EACCES for
 * a non-owner that is not root. On success the caller holds a slave reference.
 */
int
pty_open_slave(int n, unsigned int uid)
{
	struct pty *pt;
	int r = 0;

	if (n < 0 || n >= NPTY)
		return (-PTY_ENXIO);
	pt = &ptytab[n];
	pty_lock(pt);
	if (!pt->pt_used || pt->pt_mref == 0)
		r = -PTY_ENXIO;
	else if (pt->pt_locked)
		r = -PTY_EIO;
	else if (uid != 0 && uid != pt->pt_uid)
		r = -PTY_EACCES;
	else {
		pt->pt_sref++;
		pt->pt_ever = 1;
	}
	pty_unlock(pt);
	return (r);
}

/* A second descriptor for one end (fork, dup): one more reference. */
void
pty_ref(int n, int master)
{
	struct pty *pt = &ptytab[n];

	pty_lock(pt);
	if (master)
		pt->pt_mref++;
	else
		pt->pt_sref++;
	pty_unlock(pt);
}

/* Drop one end's reference; the pair is freed when both ends are gone. */
void
pty_close(int n, int master)
{
	struct pty *pt = &ptytab[n];
	int hup = 0;

	pty_lock(pt);
	if (master && pt->pt_mref > 0)
		pt->pt_mref--;
	else if (!master && pt->pt_sref > 0)
		pt->pt_sref--;
	if (master && pt->pt_mref == 0 && pt->pt_sid != 0)
		hup = pt->pt_sid, pt->pt_sid = pt->pt_pgrp = 0;	/* hangup: the ctty is gone */
	if (pt->pt_mref == 0 && pt->pt_sref == 0)
		pt->pt_used = 0;
	pty_unlock(pt);
	if (hup != 0)
		(void) proc_signal(hup, 1 /* SIGHUP, to the session leader */);
}

/*
 * pty_read -- up to n bytes for one end into kbuf. The master reads what the
 * slave wrote and vice versa. Returns the count; 0 = EOF (the other end has
 * closed and the ring is drained: a master sees EOF once every slave fd that
 * was ever opened is gone); -EAGAIN = empty, the caller waits and retries.
 */
long
pty_read(int n, int master, char *kbuf, unsigned long len)
{
	struct pty *pt = &ptytab[n];
	long r;

	pty_lock(pt);
	if (!master && (PTY_LFLAG(pt) & 02))
		r = ld_read(pt, kbuf, len);
	else if ((r = (long)ring_get(master ? &pt->pt_s2m : &pt->pt_m2s, kbuf, len)) == 0 && len > 0)
		r = -1;
	if (r == -1) {				/* nothing to read */
		if (master ? (pt->pt_ever && pt->pt_sref == 0) : pt->pt_mref == 0)
			r = 0;			/* EOF */
		else
			r = -PTY_EAGAIN;
	}
	pty_unlock(pt);
	return (r);
}

/*
 * pty_write -- up to len bytes from kbuf toward the other end. Returns the
 * count taken; -EAGAIN when that ring is full; -EIO when the other end is gone
 * (illumos: a slave write after the master closes fails EIO).
 */
long
pty_write(int n, int master, const char *kbuf, unsigned long len)
{
	struct pty *pt = &ptytab[n];
	long r;
	int sig, pg;

	pty_lock(pt);
	if (master ? (pt->pt_ever && pt->pt_sref == 0) : pt->pt_mref == 0)
		r = -PTY_EIO;
	else {
		r = (long)(master ? ld_in(pt, kbuf, len) : ld_out(pt, kbuf, len));
		if (r == 0 && len > 0)
			r = -PTY_EAGAIN;
	}
	sig = pt->pt_sigpend, pg = pt->pt_pgrp, pt->pt_sigpend = 0;
	pty_unlock(pt);
	if (sig != 0 && pg > 0)
		(void) proc_signal_pgrp(pg, sig);
	return (r);
}

/* Readiness of one end: PTY_RD / PTY_WR / PTY_HUP (HUP: other end gone). */
int
pty_poll(int n, int master)
{
	struct pty *pt = &ptytab[n];
	struct ptyring *in, *out;
	int m = 0, gone;

	pty_lock(pt);
	in = master ? &pt->pt_s2m : &pt->pt_m2s;
	out = master ? &pt->pt_m2s : &pt->pt_s2m;
	gone = master ? (pt->pt_ever && pt->pt_sref == 0) : pt->pt_mref == 0;
	if (in->r_wpos - in->r_rpos > (!master && (PTY_LFLAG(pt) & 02) ? pt->pt_llen : 0))
		m |= PTY_RD;			/* ICANON: a whole line */
	if (gone)
		m |= PTY_HUP | PTY_RD;		/* a read returns now (EOF) */
	else if (out->r_wpos - out->r_rpos < PTYBUF)
		m |= PTY_WR;
	pty_unlock(pt);
	return (m);
}

/* illumos ioctl numbers: sys/ptms.h ('P'<<8) and sys/termios.h ('T'<<8). */
#define	PTY_ISPTM	0x5001
#define	PTY_UNLKPT	0x5002
#define	PTY_OWNERPT	0x5005	/* arg: struct pt_own { uid_t ruid; gid_t rgid; } */
#define	PTY_TCGETS	0x540d
#define	PTY_TCSETS	0x540e
#define	PTY_TCSETSW	0x540f
#define	PTY_TCSETSF	0x5410
#define	PTY_TIOCSWINSZ	0x5467
#define	PTY_TIOCGWINSZ	0x5468
#define	PTY_TIOCGPGRP	0x7414	/* illumos tIOC|20 */
#define	PTY_TIOCSPGRP	0x7415
#define	PTY_TIOCGSID	0x7416
#define	PTY_TIOCNOTTY	0x7471	/* tIOC|113 */
#define	PTY_TIOCSCTTY	0x7484	/* tIOC|132 */

/* Become `sid`'s controlling tty, with `pgid` in the foreground (session leaders only, from open or TIOCSCTTY). */
int
pty_set_ctty(int n, int sid, int pgid)
{
	struct pty *pt = &ptytab[n];
	int r = -1;

	pty_lock(pt);
	if (pt->pt_sid == 0 || pt->pt_sid == sid) {
		pt->pt_sid = sid, pt->pt_pgrp = pgid, r = 0;
	}
	pty_unlock(pt);
	return (r);
}

/* The ctty session of slave n (0 = none) and its foreground group; and set the foreground group. */
int
pty_ctty(int n, int *pgrp)
{
	*pgrp = ptytab[n].pt_pgrp;
	return (ptytab[n].pt_sid);
}

void
pty_set_pgrp(int n, int pgrp)
{
	ptytab[n].pt_pgrp = pgrp;
}

int
pty_drop_ctty(int n)
{
	ptytab[n].pt_sid = ptytab[n].pt_pgrp = 0;
	return (0);
}

/* The slave that is session `sid`'s ctty, or -1. */
int
pty_session_ctty(int sid)
{
	int n;

	for (n = 0; n < NPTY; n++)
		if (ptytab[n].pt_used && ptytab[n].pt_sid == sid)
			return (n);
	return (-1);
}

extern long copyin(const void *uaddr, void *kaddr, unsigned long n);
extern long copyout(const void *kaddr, void *uaddr, unsigned long n);

/*
 * pty_ioctl -- the pty ioctls on either end; uarg is the user argument and uid
 * the caller's. termios and the window size are one shared copy per pair.
 * User copies happen with the lock dropped (a fault must not hold it).
 */
long
pty_ioctl(int n, int master, int cmd, unsigned long uarg, unsigned int uid)
{
	struct pty *pt = &ptytab[n];
	unsigned char b[36];
	unsigned int own[2];
	int i;

	switch (cmd) {
	case PTY_ISPTM:
		return (master ? 0 : -PTY_EINVAL);
	case PTY_UNLKPT:
	case PTY_OWNERPT:
		if (!master)
			return (-PTY_EINVAL);
		if (cmd == PTY_OWNERPT) {
			if (copyin((void *)uarg, own, sizeof (own)) != 0)
				return (-PTY_EFAULT);
			if (uid != 0 && own[0] != uid)
				return (-PTY_EACCES);	/* only root gives it away */
		}
		pty_lock(pt);
		if (cmd == PTY_UNLKPT)
			pt->pt_locked = 0;
		else {
			pt->pt_uid = own[0];
			pt->pt_gid = own[1];
		}
		pty_unlock(pt);
		return (0);
	case PTY_TCGETS:
	case 0x5401:		/* the libc glue's isatty() probe (Linux TCGETS) */
	case PTY_TIOCGWINSZ:
		pty_lock(pt);
		for (i = 0; i < 36; i++)
			b[i] = cmd != PTY_TIOCGWINSZ ? pt->pt_termios[i] :
			    i < 8 ? ((unsigned char *)pt->pt_winsz)[i] : 0;
		pty_unlock(pt);
		return (copyout(b, (void *)uarg, cmd != PTY_TIOCGWINSZ ? 36 : 8) != 0 ?
		    -PTY_EFAULT : 0);
	case PTY_TCSETS:
	case PTY_TCSETSW:	/* shortcut: output is not drained first; drain when a client needs it */
	case PTY_TCSETSF:
	case PTY_TIOCSWINSZ:
		if (copyin((void *)uarg, b, cmd == PTY_TIOCSWINSZ ? 8 : 36) != 0)
			return (-PTY_EFAULT);
		pty_lock(pt);
		for (i = 0; i < (cmd == PTY_TIOCSWINSZ ? 8 : 36); i++) {
			if (cmd == PTY_TIOCSWINSZ)
				((unsigned char *)pt->pt_winsz)[i] = b[i];
			else
				pt->pt_termios[i] = b[i];
		}
		if (cmd == PTY_TCSETSF)		/* flush this end's pending input */
			(master ? &pt->pt_s2m : &pt->pt_m2s)->r_rpos =
			    (master ? &pt->pt_s2m : &pt->pt_m2s)->r_wpos;
		pty_unlock(pt);
		return (0);
	}
	return (-PTY_ENOTTY);
}

/* Owner of /dev/pts/N for stat (ptsname/ttyname, dropbear's pty_setowner). */
int
pty_owner(int n, unsigned int *uid, unsigned int *gid)
{
	int r = 0;

	if (n < 0 || n >= NPTY)
		return (-PTY_ENXIO);
	pty_lock(&ptytab[n]);
	if (!ptytab[n].pt_used)
		r = -PTY_ENXIO;
	*uid = ptytab[n].pt_uid;
	*gid = ptytab[n].pt_gid;
	pty_unlock(&ptytab[n]);
	return (r);
}
