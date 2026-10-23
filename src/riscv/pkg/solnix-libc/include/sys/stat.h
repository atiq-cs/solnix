/* newlib declares lstat/mknod only for SPU/rtems/cygwin; the solnix glue provides both. */
#include_next <sys/stat.h>
#ifndef _SOLNIX_SYS_STAT_EXTRA
#define	_SOLNIX_SYS_STAT_EXTRA
int lstat(const char *__restrict, struct stat *__restrict);
int mknod(const char *, mode_t, dev_t);
#endif
