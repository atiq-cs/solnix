/*
 * pvr_hwrt.c - C-PVR-b: PowerVR HWRT (hardware render target) datasets,
 * illumos side. The pvr analogue of Linux's pvr_hwrt.c. Handles
 * CREATE_HWRT_DATASET (0x0b) + DESTROY_HWRT_DATASET (0x0c).
 *
 * A HWRT dataset holds the per-render-target GPU state a RENDER context's
 * geometry + fragment jobs share: the tile-pointer cache (TPC), the vheap /
 * macrotile / region-header device addresses, the render dimensions, and the
 * (up to 2) free lists it draws PM pages from. The kernel validates the args,
 * takes references on the named free lists, and records the dataset. The FW
 * HWRT-setup command is BXE-hardware-gated; the record + the ioctl ABI are the
 * C1-framework part.
 */

#include <sys/types.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/errno.h>

#include "drm_internal.h"
#include "pvr_priv.h"
#include "uapi/pvr_drm.h"

struct pvr_hwrt_dataset {
	struct kref		ref;
	struct pvr_softc	*pvr;
	uint32_t		width;
	uint32_t		height;
	uint32_t		samples;
	uint32_t		layers;
	uint32_t		free_list_handles[2];
	uint32_t		handle;
};

int
pvr_create_hwrt_dataset_ioctl(struct pvr_softc *sc, struct pvr_file *pf,
    intptr_t arg, int mode)
{
	struct drm_pvr_ioctl_create_hwrt_dataset_args a;
	struct pvr_hwrt_dataset *hwrt;

	if (ddi_copyin((void *)arg, &a, sizeof (a), mode) != 0)
		return (EFAULT);
	if (a.width == 0 || a.height == 0)
		return (EINVAL);

	/* both named free lists must resolve (Linux: pvr_free_list_lookup) */
	if (idr_find(&pf->free_list_handles, a.free_list_handles[0]) == NULL ||
	    idr_find(&pf->free_list_handles, a.free_list_handles[1]) == NULL)
		return (EINVAL);

	hwrt = kmem_zalloc(sizeof (*hwrt), KM_SLEEP);
	kref_init(&hwrt->ref);
	hwrt->pvr = sc;
	hwrt->width = a.width;
	hwrt->height = a.height;
	hwrt->samples = a.samples;
	hwrt->layers = a.layers;
	hwrt->free_list_handles[0] = a.free_list_handles[0];
	hwrt->free_list_handles[1] = a.free_list_handles[1];

	hwrt->handle = idr_alloc(&pf->hwrt_handles, hwrt);
	a.handle = hwrt->handle;
	if (ddi_copyout(&a, (void *)arg, sizeof (a), mode) != 0) {
		(void) idr_remove(&pf->hwrt_handles, hwrt->handle);
		kmem_free(hwrt, sizeof (*hwrt));
		return (EFAULT);
	}
	return (0);
}

int
pvr_destroy_hwrt_dataset_ioctl(struct pvr_softc *sc, struct pvr_file *pf,
    intptr_t arg, int mode)
{
	struct drm_pvr_ioctl_destroy_hwrt_dataset_args a;
	struct pvr_hwrt_dataset *hwrt;

	(void) sc;
	if (ddi_copyin((void *)arg, &a, sizeof (a), mode) != 0)
		return (EFAULT);
	if (a._padding_4 != 0)
		return (EINVAL);

	hwrt = idr_remove(&pf->hwrt_handles, a.handle);
	if (hwrt == NULL)
		return (EINVAL);
	if (atomic_dec_uint_nv(&hwrt->ref.refcount) == 0)
		kmem_free(hwrt, sizeof (*hwrt));
	return (0);
}
