/* newlib 4.5.0 riscv64 <limits.h> lacks SSIZE_MAX (POSIX); ssize_t is long here. */
#include_next <limits.h>
#ifndef SSIZE_MAX
#define	SSIZE_MAX	__LONG_MAX__
#endif
#ifndef _POSIX_ARG_MAX
#define	_POSIX_ARG_MAX		4096
#define	_POSIX_PATH_MAX		256
#define	_POSIX_NAME_MAX		14
#define	_POSIX_HOST_NAME_MAX	255
#endif
#ifndef NZERO
#define	NZERO			20
#endif
