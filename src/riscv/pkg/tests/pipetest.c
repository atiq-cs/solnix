/*
 * pipetest.c -- the pipe + fork + dup2 shape a shell pipeline uses, through the
 * glue's user fd table. A: child dup2(p[1],1) + printf, parent reads p[0].
 * B: two children (writer dup2 to 1, reader dup2 to 0), parent only waits -- dash's
 * evalpipe exactly. C: B, but the reader exec()s nothing; it reports what it read.
 */
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>

int
main(void)
{
	int p[2], st, ok = 1, r1, r2;
	char buf[64];
	ssize_t n;

	pipe(p);
	if (fork() == 0) {
		close(p[0]); dup2(p[1], 1); close(p[1]);
		printf("A-from-child\n"); fflush(stdout);
		_exit(0);
	}
	close(p[1]);
	memset(buf, 0, sizeof (buf));
	n = read(p[0], buf, sizeof (buf) - 1);
	close(p[0]);
	wait(&st);
	fprintf(stderr, "pipetest A: parent read %ld [%s]\n", (long)n, strtok(buf, "\n"));
	ok &= n == 13;

	pipe(p);
	if ((r1 = fork()) == 0) {
		close(p[0]); dup2(p[1], 1); close(p[1]);
		printf("B-payload\n"); fflush(stdout);
		_exit(0);
	}
	if ((r2 = fork()) == 0) {
		close(p[1]); dup2(p[0], 0); close(p[0]);
		memset(buf, 0, sizeof (buf));
		n = read(0, buf, sizeof (buf) - 1);
		fprintf(stderr, "pipetest B: reader got %ld [%s]\n", (long)n, strtok(buf, "\n"));
		_exit(n == 10 ? 0 : 1);
	}
	close(p[0]); close(p[1]);
	waitpid(r1, &st, 0);
	waitpid(r2, &st, 0);
	ok &= WEXITSTATUS(st) == 0;
	printf("PIPETEST %s\n", ok ? "PASS" : "FAIL");
	return (!ok);
}
