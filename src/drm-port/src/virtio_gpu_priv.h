/*
 * virtio_gpu_priv.h - shared virtio-gpu transport state + helpers (C1d).
 *
 * The C1b virtio-gpu softc + the synchronous command primitive lived private
 * to virtio_gpu.c. C1d adds a second translation unit (virtio_gpu_3d.c) for the
 * 3D command/ioctl path, which needs to reach the same softc, the same
 * controlq exec primitive, and the same scheduler. This header shares exactly
 * those, so the two files agree on the struct layout without exposing it to the
 * drm core (which only ever holds it as an opaque void *dev->vgpu).
 *
 * Provenance: the split mirrors Linux drm/virtio, where virtgpu_vq.c owns the
 * virtqueue/command flow and virtgpu_ioctl.c the DRM ioctls, both sharing
 * struct virtio_gpu_device. No Linux .c is lifted.
 */

#ifndef _VIRTIO_GPU_PRIV_H_
#define _VIRTIO_GPU_PRIV_H_

#include <sys/types.h>
#include <sys/ksynch.h>
#include "virtio_impl.h"
#include "drm_sched.h"

struct drm_device;

/* first non-reserved id (0 is invalid in the protocol) for resources + ctx. */
#define VIRTIO_GPU_FIRST_RES_ID		1
#define VIRTIO_GPU_FIRST_CTX_ID		1

/*
 * struct virtio_gpu_softc - per-instance virtio-gpu transport state, hung off
 * drm_device->vgpu. C1b fields (framework handle, queues, scanout geometry,
 * resource-id counter) plus the C1d 3D additions: whether the host offers
 * virgl/3D (feature negotiated), num_capsets from config space, a monotonic
 * context-id counter, and the C1c scheduler that serializes SUBMIT_3D onto the
 * controlq.
 */
struct virtio_gpu_softc {
	dev_info_t	*sc_dip;
	virtio_t	*sc_virtio;
	virtio_queue_t	*sc_controlq;
	virtio_queue_t	*sc_cursorq;
	kmutex_t	sc_lock;

	uint32_t	sc_num_scanouts;
	uint32_t	sc_num_capsets;		/* C1d: config-space num_capsets */
	uint32_t	sc_next_res_id;
	uint32_t	sc_next_ctx_id;		/* C1d: 3D context ids */
	boolean_t	sc_has_virgl;		/* C1d: VIRTIO_GPU_F_VIRGL ok */

	uint32_t	sc_width;
	uint32_t	sc_height;
	boolean_t	sc_display_ok;

	struct drm_gpu_scheduler sc_sched;	/* C1d: SUBMIT_3D ordering */
	struct drm_device *sc_drm;
};

/*
 * virtio_gpu_exec - submit one control-queue command + wait for its response
 * (synchronous, one command in flight under sc_lock). Shared by the 2D modeset
 * path (virtio_gpu.c) and the 3D command emitters (virtio_gpu_3d.c). Returns 0
 * on a VIRTIO_GPU_RESP_OK_* response, EIO/ENOMEM otherwise.
 */
int virtio_gpu_exec(struct virtio_gpu_softc *sc, const void *cmd,
    size_t cmd_len, void *resp, size_t resp_len);

/*
 * virtio_gpu_exec_extra - like virtio_gpu_exec but the command is followed by
 * `extra_len` bytes of trailing payload (the SUBMIT_3D command stream, the
 * ATTACH_BACKING mem_entry array, etc.) copied contiguously after the command
 * struct. Used by the 3D SUBMIT path.
 */
int virtio_gpu_exec_extra(struct virtio_gpu_softc *sc, const void *cmd,
    size_t cmd_len, const void *extra, size_t extra_len,
    void *resp, size_t resp_len);

/* the shared DMA attributes for command buffers (defined in virtio_gpu.c). */
extern const ddi_dma_attr_t virtio_gpu_dma_attr;

/* C1d 3D ioctl handlers (virtio_gpu_3d.c), dispatched from drm_core.c. */
int virtio_gpu_ioctl_context_init(struct drm_device *, intptr_t arg, int mode);
int virtio_gpu_ioctl_execbuffer(struct drm_device *, intptr_t arg, int mode);
int virtio_gpu_ioctl_getparam(struct drm_device *, intptr_t arg, int mode);
int virtio_gpu_ioctl_get_caps(struct drm_device *, intptr_t arg, int mode);
int virtio_gpu_ioctl_resource_create(struct drm_device *, intptr_t arg,
    int mode);
int virtio_gpu_ioctl_resource_info(struct drm_device *, intptr_t arg, int mode);
int virtio_gpu_ioctl_transfer_to_host(struct drm_device *, intptr_t arg,
    int mode);
int virtio_gpu_ioctl_transfer_from_host(struct drm_device *, intptr_t arg,
    int mode);
int virtio_gpu_ioctl_map(struct drm_device *, intptr_t arg, int mode);
int virtio_gpu_ioctl_wait(struct drm_device *, intptr_t arg, int mode);

/* C1d: drop the device 3D context at detach (virtio_gpu_3d.c). */
void virtio_gpu_3d_context_fini(struct virtio_gpu_softc *, struct drm_device *);

#endif /* _VIRTIO_GPU_PRIV_H_ */
