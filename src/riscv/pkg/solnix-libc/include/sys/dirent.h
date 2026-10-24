/*
 * Directories: the solnix riscv64 kernel's getdents64 (rvsh). DIR is the glue's
 * opaque handle (glue.c struct sdir); d_ino is the kernel's path hash.
 */
#ifndef _SYS_DIRENT_H
#define	_SYS_DIRENT_H
#include <sys/types.h>
struct dirent { ino_t d_ino; char d_name[256]; };
typedef struct { int dd_fd; } DIR;
DIR *opendir(const char *);
DIR *fdopendir(int);
struct dirent *readdir(DIR *);
int closedir(DIR *);
void rewinddir(DIR *);
int dirfd(DIR *);
#endif
