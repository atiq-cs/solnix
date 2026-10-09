/*
 * obsd_ushim.h -- a userland (pthread) model of the illumos kernel
 * primitives obsd_time.c uses, so its sleep queue can be tested as a
 * normal program (test/test_sleep.c). Each primitive keeps its illumos
 * contract as far as obsd_time.c relies on it:
 *   cv_timedwait_hires(.., deadline, .., CALLOUT_FLAG_ABSOLUTE) returns -1
 *     on timeout, >0 otherwise; deadline is absolute gethrtime() ns;
 *   cv_wait_sig / cv_timedwait_sig_hrtime return 0 when "a signal" is
 *     pending: modelled by a per-thread flag the test raises, since a
 *     userland thread has no illumos lwp signal state.
 */
#ifndef _OBSD_USHIM_H
#define _OBSD_USHIM_H

#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <errno.h>
#include <time.h>
#include <assert.h>
#include <sys/queue.h>

#ifndef __sun
typedef int64_t hrtime_t;
typedef unsigned int uint_t;
#endif
typedef pthread_mutex_t kmutex_t;
typedef pthread_cond_t kcondvar_t;

#define MUTEX_DRIVER	0
#define CV_DRIVER	0
#define CALLOUT_FLAG_ABSOLUTE	2
#define ASSERT(x)	assert(x)
#define MUTEX_HELD(m)	1
#ifndef MIN
#define MIN(a, b)	((a) < (b) ? (a) : (b))
#define MAX(a, b)	((a) > (b) ? (a) : (b))
#endif
#define INFSLP		UINT64_MAX
#define PCATCH		0x100
#define PNORELOCK	0x200
#define P_SINTR		0x00000080
#define P_INSCHED	0x00000400
#define SSLEEP		1
#define SONPROC		6
#define nsec_per_tick	10000000L

#ifndef __sun			/* illumos libc has gethrtime(3C) */
static inline hrtime_t
gethrtime(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ((hrtime_t)ts.tv_sec * 1000000000LL + ts.tv_nsec);
}
#endif

static inline void
mutex_init(kmutex_t *m, void *n, int t, void *a)
{
	(void) n; (void) t; (void) a;
	pthread_mutex_init(m, NULL);
}
/* obsd_time.c passes both kmutex_t * and OpenBSD struct mutex * (which is
 * kmutex_t in the kernel build); here struct mutex wraps the same type. */
#define mutex_enter(m)	pthread_mutex_lock((pthread_mutex_t *)(m))
#define mutex_exit(m)	pthread_mutex_unlock((pthread_mutex_t *)(m))
#define cv_signal(c)	pthread_cond_signal(c)

static inline void
cv_init(kcondvar_t *c, void *n, int t, void *a)
{
	pthread_condattr_t at;

	(void) n; (void) t; (void) a;
	pthread_condattr_init(&at);
	pthread_condattr_setclock(&at, CLOCK_MONOTONIC);
	pthread_cond_init(c, &at);
}

/* The "signal pending" flag of the calling thread (see header): a
 * thread-local pointer so another thread can raise it. */
extern __thread volatile int *ushim_sigp;
#define ushim_sigpending	(ushim_sigp != NULL && *ushim_sigp)

static inline void
cv_wait(kcondvar_t *c, kmutex_t *m)
{
	pthread_cond_wait(c, m);
}

static inline int
cv_timedwait_hires(kcondvar_t *c, kmutex_t *m, hrtime_t deadline,
    hrtime_t res, int flag)
{
	struct timespec ts;

	(void) res; (void) flag;
	if (gethrtime() >= deadline)
		return (-1);
	ts.tv_sec = deadline / 1000000000LL;
	ts.tv_nsec = deadline % 1000000000LL;
	if (pthread_cond_timedwait(c, m, &ts) == ETIMEDOUT)
		return (-1);
	return (1);
}

/* A signal is noticed at the next wakeup/poll; poll every 1 ms. */
static inline int
cv_timedwait_sig_hrtime(kcondvar_t *c, kmutex_t *m, hrtime_t deadline)
{
	hrtime_t slice;

	if (ushim_sigpending)
		return (0);
	slice = MIN(deadline, gethrtime() + 1000000);
	if (cv_timedwait_hires(c, m, slice, 1, 2) < 0 && slice >= deadline)
		return (-1);
	return (ushim_sigpending ? 0 : 1);
}

static inline int
cv_wait_sig(kcondvar_t *c, kmutex_t *m)
{
	return (cv_timedwait_sig_hrtime(c, m, INT64_MAX / 2));
}

static inline void
atomic_or_uint(volatile uint_t *p, uint_t v)
{
	__atomic_fetch_or(p, v, __ATOMIC_SEQ_CST);
}

static inline void
atomic_and_uint(volatile uint_t *p, uint_t v)
{
	__atomic_fetch_and(p, v, __ATOMIC_SEQ_CST);
}

/* The OpenBSD types obsd_time.c touches (same fields as obsd_kern.h). */
struct mutex { kmutex_t m; };
struct proc {
	const volatile void	*p_wchan;
	int			p_flag;
	char			p_stat;
	TAILQ_ENTRY(proc)	p_runq;
	kcondvar_t		p_cv;
	const char		*p_wmesg;
};
extern struct proc *ushim_curproc(void);
#define curproc		ushim_curproc()
#define wakeup(c)	wakeup_n((c), -1)
#define wakeup_one(c)	wakeup_n((c), 1)
extern void wakeup_n(const volatile void *, int);

#endif /* _OBSD_USHIM_H */
