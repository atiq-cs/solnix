/*
 * sys/stat.h -- solnix riscv64 libc file-status.  The reduced kernel stat ABI
 * (SYS_stat/SYS_fstat) reports only the file size (it writes st_size into a
 * single unsigned long); the libc wrapper fills a struct stat, synthesizing a
 * plausible st_mode (regular file, mode 0644) so the S_ISREG()/mode macros a
 * real coreutils util uses resolve, and a nominal st_blksize for io_blksize.
 *
 * CRIB PROVENANCE: the struct stat member set + S_IF* / S_ISREG macros are the
 * illumos/POSIX <sys/stat.h> contract, reduced to what fits the size-only
 * kernel getattr; a fuller stat grows when the kernel VOP_GETATTR reports
 * mode/dev/ino/times.
 */
#ifndef _SYS_STAT_H
#define _SYS_STAT_H
#include <sys/types.h>

typedef long time_t;

struct stat {
	dev_t		st_dev;
	ino_t		st_ino;
	mode_t		st_mode;
	nlink_t		st_nlink;
	uid_t		st_uid;
	gid_t		st_gid;
	dev_t		st_rdev;
	off_t		st_size;
	blksize_t	st_blksize;
	blkcnt_t	st_blocks;
	time_t		st_atime;
	time_t		st_mtime;
	time_t		st_ctime;
};

#define S_IFMT   0170000
#define S_IFDIR  0040000
#define S_IFCHR  0020000
#define S_IFBLK  0060000
#define S_IFREG  0100000
#define S_IFIFO  0010000
#define S_IFLNK  0120000
#define S_IFSOCK 0140000

#define S_ISDIR(m)  (((m) & S_IFMT) == S_IFDIR)
#define S_ISREG(m)  (((m) & S_IFMT) == S_IFREG)
#define S_ISCHR(m)  (((m) & S_IFMT) == S_IFCHR)
#define S_ISBLK(m)  (((m) & S_IFMT) == S_IFBLK)
#define S_ISFIFO(m) (((m) & S_IFMT) == S_IFIFO)
#define S_ISLNK(m)  (((m) & S_IFMT) == S_IFLNK)

int stat(const char *path, struct stat *sb);
int fstat(int fd, struct stat *sb);
int lstat(const char *path, struct stat *sb);

#endif /* _SYS_STAT_H */
