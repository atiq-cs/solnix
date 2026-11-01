/*
 * FreeBSD-isms the vendored iwmbtfw expects beyond endian.h (solnix compat,
 * new code). Force-included (-include) before every upstream file.
 */
#ifndef _SOLNIX_IWMBT_COMPAT_H
#define	_SOLNIX_IWMBT_COMPAT_H

#include <sys/types.h>
#include <sys/time.h>
#include <time.h>

#ifndef nitems
#define	nitems(x)	(sizeof (x) / sizeof ((x)[0]))
#endif

#ifndef timespecadd
#define	timespecadd(a, b, r) do {					\
	(r)->tv_sec = (a)->tv_sec + (b)->tv_sec;			\
	(r)->tv_nsec = (a)->tv_nsec + (b)->tv_nsec;			\
	if ((r)->tv_nsec >= 1000000000L) {				\
		(r)->tv_sec++;						\
		(r)->tv_nsec -= 1000000000L;				\
	}								\
} while (0)
#define	timespecsub(a, b, r) do {					\
	(r)->tv_sec = (a)->tv_sec - (b)->tv_sec;			\
	(r)->tv_nsec = (a)->tv_nsec - (b)->tv_nsec;			\
	if ((r)->tv_nsec < 0) {						\
		(r)->tv_sec--;						\
		(r)->tv_nsec += 1000000000L;				\
	}								\
} while (0)
#define	timespeccmp(a, b, op)						\
	(((a)->tv_sec == (b)->tv_sec) ?					\
	    ((a)->tv_nsec op (b)->tv_nsec) : ((a)->tv_sec op (b)->tv_sec))
#endif

#endif
