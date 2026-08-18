/*
 * pvr_free_list.c - C-PVR-b: PowerVR free lists, illumos side. The pvr
 * analogue of Linux's pvr_free_list.c. Handles CREATE_FREE_LIST (0x09) +
 * DESTROY_FREE_LIST (0x0a).
 *
 * A free list is the GPU's supply of physical pages for the Parameter Manager
 * (PM) to grow tile/geometry state during a render. The kernel allocates the
 * backing BO(s), records the grow policy, and hands the FW the free-list
 * device address. The actual page-list program + the FW grow callback are
 * BXE-hardware-gated; the allocation + the ioctl ABI are the C1-framework part.
 */

#include <sys/types.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/errno.h>

#include "drm_internal.h"
#include "pvr_priv.h"
#include "uapi/pvr_drm.h"

struct pvr_free_list {
	struct kref		ref;
	struct pvr_softc	*pvr;
	struct pvr_vm_context	*vm_ctx;
	uint64_t		gpu_addr;
	uint32_t		initial_num_pages;
	uint32_t		max_num_pages;
	uint32_t		grow_num_pages;
	uint32_t		grow_threshold;
	uint32_t		handle;
};

int
pvr_create_free_list_ioctl(struct pvr_softc *sc, struct pvr_file *pf,
    intptr_t arg, int mode)
{
	struct drm_pvr_ioctl_create_free_list_args a;
	struct pvr_free_list *fl;
	struct pvr_vm_context *vm;

	if (ddi_copyin((void *)arg, &a, sizeof (a), mode) != 0)
		return (EFAULT);
	if (a.max_num_pages == 0 || a.initial_num_pages > a.max_num_pages)
		return (EINVAL);

	vm = idr_find(&pf->vm_ctx_handles, a.vm_context_handle);
	if (vm == NULL)
		return (EINVAL);

	fl = kmem_zalloc(sizeof (*fl), KM_SLEEP);
	kref_init(&fl->ref);
	fl->pvr = sc;
	fl->vm_ctx = vm;
	fl->gpu_addr = a.free_list_gpu_addr;
	fl->initial_num_pages = a.initial_num_pages;
	fl->max_num_pages = a.max_num_pages;
	fl->grow_num_pages = a.grow_num_pages;
	fl->grow_threshold = a.grow_threshold;

	/* device-wide free-list id (Linux: xa_alloc on pvr_dev->free_list_ids) */
	fl->handle = idr_alloc(&pf->free_list_handles, fl);
	a.handle = fl->handle;
	if (ddi_copyout(&a, (void *)arg, sizeof (a), mode) != 0) {
		(void) idr_remove(&pf->free_list_handles, fl->handle);
		kmem_free(fl, sizeof (*fl));
		return (EFAULT);
	}
	return (0);
}

int
pvr_destroy_free_list_ioctl(struct pvr_softc *sc, struct pvr_file *pf,
    intptr_t arg, int mode)
{
	struct drm_pvr_ioctl_destroy_free_list_args a;
	struct pvr_free_list *fl;

	(void) sc;
	if (ddi_copyin((void *)arg, &a, sizeof (a), mode) != 0)
		return (EFAULT);
	if (a._padding_4 != 0)
		return (EINVAL);

	fl = idr_remove(&pf->free_list_handles, a.handle);
	if (fl == NULL)
		return (EINVAL);
	if (atomic_dec_uint_nv(&fl->ref.refcount) == 0)
		kmem_free(fl, sizeof (*fl));
	return (0);
}
