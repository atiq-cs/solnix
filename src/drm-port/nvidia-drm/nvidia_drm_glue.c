/*
 * SPDX-FileCopyrightText: Copyright (c) 2026 solnix contributors
 * SPDX-License-Identifier: MIT
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

/*
 * nvidia_drm_glue.c -- the few things the illumos shell needs from inside
 * NVKMS's and OpenBSD drm's structures (i915_drmglue.c's role for i915).
 * Compiled with nvidia-drm's flags and headers.
 */
#include "nvidia-drm-conftest.h"
#include "nvidia-drm-priv.h"
#include "nvkms-kapi.h"
#include "nvidia-drm-gem.h"
#include "nvidia-drm-gem-nvkms-memory.h"
#include <drm/drm_file.h>
#include <drm/drm_drv.h>
#include "nvidia_drm_illumos.h"

dev_info_t *
nv_drm_sunos_gpu_dip(const struct NvKmsKapiGpuInfo *gpu_info)
{
	return (gpu_info->gpuInfo.os_device_ptr);
}

int
nv_drm_sunos_drm_attached(struct drm_device *dev)
{
	return (dev->dev_private != NULL);
}

int
nv_drm_sunos_drm_unit(struct drm_device *dev)
{
	extern struct cfdriver drm_cd;
	int u;

	for (u = 0; u < drm_cd.cd_ndevs; u++) {
		struct drm_softc *sc = drm_cd.cd_devs[u];

		if (sc != NULL && sc->sc_drm == dev)
			return (u);
	}
	return (-1);
}

static struct drm_file *
glue_file(dev_t odev)
{
	struct drm_device *dev = drm_get_device_from_kdev(odev);
	struct drm_file *fp;

	if (dev == NULL)
		return (NULL);
	mutex_lock(&dev->filelist_mutex);
	fp = drm_find_file_by_minor(dev, minor(odev));
	mutex_unlock(&dev->filelist_mutex);
	return (fp);
}

/* As i915_glue_chpoll: a lock-free read of the drm_file's event list. */
int
nv_drm_sunos_chpoll(dev_t odev, short events, int anyyet, short *reventsp,
    struct pollhead **phpp)
{
	struct drm_file *fp = glue_file(odev);

	if (fp == NULL)
		return (ENXIO);
	*reventsp = 0;
	if (!list_empty(&fp->event_list))
		*reventsp = events & (POLLIN | POLLRDNORM);
	if ((*reventsp == 0 && !anyyet) || (events & POLLET))
		*phpp = &fp->rsel.si_ph;
	return (0);
}

/* drmclose frees the drm_file holding the pollhead: clean it first. */
void
nv_drm_sunos_pollhead_clean(dev_t odev)
{
	struct drm_file *fp = glue_file(odev);

	if (fp != NULL)
		pollhead_clean(&fp->rsel.si_ph);
}

/*
 * GEM mmap (D2.3). The object behind a DRM fd's fake offset, as
 * nv_drm_mmap() finds it on Linux (an exact vma-offset lookup that refuses an
 * object whose last reference is gone, then drm_vma_node_is_allowed), with
 * kref_get_unless_zero (one compare-and-swap with i915/obsd-norcu.patch). Then 0003's
 * nv_drm_sunos_gem_mmap_pa: nvkms video memory only, mapped USER, the GC6
 * blocker held. On success *objp holds the reference (nv_drm_sunos_gem_put).
 * 0 or a positive errno.
 */
int
nv_drm_sunos_gem_map(dev_t odev, uint64_t start, uint64_t pages,
    void **objp, uint64_t *pap, uint64_t *sizep)
{
	struct drm_device *dev = drm_get_device_from_kdev(odev);
	struct drm_file *fp = glue_file(odev);
	struct drm_vma_offset_node *node;
	struct drm_gem_object *obj = NULL;
	int ret;

	if (dev == NULL || fp == NULL)
		return (ENXIO);
	drm_vma_offset_lock_lookup(dev->vma_offset_manager);
	node = drm_vma_offset_exact_lookup_locked(dev->vma_offset_manager,
	    (unsigned long)start, (unsigned long)pages);
	if (node != NULL) {
		obj = container_of(node, struct drm_gem_object, vma_node);
		if (!kref_get_unless_zero(&obj->refcount))
			obj = NULL;
	}
	drm_vma_offset_unlock_lookup(dev->vma_offset_manager);
	if (obj == NULL)
		return (EINVAL);
	if (!drm_vma_node_is_allowed(node, fp)) {
		drm_gem_object_put(obj);
		return (EACCES);
	}
	ret = nv_drm_sunos_gem_mmap_pa(to_nv_gem_object(obj), pap, sizep);
	if (ret != 0) {
		drm_gem_object_put(obj);
		return (-ret);
	}
	*objp = obj;
	return (0);
}

/* Drop the reference nv_drm_sunos_gem_map took (may free the object). */
void
nv_drm_sunos_gem_put(void *obj)
{
	drm_gem_object_put(obj);
}
