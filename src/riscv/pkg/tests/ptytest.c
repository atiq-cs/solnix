/*
 * ptytest.c -- rvtty step 1: a pty pair, raw ecalls (illumos ioctl numbers).
 *   open /dev/ptmx; ISPTM; fstat gives minor N; the slave refuses to open before
 *   unlockpt; OWNERPT (grantpt) + UNLKPT; open /dev/pts/N; stat shows the owner;
 *   bytes each way; poll; TIOCSWINSZ on the master reads back on the slave;
 *   TCSETS/TCGETS round trip; 10000 bytes (> the 4 KiB ring) from a fork child
 *   through the slave; closing the slave = EOF + EIO at the master, and closing
 *   a master = EOF at its slave.
 * prints PTYTEST PASS / PTYTEST FAIL <why>
 */
#include <stdio.h>

static long
ks(long n, long a, long b, long c)
{
	register long a0 __asm__("a0") = a, a1 __asm__("a1") = b,
	    a2 __asm__("a2") = c, a7 __asm__("a7") = n;
	__asm__ __volatile__("ecall" : "+r"(a0) : "r"(a1), "r"(a2), "r"(a7) : "memory");
	return (a0);
}
static long
ks4(long n, long a, long b, long c, long d)
{
	register long a0 __asm__("a0") = a, a1 __asm__("a1") = b,
	    a2 __asm__("a2") = c, a3 __asm__("a3") = d, a7 __asm__("a7") = n;
	__asm__ __volatile__("ecall" : "+r"(a0) : "r"(a1), "r"(a2), "r"(a3), "r"(a7)
	    : "memory");
	return (a0);
}
#define	K_ioctl		29
#define	K_openat	56
#define	K_close		57
#define	K_read		63
#define	K_write		64
#define	K_poll		73	/* this kernel: (fds, nfds, timeout ms) */
#define	K_fstatat	79
#define	K_fstat		80
#define	K_exit		93
#define	K_getuid	174
#define	K_fork		220
#define	K_wait4		260
#define	AT_FDCWD	(-100)
#define	O_RDWR		2
#define	O_NOCTTY	0x100

#define	ISPTM		0x5001
#define	UNLKPT		0x5002
#define	OWNERPT		0x5005
#define	TCGETS		0x540d
#define	TCSETS		0x540e
#define	TIOCSWINSZ	0x5467
#define	TIOCGWINSZ	0x5468

struct kst {			/* the kernel's struct stat (uproc.c kstat_k) */
	unsigned long dev, ino;
	unsigned int mode, nlink, uid, gid;
	unsigned long rdev, pad1;
	long size, rest[11];
};
struct kpfd { int fd; short ev, rev; };

static int
fail(const char *w, long r)
{
	printf("PTYTEST FAIL %s r=%ld\n", w, r);
	return (1);
}

static long
op(const char *path)
{
	return (ks4(K_openat, AT_FDCWD, (long)path, O_RDWR | O_NOCTTY, 0));
}

int
main(void)
{
	long m, s, n, r, own[1];
	unsigned int ow[2];
	struct kst st;
	struct kpfd pf;
	unsigned short ws[4] = { 33, 111, 0, 0 }, wg[4];
	unsigned char t[36], tg[36], buf[512];
	char sp[12] = "/dev/pts/0";
	int i, got = 0, wst = 0;

	(void) own;
	if ((m = op("/dev/ptmx")) < 0)
		return (fail("open /dev/ptmx", m));
	if ((r = ks(K_ioctl, m, ISPTM, 0)) != 0)
		return (fail("ISPTM on the master", r));
	if ((r = ks(K_fstat, m, (long)&st, 0)) != 0 || (st.mode & 0170000) != 0020000)
		return (fail("fstat master: want S_IFCHR", r));
	n = (long)st.rdev;
	sp[9] = (char)('0' + n);
	if ((r = op(sp)) != -5)
		return (fail("slave open before unlockpt: want -EIO", r));
	ow[0] = (unsigned int)ks(K_getuid, 0, 0, 0);
	ow[1] = 7;			/* group tty */
	if ((r = ks(K_ioctl, m, OWNERPT, (long)ow)) != 0 ||
	    (r = ks(K_ioctl, m, UNLKPT, 0)) != 0)
		return (fail("grantpt/unlockpt", r));
	if ((s = op(sp)) < 0)
		return (fail("open slave", s));
	if ((r = ks4(K_fstatat, AT_FDCWD, (long)sp, (long)&st, 0)) != 0 ||
	    st.uid != ow[0] || st.gid != 7 || (st.mode & 07777) != 0620 ||
	    (long)st.rdev != n)
		return (fail("stat slave: owner/mode/minor", r));
	if ((r = ks(K_ioctl, s, ISPTM, 0)) == 0)
		return (fail("ISPTM on the slave must fail", r));
	if (ks(K_write, m, (long)"to-slave", 8) != 8 ||
	    (r = ks(K_read, s, (long)buf, sizeof (buf))) != 8 ||
	    __builtin_memcmp(buf, "to-slave", 8) != 0)
		return (fail("master -> slave", r));
	pf.fd = (int)m; pf.ev = 1; pf.rev = 0;
	if ((r = ks(K_poll, (long)&pf, 1, 0)) != 0)
		return (fail("poll master empty: want 0", r));
	if (ks(K_write, s, (long)"to-master", 9) != 9 ||
	    (r = ks(K_poll, (long)&pf, 1, 1000)) != 1 || !(pf.rev & 1) ||
	    (r = ks(K_read, m, (long)buf, sizeof (buf))) != 9 ||
	    __builtin_memcmp(buf, "to-master", 9) != 0)
		return (fail("slave -> master (+poll)", r));
	if ((r = ks(K_ioctl, m, TIOCSWINSZ, (long)ws)) != 0 ||
	    (r = ks(K_ioctl, s, TIOCGWINSZ, (long)wg)) != 0 ||
	    wg[0] != 33 || wg[1] != 111)
		return (fail("TIOCSWINSZ master -> TIOCGWINSZ slave", r));
	for (i = 0; i < 36; i++)
		t[i] = (unsigned char)(i * 7 + 1);
	if ((r = ks(K_ioctl, s, TCSETS, (long)t)) != 0 ||
	    (r = ks(K_ioctl, m, TCGETS, (long)tg)) != 0 ||
	    __builtin_memcmp(t, tg, 36) != 0)
		return (fail("TCSETS slave -> TCGETS master", r));
	if (ks(K_fork, 0, 0, 0) == 0) {
		for (i = 0; i < (int)sizeof (buf); i++)
			buf[i] = (unsigned char)i;
		for (i = 0; i < 10000; i += (int)r)
			if ((r = ks(K_write, s, (long)buf + i % 256,
			    10000 - i > 256 ? 256 : 10000 - i)) <= 0)
				ks(K_exit, 9, 0, 0);
		ks(K_exit, 0, 0, 0);
	}
	while (got < 10000 && (r = ks(K_read, m, (long)buf, sizeof (buf))) > 0) {
		for (i = 0; i < r; i++)
			if (buf[i] != (unsigned char)((got + i) % 256))
				return (fail("big transfer byte", got + i));
		got += (int)r;
	}
	if (got != 10000 || ks(K_wait4, -1, (long)&wst, 0) <= 0 || (wst & 0xffff))
		return (fail("10000 bytes slave -> master via a fork child", got));
	ks(K_close, s, 0, 0);
	if ((r = ks(K_read, m, (long)buf, 1)) != 0)
		return (fail("master read after slave close: want EOF", r));
	if ((r = ks(K_write, m, (long)"x", 1)) != -5)
		return (fail("master write after slave close: want -EIO", r));
	ks(K_close, m, 0, 0);

	/* Second pair: closing the master is EOF on its slave. */
	if ((m = op("/dev/ptmx")) < 0 || ks(K_ioctl, m, UNLKPT, 0) != 0 ||
	    ks(K_fstat, m, (long)&st, 0) != 0)
		return (fail("second ptmx", m));
	sp[9] = (char)('0' + st.rdev);
	if ((s = op(sp)) < 0)
		return (fail("second slave", s));
	ks(K_close, m, 0, 0);
	if ((r = ks(K_read, s, (long)buf, 1)) != 0)
		return (fail("slave read after master close: want EOF", r));
	ks(K_close, s, 0, 0);
	if ((r = op("/dev/pts/9")) >= 0)
		return (fail("open /dev/pts/9: want an error", r));
	printf("PTYTEST PASS pts=%ld ws=%ux%u big=%d\n", n, wg[0], wg[1], got);
	return (0);
}
