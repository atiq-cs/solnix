/*
 * dirent.h -- solnix riscv64 libc directory reading.  A DIR handle wraps an
 * open directory fd; readdir() pulls one basename per call through the kernel's
 * SYS_getdents (which returns a single entry name per call, 0 at end-of-dir).
 *
 * CRIB PROVENANCE: the opendir/readdir/closedir + struct dirent contract is
 * illumos <dirent.h> / usr/src/lib/libc getdents-backed readdir, reduced to the
 * kernel's one-name-per-getdents ABI (no d_ino/d_reclen packing on the kernel
 * side yet -- d_ino is synthesized).
 */
#ifndef _DIRENT_H
#define _DIRENT_H
#include <sys/types.h>

#define MAXNAMLEN 255

struct dirent {
	ino_t		d_ino;			/* synthesized (kernel: name only) */
	off_t		d_off;			/* entry index */
	unsigned short	d_reclen;
	char		d_name[MAXNAMLEN + 1];
};

typedef struct __DIR DIR;
struct __DIR {
	int		fd;
	long		index;
	struct dirent	de;
};

DIR *opendir(const char *path);
struct dirent *readdir(DIR *d);
int closedir(DIR *d);

#endif /* _DIRENT_H */
