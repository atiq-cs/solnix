/*
 * pvr_gem.c - C-PVR-b: PowerVR buffer objects over the C1 GEM (ddi_umem).
 * The pvr analogue of Linux's pvr_gem.c, wired onto the C1 drm_gem.c backing
 * (ddi_umem_alloc pages + a devmap cookie) the way C3-amdgpu's TTM BOs wrap the
 * same primitive. Handles DRM_IOCTL_PVR_CREATE_BO (0x01) +
 * DRM_IOCTL_PVR_GET_BO_MMAP_OFFSET (0x02).
 *
 * A pvr_gem_object is a thin wrapper: a C1 drm_gem_object (the real ddi_umem
 * backing + handle + mmap_offset) plus the pvr BO flags (cacheability, CPU/
 * device access) that pvr_vm + pvr_fw key off. The C1 GEM owns the page
 * lifecycle; pvr adds the device-virtual mapping (pvr_vm) on top.
 */

#include <sys/types.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/ddidevmap.h>
#include <sys/errno.h>
#include <sys/sysmacros.h>	/* P2ROUNDUP */

#include "drm_internal.h"
#include "pvr_priv.h"
#include "uapi/pvr_drm.h"

#ifndef PAGESIZE
#define	PAGESIZE	4096
#endif

/*
 * pvr_gem_object - the pvr BO. Embeds a C1 drm_gem_object (by value: the C1 GEM
 * create path fills handle/mmap_offset/kaddr/umem_cookie) plus pvr flags.
 * Linux's struct pvr_gem_object embeds a drm_gem_shmem_object similarly.
 */
struct pvr_gem_object {
	struct drm_gem_object	base;	/* the C1 GEM object (real backing) */
	struct pvr_softc	*pvr;
	uint64_t		flags;	/* DRM_PVR_BO_* */
};

/* the valid DRM_PVR_BO_* mask (pvr_drm.h) -- reject unknown/reserved bits */
#define	PVR_BO_VALID_FLAGS \
	(DRM_PVR_BO_BYPASS_DEVICE_CACHE | DRM_PVR_BO_PM_FW_PROTECT | \
	 DRM_PVR_BO_ALLOW_CPU_USERSPACE_ACCESS)

/*
 * pvr_gem_object_create - allocate a pvr BO. Rounds size to a page, allocates
 * the real backing via ddi_umem_alloc (through the C1 GEM primitive), and
 * records the pvr flags. Linux: pvr_gem_object_create -> drm_gem_shmem_create.
 */
struct pvr_gem_object *
pvr_gem_object_create(struct pvr_softc *sc, uint64_t size, uint64_t flags)
{
	struct pvr_gem_object *obj;

	if (size == 0)
		return (NULL);

	obj = kmem_zalloc(sizeof (*obj), KM_SLEEP);
	obj->pvr = sc;
	obj->flags = flags;
	kref_init(&obj->base.refcount);
	obj->base.size = P2ROUNDUP(size, PAGESIZE);

	/*
	 * Real page backing (the C1 drm_gem.c path): ddi_umem_alloc gives
	 * kernel-VA-mapped pageable memory + a cookie for devmap_umem_setup so a
	 * userland mmap of the render node faults the same pages in.
	 */
	obj->base.kaddr = ddi_umem_alloc(obj->base.size, DDI_UMEM_SLEEP,
	    &obj->base.umem_cookie);
	if (obj->base.kaddr == NULL) {
		kmem_free(obj, sizeof (*obj));
		return (NULL);
	}

	/* register the C1 GEM handle + mmap offset (device-global table) */
	mutex_enter(&sc->drm->lock);
	obj->base.handle = idr_alloc(&sc->drm->gem_handles, &obj->base);
	obj->base.mmap_offset = sc->drm->next_mmap_offset;
	sc->drm->next_mmap_offset += obj->base.size;
	mutex_exit(&sc->drm->lock);

	return (obj);
}

void
pvr_gem_object_put(struct pvr_gem_object *obj)
{
	if (obj == NULL)
		return;
	if (kref_put(&obj->base.refcount, NULL) == 0)
		return;
	if (obj->base.handle != 0)
		(void) idr_remove(&obj->pvr->drm->gem_handles, obj->base.handle);
	if (obj->base.kaddr != NULL)
		ddi_umem_free(obj->base.umem_cookie);
	kmem_free(obj, sizeof (*obj));
}

void
pvr_gem_object_get_ref(struct pvr_gem_object *obj)
{
	if (obj != NULL)
		kref_get(&obj->base.refcount);
}

uint64_t
pvr_gem_object_size(struct pvr_gem_object *obj)
{
	return (obj->base.size);
}

void *
pvr_gem_object_vmap(struct pvr_gem_object *obj)
{
	/* the pages are already kernel-VA-mapped by ddi_umem_alloc */
	return (obj->base.kaddr);
}

void
pvr_gem_object_vunmap(struct pvr_gem_object *obj)
{
	(void) obj;	/* ddi_umem VA persists for the object's lifetime */
}

/* resolve a client BO handle to the pvr_gem_object (via the C1 GEM table) */
static struct pvr_gem_object *
pvr_gem_lookup(struct pvr_softc *sc, uint32_t handle)
{
	struct drm_gem_object *base = idr_find(&sc->drm->gem_handles, handle);

	if (base == NULL)
		return (NULL);
	/* base is the first member of pvr_gem_object -> container cast */
	return ((struct pvr_gem_object *)base);
}

/*
 * pvr_gem_create_bo_ioctl - DRM_IOCTL_PVR_CREATE_BO (0x01). ABI:
 * drm_pvr_ioctl_create_bo_args { u64 size; u32 handle; u32 _pad; u64 flags; }.
 * Validates flags + page alignment, allocates the BO, returns the handle.
 * Linux: pvr_ioctl_create_bo.
 */
int
pvr_gem_create_bo_ioctl(struct pvr_softc *sc, struct pvr_file *pf,
    intptr_t arg, int mode)
{
	struct drm_pvr_ioctl_create_bo_args a;
	struct pvr_gem_object *obj;

	(void) pf;
	if (ddi_copyin((void *)arg, &a, sizeof (a), mode) != 0)
		return (EFAULT);
	if (a._padding_c != 0)
		return (EINVAL);
	if (a.size == 0 || (a.size & (PAGESIZE - 1)) != 0)
		return (EINVAL);
	if ((a.flags & ~(uint64_t)PVR_BO_VALID_FLAGS) != 0)
		return (EINVAL);

	obj = pvr_gem_object_create(sc, a.size, a.flags);
	if (obj == NULL)
		return (ENOMEM);

	a.handle = obj->base.handle;
	if (ddi_copyout(&a, (void *)arg, sizeof (a), mode) != 0) {
		pvr_gem_object_put(obj);
		return (EFAULT);
	}
	return (0);
}

/*
 * pvr_gem_get_bo_mmap_offset_ioctl - DRM_IOCTL_PVR_GET_BO_MMAP_OFFSET (0x02).
 * ABI: { u32 handle; u32 _pad; u64 offset; }. Returns the C1 mmap_offset the
 * client mmaps the render node at (cb_devmap faults the umem pages -- the C1b
 * path). Linux: pvr_ioctl_get_bo_mmap_offset -> drm_gem_create_mmap_offset.
 */
int
pvr_gem_get_bo_mmap_offset_ioctl(struct pvr_softc *sc, struct pvr_file *pf,
    intptr_t arg, int mode)
{
	struct drm_pvr_ioctl_get_bo_mmap_offset_args a;
	struct pvr_gem_object *obj;

	(void) pf;
	if (ddi_copyin((void *)arg, &a, sizeof (a), mode) != 0)
		return (EFAULT);
	if (a._padding_4 != 0)
		return (EINVAL);

	obj = pvr_gem_lookup(sc, a.handle);
	if (obj == NULL)
		return (ENOENT);

	a.offset = obj->base.mmap_offset;
	if (ddi_copyout(&a, (void *)arg, sizeof (a), mode) != 0)
		return (EFAULT);
	return (0);
}

/* internal lookup used by pvr_vm.c to resolve a map handle */
struct pvr_gem_object *
pvr_gem_object_lookup(struct pvr_softc *sc, uint32_t handle)
{
	return (pvr_gem_lookup(sc, handle));
}
