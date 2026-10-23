/*
 * fstest.c -- the file operations sbase ed (and any editor) needs, on the kernel
 * ramfs, through the glue: mkstemp, write, lseek, read back, reopen by name, and
 * fopen/getline of a file served by the ustar root. Prints one ok/FAIL per step.
 */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define	CK(c, m) do { if (c) printf("fstest ok: %s\n", m); \
	else { printf("fstest FAIL: %s\n", m); bad++; } } while (0)

int
main(void)
{
	char tmpl[] = "/tmp/ed.XXXXXX", buf[64];
	char *line = NULL;
	size_t cap = 0;
	int fd, fd2, bad = 0, n = 0;
	FILE *f;

	fd = mkstemp(tmpl);
	printf("fstest: mkstemp -> fd %d name %s\n", fd, tmpl);
	CK(fd >= 0, "mkstemp");
	CK(write(fd, "alpha\nbeta\n", 11) == 11, "write 11");
	CK(lseek(fd, 0, SEEK_END) == 11, "lseek END == 11");
	CK(lseek(fd, 6, SEEK_SET) == 6, "lseek SET 6");
	memset(buf, 0, sizeof (buf));
	CK(read(fd, buf, 5) == 5 && memcmp(buf, "beta\n", 5) == 0, "read back 'beta'");
	fd2 = open(tmpl, O_RDONLY);
	memset(buf, 0, sizeof (buf));
	CK(fd2 >= 0 && read(fd2, buf, 11) == 11 && strcmp(buf, "alpha\nbeta\n") == 0,
	    "reopen by name, read all");
	close(fd2);
	close(fd);
	f = fopen("/etc/words", "r");
	CK(f != NULL, "fopen /etc/words");
	while (f && getline(&line, &cap, f) > 0)
		n++;
	CK(n == 9, "getline counts 9 lines");
	printf("FSTEST %s\n", bad ? "FAIL" : "PASS");
	return (bad != 0);
}
