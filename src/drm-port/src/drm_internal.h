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
#include <sys/list.h>		/* prime export / sync_file lists */
#include <sys/ddidevmap.h>	/* ddi_umem_cookie_t, devmap_cookie_t */
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
 * struct drm_gem_object - a GEM buffer object. C1b backs it with real pageable
 * kernel memory via ddi_umem_alloc (cookie handed to devmap_umem_setup so a
 * userland mmap faults the same pages in). The mmap_offset is a monotonic
 * per-device offset that MAP_DUMB returns and cb_devmap resolves back to the
 * object. For virtio-gpu the same pages become the RESOURCE_ATTACH_BACKING
 * scatter-gather list, so the host scans out of guest RAM directly.
 */
struct drm_gem_object {
	struct kref	refcount;
	size_t		size;		/* rounded to PAGESIZE */
	uint32_t	handle;		/* idr id, 0 = unbound */
	uint64_t	mmap_offset;	/* devmap offset for MAP_DUMB */
	caddr_t		kaddr;		/* ddi_umem_alloc kernel VA */
	ddi_umem_cookie_t umem_cookie;	/* for devmap_umem_setup + free */
	uint32_t	virtio_res_id;	/* virtio-gpu resource id, 0 = none */
};

/*
 * struct drm_device - one DRI device instance (maps to one illumos dev_info).
 * Owns the GEM handle table (idr) and points at its driver identity. C1b adds
 * a back-pointer to the virtio-gpu transport state (NULL until virtio attach)
 * and an offset->object index so cb_devmap can resolve an mmap offset.
 */
struct drm_device {
	dev_info_t		*dip;
	const struct drm_driver	*driver;
	struct idr		gem_handles;	/* handle -> drm_gem_object */
	kmutex_t		lock;
	uint64_t		next_mmap_offset;
	void			*vgpu;		/* struct virtio_gpu_softc * */
	/*
	 * C1c PRIME/dma-buf + sync_file fd sharing (drm_prime.c). prime_major
	 * is this driver's major (ddi_driver_major(dip)); PRIME exports and
	 * sync_files each take a private minor >= DRM_PRIME_MINOR_BASE off
	 * prime_next_minor and record it in these lists.
	 */
	major_t			prime_major;
	minor_t			prime_next_minor;
	list_t			prime_exports;	/* struct drm_prime_export */
	list_t			sync_files;	/* struct sync_file */

	/*
	 * C1d virtio-gpu 3D context. Real DRM scopes the 3D context per
	 * drm_file (one context per open of renderD*); the C1a handle table is
	 * device-global (see struct drm_file note), so C1d keeps one context per
	 * device to match. ctx_id 0 == no context created yet; CONTEXT_INIT /
	 * the first EXECBUFFER lazily creates it via CTX_CREATE_3D.
	 * NOTE: device-global 3D context; scope per-drm_file when the handle
	 * table becomes per-file (same upgrade the drm_file note tracks).
	 */
	uint32_t		ctx_id;		/* virtio-gpu 3D context id */
	uint32_t		ctx_capset;	/* selected capset (virgl/venus) */
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

/* C1c: PRIME/sync_file fds allocate spec-vnode minors from this base up. */
#define DRM_PRIME_MINOR_BASE	4096

/* drm core entry points used by the driver glue */
int	drm_version_ioctl(struct drm_device *, intptr_t arg, int mode);
int	drm_gem_create_dumb(struct drm_device *, intptr_t arg, int mode);
int	drm_gem_map_dumb(struct drm_device *, intptr_t arg, int mode);
int	drm_gem_destroy_dumb(struct drm_device *, intptr_t arg, int mode);
int	drm_gem_close_ioctl(struct drm_device *, intptr_t arg, int mode);
void	drm_gem_object_free(struct kref *);

/* C1b: mmap support. cb_devmap resolves an offset back to a GEM object. */
struct drm_gem_object *drm_gem_object_lookup_offset(struct drm_device *,
    uint64_t offset);

/* C1b: virtio-gpu KMS path (drm_kms.c over virtio_gpu.c). */
int	drm_gem_scanout(struct drm_device *, uint32_t handle,
    uint32_t width, uint32_t height, uint32_t pitch);
int	drm_set_scanout_ioctl(struct drm_device *, intptr_t arg, int mode);

/* C1c: PRIME (dma-buf) handle<->fd + sync_file (drm_prime.c). */
struct dma_fence;
void	drm_prime_init(struct drm_device *);
void	drm_prime_fini(struct drm_device *);
int	drm_gem_prime_handle_to_fd(struct drm_device *, intptr_t arg, int mode);
int	drm_gem_prime_fd_to_handle(struct drm_device *, intptr_t arg, int mode);
void	drm_prime_export_teardown(struct drm_device *, minor_t);
struct drm_gem_object *drm_prime_devmap_object(struct drm_device *, minor_t);
int	sync_file_create(struct drm_device *, struct dma_fence *);
struct dma_fence *sync_file_get_fence(struct drm_device *, int fd);

#endif /* _DRM_INTERNAL_H_ */
