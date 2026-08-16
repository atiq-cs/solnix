/*
 * dir.c -- solnix riscv64 libc opendir/readdir/closedir.  opendir() open(2)s
 * the directory path; readdir() issues one SYS_getdents (which returns a single
 * entry basename, or 0 at end-of-directory) per call, materializing a struct
 * dirent (d_ino synthesized from the entry index, since the reduced kernel
 * getdents reports the name only).  closedir() close(2)s the fd + frees DIR.
 *
 * CRIB PROVENANCE: opendir=open+alloc, readdir=getdents-decode-into-dirent,
 * closedir=close+free is the illumos libc dirent implementation
 * (usr/src/lib/libc/port/gen/{opendir,readdir,closedir}.c) reduced to the
 * kernel's one-name-per-getdents interface.
 */
#include <dirent.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/systrap.h>

DIR *
opendir(const char *path)
{
	int fd = open(path, 0);		/* O_RDONLY */
	DIR *d;
	if (fd < 0)
		return ((void *)0);
	d = malloc(sizeof(*d));
	if (d == (void *)0) {
		close(fd);
		return ((void *)0);
	}
	d->fd = fd;
	d->index = 0;
	return (d);
}

struct dirent *
readdir(DIR *d)
{
	long n;
	if (d == (void *)0)
		return ((void *)0);
	/* one getdents == one entry basename into d_name (0 == end-of-dir). */
	n = __systrap3(SYS_getdents, d->fd, (long)d->de.d_name, MAXNAMLEN);
	if (n <= 0)
		return ((void *)0);
	d->de.d_name[n] = 0;
	d->de.d_ino = (ino_t)(d->index + 1);	/* synthesized */
	d->de.d_off = d->index;
	d->de.d_reclen = (unsigned short)n;
	d->index++;
	return (&d->de);
}

int
closedir(DIR *d)
{
	int r;
	if (d == (void *)0)
		return (-1);
	r = close(d->fd);
	free(d);
	return (r);
}
