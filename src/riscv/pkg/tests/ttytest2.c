/* ttytest2 <mode>: one console-input operation per run, so a hang names the call.
 *   r0: read(0)   r2: read(2)   p0: poll({0,POLLIN}, 3000) then read(0)
 *   k0: raw kernel read(0) bypassing the glue's fd table */
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <termios.h>
#include <errno.h>
int
main(int argc, char **argv)
{
	char b[32];
	long n = -9, r;
	struct pollfd p = { 0, POLLIN, 0 };

	memset(b, 0, sizeof (b));
	if (argc > 2) {		/* prefix op: what ttytest did first */
		struct termios t;
		int tr = tcgetattr(2, &t);
		printf("tty2 %s: prefix tcgetattr=%d errno=%d\n", argv[1], tr, errno);
	}
	printf("tty2 %s: start\n", argv[1]); fflush(stdout);
	if (strcmp(argv[1], "r0") == 0) n = read(0, b, 31);
	else if (strcmp(argv[1], "r2") == 0) n = read(2, b, 31);
	else if (strcmp(argv[1], "p0") == 0) {
		r = poll(&p, 1, 3000);
		printf("tty2 p0: poll=%ld rev=%#x\n", r, p.revents); fflush(stdout);
		n = read(0, b, 31);
	} else if (strcmp(argv[1], "k0") == 0) {
		register long a0 __asm__("a0") = 0, a1 __asm__("a1") = (long)b,
		    a2 __asm__("a2") = 31, a7 __asm__("a7") = 63;
		__asm__ __volatile__("ecall" : "+r"(a0) : "r"(a1), "r"(a2), "r"(a7) : "memory");
		n = a0;
	}
	printf("tty2 %s: n=%ld [%s]\n", argv[1], n, strtok(b, "\n"));
	return (0);
}
