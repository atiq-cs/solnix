/*
 * sidtest.c -- rvlogin: setsid/getsid/getpgid and wait4(WNOHANG), raw ecalls.
 *   a fork child (not a group leader) setsid() -> its pid; getsid(0) = getpgid(0) = pid;
 *   a second setsid() in it -> EPERM; the parent's session is unchanged; the parent's
 *   wait4(WNOHANG) returns 0 while the child lives and reaps it after it exits;
 *   wait4 with no children -> -ECHILD-ish (<0); an unknown option bit -> EINVAL.
 * prints SIDTEST PASS / SIDTEST FAIL <why>
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
#define	K_getpgid	155
#define	K_getsid	156
#define	K_setsid	157
#define	K_getpid	172
#define	K_fork		220
#define	K_wait4		260
#define	K_exit		93
#define	K_nanosleep	101
#define	K_pipe2		59
#define	K_read		63
#define	K_write		64

static int
fail(const char *w, long r)
{
	printf("SIDTEST FAIL %s r=%ld\n", w, r);
	return (1);
}

int
main(void)
{
	long me = ks(K_getpid, 0, 0, 0), psid = ks(K_getsid, 0, 0, 0), pid, r;
	int p[2], st = 0, polls = 0;
	char c = 0;

	if (ks(K_pipe2, (long)p, 0, 0) != 0)
		return (fail("pipe", -1));
	if ((pid = ks(K_fork, 0, 0, 0)) == 0) {
		long s = ks(K_setsid, 0, 0, 0), self = ks(K_getpid, 0, 0, 0);
		char ok = (s == self && ks(K_getsid, 0, 0, 0) == self &&
		    ks(K_getpgid, 0, 0, 0) == self &&
		    ks(K_setsid, 0, 0, 0) == -1) ? 'Y' : 'N';
		long ts[2] = { 0, 300000000 };	/* stay alive 0.3 s for WNOHANG */

		ks(K_write, p[1], (long)&ok, 1);
		ks(K_nanosleep, (long)ts, 0, 0);
		ks(K_exit, 7, 0, 0);
	}
	if (pid < 0)
		return (fail("fork", pid));
	if (ks(K_read, p[0], (long)&c, 1) != 1 || c != 'Y')
		return (fail("child setsid/getsid/getpgid/EPERM", c));
	if (ks(K_getsid, 0, 0, 0) != psid || ks(K_getsid, pid, 0, 0) != pid)
		return (fail("parent session changed / getsid(child)", psid));
	if ((r = ks(K_wait4, pid, (long)&st, 1)) != 0)
		return (fail("WNOHANG on a live child: want 0", r));
	if ((r = ks(K_wait4, pid, (long)&st, 4)) != -22)
		return (fail("unknown option: want -22", r));
	while ((r = ks(K_wait4, -1, (long)&st, 1)) == 0) {
		long ts[2] = { 0, 10000000 };
		polls++;
		ks(K_nanosleep, (long)ts, 0, 0);
	}
	if (r != pid || (st & 0xff) != 7)
		return (fail("reap after exit", r));
	if ((r = ks(K_wait4, -1, (long)&st, 1)) >= 0)
		return (fail("no children: want <0", r));
	printf("SIDTEST PASS me=%ld sid=%ld child=%ld polls=%d\n", me, psid, pid, polls);
	return (0);
}
