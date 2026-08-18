/*
 * pvr_drv.c - C-PVR-b: the PowerVR DRM ioctl dispatch, illumos side. The pvr
 * analogue of Linux's pvr_drv.c pvr_drm_driver_ioctls[] table, wired into the
 * C1 drm_ioctl the way the virtio-gpu 3D ioctls are (src/drm_core.c).
 *
 * The 15 pvr_drm ioctls decode EXACTLY the ABI C-PVR-a's userspace targets
 * (../powervr/pvr_drm.h == uapi/pvr_drm.h == the Linux uapi). The command
 * numbers are the Linux DRM scheme: type 'd' (0x64), nr = DRM_COMMAND_BASE
 * (0x40) + opcode, encoded through the same _IOC path C-PVR-a's winsys uses --
 * so libvulkan_powervr_mesa.so <-> this driver is the libdrm_amdgpu <-> amdgpu
 * analogue.
 *
 *   opcode  ioctl                             handler (this file / subsystem)
 *   0x00    DRM_IOCTL_PVR_DEV_QUERY           pvr_dev_query_ioctl        (pvr_drv)
 *   0x01    DRM_IOCTL_PVR_CREATE_BO           pvr_gem_create_bo_ioctl    (pvr_gem)
 *   0x02    DRM_IOCTL_PVR_GET_BO_MMAP_OFFSET  pvr_gem_get_bo_mmap_offset (pvr_gem)
 *   0x03    DRM_IOCTL_PVR_CREATE_VM_CONTEXT   pvr_create_vm_context      (pvr_vm)
 *   0x04    DRM_IOCTL_PVR_DESTROY_VM_CONTEXT  pvr_destroy_vm_context     (pvr_vm)
 *   0x05    DRM_IOCTL_PVR_VM_MAP              pvr_vm_map_ioctl           (pvr_vm)
 *   0x06    DRM_IOCTL_PVR_VM_UNMAP            pvr_vm_unmap_ioctl         (pvr_vm)
 *   0x07    DRM_IOCTL_PVR_CREATE_CONTEXT      pvr_create_context         (pvr_context)
 *   0x08    DRM_IOCTL_PVR_DESTROY_CONTEXT     pvr_destroy_context        (pvr_context)
 *   0x09    DRM_IOCTL_PVR_CREATE_FREE_LIST    pvr_create_free_list       (pvr_free_list)
 *   0x0a    DRM_IOCTL_PVR_DESTROY_FREE_LIST   pvr_destroy_free_list      (pvr_free_list)
 *   0x0b    DRM_IOCTL_PVR_CREATE_HWRT_DATASET pvr_create_hwrt_dataset    (pvr_hwrt)
 *   0x0c    DRM_IOCTL_PVR_DESTROY_HWRT_DATASET pvr_destroy_hwrt_dataset  (pvr_hwrt)
 *   0x0d    DRM_IOCTL_PVR_SUBMIT_JOBS         pvr_submit_jobs            (pvr_job)
 */

#include <sys/types.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/errno.h>

#include "drm_internal.h"
#include "pvr_priv.h"
#include "uapi/pvr_drm.h"

/*
 * pvr_ioctl - the pvr DRM ioctl dispatch. The C1 drm_ioctl (src/drm_core.c)
 * routes a pvr command number here after the softc is resolved from the
 * drm_device. Handlers return positive illumos errnos (the cb_ioctl boundary);
 * the cribbed Linux handlers use -errno internally (the shim negates).
 *
 * We switch on the DRM command number. Because the C1 uapi drm.h and pvr_drm.h
 * both encode through the Linux _IOC scheme, the case values are the exact
 * DRM_IOCTL_PVR_* macros C-PVR-a's winsys issues.
 */
int
pvr_ioctl(struct pvr_softc *sc, struct pvr_file *pf, int cmd,
    intptr_t arg, int mode)
{
	if (sc == NULL || pf == NULL)
		return (ENXIO);

	switch ((unsigned)cmd) {
	case DRM_IOCTL_PVR_DEV_QUERY:
		return (pvr_dev_query_ioctl(sc, pf, arg, mode));
	case DRM_IOCTL_PVR_CREATE_BO:
		return (pvr_gem_create_bo_ioctl(sc, pf, arg, mode));
	case DRM_IOCTL_PVR_GET_BO_MMAP_OFFSET:
		return (pvr_gem_get_bo_mmap_offset_ioctl(sc, pf, arg, mode));
	case DRM_IOCTL_PVR_CREATE_VM_CONTEXT:
		return (pvr_create_vm_context_ioctl(sc, pf, arg, mode));
	case DRM_IOCTL_PVR_DESTROY_VM_CONTEXT:
		return (pvr_destroy_vm_context_ioctl(sc, pf, arg, mode));
	case DRM_IOCTL_PVR_VM_MAP:
		return (pvr_vm_map_ioctl(sc, pf, arg, mode));
	case DRM_IOCTL_PVR_VM_UNMAP:
		return (pvr_vm_unmap_ioctl(sc, pf, arg, mode));
	case DRM_IOCTL_PVR_CREATE_CONTEXT:
		return (pvr_create_context_ioctl(sc, pf, arg, mode));
	case DRM_IOCTL_PVR_DESTROY_CONTEXT:
		return (pvr_destroy_context_ioctl(sc, pf, arg, mode));
	case DRM_IOCTL_PVR_CREATE_FREE_LIST:
		return (pvr_create_free_list_ioctl(sc, pf, arg, mode));
	case DRM_IOCTL_PVR_DESTROY_FREE_LIST:
		return (pvr_destroy_free_list_ioctl(sc, pf, arg, mode));
	case DRM_IOCTL_PVR_CREATE_HWRT_DATASET:
		return (pvr_create_hwrt_dataset_ioctl(sc, pf, arg, mode));
	case DRM_IOCTL_PVR_DESTROY_HWRT_DATASET:
		return (pvr_destroy_hwrt_dataset_ioctl(sc, pf, arg, mode));
	case DRM_IOCTL_PVR_SUBMIT_JOBS:
		return (pvr_submit_jobs_ioctl(sc, pf, arg, mode));
	default:
		return (ENOTTY);
	}
}

/*
 * pvr_dev_query_ioctl - DRM_IOCTL_PVR_DEV_QUERY (opcode 0x00). Feeds C-PVR-a's
 * pvr_device_info: GPU_INFO_GET / RUNTIME_INFO_GET / QUIRKS_GET /
 * ENHANCEMENTS_GET / HEAP_INFO_GET / STATIC_DATA_AREAS_GET. The two-pass
 * contract (pointer==0 -> report required size; else fill) is Linux's
 * pvr_ioctl_dev_query. For the compile milestone we decode the args + honor
 * the size-probe pass; the per-query payloads (GPU feature/quirk tables) are
 * BXE-2-32-hardware-gated -- they read from the FW-reported device info that
 * only exists once the BXE FW has booted (see ../powervr/POWERVR-STATUS.md:
 * Mesa 24.0.9 does not even carry the BXE-2-32 device table).
 */
int
pvr_dev_query_ioctl(struct pvr_softc *sc, struct pvr_file *pf,
    intptr_t arg, int mode)
{
	struct drm_pvr_ioctl_dev_query_args a;

	(void) pf;
	if (ddi_copyin((void *)arg, &a, sizeof (a), mode) != 0)
		return (EFAULT);

	switch (a.type) {
	case DRM_PVR_DEV_QUERY_GPU_INFO_GET:
	case DRM_PVR_DEV_QUERY_RUNTIME_INFO_GET:
	case DRM_PVR_DEV_QUERY_QUIRKS_GET:
	case DRM_PVR_DEV_QUERY_ENHANCEMENTS_GET:
	case DRM_PVR_DEV_QUERY_HEAP_INFO_GET:
	case DRM_PVR_DEV_QUERY_STATIC_DATA_AREAS_GET:
		break;
	default:
		return (EINVAL);
	}

	/*
	 * The payloads are read from sc->fw device info (FW-boot-gated). Until
	 * the BXE FW is up we cannot fill them, so the size-probe pass (pointer
	 * == 0) succeeds (returns the args unchanged) and the fill pass reports
	 * EOPNOTSUPP-equivalent. Real fills: pvr_dev_query_gpu_info_get etc.
	 */
	if (a.pointer == 0) {
		/* size-probe pass: leave a.size as the caller set it */
		if (ddi_copyout(&a, (void *)arg, sizeof (a), mode) != 0)
			return (EFAULT);
		return (0);
	}
	/* fill pass is hardware-gated on the booted FW device info */
	return (sc->fw.booted ? 0 : ENOTSUP);
}
