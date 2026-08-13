/*
 * drm_gem.c - GEM (Graphics Execution Manager) buffer objects for illumos.
 *
 * Provenance: the object lifecycle (create -> handle in idr -> refcounted ->
 * close/free) mirrors NetBSD/Linux
 *   sys/external/bsd/drm2/dist/drm/drm_gem.c
 * (drm_gem_object_init / drm_gem_handle_create / drm_gem_object_release /
 * drm_gem_handle_delete). C1b replaces the C1a kmem_zalloc stub backing with
 * real illumos memory via ddi_umem_alloc(9F): the returned cookie is handed to
 * devmap_umem_setup(9F) in drm_core.c cb_devmap so a userland mmap of the DRI
 * node faults in exactly these pages -- the illumos analogue of Linux
 * drm_gem_mmap -> shmem/uvm fault. Same pages also become the virtio-gpu
 * RESOURCE_ATTACH_BACKING sg-list (virtio_gpu.c), so the host reads guest RAM.
 */

#include <sys/types.h>
#include <sys/sysmacros.h>	/* P2ROUNDUP */
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/ddidevmap.h>	/* ddi_umem_alloc, DDI_UMEM_SLEEP */

#include "uapi/drm/drm.h"
#include "drm_internal.h"

/* Called when the last reference on a GEM object drops (kref release). */
void
drm_gem_object_free(struct kref *kref)
{
	struct drm_gem_object *obj =
	    (struct drm_gem_object *)((char *)kref -
	    offsetof(struct drm_gem_object, refcount));

	if (obj->umem_cookie != NULL)
		ddi_umem_free(obj->umem_cookie);
	kmem_free(obj, sizeof (*obj));
}

/*
 * DRM_IOCTL_MODE_CREATE_DUMB - allocate a dumb (linear) buffer, back it, and
 * hand back a GEM handle + pitch + size. Mirrors Linux drm_mode_create_dumb.
 */
int
drm_gem_create_dumb(struct drm_device *dev, intptr_t arg, int mode)
{
	struct drm_mode_create_dumb req;
	struct drm_gem_object *obj;
	uint32_t pitch;
	uint64_t size;

	if (ddi_copyin((void *)arg, &req, sizeof (req), mode) != 0)
		return (EFAULT);

	/* pitch = width * bytes-per-pixel, rounded; size = pitch * height. */
	pitch = req.width * ((req.bpp + 7) / 8);
	size = (uint64_t)pitch * req.height;
	if (size == 0)
		return (EINVAL);
	size = P2ROUNDUP(size, PAGESIZE);

	obj = kmem_zalloc(sizeof (*obj), KM_SLEEP);
	kref_init(&obj->refcount);
	obj->size = (size_t)size;
	/*
	 * Real page backing: ddi_umem_alloc gives kernel-VA-mapped, pageable
	 * memory plus a cookie that devmap_umem_setup can hand to userland.
	 * This replaces the C1a kmem_zalloc stub.
	 */
	obj->kaddr = ddi_umem_alloc(obj->size, DDI_UMEM_SLEEP,
	    &obj->umem_cookie);
	if (obj->kaddr == NULL) {
		kmem_free(obj, sizeof (*obj));
		return (ENOMEM);
	}

	mutex_enter(&dev->lock);
	obj->handle = idr_alloc(&dev->gem_handles, obj);
	obj->mmap_offset = dev->next_mmap_offset;
	dev->next_mmap_offset += obj->size;
	mutex_exit(&dev->lock);

	req.handle = obj->handle;
	req.pitch = pitch;
	req.size = size;

	if (ddi_copyout(&req, (void *)arg, sizeof (req), mode) != 0) {
		/* roll back the handle on copyout failure */
		mutex_enter(&dev->lock);
		(void) idr_remove(&dev->gem_handles, obj->handle);
		mutex_exit(&dev->lock);
		(void) kref_put(&obj->refcount, drm_gem_object_free);
		return (EFAULT);
	}
	return (0);
}

/*
 * DRM_IOCTL_MODE_MAP_DUMB - return the fake mmap offset for a handle. The
 * userland then mmaps the DRI node at that offset; C1a only returns the offset
 * (the devmap plumbing that turns it into pages is a C1b item, see DESIGN.md).
 */
int
drm_gem_map_dumb(struct drm_device *dev, intptr_t arg, int mode)
{
	struct drm_mode_map_dumb req;
	struct drm_gem_object *obj;

	if (ddi_copyin((void *)arg, &req, sizeof (req), mode) != 0)
		return (EFAULT);

	obj = idr_find(&dev->gem_handles, req.handle);
	if (obj == NULL)
		return (ENOENT);

	req.offset = obj->mmap_offset;

	if (ddi_copyout(&req, (void *)arg, sizeof (req), mode) != 0)
		return (EFAULT);
	return (0);
}

/* DRM_IOCTL_MODE_DESTROY_DUMB - drop the handle + its reference. */
int
drm_gem_destroy_dumb(struct drm_device *dev, intptr_t arg, int mode)
{
	struct drm_mode_destroy_dumb req;
	struct drm_gem_object *obj;

	if (ddi_copyin((void *)arg, &req, sizeof (req), mode) != 0)
		return (EFAULT);

	mutex_enter(&dev->lock);
	obj = idr_remove(&dev->gem_handles, req.handle);
	mutex_exit(&dev->lock);
	if (obj == NULL)
		return (ENOENT);

	(void) kref_put(&obj->refcount, drm_gem_object_free);
	return (0);
}

/* DRM_IOCTL_GEM_CLOSE - same as destroy for the stub (drop handle+ref). */
int
drm_gem_close_ioctl(struct drm_device *dev, intptr_t arg, int mode)
{
	struct drm_gem_close req;
	struct drm_gem_object *obj;

	if (ddi_copyin((void *)arg, &req, sizeof (req), mode) != 0)
		return (EFAULT);

	mutex_enter(&dev->lock);
	obj = idr_remove(&dev->gem_handles, req.handle);
	mutex_exit(&dev->lock);
	if (obj == NULL)
		return (ENOENT);

	(void) kref_put(&obj->refcount, drm_gem_object_free);
	return (0);
}

/*
 * drm_gem_object_lookup_offset - resolve an mmap offset (as returned by
 * MAP_DUMB) back to its GEM object, for cb_devmap. C1b walks the handle table;
 * a real port keys a dedicated offset AVL / drm_vma_offset_manager. Since each
 * object's [mmap_offset, mmap_offset+size) is a disjoint monotonic range, an
 * offset falls in exactly one object.
 * NOTE: O(n) scan over the handle table; swap for an offset-keyed AVL if
 * a device ever holds enough live objects for this to show up.
 */
struct drm_gem_object *
drm_gem_object_lookup_offset(struct drm_device *dev, uint64_t offset)
{
	struct idr_entry *e;
	struct drm_gem_object *found = NULL;

	mutex_enter(&dev->gem_handles.idr_lock);
	for (e = avl_first(&dev->gem_handles.idr_tree); e != NULL;
	    e = AVL_NEXT(&dev->gem_handles.idr_tree, e)) {
		struct drm_gem_object *o = e->ie_ptr;
		if (offset >= o->mmap_offset &&
		    offset < o->mmap_offset + o->size) {
			found = o;
			break;
		}
	}
	mutex_exit(&dev->gem_handles.idr_lock);
	return (found);
}

/*
 * DRM_IOCTL_MODE_SET_SCANOUT_SOLNIX - the solnix C1b KMS demo ioctl. Takes a
 * dumb-buffer handle + geometry and drives the virtio-gpu scanout chain
 * (drm_gem_scanout, implemented in virtio_gpu.c). If no virtio-gpu transport
 * is bound (the compile-only core, no QEMU device), drm_gem_scanout returns
 * ENXIO -- the ioctl surface still compiles + dispatches.
 */
int
drm_set_scanout_ioctl(struct drm_device *dev, intptr_t arg, int mode)
{
	struct drm_mode_set_scanout_solnix req;

	if (ddi_copyin((void *)arg, &req, sizeof (req), mode) != 0)
		return (EFAULT);
	return (drm_gem_scanout(dev, req.handle, req.width, req.height,
	    req.pitch));
}
