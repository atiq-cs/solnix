/*
 * nbtest.c -- rvlogin: the fd/signal/cred semantics dropbear relies on.
 *   1 fcntl F_SETFL O_NONBLOCK on a pipe: empty read -> EAGAIN, F_GETFL shows it;
 *     the console fd 0 refuses it with ENODEV (dropbear tolerates exactly that)
 *   2 poll(-1) on an empty pipe is interrupted (EINTR) by a caught SIGCHLD
 *   3 setuid: uid 0 may become 1000, uid 1000 may not become 0 (EPERM); getgid;
 *     seteuid round trip (setresuid(-1,1000,-1) then (-1,0,-1)) works for root, as
 *     dropbear does to read authorized_keys as the user
 * Raw ecalls for the kernel calls; newlib signal() for the handler.
 * prints NBTEST PASS / NBTEST FAIL <why>
 */
#include <stdio.h>
#include <signal.h>

static long
ks(long n, long a, long b, long c)
{
	register long a0 __asm__("a0") = a, a1 __asm__("a1") = b,
	    a2 __asm__("a2") = c, a7 __asm__("a7") = n;
	__asm__ __volatile__("ecall" : "+r"(a0) : "r"(a1), "r"(a2), "r"(a7) : "memory");
	return (a0);
}
#define	K_fcntl 25
#define	K_pipe2 59
#define	K_read 63
#define	K_poll 73
#define	K_exit 93
#define	K_setgid 144
#define	K_setuid 146
#define	K_getuid 174
#define	K_getgid 176
#define	K_geteuid 175
#define	K_setresuid 147
#define	K_fork 220
#define	K_wait4 260

static volatile int got_chld;
static void onchld(int s) { (void) s; got_chld++; }

static int
fail(const char *w, long r)
{
	printf("NBTEST FAIL %s r=%ld\n", w, r);
	return (1);
}

int
main(void)
{
	int p[2], st;
	char c;
	long r, pid;
	struct { int fd; short ev, rev; } pf;

	if (ks(K_pipe2, (long)p, 0, 0) != 0)
		return (fail("pipe", -1));
	if ((r = ks(K_fcntl, p[0], 4, 0x800)) != 0)
		return (fail("F_SETFL O_NONBLOCK", r));
	if (((r = ks(K_fcntl, p[0], 3, 0)) & 0x800) == 0)
		return (fail("F_GETFL lacks O_NONBLOCK", r));
	if ((r = ks(K_read, p[0], (long)&c, 1)) != -11)
		return (fail("empty nonblocking read: want -11 EAGAIN", r));
	if ((r = ks(K_fcntl, 0, 4, 0x800)) != -19)
		return (fail("console F_SETFL: want -19 ENODEV", r));
	/* 2: a child exits while we poll(-1) an empty pipe */
	signal(SIGCHLD, onchld);
	if ((pid = ks(K_fork, 0, 0, 0)) == 0)
		ks(K_exit, 0, 0, 0);
	pf.fd = p[0]; pf.ev = 1; pf.rev = 0;
	r = ks(K_poll, (long)&pf, 1, -1);
	if (r != -4 || got_chld != 1)
		return (fail("poll(-1) + SIGCHLD: want -4 EINTR and the handler", r * 10 + got_chld));
	if ((r = ks(K_wait4, pid, (long)&st, 0)) != pid)
		return (fail("reap", r));
	/* 3: credentials, in a child so the test process stays root */
	if ((pid = ks(K_fork, 0, 0, 0)) == 0) {
		long t1 = ks(K_setresuid, -1, 1000, -1), eu = ks(K_geteuid, 0, 0, 0);
		long ru = ks(K_getuid, 0, 0, 0), t2 = ks(K_setresuid, -1, 0, -1);
		if (t1 != 0 || eu != 1000 || ru != 0 || t2 != 0 || ks(K_geteuid, 0, 0, 0) != 0)
			ks(K_exit, 8, 0, 0);
		long a = ks(K_setgid, 1000, 0, 0), b = ks(K_setuid, 1000, 0, 0);
		long g = ks(K_getgid, 0, 0, 0), u = ks(K_getuid, 0, 0, 0);
		long e = ks(K_setuid, 0, 0, 0), e2 = ks(K_setgid, 0, 0, 0);
		ks(K_exit, (a == 0 && b == 0 && g == 1000 && u == 1000 && e == -1 &&
		    e2 == -1 && ks(K_getuid, 0, 0, 0) == 1000 &&
		    ks(K_setresuid, -1, 0, -1) == -1) ? 0 : 9, 0, 0);
	}
	signal(SIGCHLD, SIG_DFL);
	if ((r = ks(K_wait4, pid, (long)&st, 0)) != pid || (st & 0xff) != 0)
		return (fail("setuid/setgid/getgid child", st));
	printf("NBTEST PASS\n");
	return (0);
}
