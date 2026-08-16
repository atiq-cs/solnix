/*
 * stat.c -- solnix riscv64 libc stat/fstat/lstat.  The kernel's SYS_stat/
 * SYS_fstat write ONLY the file size (a single unsigned long) into the buffer
 * pointer; these wrappers pass a local size word, then fill a full struct stat,
 * synthesizing st_mode (a regular file, 0644, or a directory when the size word
 * is reported for a dir -- see below), st_blksize, and st_blocks so the POSIX
 * S_ISREG()/io_blksize() a real coreutils util uses behave.  lstat == stat (no
 * symlinks in the reduced fs).
 *
 * CRIB PROVENANCE: the "trap, then materialize a struct stat from the reduced
 * getattr" shape is the illumos libc stat()/xstat cooking cheaper kernel getattr
 * output into the POSIX struct; here the kernel reports size only, so mode is
 * synthesized (regular file) -- it grows to a real mode when VOP_GETATTR does.
 */
#include <sys/stat.h>
#include <sys/systrap.h>

extern int errno;

static int
__fill(struct stat *sb, unsigned long size, int rc, int is_chr)
{
	if (rc < 0 && rc > -256) {
		errno = -rc;
		return (-1);
	}
	if (sb == 0)
		return (0);
	sb->st_dev = 0;
	sb->st_ino = 0;
	sb->st_mode = is_chr ? (S_IFCHR | 0666) : (S_IFREG | 0644);
	sb->st_nlink = 1;
	sb->st_uid = 0;
	sb->st_gid = 0;
	sb->st_rdev = 0;
	sb->st_size = (off_t)size;
	sb->st_blksize = 4096;
	sb->st_blocks = (blkcnt_t)((size + 511) / 512);
	sb->st_atime = 0;
	sb->st_mtime = 0;
	sb->st_ctime = 0;
	return (0);
}

int
stat(const char *path, struct stat *sb)
{
	unsigned long size = 0;
	long rc = __systrap2(SYS_stat, (long)path, (long)&size);
	return (__fill(sb, size, (int)rc, 0));
}

int
fstat(int fd, struct stat *sb)
{
	unsigned long size = 0;
	long rc = __systrap2(SYS_fstat, (long)fd, (long)&size);
	/* fd 0/1/2 are the console tty: report char-special so a util's
	   "input file == output file" (dev/ino) guard does not misfire when
	   the reduced kernel getattr cannot distinguish dev/ino. */
	return (__fill(sb, size, (int)rc, (fd >= 0 && fd <= 2)));
}

int
lstat(const char *path, struct stat *sb)
{
	return (stat(path, sb));	/* no symlinks in the reduced fs */
}
