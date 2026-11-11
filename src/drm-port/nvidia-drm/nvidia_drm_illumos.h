/*
 * SPDX-FileCopyrightText: Copyright (c) 2026 solnix contributors
 * SPDX-License-Identifier: MIT
 *
 * nvidia_drm_illumos.h -- what the illumos shell (nvidia_drm_illumos.c) needs
 * from inside nvidia-drm and OpenBSD drm structures, implemented by
 * nvidia_drm_glue.c, which is compiled like nvidia-drm (its headers).
 */
#ifndef _NVIDIA_DRM_ILLUMOS_H
#define _NVIDIA_DRM_ILLUMOS_H

struct drm_device;
struct drm_driver;
struct NvKmsKapiGpuInfo;
struct pollhead;

/* the nvidia PCI node behind an NVKMS GPU (gpuInfo.os_device_ptr) */
extern dev_info_t *nv_drm_sunos_gpu_dip(const struct NvKmsKapiGpuInfo *);
/* drm_attach() finished (it leaves dev_private NULL when it failed) */
extern int nv_drm_sunos_drm_attached(struct drm_device *);
/* the drm_cd unit (OpenBSD minor) of a registered drm_device, or -1 */
extern int nv_drm_sunos_drm_unit(struct drm_device *);
extern int nv_drm_sunos_chpoll(dev_t, short, int, short *, struct pollhead **);
extern void nv_drm_sunos_pollhead_clean(dev_t);

/* the hooks nvidia-drm-sunos.h declares */
extern struct drm_device *nv_drm_sunos_dev_alloc(const struct drm_driver *,
    const struct NvKmsKapiGpuInfo *);
extern void *nv_drm_sunos_ioremap_wc(uint64_t, size_t);
extern void nv_drm_sunos_iounmap(void *);

#endif /* _NVIDIA_DRM_ILLUMOS_H */
