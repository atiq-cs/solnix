/*
 * drm_internal.h - illumos-side DRM device + GEM object model (C1a stub).
 *
 * Analogue of NetBSD's drm2/drm/ glue structs (drm_device, drm_file, GEM
 * object) bound to the illumos DDI instead of NetBSD's device_t/cdevsw. Only
 * the fields the C1a stub needs are present. The real port grows this toward
 * the imported dist/drm/drm_device.h / drm_gem.h shapes.
 */

#ifndef _DRM_INTERNAL_H_
#define _DRM_INTERNAL_H_

#include <sys/types.h>
#include <sys/ksynch.h>
#include "linux-compat/linux_compat.h"

/*
 * struct drm_driver - the per-driver identity (name/date/desc/version) the
 * DRM_IOCTL_VERSION path reports. NetBSD: dev->driver->{name,date,desc,major}.
 * For C1a the "driver" is the virtio-gpu-shaped stub identity.
 */
struct drm_driver {
	const char	*name;
	const char	*date;
	const char	*desc;
	int		major;
	int		minor;
	int		patchlevel;
};

/*
 * struct drm_gem_object - a GEM buffer object. NetBSD/Linux carry a full
 * uvm/shmem backing + dma-buf export; the C1a stub carries just size + a
 * kmem-backed kernel buffer + a refcount + the handle it was issued.
 */
struct drm_gem_object {
	struct kref	refcount;
	size_t		size;		/* rounded to PAGESIZE */
	uint32_t	handle;		/* idr id, 0 = unbound */
	uint64_t	mmap_offset;	/* fake offset for MAP_DUMB (stub) */
	caddr_t		kaddr;		/* kmem-backed pages (stub backing) */
};

/*
 * struct drm_device - one DRI device instance (maps to one illumos dev_info).
 * Owns the GEM handle table (idr) and points at its driver identity.
 */
struct drm_device {
	dev_info_t		*dip;
	const struct drm_driver	*driver;
	struct idr		gem_handles;	/* handle -> drm_gem_object */
	kmutex_t		lock;
	uint64_t		next_mmap_offset;
};

/*
 * struct drm_file - per-open state (one per open of a DRI node). NetBSD keys
 * this off struct file; illumos keys it off the soft-state + minor. For C1a
 * the handle table is device-global (not per-file) to keep the stub small;
 * DESIGN.md notes real DRM scopes handles per drm_file.
 */
struct drm_file {
	struct drm_device	*dev;
	minor_t			minor;
	boolean_t		is_render;	/* renderD* vs card* */
};

/* drm core entry points used by the driver glue */
int	drm_version_ioctl(struct drm_device *, intptr_t arg, int mode);
int	drm_gem_create_dumb(struct drm_device *, intptr_t arg, int mode);
int	drm_gem_map_dumb(struct drm_device *, intptr_t arg, int mode);
int	drm_gem_destroy_dumb(struct drm_device *, intptr_t arg, int mode);
int	drm_gem_close_ioctl(struct drm_device *, intptr_t arg, int mode);
void	drm_gem_object_free(struct kref *);

#endif /* _DRM_INTERNAL_H_ */
