/* rvlogin: no resource limits in the kernel: getrlimit reports infinity, setrlimit is accepted only
 * for RLIMIT_CORE (no core dumps exist, so 0 is already true) [STUB]. */
#ifndef _SYS_RESOURCE_H
#define	_SYS_RESOURCE_H
#include <sys/types.h>
#include <sys/time.h>
typedef unsigned long rlim_t;
struct rlimit { rlim_t rlim_cur, rlim_max; };
struct rusage { struct timeval ru_utime, ru_stime; long ru_pad[14]; };
#define	RLIM_INFINITY (~0UL)
#define	RLIMIT_CPU 0
#define	RLIMIT_FSIZE 1
#define	RLIMIT_DATA 2
#define	RLIMIT_STACK 3
#define	RLIMIT_CORE 4
#define	RLIMIT_NOFILE 7
#define	PRIO_PROCESS 0
int getrlimit(int, struct rlimit *);
int setrlimit(int, const struct rlimit *);
int getpriority(int, int);
int setpriority(int, int, int);
#endif
