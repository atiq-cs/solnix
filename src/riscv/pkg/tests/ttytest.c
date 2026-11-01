/*
 * ttytest.c -- what an interactive full-screen program needs from the console:
 * read keys from fd 2 (less's open_tty fallback) and fd 0, poll() on both, and
 * tcgetattr() (which tells the program whether it can go into raw mode).
 * Reports each result; the console input is fed by the harness (STDIN_FILE).
 */
#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

int
main(void)
{
	struct termios t;
	struct pollfd p[2] = { { 0, POLLIN, 0 }, { 2, POLLIN, 0 } };
	char b[32];
	ssize_t n;
	int r;

	r = tcgetattr(2, &t);
	printf("ttytest: tcgetattr(2) = %d errno=%d (%s)\n", r, r ? errno : 0,
	    r ? strerror(errno) : "ok");
	/* read FIRST (proves bytes are arriving), then poll for the next line */
	memset(b, 0, sizeof (b));
	n = read(2, b, sizeof (b) - 1);
	printf("ttytest: read(2) = %ld [%s]\n", (long)n, strtok(b, "\n"));
	r = poll(p, 2, 3000);
	printf("ttytest: poll(0,2) = %d rev0=%#x rev2=%#x\n", r, p[0].revents, p[1].revents);
	p[0].revents = 0;
	r = poll(p, 1, 0);
	printf("ttytest: poll(0) timeout=0 = %d rev0=%#x\n", r, p[0].revents);
	memset(b, 0, sizeof (b));
	n = read(0, b, sizeof (b) - 1);
	printf("ttytest: read(0) = %ld [%s]\n", (long)n, strtok(b, "\n"));
	printf("TTYTEST DONE\n");
	return (0);
}
