/*
 * echo.c — solnix riscv64 /bin/echo. Prints its arguments (argv delivered
 * across execve since R-P9). R-P10: linked against libc-riscv.
 */
#include "libc.h"

int
main(int argc, char **argv)
{
	int i;

	for (i = 1; i < argc; i++) {
		printf("%s", argv[i]);
		if (i + 1 < argc)
			printf(" ");
	}
	printf("\n");
	return (0);
}
