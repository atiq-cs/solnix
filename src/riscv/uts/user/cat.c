/*
 * cat.c — solnix riscv64 /bin/cat (R-P8 util). Reads /etc/motd and writes it
 * to stdout (R-P8 has no argv, so it cats a fixed file to prove open/read/write
 * from an execed util; argv-driven cat is R-P9).
 */
#include "libu.h"

int
main(int argc, char **argv)
{
	char buf[128];
	int fd;
	long n;

	(void) argc; (void) argv;
	fd = (int)uopen("/etc/motd", O_RDONLY);
	if (fd < 0) {
		uputs("cat: cannot open /etc/motd\n");
		return (1);
	}
	while ((n = uread(fd, buf, sizeof (buf))) > 0)
		uwrite(1, buf, (unsigned long)n);
	uclose(fd);
	return (0);
}
