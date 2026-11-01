/* newlib 4.5.0 has no pty functions; glue.c provides them (rvtty3c, the illumos /dev/ptmx shape). */
#include_next <stdlib.h>
#ifndef _SOLNIX_STDLIB_EXTRA
#define	_SOLNIX_STDLIB_EXTRA
int posix_openpt(int);
int grantpt(int);
int unlockpt(int);
char *ptsname(int);
#endif
