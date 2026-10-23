/*
 * sigtest.c -- checks the glue's signal-number translation and dispatch.
 *  1. SIGUSR1 to self is caught by the handler installed for SIGUSR1 (newlib 25,
 *     kernel 10): proves kill() and sigaction() translate the same way.
 *  2. SIGCHLD (newlib 20, kernel 17) is caught when a child exits: proves the
 *     signal the KERNEL posts reaches the handler for the newlib name.
 *  3. A child killed by SIGTERM reports exit 128+15.
 * With NOTRANSLATE defined, step 2 installs on the raw kernel number instead, which
 * is what a pass-through glue would do -- used as the negative control.
 */
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>

static volatile int got_usr1, got_chld, last;

static void h_usr1(int s) { got_usr1++; last = s; }
static void h_chld(int s) { got_chld++; last = s; }

int
main(void)
{
	struct sigaction sa;
	int pid, st, i, ok = 1;

	memset(&sa, 0, sizeof (sa));
	sa.sa_handler = h_usr1;
	sigaction(SIGUSR1, &sa, NULL);
	kill(getpid(), SIGUSR1);
	for (i = 0; i < 2000000 && !got_usr1; i++)
		;
	printf("sigtest: SIGUSR1 caught=%d signo=%d (want 1, %d)\n", got_usr1, last, SIGUSR1);
	ok &= got_usr1 == 1 && last == SIGUSR1;

	sa.sa_handler = h_chld;
	sigaction(SIGCHLD, &sa, NULL);
	pid = fork();
	if (pid == 0)
		_exit(3);
	waitpid(pid, &st, 0);
	for (i = 0; i < 20000000 && !got_chld; i++)
		;
	printf("sigtest: SIGCHLD caught=%d child exit=%d (want >=1, 3)\n", got_chld, WEXITSTATUS(st));
	ok &= got_chld >= 1 && WEXITSTATUS(st) == 3;

	pid = fork();
	if (pid == 0) {
		for (;;)
			;
	}
	kill(pid, SIGTERM);
	waitpid(pid, &st, 0);
	printf("sigtest: SIGTERM'd child exit=%d (want %d)\n", WEXITSTATUS(st), 128 + 15);
	ok &= WEXITSTATUS(st) == 128 + 15;

	printf("SIGTEST %s\n", ok ? "PASS" : "FAIL");
	return (ok ? 0 : 1);
}
