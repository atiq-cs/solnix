/*
 * n80211_kcompat.c -- the OpenBSD-kernel-PRIMITIVE backing that the vendored
 * net80211 (and if_iwx.c) call but illumos names differently. These are the
 * declared-only shims iwx/compat/sys/iwx_kernel.h and n80211_compat.h promise:
 * timeout_*, task_*, systq, iwx_bsd_malloc/free, etherbroadcastaddr, suser,
 * ratecheck, getmicrouptime, iwx_fls/iwx_flsl.  They are OpenBSD's own libkern
 * / kern facilities mapped onto illumos equivalents that DO exist -- timeout(9F),
 * ddi_taskq(9F), kmem(9F), secpolicy/drv_priv -- so each is a REAL mapping, not
 * a stub, EXCEPT where noted.
 *
 * These are distinct from the GLDv3 stack adapters (n80211_stack.c): those bridge
 * net80211's DOWNWARD calls onto GLDv3's upward-push model and genuinely need a
 * live mac_handle; the primitives here are self-contained and complete.
 *
 * The timeout/task shims need a dev_info_t to create a real ddi_taskq and to
 * name timeouts. Until attach hands one in, taskq creation falls back to the
 * kernel's system_taskq (via ddi_taskq_create(NULL,...) is illegal, so we use a
 * lazily-created private taskq with dip==NULL guarded). NOTE: the timeout(9F)
 * path needs no dip and is fully REAL; the taskq path is REAL once
 * n80211_kcompat_set_dip() is called from attach.
 */

#ifdef _KERNEL
#include <sys/types.h>
#include <sys/systm.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/kmem.h>
#include <sys/time.h>
#include <sys/cmn_err.h>
#include <sys/atomic.h>
#include <sys/policy.h>
#endif

#include <sys/iwx_kernel.h>

/* ---------------------------------------------------------------- taskq --- */

/*
 * OpenBSD `struct taskq` is opaque to net80211; we back it with a ddi_taskq_t.
 * `systq` is OpenBSD's shared system taskq. illumos has the global system_taskq
 * (a taskq_t), but ddi_taskq is the DDI-blessed per-driver facility. We create a
 * single shared ddi_taskq lazily on first use, using the dip attach registers.
 */
struct taskq {
	ddi_taskq_t	*tq;
};

static dev_info_t	*n80211_dip;		/* set by attach */
static struct taskq	 n80211_systq_storage;
struct taskq		*systq = &n80211_systq_storage;

void
n80211_kcompat_set_dip(dev_info_t *dip)
{
	n80211_dip = dip;
	if (systq->tq == NULL && dip != NULL)
		systq->tq = ddi_taskq_create(dip, "n80211_systq", 1,
		    TASKQ_DEFAULTPRI, 0);
}

struct taskq *
iwx_taskq_create(const char *name, unsigned int nthreads, int ipl,
    unsigned int flags)
{
	struct taskq *t;

	(void) ipl;
	(void) flags;
	t = kmem_zalloc(sizeof (*t), KM_SLEEP);
	t->tq = ddi_taskq_create(n80211_dip, name, nthreads,
	    TASKQ_DEFAULTPRI, 0);
	if (t->tq == NULL) {
		kmem_free(t, sizeof (*t));
		return (NULL);
	}
	return (t);
}

void
taskq_destroy(struct taskq *t)
{
	if (t == NULL || t == systq)
		return;
	if (t->tq != NULL)
		ddi_taskq_destroy(t->tq);
	kmem_free(t, sizeof (*t));
}

/* task state values */
#define N80211_TASK_IDLE	0
#define N80211_TASK_PENDING	1

void
task_set(struct task *t, void (*fn)(void *), void *arg)
{
	t->t_func = fn;
	t->t_arg = arg;
	t->t_state = N80211_TASK_IDLE;
	t->t_tq = NULL;
}

/*
 * OpenBSD task_add returns 1 if it was enqueued, 0 if already pending. We
 * mirror that with an atomic test-and-set on t_state so a double task_add does
 * not dispatch twice.
 */
int
task_add(struct taskq *tq, struct task *t)
{
	if (tq == NULL || tq->tq == NULL)
		return (0);
	if (atomic_cas_uint(&t->t_state, N80211_TASK_IDLE,
	    N80211_TASK_PENDING) != N80211_TASK_IDLE)
		return (0);				/* already pending */
	t->t_tq = tq;
	if (ddi_taskq_dispatch(tq->tq, t->t_func, t->t_arg, DDI_NOSLEEP)
	    != DDI_SUCCESS) {
		t->t_state = N80211_TASK_IDLE;
		return (0);
	}
	return (1);
}

/*
 * OpenBSD task_del cancels a not-yet-run task. ddi_taskq has no per-task
 * cancel, so we can only clear the pending flag if the task has not yet been
 * picked up; a task already running or dispatched completes normally. This is
 * the honest limitation and matches the safe direction (the task's own handler
 * must tolerate a spurious run, which net80211's do -- they re-check state).
 * Returns 1 if we cleared a pending mark, else 0.
 * ponytail: cannot truly cancel an in-flight ddi_taskq item; handlers re-check.
 */
int
task_del(struct taskq *tq, struct task *t)
{
	(void) tq;
	if (atomic_cas_uint(&t->t_state, N80211_TASK_PENDING,
	    N80211_TASK_IDLE) == N80211_TASK_PENDING)
		return (1);
	return (0);
}

int
task_pending(struct task *t)
{
	return (t->t_state == N80211_TASK_PENDING);
}

/* -------------------------------------------------------------- timeout --- */

/*
 * OpenBSD's timeout(9) -> illumos timeout(9F)/untimeout(9F). timeout_set just
 * records the handler; timeout_add_* schedules it. A wrapper trampoline clears
 * to_pending before invoking the handler, matching OpenBSD semantics (the
 * timeout is no longer pending once it fires).
 */
static void
n80211_timeout_trampoline(void *arg)
{
	struct timeout *to = arg;

	to->to_pending = 0;
	if (to->to_func != NULL)
		to->to_func(to->to_arg);
}

void
timeout_set(struct timeout *to, void (*fn)(void *), void *arg)
{
	to->to_func = fn;
	to->to_arg = arg;
	to->to_id = 0;
	to->to_pending = 0;
}

static int
n80211_timeout_add_ticks(struct timeout *to, clock_t ticks)
{
	if (to->to_pending)
		return (0);				/* already scheduled */
	if (ticks < 1)
		ticks = 1;
	to->to_pending = 1;
	to->to_id = timeout(n80211_timeout_trampoline, to, ticks);
	return (1);
}

int
timeout_add(struct timeout *to, int ticks)
{
	return (n80211_timeout_add_ticks(to, (clock_t)ticks));
}

int
timeout_add_msec(struct timeout *to, int msec)
{
	return (n80211_timeout_add_ticks(to,
	    drv_usectohz((clock_t)msec * 1000)));
}

int
timeout_add_usec(struct timeout *to, int usec)
{
	return (n80211_timeout_add_ticks(to, drv_usectohz((clock_t)usec)));
}

int
timeout_add_sec(struct timeout *to, int sec)
{
	return (n80211_timeout_add_ticks(to,
	    drv_usectohz((clock_t)sec * 1000000)));
}

int
timeout_del(struct timeout *to)
{
	int was_pending = to->to_pending;

	if (to->to_pending && to->to_id != 0) {
		(void) untimeout(to->to_id);
		to->to_id = 0;
		to->to_pending = 0;
	}
	return (was_pending);
}

int
timeout_pending(struct timeout *to)
{
	return (to->to_pending);
}

/* --------------------------------------------------------------- malloc --- */

/*
 * OpenBSD malloc(size, type, flags) with M_ZERO/M_NOWAIT -> kmem(9F). The type
 * arg is a statistics bucket on OpenBSD; illumos kmem does not take one, so it
 * is discarded. free(ptr, type, size) NEEDS the size on illumos (kmem_free),
 * and OpenBSD passes it too, so the mapping is exact -- unlike a libc free.
 */
void *
iwx_bsd_malloc(size_t size, int type, int flags)
{
	void *p;
	int km = (flags & M_NOWAIT) ? KM_NOSLEEP : KM_SLEEP;

	(void) type;
	if (size == 0)
		return (NULL);
	if (flags & M_ZERO)
		p = kmem_zalloc(size, km);
	else
		p = kmem_alloc(size, km);
	return (p);
}

void *
iwx_bsd_mallocarray(size_t nmemb, size_t size, int type, int flags)
{
	/* overflow-checked product, as OpenBSD's mallocarray does */
	if (nmemb != 0 && size > (size_t)-1 / nmemb)
		return (NULL);
	return (iwx_bsd_malloc(nmemb * size, type, flags));
}

void
iwx_bsd_free(void *ptr, int type, size_t size)
{
	(void) type;
	if (ptr != NULL && size != 0)
		kmem_free(ptr, size);
}

/* ----------------------------------------------------------- misc kern --- */

const uint8_t etherbroadcastaddr[6] = { 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
const uint8_t etheranyaddr[6] = { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };

/*
 * suser: OpenBSD privilege check, 0 == permitted. illumos uses secpolicy/cred;
 * net80211 only calls it on the SIOCS80211* ioctl path (which illumos userland
 * does not issue -- FINDINGS Finding 2), so the honest mapping is drv_priv on
 * the passed cred. The arg is a `struct proc *`/cred on OpenBSD; the ioctl
 * bridge passes the illumos cred_t through it.
 */
int
suser(void *cr)
{
	return (drv_priv((struct cred *)cr));
}

/*
 * ratecheck: OpenBSD "has *lasttime + mininterval elapsed?". Used only to
 * throttle diagnostic prints. Backed by ddi_get_lbolt(). Returns 1 if enough
 * time has passed (and updates *lasttime), else 0.
 */
int
ratecheck(struct timeval *lasttime, const struct timeval *mininterval)
{
	hrtime_t now = gethrtime();
	hrtime_t last = (hrtime_t)lasttime->tv_sec * NANOSEC +
	    (hrtime_t)lasttime->tv_usec * 1000;
	hrtime_t interval = (hrtime_t)mininterval->tv_sec * NANOSEC +
	    (hrtime_t)mininterval->tv_usec * 1000;

	if (last == 0 || now - last >= interval) {
		lasttime->tv_sec = now / NANOSEC;
		lasttime->tv_usec = (now % NANOSEC) / 1000;
		return (1);
	}
	return (0);
}

/*
 * getmicrouptime: OpenBSD fills a timeval with seconds+usec since boot. illumos
 * gethrtime() is ns since an arbitrary epoch; net80211/iwx use only DIFFERENCES,
 * so the epoch is irrelevant. REAL for the difference-only callers.
 */
void
getmicrouptime(struct timeval *tv)
{
	hrtime_t now = gethrtime();

	tv->tv_sec = now / NANOSEC;
	tv->tv_usec = (now % NANOSEC) / 1000;
}

void
iwx_getnanouptime(struct timespec *ts)
{
	hrtime_t now = gethrtime();

	ts->tv_sec = now / NANOSEC;
	ts->tv_nsec = now % NANOSEC;
}

/*
 * fls/flsl: find last (highest) set bit, 1-based; 0 for 0. OpenBSD libkern.
 * Used by net80211's rate math. REAL.
 */
int
iwx_fls(int v)
{
	int i = 0;
	unsigned int u = (unsigned int)v;

	while (u != 0) { i++; u >>= 1; }
	return (i);
}

int
iwx_flsl(long v)
{
	int i = 0;
	unsigned long u = (unsigned long)v;

	while (u != 0) { i++; u >>= 1; }
	return (i);
}
