/*
 * ctytest.c -- rvtty3b: controlling tty, process groups, ISIG and hangup on a pty (raw ecalls).
 *   1. a forked session leader opens the slave without O_NOCTTY: TIOCGSID = its pid; /dev/tty opens.
 *   2. its child in a NEW pgrp, made foreground (TIOCSPGRP), blocks in read on the slave;
 *      ^C (0x03) on the master kills it with SIGINT; the leader (other pgrp) is untouched.
 *   3. the master closes: the leader gets SIGHUP.
 * prints CTYTEST PASS / CTYTEST FAIL <why>
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
#define	K_ioctl 29
#define	K_openat 56
#define	K_close 57
#define	K_read 63
#define	K_write 64
#define	K_exit 93
#define	K_nanosleep 101
#define	K_setpgid 154
#define	K_setsid 157
#define	K_getpid 172
#define	K_fork 220
#define	K_wait4 260
#define	AT_FDCWD (-100)
#define	O_RDWR 2
#define	O_NOCTTY 0x100
#define	UNLKPT 0x5002
#define	OWNERPT 0x5005
#define	TIOCGPGRP 0x7414
#define	TIOCSPGRP 0x7415
#define	TIOCGSID 0x7416
#define	TCGETS 0x540d
#define	TCSETS 0x540e

static int bad;
static void
fail(const char *w, long r)
{
	printf("CTYTEST FAIL %s r=%ld\n", w, r);
	bad = 1;
}

static void
nap(long ms)
{
	long ts[2] = { 0, ms * 1000000L };

	(void) ks(K_nanosleep, (long)ts, 0, 0);
}

/* The session leader (a fork of main): returns its exit code to main. */
static int
leader(int ptsn)
{
	char path[12] = "/dev/pts/0", b[4];
	long s, sid = 0, pg = 0, c, wst = 0;

	path[9] = (char)('0' + ptsn);
	if (ks(K_setsid, 0, 0, 0) <= 0)
		return (10);
	if ((s = ks(K_openat, AT_FDCWD, (long)path, O_RDWR)) < 0)	/* no O_NOCTTY: becomes the ctty */
		return (11);
	if (ks(K_ioctl, s, TIOCGSID, (long)&sid) != 0 || sid != ks(K_getpid, 0, 0, 0))
		return (12);
	c = ks(K_openat, AT_FDCWD, (long)"/dev/tty", O_RDWR);
	if (c < 0)
		return (13);
	(void) ks(K_close, c, 0, 0);
	if ((c = ks(K_fork, 0, 0, 0)) == 0) {			/* child: own pgrp, foreground, blocks */
		(void) ks(K_setpgid, 0, 0, 0);
		pg = ks(K_getpid, 0, 0, 0);
		(void) ks(K_ioctl, s, TIOCSPGRP, (long)&pg);
		(void) ks(K_read, s, (long)b, 1);		/* ^C must kill us here */
		ks(K_exit, 7, 0, 0);
	}
	nap(300);
	if (ks(K_ioctl, s, TIOCGPGRP, (long)&pg) != 0 || pg != c)
		return (14);
	if (ks(K_wait4, c, (long)&wst, 0) != c || (wst & 0xff) != 128 + 2)
		return (15);					/* not killed by SIGINT */
	pg = ks(K_getpid, 0, 0, 0);				/* the shell takes the terminal back */
	if (ks(K_ioctl, s, TIOCSPGRP, (long)&pg) != 0)
		return (17);
	(void) ks(K_write, 1, (long)"CTY-LEADER-READ\n", 16);
	if (ks(K_read, s, (long)b, 3) != 3 || b[0] != 'o' || b[1] != 'k')
		return (18);					/* the next line after ^C */
	(void) ks(K_write, 1, (long)"CTY-LEADER-READY\n", 17);
	for (c = 0; c < 100; c++)				/* main closes the master: SIGHUP kills us */
		nap(100);
	return (16);						/* no hangup within 10 s */
}

int
main(void)
{
	long m, n = -1, own[2] = { 0, 0 }, wst = 0, lp, r;

	if ((m = ks(K_openat, AT_FDCWD, (long)"/dev/ptmx", O_RDWR | O_NOCTTY)) < 0)
		return (fail("open /dev/ptmx", m), 1);
	if ((r = ks(K_ioctl, m, OWNERPT, (long)own)) != 0 || (r = ks(K_ioctl, m, UNLKPT, 0)) != 0)
		return (fail("grantpt/unlockpt", r), 1);
	{	/* ISIG on (c_lflag offset 12, ISIG = 01), as an ssh client's pty-req modes would set it */
		unsigned char t[36];

		if ((r = ks(K_ioctl, m, TCGETS, (long)t)) != 0)
			return (fail("TCGETS", r), 1);
		t[12] |= 01;
		if ((r = ks(K_ioctl, m, TCSETS, (long)t)) != 0)
			return (fail("TCSETS", r), 1);
	}
	for (n = 0; n < 8; n++) {			/* which N: the slave that opens */
		char path[12] = "/dev/pts/0";
		long t;

		path[9] = (char)('0' + n);
		if ((t = ks(K_openat, AT_FDCWD, (long)path, O_RDWR | O_NOCTTY)) >= 0) {
			(void) ks(K_close, t, 0, 0);
			break;
		}
	}
	if ((lp = ks(K_fork, 0, 0, 0)) == 0) {
		(void) ks(K_close, m, 0, 0);		/* the leader holds only the slave, as sshd's child does */
		ks(K_exit, leader((int)n), 0, 0);
	}
	nap(500);
	(void) ks(K_write, m, (long)"\003", 1);		/* ^C at the foreground group */
	nap(1500);
	(void) ks(K_write, m, (long)"ok\n", 3);			/* the line the leader reads next */
	nap(1000);
	(void) ks(K_close, m, 0, 0);			/* hangup */
	if ((r = ks(K_wait4, lp, (long)&wst, 0)) != lp)
		return (fail("wait leader", r), 1);
	r = wst & 0xff;	/* raw exit code: the kernel reports 128+sig for a signal death */
	if (r != 128 + 1)
		return (fail(r < 20 ? "leader step (code)" : "leader not hung up (status)", r), 1);
	printf("CTYTEST PASS pts=%ld\n", n);
	return (bad);
}
