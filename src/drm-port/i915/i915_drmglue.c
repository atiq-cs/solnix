/*
 * i915_drmglue.c -- the few things the illumos cdev (i915_illumos.c) needs
 * from inside OpenBSD's drm and i915 structures. Compiled like the OpenBSD
 * drm objects (obsd_prelude.h forced, OpenBSD drm include paths), so it may
 * name struct drm_device, drm_file and i915 GEM objects; i915_illumos.c
 * stays a plain DDI file and calls only these functions.
 *
 * odev is always a dev_t whose minor is the OpenBSD drm minor
 * (i915_drmioc.h i915_il_ominor), the same value drmopen keyed the
 * drm_file with.
 */
#include <drm/drm_device.h>
#include <drm/drm_drv.h>
#include <drm/drm_file.h>
#include <drm/drm_vma_manager.h>
#include <drm/drm_client_event.h>
#include "i915_drv.h"
#include "gem/i915_gem_object.h"
#include "gem/i915_gem_mman.h"
#include "i915_drmglue.h"

static struct drm_file *
glue_file(dev_t odev, struct drm_device **devp)
{
	struct drm_device *dev = drm_get_device_from_kdev(odev);
	struct drm_file *fp;

	if (dev == NULL)
		return (NULL);
	mutex_lock(&dev->filelist_mutex);
	fp = drm_find_file_by_minor(dev, minor(odev));
	mutex_unlock(&dev->filelist_mutex);
	*devp = dev;
	return (fp);
}

/* A snapshot of "some open file is the DRM master" (dev->master is
 * set by drm_master_open/SET_MASTER and cleared by DROP_MASTER and the
 * master's close). Read without master_mutex: the caller only uses it to
 * switch the console mode, after the ioctl or open/close that changed it. */
int
i915_glue_has_master(dev_t odev)
{
	struct drm_device *dev = drm_get_device_from_kdev(odev);

	return (dev != NULL && READ_ONCE(dev->master) != NULL);
}

/* Put the fbdev (kernel) configuration back, as OpenBSD's drm_lastclose
 * does, before the text console draws again. */
void
i915_glue_restore(dev_t odev)
{
	struct drm_device *dev = drm_get_device_from_kdev(odev);

	if (dev != NULL)
		drm_client_dev_restore(dev, false);
}

/*
 * The dumb-buffer mmap, docs/x1-gpu-route.md 5.6 F6/F7. MAP_DUMB
 * (i915_gem_dumb_mmap_offset) creates an i915_mmap_offset node of type WC
 * on Gen9 (no LMEM, PAT enabled); OpenBSD's i915_gem_mmap finds that node
 * by the exact (offset, pages) of the mmap and its fault handler maps the
 * object's system pages write-combined. Here the object is pinned into a
 * contiguous write-combined kernel mapping (pin_map I915_MAP_WC, vmap over
 * pmap_enter = hat_devload on kas), whose VA becomes a KMEM_NON_PAGEABLE
 * umem cookie: segdev resolves each user fault with hat_getpfnum on that
 * VA. The pin lasts until i915_glue_dumb_unmap.
 * Returns 0 or an errno; only WC mmap offsets are served (GTT/WB/UC are
 * the R2 GEM paths: ENOTSUP).
 */
int
i915_glue_dumb_map(dev_t odev, uint64_t off, size_t len, void **kvap,
    size_t *sizep, int *readonlyp, void **objp)
{
	struct drm_device *dev = NULL;
	struct drm_file *fp = glue_file(odev, &dev);
	struct drm_vma_offset_node *node;
	struct i915_mmap_offset *mmo = NULL;
	struct drm_i915_gem_object *obj = NULL;
	void *va;

	if (fp == NULL)
		return (ENXIO);
	rcu_read_lock();
	drm_vma_offset_lock_lookup(dev->vma_offset_manager);
	node = drm_vma_offset_exact_lookup_locked(dev->vma_offset_manager,
	    off >> PAGE_SHIFT, atop(round_page(len)));
	if (node != NULL && drm_vma_node_is_allowed(node, fp) &&
	    node->driver_private == NULL) {
		mmo = container_of(node, struct i915_mmap_offset, vma_node);
		obj = i915_gem_object_get_rcu(mmo->obj);
	}
	drm_vma_offset_unlock_lookup(dev->vma_offset_manager);
	rcu_read_unlock();
	if (obj == NULL)
		return (EINVAL);
	if (mmo->mmap_type != I915_MMAP_TYPE_WC) {
		i915_gem_object_put(obj);
		return (ENOTSUP);
	}
	va = i915_gem_object_pin_map_unlocked(obj, I915_MAP_WC);
	if (IS_ERR(va)) {
		i915_gem_object_put(obj);
		return (-PTR_ERR(va));
	}
	*kvap = va;
	*sizep = obj->base.size;
	*readonlyp = i915_gem_object_is_readonly(obj);
	*objp = obj;
	return (0);
}

void
i915_glue_dumb_unmap(void *o)
{
	struct drm_i915_gem_object *obj = o;

	i915_gem_object_unpin_map(obj);
	i915_gem_object_put(obj);
}

/*
 * chpoll(9E) for the event queue drmread drains (vblank, page-flip
 * completion). The check is a lock-free read: OpenBSD's drm calls
 * selwakeup (pollwakeup, obsd_glue.c) with event_lock held, and chpoll
 * must not take a lock its pollwakeup caller holds.
 */
int
i915_glue_chpoll(dev_t odev, short events, int anyyet, short *reventsp,
    struct pollhead **phpp)
{
	struct drm_device *dev = NULL;
	struct drm_file *fp = glue_file(odev, &dev);

	if (fp == NULL)
		return (ENXIO);
	*reventsp = 0;
	if (!list_empty(&fp->event_list))
		*reventsp = events & (POLLIN | POLLRDNORM);
	if ((*reventsp == 0 && !anyyet) || (events & POLLET))
		*phpp = &fp->rsel.si_ph;
	return (0);
}

/* drm unit of the drm child inteldrm's attach created (drm_cd index, the
 * low bits of the OpenBSD minor), once drm_dev_register has run; -1 if the
 * OpenBSD attach stopped before that (it returns without a status). */
int
i915_glue_drm_unit(void *self)
{
	struct drm_i915_private *i915 = self;
	extern struct cfdriver drm_cd;
	int u;

	for (u = 0; u < drm_cd.cd_ndevs; u++) {
		struct drm_softc *sc = drm_cd.cd_devs[u];

		if (sc != NULL && sc->sc_drm == &i915->drm)
			return (i915->drm.registered ? u : -1);
	}
	return (-1);
}

/* poll(9E): a pollhead must be cleaned before the memory holding it is
 * freed; drmclose frees the drm_file that holds rsel. */
void
i915_glue_pollhead_clean(dev_t odev)
{
	struct drm_device *dev = NULL;
	struct drm_file *fp = glue_file(odev, &dev);

	if (fp != NULL)
		pollhead_clean(&fp->rsel.si_ph);
}
