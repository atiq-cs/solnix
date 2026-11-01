/* holetest <file> <MB> <msync 0|1>: write a new file through mmap (as ld/go's linker do), munmap,
 * close, then immediately ask SEEK_DATA/SEEK_HOLE. Prints the extents ZFS reports; a "hole" over
 * bytes we wrote is the bug (cp/install skip it and write zeros). */
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <sys/mman.h>
int main(int argc, char **argv) {
	const char *p = argv[1]; size_t n = (size_t)atoi(argv[2]) << 20; int ms = atoi(argv[3]);
	int fd = open(p, O_RDWR | O_CREAT | O_TRUNC, 0644);
	if (fd < 0 || ftruncate(fd, n) != 0) { perror("open/ftruncate"); return 2; }
	unsigned char *m = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (m == MAP_FAILED) { perror("mmap"); return 2; }
	for (size_t i = 0; i < n; i++) m[i] = (unsigned char)(i * 131 + 7) | 1;	/* never zero */
	if (ms) msync(m, n, MS_SYNC);
	munmap(m, n); close(fd);
	fd = open(p, O_RDONLY);
	off_t o = 0, holes = 0; int ext = 0;
	while (o < (off_t)n) {
		off_t d = lseek(fd, o, SEEK_DATA); if (d < 0) { holes += n - o; break; }
		if (d > o) holes += d - o;
		off_t h = lseek(fd, d, SEEK_HOLE); if (h < 0) h = n;
		ext++; o = h;
	}
	printf("%s msync=%d size=%zu data-extents=%d reported-hole-bytes=%lld %s\n", p, ms, n, ext, (long long)holes, holes ? "BUG" : "ok");
	close(fd); return holes ? 1 : 0;
}
