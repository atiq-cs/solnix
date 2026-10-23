/*
 * newlib hides CLOCK_MONOTONIC and clock_gettime behind _POSIX_MONOTONIC_CLOCK /
 * _POSIX_TIMERS, which its riscv64 bare-metal config does not define. The solnix
 * kernel HAS both (uts/syscall.c SYS_clock_gettime), so expose them.
 */
#ifndef _POSIX_TIMERS
#define	_POSIX_TIMERS 1
#endif
#ifndef _POSIX_MONOTONIC_CLOCK
#define	_POSIX_MONOTONIC_CLOCK 200112L
#endif
#include_next <time.h>
