/*
 * linux_compat.h - the C1a subset of NetBSD's linux-KPI shim, mapped to illumos.
 *
 * NetBSD's sys/external/bsd/drm2/{linux,include/linux} + common/linux emulate
 * the Linux kernel API the imported DRM core calls (31 .c + 178 headers). This
 * header is the illumos analogue for ONLY the primitives the drm-core + GEM
 * create/close/mmap stub exercises. Each Linux primitive is mapped to its
 * illumos ddi/ksynch equivalent; the fuller mapping (workqueue, dma-fence,
 * dma-resv, ww_mutex, radixtree/xarray, rcu) is documented in DESIGN.md and
 * deferred to C1b/C1c.
 *
 * Mapping summary (Linux -> illumos), full table in DESIGN.md:
 *   struct kref        -> uint_t + atomic_inc/dec_uint  (sys/atomic.h)
 *   struct idr         -> avl_tree_t keyed by u32 handle (sys/avl.h) [C1a: simple]
 *   struct mutex       -> kmutex_t + mutex_enter/exit   (sys/ksynch.h)
 *   spinlock_t         -> kmutex_t (MUTEX_DRIVER)        (sys/ksynch.h)
 *   kmalloc/kfree      -> kmem_alloc/kmem_free          (sys/kmem.h)
 *   copy_to/from_user  -> ddi_copyout/ddi_copyin        (sys/sunddi.h)
 *   EXPORT_SYMBOL      -> no-op (single module, no per-symbol export)
 */

#ifndef _DRM_LINUX_COMPAT_H_
#define _DRM_LINUX_COMPAT_H_

#include <sys/types.h>
#include <sys/sysmacros.h>	/* offsetof */
#include <sys/atomic.h>
#include <sys/kmem.h>
#include <sys/ksynch.h>
#include <sys/sunddi.h>
#include <sys/avl.h>
#include <sys/errno.h>

/*
 * Linux negative-errno convention. The DRM core returns -EINVAL etc.; the
 * illumos cb_ioctl contract returns positive errnos. The dispatch layer
 * negates on the boundary (see drm_core.c drm_ioctl_shim). We keep the Linux
 * names so cribbed core code reads unchanged.
 */
#ifndef EFAULT
#define EFAULT	14
#endif

/* --- kref: Linux reference count -> illumos atomic uint --- */
struct kref {
	volatile uint_t refcount;
};
static inline void
kref_init(struct kref *k)
{
	k->refcount = 1;
}
static inline void
kref_get(struct kref *k)
{
	atomic_inc_uint(&k->refcount);
}
/* returns 1 (and caller must release) when the count hit zero */
static inline int
kref_put(struct kref *k, void (*release)(struct kref *))
{
	if (atomic_dec_uint_nv(&k->refcount) == 0) {
		if (release != NULL)
			release(k);
		return (1);
	}
	return (0);
}

/* --- kmalloc/kfree -> kmem --- */
#define GFP_KERNEL	0
static inline void *
kzalloc(size_t sz, int flags)
{
	(void) flags;
	return (kmem_zalloc(sz, KM_SLEEP));
}
static inline void
kfree_sz(void *p, size_t sz)
{
	if (p != NULL)
		kmem_free(p, sz);
}

/*
 * --- idr: Linux integer-id -> object map. GEM uses it for handle<->bo.
 * C1a implementation: an AVL tree keyed by a monotonically-issued u32 handle.
 * NOTE: linear id issue (next_id++), fine for a stub; a real port swaps in
 * illumos id_space(9F) for handle reuse + wraparound safety (see DESIGN.md).
 */
struct idr_entry {
	avl_node_t	ie_node;
	uint32_t	ie_id;
	void		*ie_ptr;
};
struct idr {
	kmutex_t	idr_lock;
	avl_tree_t	idr_tree;
	uint32_t	idr_next;
};

static int
idr_compare(const void *a, const void *b)
{
	const struct idr_entry *ea = a, *eb = b;
	if (ea->ie_id < eb->ie_id)
		return (-1);
	if (ea->ie_id > eb->ie_id)
		return (1);
	return (0);
}
static inline void
idr_init(struct idr *idr)
{
	mutex_init(&idr->idr_lock, NULL, MUTEX_DRIVER, NULL);
	avl_create(&idr->idr_tree, idr_compare, sizeof (struct idr_entry),
	    offsetof(struct idr_entry, ie_node));
	idr->idr_next = 1;	/* handle 0 is reserved / invalid */
}
static inline void
idr_destroy(struct idr *idr)
{
	struct idr_entry *e;
	void *cookie = NULL;
	while ((e = avl_destroy_nodes(&idr->idr_tree, &cookie)) != NULL)
		kmem_free(e, sizeof (*e));
	avl_destroy(&idr->idr_tree);
	mutex_destroy(&idr->idr_lock);
}
/* allocate a new id for ptr; returns id (>0) or 0 on OOM */
static inline uint32_t
idr_alloc(struct idr *idr, void *ptr)
{
	struct idr_entry *e = kmem_zalloc(sizeof (*e), KM_SLEEP);
	uint32_t id;
	mutex_enter(&idr->idr_lock);
	id = idr->idr_next++;
	e->ie_id = id;
	e->ie_ptr = ptr;
	avl_add(&idr->idr_tree, e);
	mutex_exit(&idr->idr_lock);
	return (id);
}
static inline void *
idr_find(struct idr *idr, uint32_t id)
{
	struct idr_entry key, *e;
	void *ptr = NULL;
	key.ie_id = id;
	mutex_enter(&idr->idr_lock);
	e = avl_find(&idr->idr_tree, &key, NULL);
	if (e != NULL)
		ptr = e->ie_ptr;
	mutex_exit(&idr->idr_lock);
	return (ptr);
}
/* remove id; returns the ptr that was stored, or NULL */
static inline void *
idr_remove(struct idr *idr, uint32_t id)
{
	struct idr_entry key, *e;
	void *ptr = NULL;
	key.ie_id = id;
	mutex_enter(&idr->idr_lock);
	e = avl_find(&idr->idr_tree, &key, NULL);
	if (e != NULL) {
		ptr = e->ie_ptr;
		avl_remove(&idr->idr_tree, e);
		kmem_free(e, sizeof (*e));
	}
	mutex_exit(&idr->idr_lock);
	return (ptr);
}

#endif /* _DRM_LINUX_COMPAT_H_ */
