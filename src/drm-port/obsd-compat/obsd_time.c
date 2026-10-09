/*
 * obsd_time.c -- OpenBSD's sleep queue on illumos kmutex/kcondvar:
 * sleep_setup/sleep_finish, tsleep/msleep/rwsleep (+ _nsec), wakeup,
 * wakeup_n, wakeup_proc and unsleep, and the jiffies counter. hz is the
 * illumos kernel variable and ticks reads ddi_get_lbolt() (obsd_kern.h).
 *
 * Model (the one OpenBSD kern_synch.c uses): a thread about to sleep is put
 * on a hashed queue keyed by its wait channel (any address), under one lock,
 * SCHED_LOCK. wakeup(chan) takes every thread whose p_wchan == chan off the
 * queue, sets its p_wchan to NULL and signals that thread's own condvar. A
 * sleeper waits until its own p_wchan is NULL. Two consequences that
 * OpenBSD's linux/wait.h depends on:
 *   - a wakeup that lands between sleep_setup() and sleep_finish() is not
 *     lost (wait_event checks its condition between the two calls);
 *   - a wakeup of another channel never wakes this thread, even when both
 *     channels hash to the same queue.
 * (The earlier body in obsd_kern.c broadcast one condvar per hash bucket and
 * had neither property: a wakeup before the cv_wait was lost.)
 *
 * Returns (OpenBSD): 0 woken; EWOULDBLOCK the timeout expired first; EINTR
 * a signal arrived and PCATCH was set. OpenBSD may also return ERESTART for
 * a signal; every drm/inteldrm caller tests both.
 * MAP: illumos reports a signal as cv_*_sig returning 0, which only happens
 * for a thread with an lwp (a user thread inside an ioctl). Kernel threads
 * sleep through it, as OpenBSD kernel threads do. A woken thread with a
 * signal pending returns 0, not EINTR (OpenBSD re-checks signals after a
 * wakeup and returns EINTR); every caller loops on its own condition, so it
 * sees the signal on its next sleep.
 * NOTE: one global lock for the queue, as on OpenBSD. Per-bucket locks are
 * the upgrade if lock contention on it is ever measured.
 *
 * Built twice: as kernel code (obsd-compat Makefile, obj) and, with
 * -DOBSD_USERTEST, against test/obsd_ushim.h, a pthread model of the few
 * illumos primitives used here, for test/test_sleep.c.
 */
#ifdef OBSD_USERTEST
#include "test/obsd_ushim.h"
#else
#include <sys/types.h>
#include <sys/callo.h>		/* CALLOUT_FLAG_ABSOLUTE */
#include <obsd_prelude.h>
/* this file calls the illumos rw_enter/rw_exit on the krwlock_t inside an
 * OpenBSD struct rwlock; the prelude's call-site renames must not apply */
#undef rw_enter
#undef rw_exit
#endif

#ifndef OBSD_SLEEP_SABOTAGE
#define OBSD_SLEEP_SABOTAGE	0
#endif

kmutex_t obsd_sched_lock;
int nowake;			/* a channel nobody wakes: a pure timed sleep */

#define OBSD_SLPQ_SIZE	128
#define OBSD_LOOKUP(x)	((((uintptr_t)(x)) >> 8) & (OBSD_SLPQ_SIZE - 1))
static TAILQ_HEAD(obsd_slpque, proc) obsd_slpque[OBSD_SLPQ_SIZE];

#ifndef OBSD_USERTEST
/*
 * jiffies: lbolt sampled once per clock tick, so it advances hz times a
 * second like OpenBSD's. Starting it at lbolt (not 0) keeps time_after()
 * comparisons valid across a module reload.
 */
volatile unsigned long jiffies;
static ddi_periodic_t obsd_jiffies_periodic;

static void
obsd_jiffies_tick(void *arg)
{
	(void) arg;
	jiffies = (unsigned long)ddi_get_lbolt();
}
#endif

void
obsd_sleepq_init(void)
{
	int i;

	mutex_init(&obsd_sched_lock, NULL, MUTEX_DRIVER, NULL);
	for (i = 0; i < OBSD_SLPQ_SIZE; i++)
		TAILQ_INIT(&obsd_slpque[i]);
#ifndef OBSD_USERTEST
	jiffies = (unsigned long)ddi_get_lbolt();
	obsd_jiffies_periodic = ddi_periodic_add(obsd_jiffies_tick, NULL,
	    (hrtime_t)nsec_per_tick, DDI_IPL_0);
#endif
}

#ifndef OBSD_USERTEST
/* Called from the driver's _fini path, after the last user is gone. */
void
obsd_sleepq_fini(void)
{
	if (obsd_jiffies_periodic != NULL)
		ddi_periodic_delete(obsd_jiffies_periodic);
	obsd_jiffies_periodic = NULL;
}
#endif

/* Take p off its queue. Caller holds SCHED_LOCK. Does not wake it. */
void
unsleep(struct proc *p)
{
	ASSERT(MUTEX_HELD(&obsd_sched_lock));
	if (p->p_wchan != NULL) {
		TAILQ_REMOVE(&obsd_slpque[OBSD_LOOKUP(p->p_wchan)], p, p_runq);
		p->p_wchan = NULL;
		p->p_wmesg = NULL;
	}
}

/* Wake p if it is asleep; 1 if it was. Caller holds SCHED_LOCK. */
int
wakeup_proc(struct proc *p)
{
	ASSERT(MUTEX_HELD(&obsd_sched_lock));
	if (p->p_wchan == NULL)
		return (0);
	unsleep(p);
	cv_signal(&p->p_cv);
	return (1);
}

void
wakeup_n(const volatile void *ident, int n)
{
	struct obsd_slpque *qp = &obsd_slpque[OBSD_LOOKUP(ident)];
	struct proc *p, *pnext;

	mutex_enter(&obsd_sched_lock);
	for (p = TAILQ_FIRST(qp); p != NULL && n != 0; p = pnext) {
		pnext = TAILQ_NEXT(p, p_runq);
#if OBSD_SLEEP_SABOTAGE != 2
		if (p->p_wchan == ident) {
#else
		/* negative control 2: wake the whole hash bucket */
		if (p->p_wchan != NULL) {
#endif
			(void) wakeup_proc(p);
			--n;
		}
	}
	mutex_exit(&obsd_sched_lock);
}

void
sleep_setup(const volatile void *ident, int prio, const char *wmesg)
{
	struct proc *p = curproc;

	ASSERT(ident != NULL);
	mutex_enter(&obsd_sched_lock);
	ASSERT(p->p_wchan == NULL);
	p->p_wchan = ident;
	p->p_wmesg = wmesg;
	TAILQ_INSERT_TAIL(&obsd_slpque[OBSD_LOOKUP(ident)], p, p_runq);
	atomic_or_uint((volatile uint_t *)&p->p_flag,
	    P_INSCHED | ((prio & PCATCH) ? P_SINTR : 0));
	p->p_stat = SSLEEP;
	mutex_exit(&obsd_sched_lock);
}

int
sleep_finish(uint64_t nsecs, int do_sleep)
{
	struct proc *p = curproc;
	int catch = (p->p_flag & P_SINTR) != 0;
	hrtime_t deadline = 0;
	int r, error = 0;

	if (nsecs != INFSLP)
		deadline = gethrtime() +
		    (hrtime_t)MIN(nsecs, (uint64_t)INT64_MAX / 4);
	mutex_enter(&obsd_sched_lock);
#if OBSD_SLEEP_SABOTAGE != 1
	if (p->p_wchan == NULL)
		do_sleep = 0;		/* woken before we got here */
	while (do_sleep && p->p_wchan != NULL) {
#else
	/* negative control 1 (test/test_sleep.c): an early wakeup is lost */
	while (do_sleep) {
#endif
		if (nsecs == INFSLP) {
			if (catch) {
				r = cv_wait_sig(&p->p_cv, &obsd_sched_lock);
			} else {
				cv_wait(&p->p_cv, &obsd_sched_lock);
				r = 1;
			}
		} else if (catch) {
			r = cv_timedwait_sig_hrtime(&p->p_cv,
			    &obsd_sched_lock, deadline);
		} else {
			r = cv_timedwait_hires(&p->p_cv, &obsd_sched_lock,
			    deadline, 1, CALLOUT_FLAG_ABSOLUTE);
		}
		/* A wakeup wins over a timeout or signal that raced it, as
		 * on OpenBSD (wakeup_proc clears p_wchan before endtsleep
		 * can mark P_TIMEOUT). */
		if (p->p_wchan == NULL)
			break;
		if (r == 0) {
			error = EINTR;
			break;
		}
		if (r < 0) {
			error = EWOULDBLOCK;
			break;
		}
	}
	unsleep(p);
	p->p_stat = SONPROC;
	atomic_and_uint((volatile uint_t *)&p->p_flag,
	    ~(uint_t)(P_SINTR | P_INSCHED));
	mutex_exit(&obsd_sched_lock);
	return (error);
}

static uint64_t
obsd_ticks_to_nsec(int timo)
{
	return (timo == 0 ? INFSLP :
	    (uint64_t)MAX(timo, 0) * (uint64_t)nsec_per_tick);
}

int
tsleep_nsec(const volatile void *ident, int prio, const char *wmesg,
    uint64_t nsecs)
{
	sleep_setup(ident, prio, wmesg);
	return (sleep_finish(nsecs, 1));
}

int
tsleep(const volatile void *ident, int prio, const char *wmesg, int timo)
{
	return (tsleep_nsec(ident, prio, wmesg, obsd_ticks_to_nsec(timo)));
}

/* The interlock is dropped after the thread is on the queue, so a waker
 * that takes it, changes state and calls wakeup() cannot be missed. */
int
msleep_nsec(const volatile void *ident, struct mutex *mtx, int prio,
    const char *wmesg, uint64_t nsecs)
{
	int error;

	sleep_setup(ident, prio, wmesg);
	mutex_exit(mtx);
	error = sleep_finish(nsecs, 1);
	if (!(prio & PNORELOCK))
		mutex_enter(mtx);
	return (error);
}

int
msleep(const volatile void *ident, struct mutex *mtx, int prio,
    const char *wmesg, int timo)
{
	return (msleep_nsec(ident, mtx, prio, wmesg, obsd_ticks_to_nsec(timo)));
}

#ifndef OBSD_USERTEST
/* Same as msleep_nsec with an rwlock interlock, re-taken in the mode held. */
int
rwsleep_nsec(const volatile void *ident, struct rwlock *rwl, int prio,
    const char *wmesg, uint64_t nsecs)
{
	int write = rw_write_held(&rwl->rwl_lock), error;

	sleep_setup(ident, prio, wmesg);
	rw_exit(&rwl->rwl_lock);
	error = sleep_finish(nsecs, 1);
	if (!(prio & PNORELOCK))
		rw_enter(&rwl->rwl_lock, write ? RW_WRITER : RW_READER);
	return (error);
}
#endif
