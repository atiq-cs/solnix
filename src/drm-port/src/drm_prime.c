/*
 * drm_prime.c - PRIME (dma-buf) handle<->fd + sync_file, the C1c cross-driver /
 * cross-process buffer- and fence-sharing layer, over the illumos file/vnode
 * mechanism.
 *
 * ---- The illumos dma-buf gap and how this closes it ----
 *
 * Linux exports a GEM buffer as a `dma_buf` fd: an anonymous struct file whose
 * f_op points at dma_buf_fops, carrying a struct dma_buf that owns the pages.
 * Another process/driver imports it via the fd (received over SCM_RIGHTS) and
 * dma_buf_map/attach re-derives the sg-table. illumos has no anonymous-file
 * dma-buf type. But illumos DOES have the two ingredients Linux's dma-buf uses:
 *
 *   1. falloc(9F) -> a file_t + an fd, the kernel-side of open(2). Any subsystem
 *      can mint an fd bound to a vnode.
 *   2. makespecvp() -> a spec (device) vnode over a dev_t. mmap/read of a spec
 *      vnode routes to the owning driver's cb_ops (cb_devmap etc.).
 *
 * So the solnix PRIME fd is: an fd from falloc() whose file_t->f_vnode is a
 * spec-vnode over THIS drm device's char node (drm_prime_major) at a private
 * per-export minor that encodes the exported GEM handle. Because it is a real
 * fd over our own device:
 *   - it is passed across processes by the illumos SCM_RIGHTS / I_SENDFD
 *     mechanism exactly like any other fd (the load-bearing requirement);
 *   - mmap(fd) faults through THIS driver's cb_devmap onto the GEM object's
 *     ddi_umem pages (the same pages RESOURCE_ATTACH_BACKING hands the host),
 *     so the importer sees the exact buffer;
 *   - the importing side reverses it with getf(fd) -> fp->f_vnode -> the minor
 *     -> the GEM object (FD_TO_HANDLE), with no Linux dma_buf_ops needed.
 *
 * This is the illumos-native replacement for dma_buf fd-passing that DESIGN.md
 * section D flagged as the one primitive with no clean analogue. It reuses the
 * device's existing devmap path (C1b) instead of inventing a second mmap route.
 *
 * Provenance: the PRIME ioctl contract (DRM_IOCTL_PRIME_HANDLE_TO_FD /
 * FD_TO_HANDLE, struct drm_prime_handle) is the Linux DRM UAPI (reproduced in
 * uapi/drm/drm.h so libdrm/Mesa/GBM are unchanged). The export/import flow
 * follows Linux drm_prime.c drm_gem_prime_handle_to_fd / fd_to_handle and
 * NetBSD drm2's drm_prime glue, re-expressed over falloc/getf/makespecvp
 * instead of Linux anon_inode/dma_buf. sync_file (fd-wrapped fence) uses the
 * same fd mechanism, cribbed from linux_sync_file.c.
 *
 * C1c status: this is the DESIGN piece. The export/import LOGIC + the fd/vnode
 * mechanism compile against the illumos file/vnode KPI. The per-export minor
 * table + the spec-vnode wiring are written to the real KPI (falloc, getf,
 * makespecvp, VN_RELE) but the full runtime (a second minor space carved out of
 * the drm node + devmap dispatch keyed on the export minor) is exercised only
 * on a metal instance -- the compile milestone proves the mechanism is real
 * illumos KPI, not a phantom dma_buf.
 */

#include <sys/types.h>
#include <sys/sysmacros.h>	/* makedevice */
#include <sys/ksynch.h>
#include <sys/kmem.h>
#include <sys/file.h>		/* file_t, falloc, getf, releasef, setf */
#include <sys/vnode.h>		/* makespecvp, VN_RELE, VCHR */
#include <sys/fcntl.h>		/* FREAD, FWRITE */
#include <sys/errno.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>

#include "uapi/drm/drm.h"
#include "drm_internal.h"
#include "linux-compat/linux_dma.h"

/*
 * The exported-buffer minor space. A drm instance's card0/renderD128 minors are
 * fixed (0 / 128); PRIME exports allocate minors from a private high range so a
 * spec-vnode's minor uniquely identifies one live export -> its GEM handle.
 * Kept as a small table under drm_device->lock; O(n) is fine (few live exports
 * per client). DRM_PRIME_MINOR_BASE lives in drm_internal.h.
 */

struct drm_prime_export {
	list_node_t	pe_node;
	minor_t		pe_minor;	/* spec-vnode minor for this export */
	uint32_t	pe_handle;	/* GEM handle exported */	struct drm_gem_object *pe_obj;	/* holds a ref while exported */
	struct vnode	*pe_vp;		/* spec-vnode backing the fd */
};

/*
 * drm_prime_export_lookup_minor - reverse a spec-vnode minor to its export.
 * Used by cb_devmap when a mapped fd is a PRIME export minor rather than an
 * mmap_offset (so an imported fd mmaps onto the right GEM object's pages).
 */
static struct drm_prime_export *
drm_prime_export_lookup_minor(struct drm_device *dev, minor_t m)
{
	struct drm_prime_export *pe;

	ASSERT(MUTEX_HELD(&dev->lock));
	for (pe = list_head(&dev->prime_exports); pe != NULL;
	    pe = list_next(&dev->prime_exports, pe)) {
		if (pe->pe_minor == m)
			return (pe);
	}
	return (NULL);
}

/*
 * drm_gem_prime_handle_to_fd - DRM_IOCTL_PRIME_HANDLE_TO_FD. Export a GEM handle
 * as an fd. Mirrors Linux drm_gem_prime_handle_to_fd; the illumos body mints an
 * fd over a spec-vnode of this device at a private minor that maps back to the
 * handle.
 */
int
drm_gem_prime_handle_to_fd(struct drm_device *dev, intptr_t arg, int mode)
{
	struct drm_prime_handle req;
	struct drm_gem_object *obj;
	struct drm_prime_export *pe;
	struct vnode *vp;
	file_t *fp;
	minor_t minor;
	int fd, rc;

	if (ddi_copyin((void *)arg, &req, sizeof (req), mode) != 0)
		return (EFAULT);

	mutex_enter(&dev->lock);
	obj = idr_find(&dev->gem_handles, req.handle);
	if (obj == NULL) {
		mutex_exit(&dev->lock);
		return (ENOENT);
	}
	/* pin the object for the lifetime of the export. */
	kref_get(&obj->refcount);
	minor = dev->prime_next_minor++;
	mutex_exit(&dev->lock);

	/*
	 * A spec-vnode over this device's dev_t at the export minor: mmap/close
	 * of the resulting fd route through this driver's cb_ops. drm_prime_major
	 * is the driver's major (recorded at attach via ddi_driver_major).
	 */
	vp = makespecvp(makedevice(dev->prime_major, minor), VCHR);
	if (vp == NULL) {
		(void) kref_put(&obj->refcount, drm_gem_object_free);
		return (ENOMEM);
	}

	/* falloc mints a file_t + an fd bound to the vnode. */
	rc = falloc(vp, FREAD | FWRITE, &fp, &fd);
	if (rc != 0) {
		VN_RELE(vp);
		(void) kref_put(&obj->refcount, drm_gem_object_free);
		return (rc);
	}

	pe = kmem_zalloc(sizeof (*pe), KM_SLEEP);
	pe->pe_minor = minor;
	pe->pe_handle = req.handle;
	pe->pe_obj = obj;
	pe->pe_vp = vp;
	mutex_enter(&dev->lock);
	list_insert_tail(&dev->prime_exports, pe);
	mutex_exit(&dev->lock);

	/* falloc returns fp locked (f_tlock held); publish the fd. */
	mutex_exit(&fp->f_tlock);
	setf(fd, fp);

	req.fd = fd;
	if (ddi_copyout(&req, (void *)arg, sizeof (req), mode) != 0)
		return (EFAULT);
	return (0);
}

/*
 * drm_gem_prime_fd_to_handle - DRM_IOCTL_PRIME_FD_TO_HANDLE. Import an fd (a
 * PRIME export, possibly received over SCM_RIGHTS from another process) back to
 * a GEM handle in this client. Mirrors Linux drm_gem_prime_fd_to_handle.
 * getf(fd) -> the file_t -> its spec-vnode minor -> the export -> the object.
 */
int
drm_gem_prime_fd_to_handle(struct drm_device *dev, intptr_t arg, int mode)
{
	struct drm_prime_handle req;
	struct drm_prime_export *pe;
	struct drm_gem_object *obj;
	file_t *fp;
	minor_t minor;

	if (ddi_copyin((void *)arg, &req, sizeof (req), mode) != 0)
		return (EFAULT);

	fp = getf((int)req.fd);
	if (fp == NULL)
		return (EBADF);
	if (fp->f_vnode == NULL || fp->f_vnode->v_type != VCHR) {
		releasef((int)req.fd);
		return (EINVAL);
	}
	minor = getminor(fp->f_vnode->v_rdev);
	releasef((int)req.fd);

	mutex_enter(&dev->lock);
	pe = drm_prime_export_lookup_minor(dev, minor);
	if (pe == NULL) {
		mutex_exit(&dev->lock);
		return (EINVAL);	/* not one of our exports */
	}
	obj = pe->pe_obj;
	/*
	 * Re-issue a handle for the imported object in this client's table and
	 * take a reference. (Same-device import: the object is shared directly;
	 * a cross-device import would re-wrap the pages -- C3.)
	 */
	kref_get(&obj->refcount);
	req.handle = idr_alloc(&dev->gem_handles, obj);
	mutex_exit(&dev->lock);

	if (ddi_copyout(&req, (void *)arg, sizeof (req), mode) != 0)
		return (EFAULT);
	return (0);
}

/*
 * drm_prime_export_teardown - drop one export (called when its fd's last close
 * routes to cb_close for the export minor, or at detach). Releases the object
 * ref and the spec-vnode.
 */
void
drm_prime_export_teardown(struct drm_device *dev, minor_t m)
{
	struct drm_prime_export *pe;

	mutex_enter(&dev->lock);
	pe = drm_prime_export_lookup_minor(dev, m);
	if (pe != NULL)
		list_remove(&dev->prime_exports, pe);
	mutex_exit(&dev->lock);
	if (pe == NULL)
		return;
	if (pe->pe_vp != NULL)
		VN_RELE(pe->pe_vp);
	(void) kref_put(&pe->pe_obj->refcount, drm_gem_object_free);
	kmem_free(pe, sizeof (*pe));
}

/*
 * drm_prime_devmap_object - resolve a PRIME export minor to the GEM object its
 * fd should mmap. cb_devmap calls this when the mapped minor is >=
 * DRM_PRIME_MINOR_BASE (an imported/exported fd) rather than the card/render
 * node, so mmap(prime_fd) faults onto the exported object's umem pages.
 */
struct drm_gem_object *
drm_prime_devmap_object(struct drm_device *dev, minor_t m)
{
	struct drm_prime_export *pe;
	struct drm_gem_object *obj = NULL;

	mutex_enter(&dev->lock);
	pe = drm_prime_export_lookup_minor(dev, m);
	if (pe != NULL)
		obj = pe->pe_obj;
	mutex_exit(&dev->lock);
	return (obj);
}

/* ================= sync_file (fd-wrapped fence) ================= */

/*
 * A sync_file wraps a dma_fence in an fd so userland can pass a
 * GPU-completion signal between processes and poll(2) on it. It uses the SAME
 * fd mechanism as PRIME: falloc over a spec-vnode of this device at a private
 * minor; the minor maps to the sync_file (holding a fence ref). poll(2) of the
 * fd reports POLLIN once the fence signals (wired via dma_fence_add_callback).
 * Cribbed from linux_sync_file.c, re-expressed over falloc/getf; the poll
 * wakeup uses pollwakeup(9F) instead of NetBSD selnotify.
 *
 * C1c: the data structure + create/lookup logic compile; the poll callback ties
 * into the drm node's cb_chpoll (still nochpoll in C1b -- wiring the DRM event
 * queue + pollwakeup is the remaining runtime step, noted in STATUS.md).
 */
struct sync_file {
	list_node_t		sf_node;
	minor_t			sf_minor;
	struct dma_fence	*sf_fence;
	struct dma_fence_cb	sf_cb;
	boolean_t		sf_signalled;
};

static void
sync_file_fence_cb(struct dma_fence *fence, struct dma_fence_cb *cb)
{
	struct sync_file *sf = (struct sync_file *)((char *)cb -
	    offsetof(struct sync_file, sf_cb));
	(void) fence;
	sf->sf_signalled = B_TRUE;
	/* runtime: pollwakeup(&drm_pollhead, POLLIN) once cb_chpoll is wired. */
}

/*
 * sync_file_create - wrap a fence in a new fd. Returns the fd or -errno. The
 * sync_file takes a ref on the fence and registers a signalling callback.
 */
int
sync_file_create(struct drm_device *dev, struct dma_fence *fence)
{
	struct sync_file *sf;
	struct vnode *vp;
	file_t *fp;
	minor_t minor;
	int fd, rc;

	sf = kmem_zalloc(sizeof (*sf), KM_SLEEP);
	sf->sf_fence = dma_fence_get(fence);
	sf->sf_signalled = B_FALSE;

	mutex_enter(&dev->lock);
	minor = dev->prime_next_minor++;
	mutex_exit(&dev->lock);
	sf->sf_minor = minor;

	vp = makespecvp(makedevice(dev->prime_major, minor), VCHR);
	if (vp == NULL) {
		dma_fence_put(fence);
		kmem_free(sf, sizeof (*sf));
		return (-ENOMEM);
	}
	rc = falloc(vp, FREAD | FWRITE, &fp, &fd);
	if (rc != 0) {
		VN_RELE(vp);
		dma_fence_put(fence);
		kmem_free(sf, sizeof (*sf));
		return (-rc);
	}

	mutex_enter(&dev->lock);
	list_insert_tail(&dev->sync_files, sf);
	mutex_exit(&dev->lock);

	/* fire POLLIN when the fence signals (or mark done if already). */
	if (dma_fence_add_callback(fence, &sf->sf_cb, sync_file_fence_cb) != 0)
		sf->sf_signalled = B_TRUE;

	mutex_exit(&fp->f_tlock);
	setf(fd, fp);
	return (fd);
}

/*
 * sync_file_get_fence - DRM/UAPI import side: an fd -> its underlying fence
 * (with a ref for the caller). Cribbed from sync_file_get_fence.
 */
struct dma_fence *
sync_file_get_fence(struct drm_device *dev, int fd)
{
	struct sync_file *sf;
	struct dma_fence *fence = NULL;
	file_t *fp;
	minor_t minor;

	fp = getf(fd);
	if (fp == NULL || fp->f_vnode == NULL ||
	    fp->f_vnode->v_type != VCHR) {
		if (fp != NULL)
			releasef(fd);
		return (NULL);
	}
	minor = getminor(fp->f_vnode->v_rdev);
	releasef(fd);

	mutex_enter(&dev->lock);
	for (sf = list_head(&dev->sync_files); sf != NULL;
	    sf = list_next(&dev->sync_files, sf)) {
		if (sf->sf_minor == minor) {
			fence = dma_fence_get(sf->sf_fence);
			break;
		}
	}
	mutex_exit(&dev->lock);
	return (fence);
}

/* ================= init / fini ================= */

/*
 * drm_prime_init - create the per-device PRIME export + sync_file lists. Called
 * from drm_attach. The struct sizes live here so the export/sync_file structs
 * stay private to this translation unit.
 */
void
drm_prime_init(struct drm_device *dev)
{
	list_create(&dev->prime_exports, sizeof (struct drm_prime_export),
	    offsetof(struct drm_prime_export, pe_node));
	list_create(&dev->sync_files, sizeof (struct sync_file),
	    offsetof(struct sync_file, sf_node));
}

/*
 * drm_prime_fini - drop any live exports + sync_files and destroy the lists.
 * Called from drm_detach. Each remaining export releases its object ref + its
 * spec-vnode; each sync_file removes its fence callback + drops its fence ref.
 */
void
drm_prime_fini(struct drm_device *dev)
{
	struct drm_prime_export *pe;
	struct sync_file *sf;

	mutex_enter(&dev->lock);
	while ((pe = list_remove_head(&dev->prime_exports)) != NULL) {
		mutex_exit(&dev->lock);
		if (pe->pe_vp != NULL)
			VN_RELE(pe->pe_vp);
		(void) kref_put(&pe->pe_obj->refcount, drm_gem_object_free);
		kmem_free(pe, sizeof (*pe));
		mutex_enter(&dev->lock);
	}
	while ((sf = list_remove_head(&dev->sync_files)) != NULL) {
		mutex_exit(&dev->lock);
		(void) dma_fence_remove_callback(sf->sf_fence, &sf->sf_cb);
		dma_fence_put(sf->sf_fence);
		kmem_free(sf, sizeof (*sf));
		mutex_enter(&dev->lock);
	}
	list_destroy(&dev->prime_exports);
	list_destroy(&dev->sync_files);
	mutex_exit(&dev->lock);
}
