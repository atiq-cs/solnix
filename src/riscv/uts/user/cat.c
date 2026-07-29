/*
 * cat.c — solnix riscv64 /bin/cat. Reads argv[1] (or /etc/motd if none) and
 * writes it to stdout. R-P10: linked against libc-riscv.
 */
#include "libc.h"

int
main(int argc, char **argv)
{
	char buf[128];
	const char *path = (argc > 1) ? argv[1] : "/etc/motd";
	int fd;
	long n;

	fd = open(path, O_RDONLY);
	if (fd < 0) {
		printf("cat: cannot open %s\n", path);
		return (1);
	}
	while ((n = read(fd, buf, sizeof (buf))) > 0)
		write(1, buf, (size_t)n);
	close(fd);
	return (0);
}
