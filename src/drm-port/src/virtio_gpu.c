/*
 * virtio_gpu.c - virtio-gpu transport + 2D modeset (C1b).
 *
 * Wires the C1a drm core to the illumos virtio framework and implements the
 * virtio-gpu 2D command path far enough to (a) probe the host display
 * (GET_DISPLAY_INFO) and (b) light a framebuffer:
 *   RESOURCE_CREATE_2D -> RESOURCE_ATTACH_BACKING -> SET_SCANOUT ->
 *   TRANSFER_TO_HOST_2D -> RESOURCE_FLUSH.
 *
 * Provenance:
 *   - the command structs + enum are cribbed verbatim from Linux/QEMU
 *     include/uapi/linux/virtio_gpu.h (see virtio_gpu_hw.h; BSD-licensed).
 *   - the command-flow (create resource, attach guest pages as backing,
 *     scanout, flush) follows Linux drivers/gpu/drm/virtio/virtgpu_vq.c and
 *     NetBSD's equivalent, but is re-expressed against the illumos virtio KPI
 *     (virtio_init / virtio_queue_alloc / virtio_chain_* / virtio_dma_*) rather
 *     than the Linux virtqueue API. We do NOT lift the Linux .c.
 *   - the illumos virtio attach shape (virtio_init in attach, queues, then
 *     virtio_init_complete) follows illumos vioif(4D)/vioblk(4D).
 *
 * COMPILE milestone: this file compiles against illumos kernel headers with
 * every virtio_* symbol resolving to the real `virtio` module KPI. Whether it
 * *runs* (attaches under QEMU -device virtio-gpu, GET_DISPLAY_INFO returns) is
 * the C1b stretch; the code is written to run, not just compile.
 */

#include <sys/types.h>
#include <sys/sysmacros.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/kmem.h>
#include <sys/ksynch.h>
#include <sys/cmn_err.h>
#include <sys/ddidmareq.h>

#include "virtio_impl.h"
#include "virtio_gpu_hw.h"
#include "drm_internal.h"

/* virtqueue indices for virtio-gpu (spec: controlq=0, cursorq=1). */
#define VIRTIO_GPU_VQ_CONTROL	0
#define VIRTIO_GPU_VQ_CURSOR	1

/* first non-reserved resource id (0 is invalid in the protocol). */
#define VIRTIO_GPU_FIRST_RES_ID	1

/*
 * struct virtio_gpu_softc - per-instance virtio-gpu transport state. Hung off
 * drm_device->vgpu. Holds the framework handle, the two queues, the scanout
 * geometry read from GET_DISPLAY_INFO, and a monotonic resource-id counter.
 */
struct virtio_gpu_softc {
	dev_info_t	*sc_dip;
	virtio_t	*sc_virtio;
	virtio_queue_t	*sc_controlq;
	virtio_queue_t	*sc_cursorq;
	kmutex_t	sc_lock;

	uint32_t	sc_num_scanouts;
	uint32_t	sc_next_res_id;

	/* scanout 0 geometry from GET_DISPLAY_INFO (0x0 if display disabled). */
	uint32_t	sc_width;
	uint32_t	sc_height;
	boolean_t	sc_display_ok;

	struct drm_device *sc_drm;	/* back-pointer to the drm core device */
};

/*
 * DMA attributes for virtio-gpu command buffers. 64-bit addressable, page
 * aligned, generous sg length (backing lists can be many pages).
 * PAGESIZE is a runtime symbol (_pagesize) on illumos so it cannot appear in a
 * static initializer; amd64 base page is 4096, used as the alignment constant.
 */
#define VIRTIO_GPU_PAGE_ALIGN	4096
static const ddi_dma_attr_t virtio_gpu_dma_attr = {
	.dma_attr_version	= DMA_ATTR_V0,
	.dma_attr_addr_lo	= 0,
	.dma_attr_addr_hi	= 0xFFFFFFFFFFFFFFFFULL,
	.dma_attr_count_max	= 0xFFFFFFFFULL,
	.dma_attr_align		= VIRTIO_GPU_PAGE_ALIGN,
	.dma_attr_burstsizes	= 1,
	.dma_attr_minxfer	= 1,
	.dma_attr_maxxfer	= 0xFFFFFFFFULL,
	.dma_attr_seg		= 0xFFFFFFFFFFFFFFFFULL,
	.dma_attr_sgllen	= 256,
	.dma_attr_granular	= 1,
	.dma_attr_flags		= 0,
};

/*
 * virtio_gpu_exec - submit one control-queue command and wait for its response.
 *
 * Builds a 2-descriptor chain: [cmd (device-reads)] + [resp (device-writes)],
 * submits it on the control queue, polls for completion, and copies the
 * response type back. This is the synchronous request/response pattern the 2D
 * commands use (Linux does this async via a fence + callback; C1b uses the
 * simplest correct thing: submit + poll, one command in flight).
 *
 * NOTE: synchronous poll, one command in flight at a time under sc_lock.
 * Fine for modeset (a handful of commands at boot); a real driver pipelines
 * many chains + uses the completion interrupt. Upgrade when >1 command/frame.
 *
 * cmd_len : bytes of the command struct to send.
 * resp    : caller buffer for the response header (at least resp_len bytes).
 * Returns 0 on VIRTIO_GPU_RESP_OK_*, EIO otherwise.
 */
static int
virtio_gpu_exec(struct virtio_gpu_softc *sc, const void *cmd, size_t cmd_len,
    void *resp, size_t resp_len)
{
	virtio_dma_t *dma;
	virtio_chain_t *vic;
	uint8_t *va;
	uint64_t cmd_pa, resp_pa;
	struct virtio_gpu_ctrl_hdr *rhdr;
	uint32_t rtype;
	int ret = EIO;

	/* one DMA buffer holds cmd then response, page-aligned regions. */
	size_t total = P2ROUNDUP(cmd_len, 16) + resp_len;
	dma = virtio_dma_alloc(sc->sc_virtio, total, &virtio_gpu_dma_attr,
	    KM_SLEEP, "vgpu-cmd");
	if (dma == NULL)
		return (ENOMEM);

	va = virtio_dma_va(dma, 0);
	bcopy(cmd, va, cmd_len);
	bzero(va + P2ROUNDUP(cmd_len, 16), resp_len);

	/* the buffer is one physically-contiguous region (single cookie). */
	cmd_pa = virtio_dma_cookie_pa(dma, 0);
	resp_pa = cmd_pa + P2ROUNDUP(cmd_len, 16);

	vic = virtio_chain_alloc(sc->sc_controlq, KM_SLEEP);
	if (vic == NULL) {
		virtio_dma_free(dma);
		return (ENOMEM);
	}

	/* device reads the command, then writes the response. */
	if (virtio_chain_append(vic, cmd_pa, cmd_len,
	    VIRTIO_DIR_DEVICE_READS) != 0 ||
	    virtio_chain_append(vic, resp_pa, resp_len,
	    VIRTIO_DIR_DEVICE_WRITES) != 0) {
		virtio_chain_free(vic);
		virtio_dma_free(dma);
		return (EIO);
	}

	virtio_dma_sync(dma, DDI_DMA_SYNC_FORDEV);
	virtio_chain_submit(vic, B_TRUE);

	/* poll the control queue until our chain comes back. */
	for (;;) {
		virtio_chain_t *done = virtio_queue_poll(sc->sc_controlq);
		if (done == NULL) {
			drv_usecwait(50);
			continue;
		}
		if (done == vic)
			break;
		/* not ours (shouldn't happen with one in flight) -- release. */
		virtio_chain_free(done);
	}

	virtio_dma_sync(dma, DDI_DMA_SYNC_FORCPU);
	rhdr = (struct virtio_gpu_ctrl_hdr *)(va + P2ROUNDUP(cmd_len, 16));
	rtype = rhdr->type;
	if (resp != NULL && resp_len > 0)
		bcopy(rhdr, resp, resp_len);
	if (rtype >= VIRTIO_GPU_RESP_OK_NODATA &&
	    rtype < VIRTIO_GPU_RESP_ERR_UNSPEC)
		ret = 0;

	virtio_chain_free(vic);
	virtio_dma_free(dma);
	return (ret);
}

/*
 * virtio_gpu_get_display_info - the probe. Ask the host for scanout geometry;
 * cache scanout 0's size. On a fresh QEMU virtio-gpu the display is usually
 * present but "disabled" until a scanout is set, so a zero rect is normal.
 */
static int
virtio_gpu_get_display_info(struct virtio_gpu_softc *sc)
{
	struct virtio_gpu_ctrl_hdr cmd;
	struct virtio_gpu_resp_display_info resp;
	int ret;

	bzero(&cmd, sizeof (cmd));
	cmd.type = VIRTIO_GPU_CMD_GET_DISPLAY_INFO;

	ret = virtio_gpu_exec(sc, &cmd, sizeof (cmd), &resp, sizeof (resp));
	if (ret != 0)
		return (ret);
	if (resp.hdr.type != VIRTIO_GPU_RESP_OK_DISPLAY_INFO)
		return (EIO);

	sc->sc_width = resp.pmodes[0].r.width;
	sc->sc_height = resp.pmodes[0].r.height;
	sc->sc_display_ok = (resp.pmodes[0].enabled != 0);

	cmn_err(CE_CONT, "?virtio_gpu: scanout0 %ux%u enabled=%u\n",
	    sc->sc_width, sc->sc_height, resp.pmodes[0].enabled);
	return (0);
}

/* --- the SET_SCANOUT modeset chain (individual commands) --- */

static int
virtio_gpu_resource_create_2d(struct virtio_gpu_softc *sc, uint32_t res_id,
    uint32_t fmt, uint32_t w, uint32_t h)
{
	struct virtio_gpu_resource_create_2d cmd;
	struct virtio_gpu_ctrl_hdr resp;

	bzero(&cmd, sizeof (cmd));
	cmd.hdr.type = VIRTIO_GPU_CMD_RESOURCE_CREATE_2D;
	cmd.resource_id = res_id;
	cmd.format = fmt;
	cmd.width = w;
	cmd.height = h;
	return (virtio_gpu_exec(sc, &cmd, sizeof (cmd), &resp, sizeof (resp)));
}

/*
 * virtio_gpu_attach_backing - hand the host the guest-physical pages that back
 * a GEM object as the resource's storage. The command header is followed by
 * nr_entries virtio_gpu_mem_entry, one per DMA cookie. We build a DMA-mapped
 * copy of the GEM pages (C1b: a fresh virtio_dma_alloc region we bcopy into;
 * a real port maps the GEM umem cookie's own pages so there is no copy).
 *
 * NOTE: copies GEM pages into a virtio_dma region rather than exporting the
 * GEM umem pages' own PAs. Correct but doubles memory + needs a re-copy on each
 * present. Upgrade to zero-copy by cookie-izing the GEM umem pages (C1c, when
 * dma-buf sharing lands and the GEM object owns a ddi_dma handle).
 */
static int
virtio_gpu_attach_backing(struct virtio_gpu_softc *sc, uint32_t res_id,
    virtio_dma_t *backing)
{
	uint_t nents = virtio_dma_ncookies(backing);
	size_t cmd_len = sizeof (struct virtio_gpu_resource_attach_backing) +
	    nents * sizeof (struct virtio_gpu_mem_entry);
	struct virtio_gpu_resource_attach_backing *cmd;
	struct virtio_gpu_mem_entry *ents;
	struct virtio_gpu_ctrl_hdr resp;
	uint_t i;
	int ret;

	cmd = kmem_zalloc(cmd_len, KM_SLEEP);
	cmd->hdr.type = VIRTIO_GPU_CMD_RESOURCE_ATTACH_BACKING;
	cmd->resource_id = res_id;
	cmd->nr_entries = nents;
	ents = (struct virtio_gpu_mem_entry *)(cmd + 1);
	for (i = 0; i < nents; i++) {
		ents[i].addr = virtio_dma_cookie_pa(backing, i);
		ents[i].length = (uint32_t)virtio_dma_cookie_size(backing, i);
		ents[i].padding = 0;
	}

	ret = virtio_gpu_exec(sc, cmd, cmd_len, &resp, sizeof (resp));
	kmem_free(cmd, cmd_len);
	return (ret);
}

static int
virtio_gpu_set_scanout(struct virtio_gpu_softc *sc, uint32_t scanout_id,
    uint32_t res_id, uint32_t w, uint32_t h)
{
	struct virtio_gpu_set_scanout cmd;
	struct virtio_gpu_ctrl_hdr resp;

	bzero(&cmd, sizeof (cmd));
	cmd.hdr.type = VIRTIO_GPU_CMD_SET_SCANOUT;
	cmd.r.x = 0;
	cmd.r.y = 0;
	cmd.r.width = w;
	cmd.r.height = h;
	cmd.scanout_id = scanout_id;
	cmd.resource_id = res_id;
	return (virtio_gpu_exec(sc, &cmd, sizeof (cmd), &resp, sizeof (resp)));
}

static int
virtio_gpu_transfer_to_host_2d(struct virtio_gpu_softc *sc, uint32_t res_id,
    uint32_t w, uint32_t h)
{
	struct virtio_gpu_transfer_to_host_2d cmd;
	struct virtio_gpu_ctrl_hdr resp;

	bzero(&cmd, sizeof (cmd));
	cmd.hdr.type = VIRTIO_GPU_CMD_TRANSFER_TO_HOST_2D;
	cmd.r.x = 0;
	cmd.r.y = 0;
	cmd.r.width = w;
	cmd.r.height = h;
	cmd.offset = 0;
	cmd.resource_id = res_id;
	return (virtio_gpu_exec(sc, &cmd, sizeof (cmd), &resp, sizeof (resp)));
}

static int
virtio_gpu_resource_flush(struct virtio_gpu_softc *sc, uint32_t res_id,
    uint32_t w, uint32_t h)
{
	struct virtio_gpu_resource_flush cmd;
	struct virtio_gpu_ctrl_hdr resp;

	bzero(&cmd, sizeof (cmd));
	cmd.hdr.type = VIRTIO_GPU_CMD_RESOURCE_FLUSH;
	cmd.r.x = 0;
	cmd.r.y = 0;
	cmd.r.width = w;
	cmd.r.height = h;
	cmd.resource_id = res_id;
	return (virtio_gpu_exec(sc, &cmd, sizeof (cmd), &resp, sizeof (resp)));
}

/*
 * virtio_gpu_scanout_buffer - the full first-lit-framebuffer chain. Given a
 * DMA-backed pixel buffer, create a 2D resource, attach the buffer as backing,
 * scan it out on scanout 0, transfer the pixels to the host, and flush. This
 * is the KMS "put pixels on screen" primitive that drm_gem_scanout drives.
 */
static int
virtio_gpu_scanout_buffer(struct virtio_gpu_softc *sc, virtio_dma_t *backing,
    uint32_t w, uint32_t h)
{
	uint32_t res_id;
	int ret;

	mutex_enter(&sc->sc_lock);
	res_id = sc->sc_next_res_id++;
	mutex_exit(&sc->sc_lock);

	ret = virtio_gpu_resource_create_2d(sc, res_id,
	    VIRTIO_GPU_FORMAT_B8G8R8X8_UNORM, w, h);
	if (ret != 0)
		return (ret);
	ret = virtio_gpu_attach_backing(sc, res_id, backing);
	if (ret != 0)
		return (ret);
	ret = virtio_gpu_set_scanout(sc, 0, res_id, w, h);
	if (ret != 0)
		return (ret);
	ret = virtio_gpu_transfer_to_host_2d(sc, res_id, w, h);
	if (ret != 0)
		return (ret);
	return (virtio_gpu_resource_flush(sc, res_id, w, h));
}

/*
 * drm_gem_scanout - called from the drm core's SET_SCANOUT ioctl. Copies the
 * GEM object's pixels into a virtio DMA buffer and drives the scanout chain.
 * (The copy is the shortcut noted in virtio_gpu_attach_backing.)
 */
int
drm_gem_scanout(struct drm_device *dev, uint32_t handle, uint32_t width,
    uint32_t height, uint32_t pitch)
{
	struct virtio_gpu_softc *sc = dev->vgpu;
	struct drm_gem_object *obj;
	virtio_dma_t *backing;
	size_t fbsize = (size_t)pitch * height;
	int ret;

	if (sc == NULL)
		return (ENXIO);	/* no virtio-gpu bound (compile-only core) */
	obj = idr_find(&dev->gem_handles, handle);
	if (obj == NULL)
		return (ENOENT);
	if (fbsize == 0 || fbsize > obj->size)
		return (EINVAL);

	backing = virtio_dma_alloc(sc->sc_virtio, obj->size,
	    &virtio_gpu_dma_attr, KM_SLEEP, "vgpu-fb");
	if (backing == NULL)
		return (ENOMEM);
	bcopy(obj->kaddr, virtio_dma_va(backing, 0), fbsize);
	virtio_dma_sync(backing, DDI_DMA_SYNC_FORDEV);

	ret = virtio_gpu_scanout_buffer(sc, backing, width, height);

	virtio_dma_free(backing);
	return (ret);
}

/*
 * virtio_gpu_transport_attach - bind the illumos virtio framework to this
 * device and set up the queues. Called from the drm attach path once the node
 * is a virtio child (vendor 0x1af4, device 0x1050). Returns a softc or NULL.
 *
 * This is the illumos analogue of a Linux virtio driver's .probe: virtio_init
 * with our feature set, claim controlq + cursorq, virtio_init_complete, then
 * read num_scanouts from config space and probe the display.
 */
struct virtio_gpu_softc *
virtio_gpu_transport_attach(dev_info_t *dip, struct drm_device *drm)
{
	struct virtio_gpu_softc *sc;
	virtio_t *vio;

	/* C1b negotiates no optional features (2D only, no virgl/edid/blob). */
	vio = virtio_init(dip, 0, B_TRUE);
	if (vio == NULL) {
		cmn_err(CE_WARN, "virtio_gpu: virtio_init failed");
		return (NULL);
	}

	sc = kmem_zalloc(sizeof (*sc), KM_SLEEP);
	sc->sc_dip = dip;
	sc->sc_virtio = vio;
	sc->sc_drm = drm;
	sc->sc_next_res_id = VIRTIO_GPU_FIRST_RES_ID;
	mutex_init(&sc->sc_lock, NULL, MUTEX_DRIVER, NULL);

	/* controlq (0) carries the 2D commands; cursorq (1) the cursor. */
	sc->sc_controlq = virtio_queue_alloc(vio, VIRTIO_GPU_VQ_CONTROL,
	    "controlq", NULL, NULL, B_FALSE, virtio_gpu_dma_attr.dma_attr_sgllen);
	sc->sc_cursorq = virtio_queue_alloc(vio, VIRTIO_GPU_VQ_CURSOR,
	    "cursorq", NULL, NULL, B_FALSE, 16);
	if (sc->sc_controlq == NULL || sc->sc_cursorq == NULL) {
		cmn_err(CE_WARN, "virtio_gpu: queue alloc failed");
		goto fail;
	}

	if (virtio_init_complete(vio, 0) != DDI_SUCCESS) {
		cmn_err(CE_WARN, "virtio_gpu: virtio_init_complete failed");
		goto fail;
	}

	sc->sc_num_scanouts =
	    virtio_dev_get32(vio, VIRTIO_GPU_CFG_NUM_SCANOUTS);
	cmn_err(CE_CONT, "?virtio_gpu: %u scanout(s)\n", sc->sc_num_scanouts);

	/* the probe: ask the host what displays it has. */
	(void) virtio_gpu_get_display_info(sc);

	drm->vgpu = sc;
	return (sc);

fail:
	virtio_fini(vio, B_TRUE);
	mutex_destroy(&sc->sc_lock);
	kmem_free(sc, sizeof (*sc));
	return (NULL);
}

void
virtio_gpu_transport_detach(struct virtio_gpu_softc *sc)
{
	if (sc == NULL)
		return;
	virtio_fini(sc->sc_virtio, B_FALSE);
	mutex_destroy(&sc->sc_lock);
	kmem_free(sc, sizeof (*sc));
}
