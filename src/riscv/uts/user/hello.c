/*
 * hello.c — solnix riscv64 /bin/hello (fork/exec proof child).
 * R-P10: linked against libc-riscv (printf).
 */
#include "libc.h"

int
main(int argc, char **argv)
{
	(void) argc; (void) argv;
	printf("hello from child: /bin/hello running in U-mode (pid %d)\n",
	    getpid());
	return (0);
}
