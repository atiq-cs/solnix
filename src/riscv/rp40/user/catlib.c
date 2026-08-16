/*
 * catlib.c -- the gnulib lib/ helpers cat.c links (beyond the real libc):
 * full_write() (write(2) in a loop until all bytes go out or an error) and
 * safe_read() (read(2) retrying nothing on the reduced kernel, returning the
 * byte count, 0 at EOF, or SAFE_READ_ERROR on error).  These are the standard
 * gnulib routines reduced to the reduced kernel (no EINTR retry loop needed --
 * the kernel does not deliver signals across these blocking calls here).
 *
 * CRIB PROVENANCE: full_write = gnulib lib/full-write.c (loop over safe_write
 * until count is exhausted); safe_read = gnulib lib/safe-read.c (a read that
 * maps a short/zero return through), reduced.
 */
#include <unistd.h>

#define SAFE_READ_ERROR ((size_t)-1)

size_t
full_write(int fd, const void *buf, size_t count)
{
	const char *p = buf;
	size_t total = 0;
	while (total < count) {
		ssize_t n = write(fd, p + total, count - total);
		if (n <= 0)
			break;
		total += (size_t)n;
	}
	return (total);
}

size_t
safe_read(int fd, void *buf, size_t count)
{
	ssize_t n = read(fd, buf, count);
	if (n < 0)
		return (SAFE_READ_ERROR);
	return ((size_t)n);
}
