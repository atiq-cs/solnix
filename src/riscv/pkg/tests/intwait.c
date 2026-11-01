/*
 * intwait.c -- rvtty3c: the shell's ^C pattern through libc. The parent (a session leader with the pty as its
 * ctty) forks a child into its own foreground pgrp that sleeps 100 s; the master writes ^C; the parent's
 * waitpid must return within 3 s with the child dead of SIGINT, and the parent must then read the next line.
 */
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#include <sys/wait.h>

int
main(void)
{
	int m = posix_openpt(O_RDWR | O_NOCTTY), st = 0;
	struct termios t;
	pid_t sh, c;
	time_t t0;

	grantpt(m); unlockpt(m);
	if ((sh = fork()) == 0) {			/* the "shell" */
		char *n = ptsname(m), b[8];
		int s;

		setsid();
		s = open(n, O_RDWR);			/* ctty */
		tcgetattr(s, &t); t.c_lflag |= ISIG | ICANON; tcsetattr(s, TCSANOW, &t);
		signal(SIGINT, SIG_IGN);
		if ((c = fork()) == 0) {
			setpgid(0, 0); tcsetpgrp(s, getpid());
			signal(SIGINT, SIG_DFL);
			sleep(100);
			_exit(7);
		}
		setpgid(c, c);
		t0 = time(NULL);
		if (waitpid(c, &st, 0) != c) { printf("INTWAIT FAIL waitpid\n"); _exit(1); }
		printf("INTWAIT child done in %ld s status %d\n", (long)(time(NULL) - t0), WEXITSTATUS(st));
		tcsetpgrp(s, getpid());
		if (read(s, b, 3) != 3 || strncmp(b, "ok\n", 3)) { printf("INTWAIT FAIL read after\n"); _exit(2); }
		_exit(time(NULL) - t0 < 3 && WEXITSTATUS(st) == 130 ? 0 : 3);
	}
	sleep(1);
	write(m, "\003", 1);
	sleep(1);
	write(m, "ok\n", 3);
	waitpid(sh, &st, 0);
	printf("INTWAIT %s rc=%d\n", WEXITSTATUS(st) == 0 ? "PASS" : "FAIL", WEXITSTATUS(st));
	return (0);
}
