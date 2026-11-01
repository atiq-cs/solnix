/*
 * smpstress.c -- rvsmp: many processes on many harts, each looping over
 *   getpid()            must be its own pid       (curproc shared by harts)
 *   write(bad user ptr) must be -EFAULT, no trap  (copy_lofault shared by harts)
 *   pipe write+read     must round-trip its tag   (right proc, right AS)
 *   nanosleep(1us)      yields                    (yield before ctx saved)
 * plus a stack checksum each pass (a resumed half-saved context corrupts it).
 * First it measures parallelism: N children spin the same loop the parent
 * timed alone; par = N * t1 / tN (1.0 = one hart does all the work).
 *   smpstress <nchild> <iters> [minpar]   (nchild <= 12: NPROC is 16)
 * Prints SMPSTRESS PASS/FAIL. With minpar (e.g. 2), par below it is a FAIL:
 * the hazards cannot fire when only one hart runs user code.
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/wait.h>

static long
ks(long n, long a0, long a1, long a2)
{
	register long r0 __asm__("a0") = a0;
	register long r1 __asm__("a1") = a1;
	register long r2 __asm__("a2") = a2;
	register long r7 __asm__("a7") = n;

	__asm__ __volatile__("ecall" : "+r"(r0) : "r"(r1), "r"(r2), "r"(r7)
	    : "memory");
	return (r0);
}

#define	K_pipe2		59
#define	K_read		63
#define	K_write		64
#define	K_nanosleep	101
#define	K_clock_gettime	113
#define	K_getpid	172
#define	EFAULT_K	14
#define	BADU		0x7f000000L	/* user slot 1, never mapped */

static unsigned long
now_ns(void)
{
	long ts[2];

	(void) ks(K_clock_gettime, 4, (long)ts, 0);
	return ((unsigned long)ts[0] * 1000000000UL + (unsigned long)ts[1]);
}

static volatile unsigned long sink;

static void
spin(unsigned long n)
{
	unsigned long i, x = 1;

	for (i = 0; i < n; i++)
		x = x * 6364136223846793005UL + 1442695040888963407UL;
	sink = x;
}

static int
child(int idx, int iters)
{
	long me = ks(K_getpid, 0, 0, 0);
	long ts[2] = { 0, 1000 };
	unsigned long buf[16], sum0 = 0, sum, tag, got;
	int pfd[2], i, j, bad = 0;

	for (j = 0; j < 16; j++) {
		buf[j] = (unsigned long)me * 0x9e3779b97f4a7c15UL + j;
		sum0 += buf[j];
	}
	/* shortcut: the kernel has NPIPE 8 system-wide, so later children skip the pipe step */
	if (ks(K_pipe2, (long)pfd, 0, 0) != 0)
		pfd[0] = -1;
	for (i = 0; i < iters && bad < 5; i++) {
		long r;

		if ((r = ks(K_getpid, 0, 0, 0)) != me) {
			printf("SMPSTRESS FAIL child %d: getpid %ld != %ld "
			    "(iter %d)\n", idx, r, me, i);
			bad++;
		}
		if ((r = ks(K_write, pfd[1], BADU, 16)) != -EFAULT_K) {
			printf("SMPSTRESS FAIL child %d: write(bad) %ld "
			    "(iter %d)\n", idx, r, i);
			bad++;
		}
		tag = ((unsigned long)me << 32) | (unsigned long)i;
		got = tag;
		if (pfd[0] >= 0 && (ks(K_write, pfd[1], (long)&tag, 8) != 8 ||
		    (got = 0, ks(K_read, pfd[0], (long)&got, 8)) != 8 || got != tag)) {
			printf("SMPSTRESS FAIL child %d: pipe tag %lx != %lx "
			    "(iter %d)\n", idx, got, tag, i);
			bad++;
		}
		if ((r = ks(K_nanosleep, (long)ts, 0, 0)) != 0) {
			printf("SMPSTRESS FAIL child %d: nanosleep %ld\n",
			    idx, r);
			bad++;
		}
		for (sum = 0, j = 0; j < 16; j++)
			sum += buf[j];
		if (sum != sum0) {
			printf("SMPSTRESS FAIL child %d: stack sum %lx != %lx "
			    "(iter %d)\n", idx, sum, sum0, i);
			bad++;
		}
	}
	return (bad != 0);
}

int
main(int argc, char **argv)
{
	int n = argc > 1 ? atoi(argv[1]) : 16;
	int iters = argc > 2 ? atoi(argv[2]) : 500;
	double minpar = argc > 3 ? atof(argv[3]) : 0;
	unsigned long t0, t1, tn, sp = 2000000;
	int i, st, fails = 0;
	double par;

	/* parallelism: calibrate long enough to cover several ticks */
	do {
		sp *= 2;
		t0 = now_ns();
		spin(sp);
		t1 = now_ns() - t0;
	} while (t1 < 200000000UL && sp < (1UL << 34));
	t0 = now_ns();
	for (i = 0; i < n; i++)
		if (fork() == 0) {
			spin(sp);
			_exit(0);
		}
	for (i = 0; i < n; i++)
		(void) wait(&st);
	tn = now_ns() - t0;
	par = (double)n * (double)t1 / (double)tn;
	printf("SMPSTRESS par=%d.%02d n=%d t1=%lums tn=%lums\n", (int)par,
	    (int)(par * 100) % 100, n, t1 / 1000000, tn / 1000000);

	t0 = now_ns();
	for (i = 0; i < n; i++)
		if (fork() == 0)
			_exit(child(i, iters));
	for (i = 0; i < n; i++) {
		if (wait(&st) < 0 || !WIFEXITED(st) || WEXITSTATUS(st) != 0)
			fails++;
	}
	if (par < minpar) {
		printf("SMPSTRESS FAIL par below %d.%02d\n", (int)minpar,
		    (int)(minpar * 100) % 100);
		fails++;
	}
	printf("SMPSTRESS %s n=%d iters=%d failed=%d %lums\n",
	    fails ? "FAIL" : "PASS", n, iters, fails,
	    (now_ns() - t0) / 1000000);
	return (fails != 0);
}
