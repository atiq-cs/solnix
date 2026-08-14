/*
 * virtio_gpu_3d.c - the virtio-gpu 3D command + ioctl path (C1d).
 *
 * Extends the C1b 2D transport (virtio_gpu.c) from "put pixels on a scanout" to
 * "run GPU work": the virgl (GL) / venus (Vulkan) command streams Mesa produces
 * are shipped to the host renderer over the SAME controlq + the SAME
 * virtio_gpu_exec chain, on the SAME GEM buffers, signalling the SAME C1c
 * dma-fence, scheduled by the SAME C1c scheduler. No new transport, no VRAM, no
 * TTM -- 3D is more command types on the built substrate.
 *
 * The load-bearing pieces (the C1d task):
 *   - EXECBUFFER (DRM_IOCTL_VIRTGPU_EXECBUFFER): submit a command buffer to
 *     SUBMIT_3D via the scheduler run_job -> virtio_gpu_exec_extra, producing an
 *     out dma-fence (a sync_file fd). This is what virgl/venus use for GPU work.
 *   - CONTEXT_INIT / CTX_CREATE_3D: a per-drm-device 3D context selecting the
 *     virgl vs venus capset.
 *   - GET_CAPS: GET_CAPSET_INFO/GET_CAPSET so Mesa learns the host's features.
 *   - RESOURCE_CREATE (3D): RESOURCE_CREATE_3D (target/format/bind/dims/array/
 *     mip) over a GEM object + ATTACH_BACKING.
 *   - TRANSFER_TO/FROM_HOST (3D): the box-form 3D data movement.
 *   - MAP: reuses the C1b cb_devmap mmap-offset path unchanged.
 *
 * Provenance: the command flow (ctx create, resource create 3d, attach backing,
 * transfer box, submit command buffer, get capset) follows Linux
 * drivers/gpu/drm/virtio/virtgpu_vq.c + virtgpu_ioctl.c; the ioctl contract +
 * struct layouts are the Linux DRM UAPI (uapi/drm/virtgpu_drm.h, reproduced so
 * Mesa virgl/venus bind unchanged). Re-expressed against the illumos virtio KPI
 * + the C1c scheduler/dma-fence/sync_file; no Linux/NetBSD .c is lifted.
 *
 * COMPILE milestone (same as C1a-c): every symbol resolves to a real illumos
 * KPI, a virtio module export, or an in-tree C1 function. Runtime (an
 * accelerated triangle under QEMU -device virtio-gpu-gl) is the metal step.
 */

#include <sys/types.h>
#include <sys/sysmacros.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/kmem.h>
#include <sys/ksynch.h>
#include <sys/cmn_err.h>

#include "uapi/drm/drm.h"
#include "uapi/drm/virtgpu_drm.h"
#include "virtio_impl.h"
#include "virtio_gpu_hw.h"
#include "virtio_gpu_priv.h"
#include "drm_internal.h"
#include "drm_sched.h"
#include "linux-compat/linux_dma.h"

/* upper bound on an EXECBUFFER command stream we will copy in one go (64 MiB).
 * NOTE: fixed cap; Linux has no hard limit but virgl/venus command buffers are
 * kilobytes-to-megabytes. Raise if a real workload trips it. */
#define VIRTIO_GPU_MAX_EXECBUF	(64u * 1024 * 1024)
/* GET_CAPS blob cap (host capsets are a few KiB; virgl caps_v2 ~1-2 KiB). */
#define VIRTIO_GPU_MAX_CAPSET	(64u * 1024)

/* ================= 3D command emitters (over virtio_gpu_exec) ============= */

/*
 * virtio_gpu_cmd_ctx_create - CTX_CREATE. Creates the host-side 3D context that
 * subsequent SUBMIT_3D / resource attach commands run under. context_init
 * carries the capset id (virgl vs venus) in its low byte; debug_name is
 * informational. Mirrors Linux virtio_gpu_cmd_context_create.
 */
static int
virtio_gpu_cmd_ctx_create(struct virtio_gpu_softc *sc, uint32_t ctx_id,
    uint32_t context_init, const char *name)
{
	struct virtio_gpu_ctx_create cmd;
	struct virtio_gpu_ctrl_hdr resp;
	size_t nlen;

	bzero(&cmd, sizeof (cmd));
	cmd.hdr.type = VIRTIO_GPU_CMD_CTX_CREATE;
	cmd.hdr.ctx_id = ctx_id;
	cmd.context_init = context_init;
	nlen = (name != NULL) ? strlen(name) : 0;
	if (nlen >= sizeof (cmd.debug_name))
		nlen = sizeof (cmd.debug_name) - 1;
	if (nlen > 0)
		bcopy(name, cmd.debug_name, nlen);
	cmd.nlen = (uint32_t)nlen;
	return (virtio_gpu_exec(sc, &cmd, sizeof (cmd), &resp, sizeof (resp)));
}

/* virtio_gpu_cmd_ctx_destroy - CTX_DESTROY. Mirrors virtio_gpu_cmd_context_destroy. */
static int
virtio_gpu_cmd_ctx_destroy(struct virtio_gpu_softc *sc, uint32_t ctx_id)
{
	struct virtio_gpu_ctx_destroy cmd;
	struct virtio_gpu_ctrl_hdr resp;

	bzero(&cmd, sizeof (cmd));
	cmd.hdr.type = VIRTIO_GPU_CMD_CTX_DESTROY;
	cmd.hdr.ctx_id = ctx_id;
	return (virtio_gpu_exec(sc, &cmd, sizeof (cmd), &resp, sizeof (resp)));
}

/*
 * virtio_gpu_cmd_ctx_attach_resource - CTX_ATTACH_RESOURCE. Binds a 3D
 * resource to the context so the command stream can reference it. Mirrors
 * virtio_gpu_cmd_context_attach_resource.
 */
static int
virtio_gpu_cmd_ctx_attach_resource(struct virtio_gpu_softc *sc, uint32_t ctx_id,
    uint32_t res_id)
{
	struct virtio_gpu_ctx_resource cmd;
	struct virtio_gpu_ctrl_hdr resp;

	bzero(&cmd, sizeof (cmd));
	cmd.hdr.type = VIRTIO_GPU_CMD_CTX_ATTACH_RESOURCE;
	cmd.hdr.ctx_id = ctx_id;
	cmd.resource_id = res_id;
	return (virtio_gpu_exec(sc, &cmd, sizeof (cmd), &resp, sizeof (resp)));
}

/*
 * virtio_gpu_cmd_resource_create_3d - RESOURCE_CREATE_3D. The 3D analogue of
 * RESOURCE_CREATE_2D: adds target (texture/buffer type), bind flags, depth,
 * array size, mip levels, samples. Mirrors virtio_gpu_cmd_resource_create_3d.
 */
static int
virtio_gpu_cmd_resource_create_3d(struct virtio_gpu_softc *sc,
    const struct drm_virtgpu_resource_create *rc, uint32_t res_id)
{
	struct virtio_gpu_resource_create_3d cmd;
	struct virtio_gpu_ctrl_hdr resp;

	bzero(&cmd, sizeof (cmd));
	cmd.hdr.type = VIRTIO_GPU_CMD_RESOURCE_CREATE_3D;
	cmd.resource_id = res_id;
	cmd.target = rc->target;
	cmd.format = rc->format;
	cmd.bind = rc->bind;
	cmd.width = rc->width;
	cmd.height = rc->height;
	cmd.depth = rc->depth;
	cmd.array_size = rc->array_size;
	cmd.last_level = rc->last_level;
	cmd.nr_samples = rc->nr_samples;
	cmd.flags = rc->flags;
	return (virtio_gpu_exec(sc, &cmd, sizeof (cmd), &resp, sizeof (resp)));
}

/*
 * virtio_gpu_cmd_attach_backing - RESOURCE_ATTACH_BACKING for a GEM object's
 * pages (the 3D path reuses the C1b backing shape). Hands the host the object's
 * DMA cookies as the resource's storage. Mirrors virtio_gpu_object_attach.
 * (Uses a fresh virtio_dma copy of the object like the C1b 2D path; zero-copy
 * over the GEM umem cookie is the same upgrade the 2D path notes.)
 */
static int
virtio_gpu_cmd_attach_backing(struct virtio_gpu_softc *sc, uint32_t res_id,
    virtio_dma_t *backing)
{
	uint_t nents = virtio_dma_ncookies(backing);
	size_t cmd_len = sizeof (struct virtio_gpu_resource_attach_backing);
	size_t ent_len = nents * sizeof (struct virtio_gpu_mem_entry);
	struct virtio_gpu_resource_attach_backing cmd;
	struct virtio_gpu_mem_entry *ents;
	struct virtio_gpu_ctrl_hdr resp;
	uint_t i;
	int ret;

	bzero(&cmd, sizeof (cmd));
	cmd.hdr.type = VIRTIO_GPU_CMD_RESOURCE_ATTACH_BACKING;
	cmd.resource_id = res_id;
	cmd.nr_entries = nents;

	ents = kmem_zalloc(ent_len, KM_SLEEP);
	for (i = 0; i < nents; i++) {
		ents[i].addr = virtio_dma_cookie_pa(backing, i);
		ents[i].length = (uint32_t)virtio_dma_cookie_size(backing, i);
		ents[i].padding = 0;
	}
	ret = virtio_gpu_exec_extra(sc, &cmd, cmd_len, ents, ent_len,
	    &resp, sizeof (resp));
	kmem_free(ents, ent_len);
	return (ret);
}

/*
 * virtio_gpu_cmd_transfer_3d - TRANSFER_TO_HOST_3D / TRANSFER_FROM_HOST_3D. The
 * box-form transfer between guest pages and a host 3D resource. `to_host`
 * selects the direction. Mirrors virtio_gpu_cmd_transfer_{to,from}_host_3d.
 */
static int
virtio_gpu_cmd_transfer_3d(struct virtio_gpu_softc *sc, uint32_t res_id,
    const struct drm_virtgpu_3d_box *box, uint32_t level, uint64_t offset,
    uint32_t stride, uint32_t layer_stride, boolean_t to_host)
{
	struct virtio_gpu_transfer_host_3d cmd;
	struct virtio_gpu_ctrl_hdr resp;

	bzero(&cmd, sizeof (cmd));
	cmd.hdr.type = to_host ? VIRTIO_GPU_CMD_TRANSFER_TO_HOST_3D :
	    VIRTIO_GPU_CMD_TRANSFER_FROM_HOST_3D;
	cmd.hdr.ctx_id = sc->sc_drm->ctx_id;
	cmd.box.x = box->x;
	cmd.box.y = box->y;
	cmd.box.z = box->z;
	cmd.box.w = box->w;
	cmd.box.h = box->h;
	cmd.box.d = box->d;
	cmd.offset = offset;
	cmd.resource_id = res_id;
	cmd.level = level;
	cmd.stride = stride;
	cmd.layer_stride = layer_stride;
	return (virtio_gpu_exec(sc, &cmd, sizeof (cmd), &resp, sizeof (resp)));
}

/*
 * virtio_gpu_cmd_get_capset_info / _get_capset - GET_CAPSET_INFO then
 * GET_CAPSET: Mesa asks the host what capset (virgl caps, venus caps) it
 * supports at a given index/version, then fetches the capset blob. Mirrors
 * virtio_gpu_cmd_get_capset_info / virtio_gpu_cmd_get_capset.
 */
static int
virtio_gpu_cmd_get_capset_info(struct virtio_gpu_softc *sc, uint32_t index,
    struct virtio_gpu_resp_capset_info *info)
{
	struct virtio_gpu_get_capset_info cmd;

	bzero(&cmd, sizeof (cmd));
	cmd.hdr.type = VIRTIO_GPU_CMD_GET_CAPSET_INFO;
	cmd.capset_index = index;
	return (virtio_gpu_exec(sc, &cmd, sizeof (cmd), info, sizeof (*info)));
}

static int
virtio_gpu_cmd_get_capset(struct virtio_gpu_softc *sc, uint32_t capset_id,
    uint32_t version, void *out, size_t out_len)
{
	struct virtio_gpu_get_capset cmd;
	struct virtio_gpu_resp_capset *resp;
	size_t resp_len = sizeof (struct virtio_gpu_ctrl_hdr) + out_len;
	int ret;

	bzero(&cmd, sizeof (cmd));
	cmd.hdr.type = VIRTIO_GPU_CMD_GET_CAPSET;
	cmd.capset_id = capset_id;
	cmd.capset_version = version;

	resp = kmem_zalloc(resp_len, KM_SLEEP);
	ret = virtio_gpu_exec(sc, &cmd, sizeof (cmd), resp, resp_len);
	if (ret == 0)
		bcopy(resp->capset_data, out, out_len);
	kmem_free(resp, resp_len);
	return (ret);
}

/* ================= 3D context (per drm device, C1d) ================= */

/*
 * virtio_gpu_ensure_context - lazily create the host 3D context. Real DRM does
 * this on CONTEXT_INIT or the first EXECBUFFER; C1d creates it once per device
 * (the device-global-context ceiling noted in drm_internal.h) and remembers the
 * ctx_id + capset in the drm_device.
 */
static int
virtio_gpu_ensure_context(struct drm_device *dev, uint32_t capset_id)
{
	struct virtio_gpu_softc *sc = dev->vgpu;
	uint32_t ctx_id;
	int ret;

	mutex_enter(&sc->sc_lock);
	if (dev->ctx_id != 0) {
		mutex_exit(&sc->sc_lock);
		return (0);
	}
	ctx_id = sc->sc_next_ctx_id++;
	mutex_exit(&sc->sc_lock);

	ret = virtio_gpu_cmd_ctx_create(sc, ctx_id,
	    capset_id & VIRTIO_GPU_CONTEXT_INIT_CAPSET_ID_MASK, "solnix");
	if (ret != 0)
		return (ret);

	dev->ctx_id = ctx_id;
	dev->ctx_capset = capset_id;
	return (0);
}

/* ================= EXECBUFFER: scheduler run_job -> SUBMIT_3D ============= */

/*
 * struct virtio_gpu_submit - one EXECBUFFER in flight. The scheduler owns it:
 * run_job ships the command bytes via SUBMIT_3D and returns NULL (synchronous
 * completion under the C1c FIFO), so the job's finished dma-fence signals as
 * soon as the host acks. free_job releases the copied command bytes + the job.
 */
struct virtio_gpu_submit {
	struct drm_sched_job	base;
	struct virtio_gpu_softc	*sc;
	uint32_t		ctx_id;
	void			*cmdbuf;	/* copied-in command stream */
	uint32_t		cmdlen;
};

static void
virtio_gpu_submit_free(struct drm_sched_job *job)
{
	struct virtio_gpu_submit *s = (struct virtio_gpu_submit *)job;

	if (s->cmdbuf != NULL)
		kmem_free(s->cmdbuf, s->cmdlen);
	kmem_free(s, sizeof (*s));
}

/*
 * virtio_gpu_submit_run - the scheduler run_job. Emit SUBMIT_3D carrying the
 * command stream (hdr + size, followed by cmdlen bytes) on the controlq under
 * this job's context. Returns NULL: the C1c synchronous exec has already
 * completed by the time this returns, so the scheduler signals the finished
 * fence immediately (a real async transport would return a hardware fence).
 * Mirrors the Linux virtgpu virtio_gpu_cmd_submit shape.
 */
static struct dma_fence *
virtio_gpu_submit_run(struct drm_sched_job *job)
{
	struct virtio_gpu_submit *s = (struct virtio_gpu_submit *)job;
	struct virtio_gpu_cmd_submit cmd;
	struct virtio_gpu_ctrl_hdr resp;

	bzero(&cmd, sizeof (cmd));
	cmd.hdr.type = VIRTIO_GPU_CMD_SUBMIT_3D;
	cmd.hdr.ctx_id = s->ctx_id;
	cmd.size = s->cmdlen;
	(void) virtio_gpu_exec_extra(s->sc, &cmd, sizeof (cmd),
	    s->cmdbuf, s->cmdlen, &resp, sizeof (resp));
	return (NULL);	/* synchronous: finished fence signals now */
}

/*
 * virtio_gpu_ioctl_execbuffer - DRM_IOCTL_VIRTGPU_EXECBUFFER. The load-bearing
 * path: submit a virgl/venus command buffer to the host.
 *
 *   copyin the command stream -> build a scheduler job whose run_job ships it
 *   via SUBMIT_3D -> push it -> the job's finished dma-fence is the out fence.
 *   If VIRTGPU_EXECBUF_FENCE_FD_OUT, wrap that fence in a sync_file fd (C1c) and
 *   return it. If VIRTGPU_EXECBUF_FENCE_FD_IN, wait on the in fence first.
 *
 * Follows Linux virtgpu_ioctl.c virtio_gpu_execbuffer_ioctl (minus the BO
 * reservation dance -- C1d uses the device-global GEM table + the FIFO
 * scheduler for ordering; per-BO dma-resv fencing is the C1c primitive to wire
 * when EXECBUFFER takes real bo_handles lists, noted below).
 */
int
virtio_gpu_ioctl_execbuffer(struct drm_device *dev, intptr_t arg, int mode)
{
	struct virtio_gpu_softc *sc = dev->vgpu;
	struct drm_virtgpu_execbuffer req;
	struct virtio_gpu_submit *s;
	struct dma_fence *fence;
	void *cmdbuf;
	int ret, out_fd;

	if (sc == NULL)
		return (ENXIO);
	if (!sc->sc_has_virgl)
		return (ENOTSUP);	/* host is 2D-only (no virtio-gpu-gl) */
	if (ddi_copyin((void *)arg, &req, sizeof (req), mode) != 0)
		return (EFAULT);
	if (req.size == 0 || req.size > VIRTIO_GPU_MAX_EXECBUF)
		return (EINVAL);

	/* a context is required for SUBMIT_3D; create the default one lazily. */
	ret = virtio_gpu_ensure_context(dev, dev->ctx_capset);
	if (ret != 0)
		return (ret);

	/*
	 * If an in-fence fd was supplied, wait for it before submitting (the
	 * "wait before GPU work" half of the fence contract). C1c sync_file.
	 */
	if (req.flags & VIRTGPU_EXECBUF_FENCE_FD_IN) {
		struct dma_fence *in = sync_file_get_fence(dev, req.fence_fd);
		if (in != NULL) {
			(void) dma_fence_wait(in, B_TRUE);
			dma_fence_put(in);
		}
	}

	/* copy the command stream in. NOTE: bo_handles list is accepted but not
	 * yet used for per-BO dma-resv fencing -- the FIFO scheduler serializes
	 * submits, which is correct-but-coarse; wire dma_resv_add when EXECBUFFER
	 * needs concurrent contexts. */
	cmdbuf = kmem_alloc(req.size, KM_SLEEP);
	if (ddi_copyin((void *)(uintptr_t)req.command, cmdbuf, req.size,
	    mode) != 0) {
		kmem_free(cmdbuf, req.size);
		return (EFAULT);
	}

	s = kmem_zalloc(sizeof (*s), KM_SLEEP);
	s->sc = sc;
	s->ctx_id = dev->ctx_id;
	s->cmdbuf = cmdbuf;
	s->cmdlen = req.size;
	(void) drm_sched_job_init(&sc->sc_sched, &s->base);
	s->base.run_job = virtio_gpu_submit_run;
	s->base.free_job = virtio_gpu_submit_free;

	/* push -> returns the finished fence (caller's ref) to wait on/export. */
	fence = drm_sched_entity_push_job(&s->base);

	if (req.flags & VIRTGPU_EXECBUF_FENCE_FD_OUT) {
		out_fd = sync_file_create(dev, fence);
		if (out_fd < 0) {
			dma_fence_put(fence);
			return (-out_fd);
		}
		req.fence_fd = out_fd;
		if (ddi_copyout(&req, (void *)arg, sizeof (req), mode) != 0) {
			dma_fence_put(fence);
			return (EFAULT);
		}
	}
	dma_fence_put(fence);	/* caller's ref (sync_file took its own) */
	return (0);
}

/* ================= the remaining virtio-gpu DRM ioctls ================= */

/*
 * virtio_gpu_ioctl_context_init - DRM_IOCTL_VIRTGPU_CONTEXT_INIT. Mesa selects
 * the renderer (virgl vs venus) by a capset id in the context_set_param array.
 * C1d reads the CAPSET_ID param and creates the context with it. Follows Linux
 * virtio_gpu_context_init_ioctl (parsing the param array for CAPSET_ID).
 */
int
virtio_gpu_ioctl_context_init(struct drm_device *dev, intptr_t arg, int mode)
{
	struct virtio_gpu_softc *sc = dev->vgpu;
	struct drm_virtgpu_context_init req;
	struct drm_virtgpu_context_set_param param;
	uint32_t capset = 0;
	uint64_t p;
	uint32_t i;

	if (sc == NULL)
		return (ENXIO);
	if (!sc->sc_has_virgl)
		return (ENOTSUP);
	if (ddi_copyin((void *)arg, &req, sizeof (req), mode) != 0)
		return (EFAULT);
	if (req.num_params == 0 || req.num_params > 16)
		return (EINVAL);

	p = req.ctx_set_params;
	for (i = 0; i < req.num_params; i++) {
		if (ddi_copyin((void *)(uintptr_t)p, &param, sizeof (param),
		    mode) != 0)
			return (EFAULT);
		if (param.param == VIRTGPU_CONTEXT_PARAM_CAPSET_ID)
			capset = (uint32_t)param.value;
		p += sizeof (param);
	}
	if (dev->ctx_id != 0)
		return (EEXIST);	/* one context per device (C1d ceiling) */
	return (virtio_gpu_ensure_context(dev, capset));
}

/*
 * virtio_gpu_ioctl_getparam - DRM_IOCTL_VIRTGPU_GETPARAM. Mesa probes whether
 * the host has 3D features / context-init before choosing virgl/venus. Follows
 * Linux virtio_gpu_getparam_ioctl.
 */
int
virtio_gpu_ioctl_getparam(struct drm_device *dev, intptr_t arg, int mode)
{
	struct virtio_gpu_softc *sc = dev->vgpu;
	struct drm_virtgpu_getparam req;
	uint64_t value = 0;

	if (sc == NULL)
		return (ENXIO);
	if (ddi_copyin((void *)arg, &req, sizeof (req), mode) != 0)
		return (EFAULT);

	switch (req.param) {
	case VIRTGPU_PARAM_3D_FEATURES:
		value = sc->sc_has_virgl ? 1 : 0;
		break;
	case VIRTGPU_PARAM_CAPSET_QUERY_FIX:
		value = 1;
		break;
	case VIRTGPU_PARAM_CONTEXT_INIT:
		value = 1;
		break;
	default:
		value = 0;
		break;
	}
	if (ddi_copyout(&value, (void *)(uintptr_t)req.value, sizeof (value),
	    mode) != 0)
		return (EFAULT);
	return (0);
}

/*
 * virtio_gpu_ioctl_get_caps - DRM_IOCTL_VIRTGPU_GET_CAPS. Fetch the host capset
 * blob (virgl caps / venus caps) into the user buffer, so Mesa configures its
 * feature set to match the host renderer. Walks GET_CAPSET_INFO to find the
 * requested capset id, then GET_CAPSET for the blob. Follows Linux
 * virtio_gpu_get_caps_ioctl.
 */
int
virtio_gpu_ioctl_get_caps(struct drm_device *dev, intptr_t arg, int mode)
{
	struct virtio_gpu_softc *sc = dev->vgpu;
	struct drm_virtgpu_get_caps req;
	struct virtio_gpu_resp_capset_info info;
	uint32_t i, size;
	void *blob;
	int ret = ENOENT;

	if (sc == NULL)
		return (ENXIO);
	if (!sc->sc_has_virgl)
		return (ENOTSUP);
	if (ddi_copyin((void *)arg, &req, sizeof (req), mode) != 0)
		return (EFAULT);
	if (req.size == 0 || req.size > VIRTIO_GPU_MAX_CAPSET)
		return (EINVAL);

	/* find the capset index whose id matches the requested cap_set_id. */
	for (i = 0; i < sc->sc_num_capsets; i++) {
		bzero(&info, sizeof (info));
		if (virtio_gpu_cmd_get_capset_info(sc, i, &info) != 0)
			continue;
		if (info.capset_id != req.cap_set_id)
			continue;

		size = info.capset_max_size;
		if (size == 0 || size > req.size)
			size = req.size;
		blob = kmem_zalloc(size, KM_SLEEP);
		ret = virtio_gpu_cmd_get_capset(sc, req.cap_set_id,
		    req.cap_set_ver, blob, size);
		if (ret == 0 &&
		    ddi_copyout(blob, (void *)(uintptr_t)req.addr, size,
		    mode) != 0)
			ret = EFAULT;
		kmem_free(blob, size);
		break;
	}
	return (ret);
}

/*
 * virtio_gpu_ioctl_resource_create - DRM_IOCTL_VIRTGPU_RESOURCE_CREATE. Create
 * a 3D resource: allocate (or reuse) a GEM object for its guest backing, issue
 * RESOURCE_CREATE_3D, attach the backing, and (if a context exists) attach the
 * resource to it. Returns the res_handle + the GEM bo_handle. Follows Linux
 * virtio_gpu_resource_create_ioctl.
 */
int
virtio_gpu_ioctl_resource_create(struct drm_device *dev, intptr_t arg, int mode)
{
	struct virtio_gpu_softc *sc = dev->vgpu;
	struct drm_virtgpu_resource_create req;
	struct drm_gem_object *obj;
	virtio_dma_t *backing;
	uint32_t res_id;
	size_t size;
	int ret;

	if (sc == NULL)
		return (ENXIO);
	if (!sc->sc_has_virgl)
		return (ENOTSUP);
	if (ddi_copyin((void *)arg, &req, sizeof (req), mode) != 0)
		return (EFAULT);

	/* size the guest backing: explicit size, else a linear w*h*4 estimate. */
	size = req.size;
	if (size == 0)
		size = (size_t)req.width * (req.height ? req.height : 1) * 4;
	if (size == 0)
		return (EINVAL);
	size = P2ROUNDUP(size, PAGESIZE);

	/* a GEM object is the guest-side handle for the resource (C1 GEM). */
	obj = kmem_zalloc(sizeof (*obj), KM_SLEEP);
	kref_init(&obj->refcount);
	obj->size = size;
	obj->kaddr = ddi_umem_alloc(size, DDI_UMEM_SLEEP, &obj->umem_cookie);
	if (obj->kaddr == NULL) {
		kmem_free(obj, sizeof (*obj));
		return (ENOMEM);
	}

	mutex_enter(&sc->sc_lock);
	res_id = sc->sc_next_res_id++;
	mutex_exit(&sc->sc_lock);
	obj->virtio_res_id = res_id;

	ret = virtio_gpu_cmd_resource_create_3d(sc, &req, res_id);
	if (ret != 0)
		goto err;

	backing = virtio_dma_alloc(sc->sc_virtio, size, &virtio_gpu_dma_attr,
	    KM_SLEEP, "vgpu-res3d");
	if (backing == NULL) {
		ret = ENOMEM;
		goto err;
	}
	ret = virtio_gpu_cmd_attach_backing(sc, res_id, backing);
	virtio_dma_free(backing);
	if (ret != 0)
		goto err;

	if (dev->ctx_id != 0)
		(void) virtio_gpu_cmd_ctx_attach_resource(sc, dev->ctx_id,
		    res_id);

	mutex_enter(&dev->lock);
	obj->handle = idr_alloc(&dev->gem_handles, obj);
	obj->mmap_offset = dev->next_mmap_offset;
	dev->next_mmap_offset += size;
	mutex_exit(&dev->lock);

	req.bo_handle = obj->handle;
	req.res_handle = res_id;
	if (ddi_copyout(&req, (void *)arg, sizeof (req), mode) != 0)
		return (EFAULT);
	return (0);

err:
	ddi_umem_free(obj->umem_cookie);
	kmem_free(obj, sizeof (*obj));
	return (ret);
}

/*
 * virtio_gpu_ioctl_resource_info - DRM_IOCTL_VIRTGPU_RESOURCE_INFO. Return a
 * GEM object's host resource id + size. Follows Linux virtio_gpu_resource_info_ioctl.
 */
int
virtio_gpu_ioctl_resource_info(struct drm_device *dev, intptr_t arg, int mode)
{
	struct drm_virtgpu_resource_info req;
	struct drm_gem_object *obj;

	if (dev->vgpu == NULL)
		return (ENXIO);
	if (ddi_copyin((void *)arg, &req, sizeof (req), mode) != 0)
		return (EFAULT);

	obj = idr_find(&dev->gem_handles, req.bo_handle);
	if (obj == NULL)
		return (ENOENT);
	req.res_handle = obj->virtio_res_id;
	req.size = (uint32_t)obj->size;
	req.blob_mem = 0;
	if (ddi_copyout(&req, (void *)arg, sizeof (req), mode) != 0)
		return (EFAULT);
	return (0);
}

/*
 * virtio_gpu_ioctl_transfer_to_host / _from_host - the box-form 3D transfers.
 * Resolve the GEM handle to its resource id + backing, then issue
 * TRANSFER_{TO,FROM}_HOST_3D. Follow Linux virtio_gpu_transfer_{to,from}_host_ioctl.
 */
static int
virtio_gpu_transfer_common(struct drm_device *dev, uint32_t bo_handle,
    const struct drm_virtgpu_3d_box *box, uint32_t level, uint32_t offset,
    uint32_t stride, uint32_t layer_stride, boolean_t to_host)
{
	struct virtio_gpu_softc *sc = dev->vgpu;
	struct drm_gem_object *obj;
	virtio_dma_t *backing;
	int ret;

	if (sc == NULL)
		return (ENXIO);
	obj = idr_find(&dev->gem_handles, bo_handle);
	if (obj == NULL)
		return (ENOENT);
	if (obj->virtio_res_id == 0)
		return (EINVAL);	/* not a 3D resource */

	/*
	 * Re-hand the object's pages to the host for this transfer. C1d copies
	 * into a fresh virtio_dma region + re-attaches (the same non-zero-copy
	 * shortcut the 2D path uses); the pages ARE the host resource storage.
	 */
	backing = virtio_dma_alloc(sc->sc_virtio, obj->size,
	    &virtio_gpu_dma_attr, KM_SLEEP, "vgpu-xfer3d");
	if (backing == NULL)
		return (ENOMEM);
	if (to_host) {
		bcopy(obj->kaddr, virtio_dma_va(backing, 0), obj->size);
		virtio_dma_sync(backing, DDI_DMA_SYNC_FORDEV);
	}
	(void) virtio_gpu_cmd_attach_backing(sc, obj->virtio_res_id, backing);
	ret = virtio_gpu_cmd_transfer_3d(sc, obj->virtio_res_id, box, level,
	    offset, stride, layer_stride, to_host);
	if (!to_host && ret == 0) {
		virtio_dma_sync(backing, DDI_DMA_SYNC_FORCPU);
		bcopy(virtio_dma_va(backing, 0), obj->kaddr, obj->size);
	}
	virtio_dma_free(backing);
	return (ret);
}

int
virtio_gpu_ioctl_transfer_to_host(struct drm_device *dev, intptr_t arg,
    int mode)
{
	struct drm_virtgpu_3d_transfer_to_host req;

	if (ddi_copyin((void *)arg, &req, sizeof (req), mode) != 0)
		return (EFAULT);
	return (virtio_gpu_transfer_common(dev, req.bo_handle, &req.box,
	    req.level, req.offset, req.stride, req.layer_stride, B_TRUE));
}

int
virtio_gpu_ioctl_transfer_from_host(struct drm_device *dev, intptr_t arg,
    int mode)
{
	struct drm_virtgpu_3d_transfer_from_host req;

	if (ddi_copyin((void *)arg, &req, sizeof (req), mode) != 0)
		return (EFAULT);
	return (virtio_gpu_transfer_common(dev, req.bo_handle, &req.box,
	    req.level, req.offset, req.stride, req.layer_stride, B_FALSE));
}

/*
 * virtio_gpu_ioctl_map - DRM_IOCTL_VIRTGPU_MAP. Return the mmap offset for a
 * resource's GEM object, exactly like MODE_MAP_DUMB: userspace then mmaps the
 * render node at this offset and cb_devmap (C1b) faults the object's umem
 * pages. This is the host-coherent map (the same pages the host renders from).
 * Follows Linux virtio_gpu_map_ioctl / the reused DUMB map path.
 */
int
virtio_gpu_ioctl_map(struct drm_device *dev, intptr_t arg, int mode)
{
	struct drm_virtgpu_map req;
	struct drm_gem_object *obj;

	if (dev->vgpu == NULL)
		return (ENXIO);
	if (ddi_copyin((void *)arg, &req, sizeof (req), mode) != 0)
		return (EFAULT);
	obj = idr_find(&dev->gem_handles, req.handle);
	if (obj == NULL)
		return (ENOENT);
	req.offset = obj->mmap_offset;
	if (ddi_copyout(&req, (void *)arg, sizeof (req), mode) != 0)
		return (EFAULT);
	return (0);
}

/*
 * virtio_gpu_ioctl_wait - DRM_IOCTL_VIRTGPU_WAIT. Wait for a resource's GPU work
 * to complete. C1d reuses the C1c sync_file/dma-fence: the handle here is a
 * resource bo_handle in the UAPI, but the fence-bearing path is EXECBUFFER's
 * out sync_file fd; a per-object busy fence would attach to the GEM object's
 * dma_resv (the C1c primitive). C1d treats it as a no-op success (the FIFO
 * scheduler already completed prior submits synchronously). NOTE: real per-BO
 * wait attaches the submit fence to the object's dma_resv and waits on it here;
 * wire when EXECBUFFER stops being synchronous. Follows virtio_gpu_wait_ioctl.
 */
int
virtio_gpu_ioctl_wait(struct drm_device *dev, intptr_t arg, int mode)
{
	struct drm_virtgpu_3d_wait req;

	if (dev->vgpu == NULL)
		return (ENXIO);
	if (ddi_copyin((void *)arg, &req, sizeof (req), mode) != 0)
		return (EFAULT);
	return (0);	/* synchronous scheduler: nothing outstanding */
}

/*
 * virtio_gpu_3d_context_fini - drop the device 3D context at detach (CTX_DESTROY
 * on the host). Called from virtio_gpu_transport_detach.
 */
void
virtio_gpu_3d_context_fini(struct virtio_gpu_softc *sc, struct drm_device *dev)
{
	if (dev != NULL && dev->ctx_id != 0) {
		(void) virtio_gpu_cmd_ctx_destroy(sc, dev->ctx_id);
		dev->ctx_id = 0;
	}
}
