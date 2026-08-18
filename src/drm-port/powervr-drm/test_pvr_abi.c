/*
 * test_pvr_abi.c - C-PVR-b self-check: the pvr_drm ioctl ABI the kernel driver
 * decodes must match C-PVR-a's userspace exactly (the libdrm_amdgpu <-> amdgpu
 * contract analogue). Verifies the 14 encoded DRM_IOCTL_PVR_* numbers + the
 * args struct sizes against the documented ABI (../powervr/POWERVR-STATUS.md's
 * pvr-ioctl-encoding.out table). Pure userland, asserts, no framework.
 *
 *   cc -I../src/uapi/drm -o /tmp/t test_pvr_abi.c && /tmp/t
 */
#include <stdio.h>
#include <stdint.h>
#include <assert.h>
typedef uint8_t __u8; typedef uint16_t __u16; typedef uint32_t __u32;
typedef int32_t __s32; typedef uint64_t __u64;
#include "uapi/pvr_drm.h"

int
main(void)
{
	/* the 14 encoded ioctl numbers -- must equal C-PVR-a's table exactly */
	assert(DRM_IOCTL_PVR_DEV_QUERY == 0xc0106440);
	assert(DRM_IOCTL_PVR_CREATE_BO == 0xc0186441);
	assert(DRM_IOCTL_PVR_GET_BO_MMAP_OFFSET == 0xc0106442);
	assert(DRM_IOCTL_PVR_CREATE_VM_CONTEXT == 0xc0086443);
	assert(DRM_IOCTL_PVR_DESTROY_VM_CONTEXT == 0x40086444);
	assert(DRM_IOCTL_PVR_VM_MAP == 0x40286445);
	assert(DRM_IOCTL_PVR_VM_UNMAP == 0x40186446);
	assert(DRM_IOCTL_PVR_CREATE_CONTEXT == 0xc0286447);
	assert(DRM_IOCTL_PVR_DESTROY_CONTEXT == 0x40086448);
	assert(DRM_IOCTL_PVR_CREATE_FREE_LIST == 0xc0206449);
	assert(DRM_IOCTL_PVR_DESTROY_FREE_LIST == 0x4008644a);
	assert(DRM_IOCTL_PVR_CREATE_HWRT_DATASET == 0xc088644b);
	assert(DRM_IOCTL_PVR_DESTROY_HWRT_DATASET == 0x4008644c);
	assert(DRM_IOCTL_PVR_SUBMIT_JOBS == 0x4010644d);

	/* the args struct sizes -- must equal C-PVR-a's table exactly */
	assert(sizeof(struct drm_pvr_ioctl_dev_query_args) == 16);
	assert(sizeof(struct drm_pvr_ioctl_create_bo_args) == 24);
	assert(sizeof(struct drm_pvr_ioctl_get_bo_mmap_offset_args) == 16);
	assert(sizeof(struct drm_pvr_ioctl_create_vm_context_args) == 8);
	assert(sizeof(struct drm_pvr_ioctl_destroy_vm_context_args) == 8);
	assert(sizeof(struct drm_pvr_ioctl_vm_map_args) == 40);
	assert(sizeof(struct drm_pvr_ioctl_vm_unmap_args) == 24);
	assert(sizeof(struct drm_pvr_ioctl_create_context_args) == 40);
	assert(sizeof(struct drm_pvr_ioctl_destroy_context_args) == 8);
	assert(sizeof(struct drm_pvr_ioctl_create_free_list_args) == 32);
	assert(sizeof(struct drm_pvr_ioctl_destroy_free_list_args) == 8);
	assert(sizeof(struct drm_pvr_ioctl_create_hwrt_dataset_args) == 136);
	assert(sizeof(struct drm_pvr_ioctl_destroy_hwrt_dataset_args) == 8);
	assert(sizeof(struct drm_pvr_ioctl_submit_jobs_args) == 16);

	printf("PASS: 14 pvr_drm ioctl numbers + arg sizes match C-PVR-a ABI\n");
	return (0);
}
