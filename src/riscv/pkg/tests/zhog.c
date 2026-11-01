/*
 * zhog.c -- rvpre repro driver: start NHOG CPU-bound children (integer or FP
 * spin), then run PROG N times in sequence and report each exit, then kill the
 * hogs. The hogs keep the run queue non-empty, so every clock tick preempts
 * PROG (the condition the netd thread creates).
 *   zhog <nhog> <i|f|r|s> <nruns> <prog> [args...]
 */
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/wait.h>

static char *env[] = { "PATH=/bin", "HOME=/", NULL };

/* i: integer spin storing to its stack; f: FP spin; r: register-only spin
 * (no memory stores); s: sleeps in read() on a pipe nobody writes. */
static void
hog(int kind)
{
	volatile unsigned long x = 0;
	volatile double d = 1.0;
	unsigned long r = 1;
	int pfd[2];
	char c;

	if (kind == 's' && pipe(pfd) == 0)
		for (;;)
			(void) read(pfd[0], &c, 1);
	for (;;) {
		if (kind == 'f')
			d = d * 1.0000001 + 0.5;
		else if (kind == 'r')
			__asm__ __volatile__("mul %0, %0, %1\n\taddi %0, %0, 7"
			    : "+r"(r) : "r"(2862933555777941757UL));
		else
			x = x * 2862933555777941757UL + 3037000493UL;
	}
}

int
main(int argc, char **argv)
{
	int nhog, kind, n, i, ok = 0, pids[16];

	if (argc < 5) {
		printf("usage: zhog nhog i|f nruns prog [args]\n");
		return (2);
	}
	nhog = atoi(argv[1]);
	kind = argv[2][0];
	n = atoi(argv[3]);
	if (nhog > 16)
		nhog = 16;
	for (i = 0; i < nhog; i++) {
		pids[i] = fork();
		if (pids[i] == 0)
			hog(kind);
	}
	for (i = 0; i < n; i++) {
		int st = 0, pid = fork(), code;

		if (pid == 0) {
			execve(argv[4], &argv[4], env);
			_exit(127);
		}
		code = (pid > 0 && waitpid(pid, &st, 0) == pid &&
		    WIFEXITED(st)) ? WEXITSTATUS(st) : -1;
		printf("ZHOG run %d exit=%d\n", i, code);
		if (code == 0)
			ok++;
	}
	for (i = 0; i < nhog; i++) {
		int st;

		if (pids[i] > 0) {
			kill(pids[i], SIGKILL);
			(void) waitpid(pids[i], &st, 0);
		}
	}
	printf("ZHOG DONE %d/%d\n", ok, n);
	return (ok == n ? 0 : 1);
}
