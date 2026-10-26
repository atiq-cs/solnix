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
 * NOT here (the next step): the line discipline. There is no ICANON, ECHO,
 * ISIG or ONLCR; bytes pass through raw, which is all a client-driven
 * (no-ICANON) dropbear session needs. termios is stored and returned only.
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
	unsigned char	pt_termios[36];	/* illumos struct termios, stored only */
	unsigned short	pt_winsz[4];	/* ws_row, ws_col, ws_xpixel, ws_ypixel */
	struct ptyring	pt_m2s;		/* master -> slave */
	struct ptyring	pt_s2m;		/* slave -> master */
};

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
		pt->pt_mref = 1;
		pt->pt_sref = pt->pt_ever = 0;
		pt->pt_locked = 1;
		pt->pt_uid = uid;
		pt->pt_gid = gid;
		pt->pt_m2s.r_rpos = pt->pt_m2s.r_wpos = 0;
		pt->pt_s2m.r_rpos = pt->pt_s2m.r_wpos = 0;
		for (i = 0; i < 36; i++)
			pt->pt_termios[i] = 0;
		/* c_cflag (offset 8, LE) CS8|CREAD = 0xb0; c_lflag 0 is the truth: no ICANON/ECHO yet. */
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

	pty_lock(pt);
	if (master && pt->pt_mref > 0)
		pt->pt_mref--;
	else if (!master && pt->pt_sref > 0)
		pt->pt_sref--;
	if (pt->pt_mref == 0 && pt->pt_sref == 0)
		pt->pt_used = 0;
	pty_unlock(pt);
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
	r = (long)ring_get(master ? &pt->pt_s2m : &pt->pt_m2s, kbuf, len);
	if (r == 0 && len > 0) {
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

	pty_lock(pt);
	if (master ? (pt->pt_ever && pt->pt_sref == 0) : pt->pt_mref == 0)
		r = -PTY_EIO;
	else {
		r = (long)ring_put(master ? &pt->pt_m2s : &pt->pt_s2m, kbuf, len);
		if (r == 0 && len > 0)
			r = -PTY_EAGAIN;
	}
	pty_unlock(pt);
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
	if (in->r_wpos != in->r_rpos)
		m |= PTY_RD;
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
	case PTY_TCSETSW:	/* shortcut: no output processing, so nothing to drain */
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
