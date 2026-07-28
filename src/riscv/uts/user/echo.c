/*
 * echo.c — solnix riscv64 /bin/echo (R-P8 util). Prints its arguments.
 *
 * R-P8 does not pass argv across execve yet (argc=0 in U-mode), so as a real
 * util it reads its "argument" from a fixed message; the shell prints the echo
 * text itself and execs echo mainly to prove exec of a second util. When argv
 * plumbing lands (R-P9) this prints argv[1..].
 */
#include "libu.h"

int
main(int argc, char **argv)
{
	int i;

	if (argc <= 1) {
		uputs("\n");
		return (0);
	}
	for (i = 1; i < argc; i++) {
		uputs(argv[i]);
		if (i + 1 < argc)
			uputs(" ");
	}
	uputs("\n");
	return (0);
}
