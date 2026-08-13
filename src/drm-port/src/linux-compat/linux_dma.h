/*
 * linux_dma.h - the C1c synchronization + reservation shim, mapped to illumos.
 *
 * This is the C1c layer NetBSD emulates in
 *   drm2/linux/linux_dma_fence.c   (dma-fence: signal/wait/callbacks)
 *   drm2/linux/linux_ww_mutex.c    (wound/wait mutex)
 *   drm2/linux/linux_dma_resv.c    (per-buffer fence container)
 *   drm2/linux/linux_sync_file.c   (fd-wrapped fence)
 * re-expressed against illumos kcondvar_t/kmutex_t/kref. We do NOT lift the
 * NetBSD .c; the struct shapes + semantics (fence flags, wound/wait ticket
 * ordering, resv excl/shared fence lists) are cribbed from those files and from
 * the Linux dma-fence/dma-resv/ww_mutex UAPI+kABI, then bound to illumos
 * primitives. The function bodies live in drm_dma.c.
 *
 * Mapping summary (Linux -> illumos):
 *   struct dma_fence      -> kref + kmutex_t + kcondvar_t + flags + callback list
 *   struct dma_fence_cb   -> a list node + func (called under the fence lock)
 *   struct ww_class       -> atomic64 ticket dispenser
 *   struct ww_acquire_ctx -> per-thread ticket + acquired count
 *   struct ww_mutex       -> kmutex_t + kcondvar_t + ticket-ordered wound/wait
 *   struct dma_resv       -> ww_mutex + excl fence + shared fence array
 *
 * Deliberate C1c simplifications (compile milestone, single-node runtime):
 *   - No RCU: NetBSD's dma-fence/dma-resv use RCU for lockless readers. illumos
 *     has no RCU; every reader here takes the fence/resv lock. The DESIGN.md D
 *     note (global-rwlock/quiescent RCU emulation) applies if lockless fence
 *     reads ever show up hot. Correct, just not lockless.
 *   - ww_mutex is the real wound/wait algorithm (ticket compare -> -EDEADLK,
 *     backoff+retry) but tracks the owning context by pointer + a curthread
 *     identity, not the NetBSD rbtree of waiters; a single cv wakes all waiters
 *     which re-check state. Correct wound/wait, coarser wakeups.
 */

#ifndef _DRM_LINUX_DMA_H_
#define _DRM_LINUX_DMA_H_

#include <sys/types.h>
#include <sys/atomic.h>
#include <sys/kmem.h>
#include <sys/ksynch.h>
#include <sys/list.h>
#include <sys/thread.h>		/* curthread */
#include <sys/ddi.h>		/* ddi_get_lbolt */
#include "linux-compat/linux_compat.h"	/* kref, kzalloc, EFAULT, errnos */

/* Linux errnos the fence/resv/ww paths return (negated at the ioctl boundary). */
#ifndef ENOENT
#define ENOENT	2
#endif
#ifndef EDEADLK
#define EDEADLK	45
#endif
#ifndef EALREADY
#define EALREADY 149
#endif
#ifndef EBUSY
#define EBUSY	16
#endif

/*
 * ---- dma-fence ----
 *
 * A dma_fence is a one-shot signal: it starts unsignalled, is signalled exactly
 * once, and wakes all waiters + fires all callbacks at signal time. Mesa/Vulkan
 * order GPU work with these (submit a job -> get a fence -> wait/callback on
 * completion). Cribbed from linux_dma_fence.c: refcount, a lock, a flags word
 * (ENABLE_SIGNAL/SIGNALED bits), a monotonic (context,seqno) identity, an ops
 * vtable, and a callback list. illumos backing: kref + kmutex_t + kcondvar_t.
 */
#define DMA_FENCE_FLAG_ENABLE_SIGNAL_BIT	0
#define DMA_FENCE_FLAG_SIGNALED_BIT		1

struct dma_fence;
struct dma_fence_cb;
typedef void (*dma_fence_func_t)(struct dma_fence *, struct dma_fence_cb *);

struct dma_fence_cb {
	list_node_t		fcb_node;
	dma_fence_func_t	func;
	boolean_t		fcb_onqueue;
};

struct dma_fence_ops {
	const char	*(*get_driver_name)(struct dma_fence *);
	const char	*(*get_timeline_name)(struct dma_fence *);
	boolean_t	(*enable_signaling)(struct dma_fence *);
	boolean_t	(*signaled)(struct dma_fence *);
	long		(*wait)(struct dma_fence *, boolean_t, long);
	void		(*release)(struct dma_fence *);
};

struct dma_fence {
	struct kref		refcount;
	kmutex_t		*lock;		/* external lock (fence lock) */
	kmutex_t		f_lock_store;	/* used if caller passes NULL */
	kcondvar_t		f_cv;
	volatile uint_t		flags;
	uint64_t		context;
	uint64_t		seqno;
	const struct dma_fence_ops *ops;
	int			error;
	list_t			f_callbacks;	/* struct dma_fence_cb */
};

/* wait timeout sentinel: "wait forever" (Linux MAX_SCHEDULE_TIMEOUT). */
#define DMA_FENCE_WAIT_FOREVER	((long)((~0UL) >> 1))

uint64_t	dma_fence_context_alloc(unsigned count);
void		dma_fence_init(struct dma_fence *, const struct dma_fence_ops *,
		    kmutex_t *lock, uint64_t context, uint64_t seqno);
struct dma_fence *dma_fence_get(struct dma_fence *);
void		dma_fence_put(struct dma_fence *);
int		dma_fence_signal(struct dma_fence *);
int		dma_fence_signal_locked(struct dma_fence *);
boolean_t	dma_fence_is_signaled(struct dma_fence *);
void		dma_fence_set_error(struct dma_fence *, int error);
int		dma_fence_add_callback(struct dma_fence *,
		    struct dma_fence_cb *, dma_fence_func_t);
boolean_t	dma_fence_remove_callback(struct dma_fence *,
		    struct dma_fence_cb *);
void		dma_fence_enable_sw_signaling(struct dma_fence *);
/* returns >0 (ticks left) on signal, 0 on timeout, <0 (-errno) on interrupt. */
long		dma_fence_wait_timeout(struct dma_fence *, boolean_t intr,
		    long timeout);
long		dma_fence_wait(struct dma_fence *, boolean_t intr);

/*
 * ---- ww_mutex (wound/wait) ----
 *
 * Deadlock-free multi-buffer locking: each acquire context takes a globally
 * ordered ticket; a context trying to lock a mutex already held by a
 * higher-ticket (younger) context gets -EDEADLK and must drop everything and
 * retry with dma_resv_lock_slow on the contended lock. Cribbed from
 * linux_ww_mutex.c (WW_UNLOCKED/WW_OWNED/WW_CTX states, ticket compare).
 */
struct ww_class {
	volatile uint64_t	wwc_ticket;
};
#define DEFINE_WW_CLASS(name) struct ww_class name = { 0 }

struct ww_acquire_ctx {
	struct ww_class	*wwx_class;
	kthread_t	*wwx_owner;	/* curthread that owns this ctx */
	uint64_t	wwx_ticket;
	unsigned	wwx_acquired;
	boolean_t	wwx_done;
};

enum ww_mutex_state {
	WW_UNLOCKED = 0,	/* nobody owns it */
	WW_OWNED,		/* owned by a thread with no context */
	WW_CTX			/* owned by an acquire context */
};

struct ww_mutex {
	kmutex_t		wwm_lock;
	kcondvar_t		wwm_cv;
	uint8_t			wwm_state;
	struct ww_class		*wwm_class;
	kthread_t		*wwm_owner;	/* WW_OWNED: owning thread */
	struct ww_acquire_ctx	*wwm_ctx;	/* WW_CTX: owning context */
};

void	ww_acquire_init(struct ww_acquire_ctx *, struct ww_class *);
void	ww_acquire_done(struct ww_acquire_ctx *);
void	ww_acquire_fini(struct ww_acquire_ctx *);
void	ww_mutex_init(struct ww_mutex *, struct ww_class *);
void	ww_mutex_destroy(struct ww_mutex *);
boolean_t ww_mutex_is_locked(struct ww_mutex *);
int	ww_mutex_lock(struct ww_mutex *, struct ww_acquire_ctx *);
void	ww_mutex_lock_slow(struct ww_mutex *, struct ww_acquire_ctx *);
int	ww_mutex_trylock(struct ww_mutex *);
void	ww_mutex_unlock(struct ww_mutex *);

/*
 * ---- dma-resv (reservation object) ----
 *
 * The per-buffer fence container GEM objects carry: one exclusive (write)
 * fence + N shared (read) fences, all protected by the object's ww_mutex.
 * Mesa/Vulkan attach the fence of each submitted job here so later submissions
 * (and page-flip / export) wait on prior GPU access. Cribbed from
 * linux_dma_resv.c (excl fence + shared_count array), minus the RCU readers.
 */
struct dma_resv {
	struct ww_mutex		lock;
	struct dma_fence	*fence_excl;
	uint32_t		shared_count;
	uint32_t		shared_max;
	struct dma_fence	**shared;	/* shared_max slots */
};

extern struct ww_class	reservation_ww_class;

void	dma_resv_init(struct dma_resv *);
void	dma_resv_fini(struct dma_resv *);
int	dma_resv_lock(struct dma_resv *, struct ww_acquire_ctx *);
void	dma_resv_lock_slow(struct dma_resv *, struct ww_acquire_ctx *);
int	dma_resv_trylock(struct dma_resv *);
void	dma_resv_unlock(struct dma_resv *);
boolean_t dma_resv_is_locked(struct dma_resv *);
int	dma_resv_reserve_shared(struct dma_resv *, unsigned int num_fences);
void	dma_resv_add_excl_fence(struct dma_resv *, struct dma_fence *);
void	dma_resv_add_shared_fence(struct dma_resv *, struct dma_fence *);
struct dma_fence *dma_resv_get_excl(struct dma_resv *);
/* wait for all fences in the resv; timeout as dma_fence_wait_timeout. */
long	dma_resv_wait_timeout(struct dma_resv *, boolean_t wait_all,
	    boolean_t intr, long timeout);

#endif /* _DRM_LINUX_DMA_H_ */
