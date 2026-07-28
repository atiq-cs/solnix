/*
 * hello.c — solnix riscv64 /bin/hello (R-P8 fork/exec proof child).
 * Execed by /sbin/init's forked child; prints a line and exits 0.
 */
#include "libu.h"

int
main(int argc, char **argv)
{
	(void) argc; (void) argv;
	uputs("hello from child: /bin/hello running in U-mode (pid ");
	uputdec((unsigned long)ugetpid());
	uputs(")\n");
	return (0);
}
