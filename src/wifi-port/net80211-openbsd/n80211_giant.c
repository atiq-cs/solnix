/*
 * n80211_giant.c -- the OpenBSD big-lock execution model, on illumos.
 *
 * WHY THIS EXISTS. OpenBSD's iwm(4), iwx(4) and net80211 are not MP-safe code
 * that uses splnet() for exclusion. They run under KERNEL_LOCK, the recursive
 * big lock, and splnet() only keeps the device interrupt off the LOCAL cpu:
 *
 *   - the ISR runs under kernel_lock unless established IPL_MPSAFE
 *     (arch/amd64/amd64/intr.c:554-559); iwm uses plain IPL_NET
 *     (if_iwm.c:11768);
 *   - softclock timeouts run under it unless SIF_MPSAFE
 *     (kern/kern_softintr.c 1.1 :79-84) and no iwm/net80211 timeout is MPSAFE;
 *   - systq tasks run under it; only TASKQ_MPSAFE queues drop it
 *     (kern/kern_task.c:430,:457);
 *   - tsleep releases it for the duration of the sleep
 *     (kern/kern_synch.c:143-144 __mp_release_all, reacquired on wakeup).
 *
 * Measured: zero IPL_MPSAFE / TASKQ_MPSAFE / TIMEOUT_MPSAFE / KERNEL_LOCK in
 * if_iwm.c and in all 18 vendored net80211 .c files. So the faithful illumos
 * model is ONE module-global lock taken at every entry boundary, with sleeps
 * dropping it. That is what this file provides:
 *
 *   n80211_giant      an ADAPTIVE kmutex. mutex_init() makes a spin mutex only
 *                     when the cookie is above LOCK_LEVEL (uts/common/os/
 *                     mutex.c:573); a NULL cookie is adaptive, and an ordinary
 *                     ddi_intr handler at or below LOCK_LEVEL may block on an
 *                     adaptive mutex (illumos iwn does exactly this:
 *                     if_iwn.c:862 then cv_timedwait on it at :4467). The
 *                     attach glue must refuse a high-level interrupt.
 *   entry boundaries  ISR, task thread, timeout trampoline, GLDv3 callbacks:
 *                     each takes giant once. Nothing inside takes it again.
 *   tsleep/wakeup     a sleeper list on giant; cv_timedwait drops giant
 *                     exactly as tsleep drops kernel_lock.
 *   rwlock, refcnt    built on the same sleep, so their sleeps drop giant too.
 *   splnet/splx       stay no-ops: giant already excludes the ISR on all cpus.
 *
 * What this REFUTES (STATUS.md / SPLNET-AUDIT.md, phase-3 session): the claim
 * that sleeping on an iblock-cookie mutex "deadlocks the CPU" is true only for
 * a high-level (spin) mutex, and the fine-grained per-region model is not
 * needed for correctness: there are no region locks, so the three nesting
 * self-deadlocks cannot happen, and ic_lock == sc_lock == giant, so the
 * ieee80211_clean_nodes -> ic_updateprot AB/BA cannot happen.
 *
 * The two illumos-specific hazards the big-lock model brings, and how each is
 * handled here:
 *   1. untimeout(9F) BLOCKS while the callout runs (callout.c:1369-1384). A
 *      trampoline waiting for giant + timeout_del holding giant = deadlock.
 *      timeout_del therefore uses untimeout_default(id, nowait=1) and a
 *      per-arm sequence number: a trampoline that lost the race sees a stale
 *      sequence under giant and returns without calling the handler.
 *   2. mac_rx() can loop a frame straight back into mc_tx, which takes giant:
 *      the RX path must not call mac_rx under giant. n80211_defer_rx() queues
 *      the chain and n80211_giant_exit() pushes it after the mutex is dropped.
 *
 * NOTE: one lock for every iwm instance. The X1 has one radio. A second radio
 * would serialize against the first; per-softc giants are the upgrade if a
 * machine with two ever matters.
 */

#ifdef _KERNEL
#include <sys/types.h>
#include <sys/systm.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/kmem.h>
#include <sys/ksynch.h>
#include <sys/thread.h>
#include <sys/proc.h>
#include <sys/disp.h>
#include <sys/cmn_err.h>
#include <sys/errno.h>
#include <sys/firmload.h>
#include <sys/stream.h>
#include <sys/strsubr.h>
#include <sys/callo.h>
#include <sys/queue.h>
#include <sys/mac_provider.h>
#include <sys/debug.h>
#endif

/*
 * This file talks to GLDv3, whose <sys/mac.h> defines LINK_STATE_UP/DOWN as
 * the link_state_t enum (UP = 1). OpenBSD's LINK_STATE_UP is 4. The compat
 * headers would #define them over the enum, so this file does NOT include
 * the OpenBSD prelude; it re-declares the few compat structs it implements
 * (n80211_giant.h) and maps link state explicitly in n80211_defer_link().
 */
#include "n80211_giant.h"
#include "compat/sys/n80211_symrename.h"

kmutex_t	n80211_giant;
static int	n80211_giant_ready;

/* RX chains and link-state changes held until giant is dropped. */
static mblk_t		*n80211_rx_head, *n80211_rx_tail;
static mac_handle_t	n80211_rx_mh;
static int		n80211_link_pending = -1;
static mac_handle_t	n80211_link_mh;

void
n80211_giant_init(void)
{
	if (n80211_giant_ready)
		return;
	mutex_init(&n80211_giant, NULL, MUTEX_DRIVER, NULL);
	n80211_giant_ready = 1;
}

void
n80211_giant_fini(void)
{
	if (!n80211_giant_ready)
		return;
	mutex_destroy(&n80211_giant);
	n80211_giant_ready = 0;
}

void
n80211_giant_enter(void)
{
	mutex_enter(&n80211_giant);
}

/*
 * Drop giant, then deliver what the locked section queued for the host stack.
 * The deferred state is detached under giant, so a concurrent producer starts
 * a fresh batch rather than racing this one.
 */
void
n80211_giant_exit(void)
{
	mblk_t *chain = n80211_rx_head;
	mac_handle_t rmh = n80211_rx_mh;
	int link = n80211_link_pending;
	mac_handle_t lmh = n80211_link_mh;

	n80211_rx_head = n80211_rx_tail = NULL;
	n80211_link_pending = -1;
	mutex_exit(&n80211_giant);

	if (link != -1 && lmh != NULL)
		mac_link_update(lmh, (link_state_t)link);
	if (chain != NULL) {
		if (rmh != NULL) {
			mac_rx(rmh, NULL, chain);
		} else {
			freemsgchain(chain);
		}
	}
}

int
n80211_giant_owned(void)
{
	return (mutex_owned(&n80211_giant));
}

/* Called with giant held: queue a b_next chain for mac_rx after unlock. */
void
n80211_defer_rx(mac_handle_t mh, mblk_t *chain)
{
	mblk_t *t;

	ASSERT(mutex_owned(&n80211_giant));
	if (chain == NULL)
		return;
	for (t = chain; t->b_next != NULL; t = t->b_next)
		;
	if (n80211_rx_head == NULL)
		n80211_rx_head = chain;
	else
		n80211_rx_tail->b_next = chain;
	n80211_rx_tail = t;
	n80211_rx_mh = mh;
}

void
n80211_defer_link(mac_handle_t mh, int up)
{
	ASSERT(mutex_owned(&n80211_giant));
	n80211_link_mh = mh;
	n80211_link_pending = up ? (int)LINK_STATE_UP : (int)LINK_STATE_DOWN;
}

/*
 * splassert(IPL_NET): OpenBSD's machine-checked "caller holds the exclusion".
 * Here the exclusion is giant. Warn once instead of panicking: a missed entry
 * boundary is a bug to report, not a reason to take down the maintainer's
 * laptop.
 */
void
n80211_splassert_fail(const char *fn)
{
	static int warned;

	if (!warned) {
		warned = 1;
		cmn_err(CE_WARN, "n80211: %s entered without the giant lock", fn);
	}
}

/* ----------------------------------------------------- tsleep / wakeup --- */

struct n80211_sleeper {
	const void		*s_chan;
	kcondvar_t		s_cv;
	int			s_woken;
	struct n80211_sleeper	*s_next;
};

static struct n80211_sleeper *n80211_sleepers;	/* protected by giant */

/*
 * tsleep_nsec: sleep on chan, dropping giant, until wakeup(chan), the timeout,
 * or (PCATCH) a signal. Returns 0, EWOULDBLOCK or EINTR, as OpenBSD does.
 * Every caller in iwm and net80211 runs inside an entry boundary, so giant is
 * held; one that is not is a missed boundary and is refused loudly.
 */
int
tsleep_nsec(const void *chan, int prio, const char *wmesg, uint64_t nsecs)
{
	struct n80211_sleeper s, **pp;
	int err = 0;
	hrtime_t deadline = 0;

	(void) wmesg;
	if (!mutex_owned(&n80211_giant)) {
		n80211_splassert_fail("tsleep_nsec");
		return (EWOULDBLOCK);
	}
	s.s_chan = chan;
	s.s_woken = 0;
	cv_init(&s.s_cv, NULL, CV_DRIVER, NULL);
	s.s_next = n80211_sleepers;
	n80211_sleepers = &s;

	if (nsecs != INFSLP)
		deadline = gethrtime() + (hrtime_t)nsecs;
	while (!s.s_woken) {
		if (nsecs == INFSLP) {
			if (prio & PCATCH) {
				if (cv_wait_sig(&s.s_cv, &n80211_giant) == 0) {
					err = EINTR;
					break;
				}
			} else {
				cv_wait(&s.s_cv, &n80211_giant);
			}
			continue;
		}
		if (prio & PCATCH) {
			int r = cv_timedwait_sig_hrtime(&s.s_cv,
			    &n80211_giant, deadline);
			if (r == 0) {
				err = EINTR;
				break;
			}
			if (r < 0) {
				err = EWOULDBLOCK;
				break;
			}
		} else {
			if (cv_timedwait_hires(&s.s_cv, &n80211_giant,
			    deadline, 0, CALLOUT_FLAG_ABSOLUTE) < 0) {
				err = EWOULDBLOCK;
				break;
			}
		}
	}
	if (s.s_woken)
		err = 0;
	for (pp = &n80211_sleepers; *pp != NULL; pp = &(*pp)->s_next) {
		if (*pp == &s) {
			*pp = s.s_next;
			break;
		}
	}
	cv_destroy(&s.s_cv);
	return (err);
}

int
tsleep(const void *chan, int prio, const char *wmesg, int timo)
{
	uint64_t ns = timo == 0 ? INFSLP :
	    (uint64_t)TICK_TO_NSEC((clock_t)timo);

	return (tsleep_nsec(chan, prio, wmesg, ns));
}

void
wakeup(const void *chan)
{
	struct n80211_sleeper *s;

	if (!mutex_owned(&n80211_giant)) {
		n80211_splassert_fail("wakeup");
		return;
	}
	for (s = n80211_sleepers; s != NULL; s = s->s_next) {
		if (s->s_chan == chan && !s->s_woken) {
			s->s_woken = 1;
			cv_signal(&s->s_cv);
		}
	}
}

/* --------------------------------------------- rwlock on the giant sleep --- */

/*
 * OpenBSD's ioctl_rwl serialises ioctl/init/stop entrants against each other
 * while one of them is asleep (if_iwm.c:10667-10670). Under giant the only
 * window where a second entrant can arrive is exactly such a sleep, so a
 * write-owner field plus the giant sleep is the whole lock. Readers are not
 * used by iwm (3 sites, all writers: :10671 :12134 :12215).
 */
void
iwx_rw_init(struct rwlock *l, const char *name)
{
	(void) name;
	l->rwl_owner = NULL;
}

void
iwx_rw_destroy(struct rwlock *l)
{
	(void) l;
}

int
iwx_rw_enter(struct rwlock *l, int flags)
{
	while (l->rwl_owner != NULL) {
		int err = tsleep_nsec(l, (flags & RW_INTR) ? PCATCH : 0,
		    "rwlock", INFSLP);
		if (err != 0)
			return (err);
	}
	l->rwl_owner = curthread;
	return (0);
}

void
iwx_rw_exit(struct rwlock *l)
{
	l->rwl_owner = NULL;
	wakeup(l);
}

int
iwx_rw_write_held(struct rwlock *l)
{
	return (l->rwl_owner == curthread);
}

/* ------------------------------------------------------------- refcnt --- */

void
refcnt_init(struct refcnt *r)
{
	r->r_refs = 1;
}

void
refcnt_take(struct refcnt *r)
{
	r->r_refs++;
}

int
refcnt_rele(struct refcnt *r)
{
	ASSERT(r->r_refs > 0);
	return (--r->r_refs == 0);
}

void
refcnt_rele_wake(struct refcnt *r)
{
	if (refcnt_rele(r))
		wakeup(r);
}

/* Drop the initial reference and sleep until every task has released. */
void
refcnt_finalize(struct refcnt *r, const char *wmesg)
{
	if (refcnt_rele(r))
		return;
	while (r->r_refs > 0)
		(void) tsleep_nsec(r, 0, wmesg, INFSLP);
}

/* -------------------------------------------------------------- taskq --- */

/*
 * One kernel thread per taskq, a FIFO of struct obsd_task under giant, and the
 * task function called with giant held: OpenBSD's taskq_thread under
 * kernel_lock. task_add is legal from the ISR (iwm_intr -> task_add(systq,
 * init_task), if_iwm.c:11506-11594) because it only links a node and signals.
 */
struct taskq {
	TAILQ_HEAD(, obsd_task)	tq_q;
	kcondvar_t		tq_cv;
	kthread_t		*tq_thr;
	kt_did_t		tq_did;
	int			tq_dying;
	int			tq_running;
	const char		*tq_name;
};

#define TASK_ONQUEUE	0x1

static struct taskq	n80211_systq_storage;
struct taskq		*systq = &n80211_systq_storage;

static void
n80211_taskq_thread(void *arg)
{
	struct taskq *tq = arg;
	struct obsd_task *t;

	mutex_enter(&n80211_giant);
	for (;;) {
		while (!tq->tq_dying && TAILQ_EMPTY(&tq->tq_q))
			cv_wait(&tq->tq_cv, &n80211_giant);
		if (tq->tq_dying && TAILQ_EMPTY(&tq->tq_q))
			break;
		t = TAILQ_FIRST(&tq->tq_q);
		TAILQ_REMOVE(&tq->tq_q, t, t_entry);
		t->t_state &= ~TASK_ONQUEUE;
		tq->tq_running = 1;
		t->t_func(t->t_arg);
		tq->tq_running = 0;
		/* deliver any RX/link state queued by the task, then relock */
		n80211_giant_exit();
		mutex_enter(&n80211_giant);
	}
	mutex_exit(&n80211_giant);
	thread_exit();
}

static void
n80211_taskq_init(struct taskq *tq, const char *name)
{
	TAILQ_INIT(&tq->tq_q);
	cv_init(&tq->tq_cv, NULL, CV_DRIVER, NULL);
	tq->tq_dying = 0;
	tq->tq_running = 0;
	tq->tq_name = name;
	tq->tq_thr = thread_create(NULL, 0, n80211_taskq_thread, tq, 0, &p0,
	    TS_RUN, minclsyspri);
	tq->tq_did = tq->tq_thr->t_did;
}

/*
 * Called with giant held; returns with it held. The thread is told to stop,
 * giant is dropped so it can drain and leave, and thread_join waits until it
 * has fully exited. A cv handshake is not enough: the thread still executes
 * module text (mutex_exit, the call to thread_exit) after any signal it
 * sends, and _fini/a failed _init unloads that text right after this returns.
 */
static void
n80211_taskq_stop(struct taskq *tq)
{
	if (tq->tq_thr == NULL)
		return;
	tq->tq_dying = 1;
	cv_signal(&tq->tq_cv);
	mutex_exit(&n80211_giant);
	thread_join(tq->tq_did);
	mutex_enter(&n80211_giant);
	tq->tq_thr = NULL;
	cv_destroy(&tq->tq_cv);
}

void
n80211_systq_init(void)
{
	n80211_taskq_init(systq, "n80211_systq");
}

void
n80211_systq_fini(void)
{
	mutex_enter(&n80211_giant);
	n80211_taskq_stop(systq);
	mutex_exit(&n80211_giant);
}

struct taskq *
iwx_taskq_create(const char *name, unsigned int nthreads, int ipl,
    unsigned int flags)
{
	struct taskq *tq;

	(void) nthreads;
	(void) ipl;
	(void) flags;
	tq = kmem_zalloc(sizeof (*tq), KM_SLEEP);
	n80211_taskq_init(tq, name);
	return (tq);
}

void
taskq_destroy(struct taskq *tq)
{
	int held;

	if (tq == NULL || tq == systq)
		return;
	held = mutex_owned(&n80211_giant);
	if (!held)
		mutex_enter(&n80211_giant);
	n80211_taskq_stop(tq);
	if (!held)
		mutex_exit(&n80211_giant);
	kmem_free(tq, sizeof (*tq));
}

void
task_set(struct obsd_task *t, void (*fn)(void *), void *arg)
{
	t->t_func = fn;
	t->t_arg = arg;
	t->t_state = 0;
	t->t_tq = NULL;
}

int
task_add(struct taskq *tq, struct obsd_task *t)
{
	ASSERT(mutex_owned(&n80211_giant));
	if (tq == NULL || tq->tq_thr == NULL || (t->t_state & TASK_ONQUEUE))
		return (0);
	t->t_state |= TASK_ONQUEUE;
	t->t_tq = tq;
	TAILQ_INSERT_TAIL(&tq->tq_q, t, t_entry);
	cv_signal(&tq->tq_cv);
	return (1);
}

int
task_del(struct taskq *tq, struct obsd_task *t)
{
	ASSERT(mutex_owned(&n80211_giant));
	if (!(t->t_state & TASK_ONQUEUE))
		return (0);
	TAILQ_REMOVE(&tq->tq_q, t, t_entry);
	t->t_state &= ~TASK_ONQUEUE;
	return (1);
}

int
task_pending(struct obsd_task *t)
{
	return ((t->t_state & TASK_ONQUEUE) != 0);
}

/* ------------------------------------------------------------ timeout --- */

/*
 * Each arm allocates a token holding the timeout and the sequence number it
 * was armed with. The trampoline takes giant and runs the handler only if
 * the timeout is still armed with that sequence: timeout_del and a re-arm
 * bump the sequence, so a callout that already fired and is waiting for
 * giant becomes a no-op. The token is freed by whichever side finishes with
 * it: the trampoline always (it owns the token once timeout(9F) fires), and
 * timeout_del only when untimeout_default() proves the callout never ran.
 */
struct n80211_to_token {
	struct timeout	*tk_to;
	uint64_t	tk_seq;
};

static void
n80211_timeout_trampoline(void *arg)
{
	struct n80211_to_token *tk = arg;
	struct timeout *to;

	mutex_enter(&n80211_giant);
	to = tk->tk_to;
	if (to->to_pending && to->to_seq == tk->tk_seq &&
	    to->to_token == tk) {
		to->to_pending = 0;
		to->to_token = NULL;
		to->to_func(to->to_arg);
	}
	n80211_giant_exit();
	kmem_free(tk, sizeof (*tk));
}

void
timeout_set(struct timeout *to, void (*fn)(void *), void *arg)
{
	to->to_func = fn;
	to->to_arg = arg;
	to->to_id = 0;
	to->to_pending = 0;
	to->to_seq = 0;
	to->to_token = NULL;
}

static int
n80211_timeout_add_ticks(struct timeout *to, clock_t ticks)
{
	struct n80211_to_token *tk;
	int was = to->to_pending;

	ASSERT(mutex_owned(&n80211_giant));
	/* OpenBSD re-arms a pending timeout with the new expiry. */
	if (was)
		(void) timeout_del(to);
	if (ticks < 1)
		ticks = 1;
	tk = kmem_alloc(sizeof (*tk), KM_NOSLEEP);
	if (tk == NULL)
		return (0);
	tk->tk_to = to;
	tk->tk_seq = ++to->to_seq;
	to->to_token = tk;
	to->to_pending = 1;
	to->to_id = timeout(n80211_timeout_trampoline, tk, ticks);
	return (!was);
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
	struct n80211_to_token *tk = to->to_token;
	int was = to->to_pending;

	ASSERT(mutex_owned(&n80211_giant));
	if (!was)
		return (0);
	to->to_pending = 0;
	to->to_seq++;
	to->to_token = NULL;
	/*
	 * nowait=1: never block on a running trampoline (it may be waiting
	 * for the giant this thread holds). A return >= 0 means the callout
	 * was removed before it ran, so the token is ours to free; -1 means
	 * it is running or has run, and the trampoline frees the token after
	 * seeing the stale sequence.
	 */
	if (untimeout_default((callout_id_t)to->to_id, 1) >= 0 && tk != NULL)
		kmem_free(tk, sizeof (*tk));
	to->to_id = 0;
	return (1);
}

int
timeout_pending(struct timeout *to)
{
	return (to->to_pending);
}

/* ----------------------------------------------------------- firmware --- */

/*
 * loadfirmware(name): OpenBSD reads /etc/firmware/<name>. Here it is
 * firmware_open("iwm", name) -> /kernel/firmware/iwm/<name> (os/firmload.c:86
 * builds "firmware/%s/%s" and searches the module path). File IO sleeps for
 * real, so giant is dropped around it -- the same window OpenBSD's VFS read
 * opens, since the caller then waits on fw_status (if_iwm.c:710-711).
 * The buffer is a malloc(9)-style kmem allocation because iwm_fw_info_free
 * releases it with free(fw_rawdata, M_DEVBUF, fw_rawsize) (if_iwm.c:673).
 */
int
loadfirmware(const char *name, uint8_t **bufp, size_t *lenp)
{
	firmware_handle_t fh;
	uint8_t *buf = NULL;
	off_t size = 0;
	int held = mutex_owned(&n80211_giant);
	int err;

	if (held)
		mutex_exit(&n80211_giant);
	err = firmware_open("iwm", name, &fh);
	if (err == 0) {
		size = firmware_get_size(fh);
		if (size <= 0 || size > 16 * 1024 * 1024) {
			err = EINVAL;
		} else {
			buf = kmem_alloc((size_t)size, KM_SLEEP);
			err = firmware_read(fh, 0, buf, (size_t)size);
			if (err != 0) {
				kmem_free(buf, (size_t)size);
				buf = NULL;
			}
		}
		(void) firmware_close(fh);
	}
	if (held)
		mutex_enter(&n80211_giant);
	if (err != 0)
		return (err);
	*bufp = buf;
	*lenp = (size_t)size;
	return (0);
}

/* The GLDv3-side view must match the compat-side layout (n80211_layout.c). */
CTASSERT(sizeof (struct obsd_task) == N80211_SIZEOF_TASK);
CTASSERT(sizeof (struct timeout) == N80211_SIZEOF_TIMEOUT);
CTASSERT(LINK_STATE_UP == 1);	/* GLDv3 link_state_t, not OpenBSD's 4 */
