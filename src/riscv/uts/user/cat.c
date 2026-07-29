/*
 * cat.c — solnix riscv64 /bin/cat. Reads argv[1] (or /etc/motd if none) and
 * writes it to stdout. R-P10: linked against libc-riscv.
 */
#include "libc.h"

int
main(int argc, char **argv)
{
	char buf[128];
	int fd;
	long n;

	/* No arg: copy stdin (fd 0) to stdout — makes `echo x | cat` stream. */
	if (argc <= 1) {
		while ((n = read(0, buf, sizeof (buf))) > 0)
			write(1, buf, (size_t)n);
		return (0);
	}
	fd = open(argv[1], O_RDONLY);
	if (fd < 0) {
		printf("cat: cannot open %s\n", argv[1]);
		return (1);
	}
	while ((n = read(fd, buf, sizeof (buf))) > 0)
		write(1, buf, (size_t)n);
	close(fd);
	return (0);
}
