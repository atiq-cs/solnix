/*
 * drm_dma.c - dma-fence, ww_mutex, dma-resv: the C1c GPU synchronization +
 * reservation primitives, over illumos ksynch.
 *
 * Provenance: the semantics are cribbed from NetBSD's linux-KPI shim
 *   drm2/linux/linux_dma_fence.c   (fence signal/wait/callback state machine)
 *   drm2/linux/linux_ww_mutex.c    (wound/wait ticket ordering)
 *   drm2/linux/linux_dma_resv.c    (excl + shared fence lists)
 * and the Linux dma-fence/dma-resv/ww_mutex kABI those emulate. No NetBSD .c is
 * lifted; each primitive is re-expressed against illumos kmutex_t/kcondvar_t/
 * kref (declarations in linux-compat/linux_dma.h). The one structural
 * divergence from NetBSD is the absence of RCU: illumos has no RCU, so every
 * reader takes the fence/resv lock (see the header's simplification note).
 */

#include <sys/types.h>
#include <sys/atomic.h>
#include <sys/ksynch.h>
#include <sys/kmem.h>
#include <sys/list.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>

#include "linux-compat/linux_dma.h"

/* --- flag helpers (Linux test_and_set_bit over the flags word) --- */
static boolean_t
fence_test_and_set(struct dma_fence *f, uint_t bit)
{
	uint_t mask = 1u << bit;
	uint_t old, new;
	do {
		old = f->flags;
		if (old & mask)
			return (B_TRUE);
		new = old | mask;
	} while (atomic_cas_uint(&f->flags, old, new) != old);
	return (B_FALSE);
}
static boolean_t
fence_test(struct dma_fence *f, uint_t bit)
{
	return ((f->flags & (1u << bit)) != 0);
}

/* ================= dma-fence ================= */

/*
 * dma_fence_context_alloc - hand out a run of unique 64-bit context ids.
 * Linux/NetBSD keep a global monotonic counter; we use atomic_add_64_nv on a
 * static, which is the illumos analogue of NetBSD's spinlocked counter.
 */
uint64_t
dma_fence_context_alloc(unsigned count)
{
	static volatile uint64_t global_context = 1;
	return (atomic_add_64_nv(&global_context, count) - count);
}

void
dma_fence_init(struct dma_fence *f, const struct dma_fence_ops *ops,
    kmutex_t *lock, uint64_t context, uint64_t seqno)
{
	kref_init(&f->refcount);
	if (lock != NULL) {
		f->lock = lock;
	} else {
		mutex_init(&f->f_lock_store, NULL, MUTEX_DRIVER, NULL);
		f->lock = &f->f_lock_store;
	}
	cv_init(&f->f_cv, NULL, CV_DRIVER, NULL);
	f->flags = 0;
	f->context = context;
	f->seqno = seqno;
	f->ops = ops;
	f->error = 0;
	list_create(&f->f_callbacks, sizeof (struct dma_fence_cb),
	    offsetof(struct dma_fence_cb, fcb_node));
}

/* kref release trampoline: call the driver release op, then tear down. */
static void
dma_fence_release(struct kref *kref)
{
	struct dma_fence *f = (struct dma_fence *)((char *)kref -
	    offsetof(struct dma_fence, refcount));

	ASSERT(list_is_empty(&f->f_callbacks));
	if (f->ops != NULL && f->ops->release != NULL) {
		/* release op owns the memory free (kfree of the container). */
		list_destroy(&f->f_callbacks);
		cv_destroy(&f->f_cv);
		if (f->lock == &f->f_lock_store)
			mutex_destroy(&f->f_lock_store);
		f->ops->release(f);
		return;
	}
	list_destroy(&f->f_callbacks);
	cv_destroy(&f->f_cv);
	if (f->lock == &f->f_lock_store)
		mutex_destroy(&f->f_lock_store);
}

struct dma_fence *
dma_fence_get(struct dma_fence *f)
{
	if (f != NULL)
		kref_get(&f->refcount);
	return (f);
}

void
dma_fence_put(struct dma_fence *f)
{
	if (f != NULL)
		(void) kref_put(&f->refcount, dma_fence_release);
}

void
dma_fence_set_error(struct dma_fence *f, int error)
{
	ASSERT(!fence_test(f, DMA_FENCE_FLAG_SIGNALED_BIT));
	f->error = error;
}

/*
 * dma_fence_signal_locked - mark signalled, wake waiters, fire+remove all
 * callbacks. Caller holds f->lock. Cribbed from linux_dma_fence.c
 * dma_fence_signal_locked. Returns 0, or -EINVAL if already signalled.
 */
int
dma_fence_signal_locked(struct dma_fence *f)
{
	struct dma_fence_cb *cb;

	ASSERT(MUTEX_HELD(f->lock));
	if (fence_test_and_set(f, DMA_FENCE_FLAG_SIGNALED_BIT))
		return (-EINVAL);

	cv_broadcast(&f->f_cv);

	while ((cb = list_remove_head(&f->f_callbacks)) != NULL) {
		cb->fcb_onqueue = B_FALSE;
		cb->func(f, cb);
	}
	return (0);
}

int
dma_fence_signal(struct dma_fence *f)
{
	int ret;

	mutex_enter(f->lock);
	ret = dma_fence_signal_locked(f);
	mutex_exit(f->lock);
	return (ret);
}

/*
 * dma_fence_ensure_signal_enabled - call the driver enable_signaling op once.
 * If the op declines (returns false) the fence is signalled immediately and we
 * report -ENOENT. Caller holds f->lock. Cribbed from linux_dma_fence.c.
 */
static int
dma_fence_ensure_signal_enabled(struct dma_fence *f)
{
	boolean_t already;

	ASSERT(MUTEX_HELD(f->lock));
	if (fence_test(f, DMA_FENCE_FLAG_SIGNALED_BIT))
		return (-ENOENT);

	already = fence_test_and_set(f, DMA_FENCE_FLAG_ENABLE_SIGNAL_BIT);
	if (!already && f->ops != NULL && f->ops->enable_signaling != NULL) {
		if (!f->ops->enable_signaling(f)) {
			(void) dma_fence_signal_locked(f);
			return (-ENOENT);
		}
	}
	return (0);
}

boolean_t
dma_fence_is_signaled(struct dma_fence *f)
{
	boolean_t signaled;

	mutex_enter(f->lock);
	if (fence_test(f, DMA_FENCE_FLAG_SIGNALED_BIT)) {
		signaled = B_TRUE;
	} else if (f->ops != NULL && f->ops->signaled != NULL &&
	    f->ops->signaled(f)) {
		/* implicit external signal: act as if dma_fence_signal ran. */
		(void) dma_fence_signal_locked(f);
		signaled = B_TRUE;
	} else {
		signaled = B_FALSE;
	}
	mutex_exit(f->lock);
	return (signaled);
}

int
dma_fence_add_callback(struct dma_fence *f, struct dma_fence_cb *cb,
    dma_fence_func_t fn)
{
	int ret;

	/* fast path: already signalled -> nothing to hook. */
	if (fence_test(f, DMA_FENCE_FLAG_SIGNALED_BIT)) {
		cb->func = NULL;
		cb->fcb_onqueue = B_FALSE;
		return (-ENOENT);
	}

	mutex_enter(f->lock);
	ret = dma_fence_ensure_signal_enabled(f);
	if (ret == 0) {
		cb->func = fn;
		list_insert_tail(&f->f_callbacks, cb);
		cb->fcb_onqueue = B_TRUE;
	}
	mutex_exit(f->lock);
	if (ret != 0) {
		cb->func = NULL;
		cb->fcb_onqueue = B_FALSE;
	}
	return (ret);
}

boolean_t
dma_fence_remove_callback(struct dma_fence *f, struct dma_fence_cb *cb)
{
	boolean_t onqueue;

	mutex_enter(f->lock);
	onqueue = cb->fcb_onqueue;
	if (onqueue) {
		list_remove(&f->f_callbacks, cb);
		cb->fcb_onqueue = B_FALSE;
	}
	mutex_exit(f->lock);
	return (onqueue);
}

void
dma_fence_enable_sw_signaling(struct dma_fence *f)
{
	mutex_enter(f->lock);
	if (!fence_test(f, DMA_FENCE_FLAG_SIGNALED_BIT))
		(void) dma_fence_ensure_signal_enabled(f);
	mutex_exit(f->lock);
}

/*
 * dma_fence_wait_timeout - block until signalled or timeout. Returns ticks
 * remaining (>=1) on signal, 0 on timeout, -EINTR if interrupted. Cribbed from
 * linux_dma_fence.c dma_fence_default_wait, mapped to cv_timedwait[_sig].
 */
long
dma_fence_wait_timeout(struct dma_fence *f, boolean_t intr, long timeout)
{
	clock_t deadline, now;
	long ret = 0;

	if (timeout < 0)
		return (-EINVAL);

	if (fence_test(f, DMA_FENCE_FLAG_SIGNALED_BIT))
		return (timeout > 0 ? timeout : 1);

	mutex_enter(f->lock);
	if (dma_fence_ensure_signal_enabled(f) != 0) {
		/* already signalled while enabling. */
		mutex_exit(f->lock);
		return (timeout > 0 ? timeout : 1);
	}
	if (timeout == 0) {
		ret = fence_test(f, DMA_FENCE_FLAG_SIGNALED_BIT) ? 1 : 0;
		mutex_exit(f->lock);
		return (ret);
	}

	now = ddi_get_lbolt();
	deadline = (timeout >= DMA_FENCE_WAIT_FOREVER) ? 0 : now + timeout;

	while (!fence_test(f, DMA_FENCE_FLAG_SIGNALED_BIT)) {
		if (deadline != 0) {
			int rc;
			now = ddi_get_lbolt();
			if (now >= deadline)
				break;	/* timed out */
			if (intr)
				rc = cv_timedwait_sig(&f->f_cv, f->lock,
				    deadline);
			else
				rc = cv_timedwait(&f->f_cv, f->lock, deadline);
			if (rc == 0 && intr) {	/* interrupted */
				ret = -EINTR;
				break;
			}
			if (rc == -1)		/* timed out */
				break;
		} else {
			if (intr) {
				if (cv_wait_sig(&f->f_cv, f->lock) == 0) {
					ret = -EINTR;
					break;
				}
			} else {
				cv_wait(&f->f_cv, f->lock);
			}
		}
	}

	if (ret == 0) {
		if (fence_test(f, DMA_FENCE_FLAG_SIGNALED_BIT)) {
			now = ddi_get_lbolt();
			ret = (deadline != 0) ?
			    (deadline > now ? (deadline - now) : 1) :
			    (timeout > 0 ? timeout : 1);
		} else {
			ret = 0;	/* timed out */
		}
	}
	mutex_exit(f->lock);
	return (ret);
}

long
dma_fence_wait(struct dma_fence *f, boolean_t intr)
{
	long ret = dma_fence_wait_timeout(f, intr, DMA_FENCE_WAIT_FOREVER);
	return (ret < 0 ? ret : 0);
}

/* ================= ww_mutex (wound/wait) ================= */

/* the reservation-object shared ww_class (Linux reservation_ww_class). */
struct ww_class reservation_ww_class = { 0 };

void
ww_acquire_init(struct ww_acquire_ctx *ctx, struct ww_class *class)
{
	ctx->wwx_class = class;
	ctx->wwx_owner = curthread;
	ctx->wwx_ticket = atomic_add_64_nv(&class->wwc_ticket, 1) - 1;
	ctx->wwx_acquired = 0;
	ctx->wwx_done = B_FALSE;
}
void
ww_acquire_done(struct ww_acquire_ctx *ctx)
{
	ctx->wwx_done = B_TRUE;
}
void
ww_acquire_fini(struct ww_acquire_ctx *ctx)
{
	ASSERT(ctx->wwx_acquired == 0);
	ctx->wwx_owner = NULL;
}

void
ww_mutex_init(struct ww_mutex *m, struct ww_class *class)
{
	mutex_init(&m->wwm_lock, NULL, MUTEX_DRIVER, NULL);
	cv_init(&m->wwm_cv, NULL, CV_DRIVER, NULL);
	m->wwm_state = WW_UNLOCKED;
	m->wwm_class = class;
	m->wwm_owner = NULL;
	m->wwm_ctx = NULL;
}
void
ww_mutex_destroy(struct ww_mutex *m)
{
	ASSERT(m->wwm_state == WW_UNLOCKED);
	cv_destroy(&m->wwm_cv);
	mutex_destroy(&m->wwm_lock);
}
boolean_t
ww_mutex_is_locked(struct ww_mutex *m)
{
	boolean_t locked;
	mutex_enter(&m->wwm_lock);
	locked = (m->wwm_state != WW_UNLOCKED);
	mutex_exit(&m->wwm_lock);
	return (locked);
}

/* wait for the mutex to leave a given state; caller holds wwm_lock. */
static void
ww_mutex_state_wait(struct ww_mutex *m, uint8_t state)
{
	while (m->wwm_state == state)
		cv_wait(&m->wwm_cv, &m->wwm_lock);
}

/*
 * ww_mutex_lock - the wound/wait acquire. Cribbed from linux_ww_mutex.c:
 *   - ctx==NULL: plain blocking lock (no deadlock avoidance).
 *   - ctx!=NULL: if held by us -> -EALREADY; if held by a lower-ticket (older)
 *     context -> wait; if held by a higher-ticket (younger) context -> -EDEADLK
 *     (caller must back off all its locks and retry via ww_mutex_lock_slow).
 */
int
ww_mutex_lock(struct ww_mutex *m, struct ww_acquire_ctx *ctx)
{
	int ret;

	mutex_enter(&m->wwm_lock);
	if (ctx == NULL) {
		while (m->wwm_state != WW_UNLOCKED)
			cv_wait(&m->wwm_cv, &m->wwm_lock);
		m->wwm_state = WW_OWNED;
		m->wwm_owner = curthread;
		mutex_exit(&m->wwm_lock);
		return (0);
	}

retry:
	switch (m->wwm_state) {
	case WW_UNLOCKED:
		m->wwm_state = WW_CTX;
		m->wwm_ctx = ctx;
		ctx->wwx_acquired++;
		mutex_exit(&m->wwm_lock);
		return (0);
	case WW_OWNED:
		/* owned by a ctx-less thread: just wait it out. */
		ww_mutex_state_wait(m, WW_OWNED);
		goto retry;
	case WW_CTX:
		break;
	default:
		panic("ww_mutex %p bad state %d", (void *)m,
		    (int)m->wwm_state);
	}

	if (m->wwm_ctx == ctx) {
		ret = -EALREADY;		/* we already hold it */
		mutex_exit(&m->wwm_lock);
		return (ret);
	}
	if (m->wwm_ctx->wwx_ticket < ctx->wwx_ticket) {
		/* held by an older (higher-priority) ctx: back off. */
		ret = -EDEADLK;
		mutex_exit(&m->wwm_lock);
		return (ret);
	}
	/* held by a younger ctx: wait for it to release. */
	while (m->wwm_state == WW_CTX && m->wwm_ctx != ctx)
		cv_wait(&m->wwm_cv, &m->wwm_lock);
	goto retry;
}

/*
 * ww_mutex_lock_slow - the post-backoff re-acquire of the one contended lock.
 * Called after -EDEADLK when the caller has released all its other locks; it
 * blocks unconditionally for this lock (no -EDEADLK possible). Cribbed from
 * linux_ww_mutex.c ww_mutex_lock_slow.
 */
void
ww_mutex_lock_slow(struct ww_mutex *m, struct ww_acquire_ctx *ctx)
{
	mutex_enter(&m->wwm_lock);
	for (;;) {
		if (m->wwm_state == WW_UNLOCKED) {
			m->wwm_state = WW_CTX;
			m->wwm_ctx = ctx;
			ctx->wwx_acquired++;
			break;
		}
		cv_wait(&m->wwm_cv, &m->wwm_lock);
	}
	mutex_exit(&m->wwm_lock);
}

int
ww_mutex_trylock(struct ww_mutex *m)
{
	int got = 0;
	mutex_enter(&m->wwm_lock);
	if (m->wwm_state == WW_UNLOCKED) {
		m->wwm_state = WW_OWNED;
		m->wwm_owner = curthread;
		got = 1;
	}
	mutex_exit(&m->wwm_lock);
	return (got);
}

void
ww_mutex_unlock(struct ww_mutex *m)
{
	mutex_enter(&m->wwm_lock);
	if (m->wwm_state == WW_CTX && m->wwm_ctx != NULL)
		m->wwm_ctx->wwx_acquired--;
	m->wwm_state = WW_UNLOCKED;
	m->wwm_owner = NULL;
	m->wwm_ctx = NULL;
	cv_broadcast(&m->wwm_cv);
	mutex_exit(&m->wwm_lock);
}

/* ================= dma-resv ================= */

void
dma_resv_init(struct dma_resv *resv)
{
	ww_mutex_init(&resv->lock, &reservation_ww_class);
	resv->fence_excl = NULL;
	resv->shared_count = 0;
	resv->shared_max = 0;
	resv->shared = NULL;
}

void
dma_resv_fini(struct dma_resv *resv)
{
	uint32_t i;

	if (resv->fence_excl != NULL)
		dma_fence_put(resv->fence_excl);
	for (i = 0; i < resv->shared_count; i++)
		dma_fence_put(resv->shared[i]);
	if (resv->shared != NULL)
		kmem_free(resv->shared,
		    resv->shared_max * sizeof (struct dma_fence *));
	ww_mutex_destroy(&resv->lock);
}

int
dma_resv_lock(struct dma_resv *resv, struct ww_acquire_ctx *ctx)
{
	return (ww_mutex_lock(&resv->lock, ctx));
}
void
dma_resv_lock_slow(struct dma_resv *resv, struct ww_acquire_ctx *ctx)
{
	ww_mutex_lock_slow(&resv->lock, ctx);
}
int
dma_resv_trylock(struct dma_resv *resv)
{
	return (ww_mutex_trylock(&resv->lock));
}
void
dma_resv_unlock(struct dma_resv *resv)
{
	ww_mutex_unlock(&resv->lock);
}
boolean_t
dma_resv_is_locked(struct dma_resv *resv)
{
	return (ww_mutex_is_locked(&resv->lock));
}

/*
 * dma_resv_reserve_shared - grow the shared-fence array so num_fences more can
 * be added without allocating under the (later) add path. Cribbed from
 * linux_dma_resv.c dma_resv_reserve_shared, minus the RCU-safe swap.
 */
int
dma_resv_reserve_shared(struct dma_resv *resv, unsigned int num_fences)
{
	uint32_t need = resv->shared_count + num_fences;
	struct dma_fence **grown;
	uint32_t newmax;

	if (need <= resv->shared_max)
		return (0);
	newmax = resv->shared_max ? resv->shared_max : 4;
	while (newmax < need)
		newmax *= 2;

	grown = kmem_zalloc(newmax * sizeof (struct dma_fence *), KM_SLEEP);
	if (resv->shared != NULL) {
		bcopy(resv->shared, grown,
		    resv->shared_count * sizeof (struct dma_fence *));
		kmem_free(resv->shared,
		    resv->shared_max * sizeof (struct dma_fence *));
	}
	resv->shared = grown;
	resv->shared_max = newmax;
	return (0);
}

/*
 * dma_resv_add_excl_fence - set the exclusive (write) fence, dropping the old
 * excl fence and all shared fences (a write orders after every prior access).
 * Caller holds the resv lock. Cribbed from linux_dma_resv.c.
 */
void
dma_resv_add_excl_fence(struct dma_resv *resv, struct dma_fence *fence)
{
	struct dma_fence *old_excl = resv->fence_excl;
	uint32_t i, old_count = resv->shared_count;

	if (fence != NULL)
		(void) dma_fence_get(fence);
	resv->fence_excl = fence;
	/* clear shared fences: the excl fence subsumes them. */
	for (i = 0; i < old_count; i++)
		dma_fence_put(resv->shared[i]);
	resv->shared_count = 0;
	if (old_excl != NULL)
		dma_fence_put(old_excl);
}

/*
 * dma_resv_add_shared_fence - append a shared (read) fence. Requires a prior
 * dma_resv_reserve_shared to have grown the array. Caller holds the resv lock.
 */
void
dma_resv_add_shared_fence(struct dma_resv *resv, struct dma_fence *fence)
{
	ASSERT(resv->shared_count < resv->shared_max);
	(void) dma_fence_get(fence);
	resv->shared[resv->shared_count++] = fence;
}

struct dma_fence *
dma_resv_get_excl(struct dma_resv *resv)
{
	return (resv->fence_excl);
}

/*
 * dma_resv_wait_timeout - wait for the resv's fences. If wait_all, wait for the
 * excl fence + every shared fence; else just the excl fence. Returns as
 * dma_fence_wait_timeout (ticks left / 0 timeout / -errno). Caller holds the
 * resv lock (readers are lock-protected here; NetBSD uses RCU).
 */
long
dma_resv_wait_timeout(struct dma_resv *resv, boolean_t wait_all,
    boolean_t intr, long timeout)
{
	long ret;
	uint32_t i;

	if (resv->fence_excl != NULL) {
		ret = dma_fence_wait_timeout(resv->fence_excl, intr, timeout);
		if (ret <= 0)
			return (ret);
		timeout = ret;
	}
	if (wait_all) {
		for (i = 0; i < resv->shared_count; i++) {
			ret = dma_fence_wait_timeout(resv->shared[i], intr,
			    timeout);
			if (ret <= 0)
				return (ret);
			timeout = ret;
		}
	}
	return (timeout > 0 ? timeout : 1);
}
