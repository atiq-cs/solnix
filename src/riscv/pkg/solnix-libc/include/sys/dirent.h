/*
 * The solnix riscv64 kernel has no getdents and no directory vnodes reachable
 * from userland, so opendir() fails ENOSYS (glue.c). Declared so code compiles.
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
