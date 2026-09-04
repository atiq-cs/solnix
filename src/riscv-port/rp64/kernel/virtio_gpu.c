/*
 * virtio_gpu.c -- R-P64: a virtio-gpu 2D display driver over the qemu-virt
 * MMIO transport.  This is the RISC-V analog of the x86 drm-port's initial
 * scanout bring-up: it brings up a framebuffer on the QEMU virtio-gpu device,
 * the software-rendered display path that COSMIC + llvmpipe target on the
 * Milk-V Jupiter (whose real GPU is the PowerVR BXE, driven separately).
 *
 * qemu invocation this driver binds against:
 *   -device virtio-gpu-device        (MMIO transport, -machine virt)
 *   (add `-display ...` to actually see the scanout; headless still works)
 *
 * The virtio-mmio TRANSPORT here is deliberately identical to virtio_blk.c
 * (probe MagicValue/Version==2/DeviceID, negotiate 0 features, one split
 * virtqueue, kick via QueueNotify, poll the used ring).  virtio-gpu differs
 * only in the DEVICE layer: DeviceID==16, a controlq that carries
 * virtio_gpu_ctrl commands, and a host-visible framebuffer we attach as
 * backing then TRANSFER_TO_HOST_2D + RESOURCE_FLUSH to display.
 *
 * Bring-up sequence (virtio spec v1.2 sec 5.7, "GPU Device"):
 *   1. GET_DISPLAY_INFO       -- read scanout 0's preferred rect (w x h)
 *   2. RESOURCE_CREATE_2D     -- create a B8G8R8X8 host resource
 *   3. RESOURCE_ATTACH_BACKING-- point the resource at our guest framebuffer
 *   4. SET_SCANOUT            -- bind the resource to scanout 0 (the display)
 *   5. TRANSFER_TO_HOST_2D    -- copy the guest fb into the host resource
 *   6. RESOURCE_FLUSH         -- present it to the display
 *
 * CRIB PROVENANCE: virtio spec v1.2 sec 4.2 (MMIO transport), 5.7 (GPU
 * device + the ctrl command structs); the virtio-mmio split-virtqueue plumbing
 * is this repo's own virtio_blk.c (R-P52/53), unchanged.  No BSD/Linux crib --
 * the virtio_gpu_ctrl structs are copied field-for-field from the public spec.
 *
 * KVTOP/KERNEL_DMAP_BASE: in the illumos kernel the rings/fb live in
 * direct-mapped DRAM so KVTOP(va) is their PA.  In the standalone R-P64 harness
 * (gpu_harness.c, -bios none, no MMU) the identity map makes KVTOP(va)==va.
 */

#include "virtio_gpu.h"

/* ---- virtio-mmio transport (identical to virtio_blk.c) ------------------ */
#define	VIRTIO_MMIO_BASE	0x10001000UL	/* qemu-virt slot 0 */
#define	VIRTIO_MMIO_STRIDE	0x1000UL
#define	VIRTIO_MMIO_NSLOT	8

#define	VMMIO_MAGIC		0x000
#define	VMMIO_VERSION		0x004
#define	VMMIO_DEVICE_ID		0x008
#define	VMMIO_DEVICE_FEATURES	0x010
#define	VMMIO_DEVICE_FEATURES_SEL 0x014
#define	VMMIO_DRIVER_FEATURES	0x020
#define	VMMIO_DRIVER_FEATURES_SEL 0x024
#define	VMMIO_QUEUE_SEL		0x030
#define	VMMIO_QUEUE_NUM_MAX	0x034
#define	VMMIO_QUEUE_NUM		0x038
#define	VMMIO_QUEUE_READY	0x044
#define	VMMIO_QUEUE_NOTIFY	0x050
#define	VMMIO_INTERRUPT_STATUS	0x060
#define	VMMIO_INTERRUPT_ACK	0x064
#define	VMMIO_STATUS		0x070
#define	VMMIO_QUEUE_DESC_LOW	0x080
#define	VMMIO_QUEUE_DESC_HIGH	0x084
#define	VMMIO_QUEUE_DRIVER_LOW	0x090
#define	VMMIO_QUEUE_DRIVER_HIGH	0x094
#define	VMMIO_QUEUE_DEVICE_LOW	0x0a0
#define	VMMIO_QUEUE_DEVICE_HIGH	0x0a4
#define	VMMIO_CONFIG		0x100

#define	VIRTIO_MAGIC_VALUE	0x74726976UL
#define	VIRTIO_DEV_GPU		16UL		/* virtio-gpu */

#define	VSTATUS_ACKNOWLEDGE	1
#define	VSTATUS_DRIVER		2
#define	VSTATUS_DRIVER_OK	4
#define	VSTATUS_FEATURES_OK	8
#define	VSTATUS_FAILED		128

/* ---- split virtqueue (controlq) ----------------------------------------- */
#define	VQ_N		8

#define	VRING_DESC_F_NEXT	1
#define	VRING_DESC_F_WRITE	2

struct virtq_desc {
	unsigned long	addr;
	unsigned int	len;
	unsigned short	flags;
	unsigned short	next;
};
struct virtq_avail {
	unsigned short	flags;
	unsigned short	idx;
	unsigned short	ring[VQ_N];
	unsigned short	used_event;
};
struct virtq_used_elem {
	unsigned int	id;
	unsigned int	len;
};
struct virtq_used {
	unsigned short	flags;
	unsigned short	idx;
	struct virtq_used_elem	ring[VQ_N];
	unsigned short	avail_event;
};

static struct virtq_desc  vq_desc[VQ_N]  __attribute__((aligned(16)));
static struct virtq_avail vq_avail       __attribute__((aligned(16)));
static struct virtq_used  vq_used        __attribute__((aligned(16)));

/* ---- virtio-gpu control commands (spec v1.2 sec 5.7.6) ------------------ */
#define	VIRTIO_GPU_CMD_GET_DISPLAY_INFO		0x0100
#define	VIRTIO_GPU_CMD_RESOURCE_CREATE_2D	0x0101
#define	VIRTIO_GPU_CMD_RESOURCE_UNREF		0x0102
#define	VIRTIO_GPU_CMD_SET_SCANOUT		0x0103
#define	VIRTIO_GPU_CMD_RESOURCE_FLUSH		0x0104
#define	VIRTIO_GPU_CMD_TRANSFER_TO_HOST_2D	0x0105
#define	VIRTIO_GPU_CMD_RESOURCE_ATTACH_BACKING	0x0106

#define	VIRTIO_GPU_RESP_OK_NODATA		0x1100
#define	VIRTIO_GPU_RESP_OK_DISPLAY_INFO		0x1101

#define	VIRTIO_GPU_FORMAT_B8G8R8X8_UNORM	2

struct virtio_gpu_ctrl_hdr {
	unsigned int	type;
	unsigned int	flags;
	unsigned long	fence_id;
	unsigned int	ctx_id;
	unsigned char	ring_idx;
	unsigned char	padding[3];
};

struct virtio_gpu_rect {
	unsigned int	x, y, width, height;
};

#define	VIRTIO_GPU_MAX_SCANOUTS	16
struct virtio_gpu_display_one {
	struct virtio_gpu_rect	r;
	unsigned int		enabled;
	unsigned int		flags;
};
struct virtio_gpu_resp_display_info {
	struct virtio_gpu_ctrl_hdr	hdr;
	struct virtio_gpu_display_one	pmodes[VIRTIO_GPU_MAX_SCANOUTS];
};

struct virtio_gpu_resource_create_2d {
	struct virtio_gpu_ctrl_hdr	hdr;
	unsigned int	resource_id;
	unsigned int	format;
	unsigned int	width;
	unsigned int	height;
};

struct virtio_gpu_mem_entry {
	unsigned long	addr;
	unsigned int	length;
	unsigned int	padding;
};
struct virtio_gpu_resource_attach_backing {
	struct virtio_gpu_ctrl_hdr	hdr;
	unsigned int	resource_id;
	unsigned int	nr_entries;
	/* followed by nr_entries * virtio_gpu_mem_entry -- we send exactly 1. */
	struct virtio_gpu_mem_entry	entry0;
};

struct virtio_gpu_set_scanout {
	struct virtio_gpu_ctrl_hdr	hdr;
	struct virtio_gpu_rect	r;
	unsigned int	scanout_id;
	unsigned int	resource_id;
};

struct virtio_gpu_transfer_to_host_2d {
	struct virtio_gpu_ctrl_hdr	hdr;
	struct virtio_gpu_rect	r;
	unsigned long	offset;
	unsigned int	resource_id;
	unsigned int	padding;
};

struct virtio_gpu_resource_flush {
	struct virtio_gpu_ctrl_hdr	hdr;
	struct virtio_gpu_rect	r;
	unsigned int	resource_id;
	unsigned int	padding;
};

/*
 * Command/response DMA scratch.  The request union covers the largest command;
 * the response union covers the largest reply (display_info).  Both are device
 * DMA targets so they carry KVTOP()'d addresses in the descriptors.
 */
union gpu_cmd {
	struct virtio_gpu_ctrl_hdr		hdr;
	struct virtio_gpu_resource_create_2d	create2d;
	struct virtio_gpu_resource_attach_backing attach;
	struct virtio_gpu_set_scanout		scanout;
	struct virtio_gpu_transfer_to_host_2d	xfer;
	struct virtio_gpu_resource_flush	flush;
};
static union gpu_cmd gpu_req  __attribute__((aligned(16)));
static struct virtio_gpu_resp_display_info gpu_resp __attribute__((aligned(16)));

/*
 * The guest framebuffer: 32bpp B8G8R8X8, linear, physically contiguous, page
 * aligned -- exactly what the /dev/fb seam (docs/riscv64-scanout-seam.md §2.1)
 * must hand a compositor.  Sized for a 1920x1080 desktop (8.3 MiB) so the mode
 * comes from GET_DISPLAY_INFO rather than a 1024x768 compile-time cap; the
 * driver still clamps to what fits.  This lives in .bss so it costs image size
 * nothing, only RAM.
 */
#define	FB_MAX_W	1920
#define	FB_MAX_H	1080
#define	FB_BPP		4
static unsigned int fb[FB_MAX_W * FB_MAX_H] __attribute__((aligned(4096)));

#define	GPU_RES_ID	1		/* our single 2D resource id */

static unsigned long virtio_base;	/* chosen slot base PA, 0 = none */
static int gpu_ready;
static unsigned int scan_w, scan_h;	/* the display we bound */
/*
 * scan_stride -- BYTES per row, a real field rather than an implied scan_w*4
 * (seam doc gap item 3), because the K1 DPU needs its plane pitch aligned and
 * the compositor must honor whatever we report instead of recomputing it.
 *
 * WHY it equals scan_w*FB_BPP on virtio-gpu: TRANSFER_TO_HOST_2D reads the
 * guest backing as packed rows at the RESOURCE_CREATE_2D width, so this backend
 * cannot pad.  A DPU backend behind the same /dev/fb node is free to report a
 * padded stride; that is precisely why the field exists.
 */
static unsigned int scan_stride;

static unsigned long virtio_probe_base = VIRTIO_MMIO_BASE;

void
virtio_gpu_set_mmio_base(unsigned long base)
{
	if (base != 0)
		virtio_probe_base = base;
}

static volatile unsigned int *
vreg(unsigned long off)
{
	return ((volatile unsigned int *)
	    (KERNEL_DMAP_BASE + virtio_base + off));
}

static void
fence(void)
{
	__asm__ __volatile__ ("fence" ::: "memory");
}

static void
zero(void *p, unsigned long n)
{
	unsigned char *b = (unsigned char *)p;
	while (n--)
		*b++ = 0;
}

/*
 * gpu_cmd -- push a 2-descriptor chain (request RO | response WR) on the
 * controlq, kick, and poll the used ring.  reqlen/resplen are the byte counts
 * the device reads / writes.  Returns the response hdr.type, 0 on transport
 * failure.
 */
static unsigned int
gpu_cmd(unsigned int reqlen, unsigned int resplen)
{
	unsigned short last_used = vq_used.idx;
	volatile unsigned short *used_idx = &vq_used.idx;
	unsigned long spins = 0;

	fence();

	vq_desc[0].addr = KVTOP(&gpu_req);
	vq_desc[0].len = reqlen;
	vq_desc[0].flags = VRING_DESC_F_NEXT;
	vq_desc[0].next = 1;

	vq_desc[1].addr = KVTOP(&gpu_resp);
	vq_desc[1].len = resplen;
	vq_desc[1].flags = VRING_DESC_F_WRITE;
	vq_desc[1].next = 0;

	vq_avail.ring[vq_avail.idx % VQ_N] = 0;
	fence();
	vq_avail.idx++;
	fence();

	*vreg(VMMIO_QUEUE_NOTIFY) = 0;		/* controlq is queue 0 */

	while (*used_idx == last_used) {
		fence();
		if (++spins > 100000000UL)
			return (0);		/* device wedged */
	}
	fence();
	{
		unsigned int is = *vreg(VMMIO_INTERRUPT_STATUS);
		if (is != 0)
			*vreg(VMMIO_INTERRUPT_ACK) = is;
	}
	return (gpu_resp.hdr.type);
}

/*
 * virtio_gpu_init -- probe the MMIO slots for a GPU device, negotiate, bring up
 * the controlq, then run the 6-step scanout bring-up against scanout 0.
 * Returns 1 if a display is live, 0 if no GPU / bring-up failed.
 */
int
virtio_gpu_init(void)
{
	int slot;
	unsigned int status, qmax, resp;
	unsigned long pa;

	gpu_ready = 0;
	virtio_base = 0;

	for (slot = 0; slot < VIRTIO_MMIO_NSLOT; slot++) {
		unsigned long base = virtio_probe_base +
		    (unsigned long)slot * VIRTIO_MMIO_STRIDE;
		volatile unsigned int *r =
		    (volatile unsigned int *)(KERNEL_DMAP_BASE + base);
		if (r[VMMIO_MAGIC / 4] != VIRTIO_MAGIC_VALUE)
			continue;
		if (r[VMMIO_VERSION / 4] != 2)
			continue;
		if (r[VMMIO_DEVICE_ID / 4] != VIRTIO_DEV_GPU)
			continue;
		virtio_base = base;
		break;
	}
	if (virtio_base == 0)
		return (0);		/* no virtio-gpu device present */

	/* reset -> ACKNOWLEDGE | DRIVER. */
	*vreg(VMMIO_STATUS) = 0;
	fence();
	status = VSTATUS_ACKNOWLEDGE;
	*vreg(VMMIO_STATUS) = status;
	status |= VSTATUS_DRIVER;
	*vreg(VMMIO_STATUS) = status;

	/* negotiate 0 features (both 32-bit windows). */
	*vreg(VMMIO_DEVICE_FEATURES_SEL) = 0;
	(void)*vreg(VMMIO_DEVICE_FEATURES);
	*vreg(VMMIO_DRIVER_FEATURES_SEL) = 0;
	*vreg(VMMIO_DRIVER_FEATURES) = 0;
	*vreg(VMMIO_DEVICE_FEATURES_SEL) = 1;
	(void)*vreg(VMMIO_DEVICE_FEATURES);
	*vreg(VMMIO_DRIVER_FEATURES_SEL) = 1;
	*vreg(VMMIO_DRIVER_FEATURES) = 0;

	status |= VSTATUS_FEATURES_OK;
	*vreg(VMMIO_STATUS) = status;
	fence();
	if ((*vreg(VMMIO_STATUS) & VSTATUS_FEATURES_OK) == 0) {
		*vreg(VMMIO_STATUS) = status | VSTATUS_FAILED;
		virtio_base = 0;
		return (0);
	}

	/* bring up controlq (queue 0). */
	*vreg(VMMIO_QUEUE_SEL) = 0;
	qmax = *vreg(VMMIO_QUEUE_NUM_MAX);
	if (qmax == 0 || qmax < VQ_N) {
		*vreg(VMMIO_STATUS) = status | VSTATUS_FAILED;
		virtio_base = 0;
		return (0);
	}
	*vreg(VMMIO_QUEUE_NUM) = VQ_N;

	zero(vq_desc, sizeof (vq_desc));
	zero(&vq_avail, sizeof (vq_avail));
	zero(&vq_used, sizeof (vq_used));

	pa = KVTOP(vq_desc);
	*vreg(VMMIO_QUEUE_DESC_LOW)  = (unsigned int)(pa & 0xffffffffUL);
	*vreg(VMMIO_QUEUE_DESC_HIGH) = (unsigned int)(pa >> 32);
	pa = KVTOP(&vq_avail);
	*vreg(VMMIO_QUEUE_DRIVER_LOW)  = (unsigned int)(pa & 0xffffffffUL);
	*vreg(VMMIO_QUEUE_DRIVER_HIGH) = (unsigned int)(pa >> 32);
	pa = KVTOP(&vq_used);
	*vreg(VMMIO_QUEUE_DEVICE_LOW)  = (unsigned int)(pa & 0xffffffffUL);
	*vreg(VMMIO_QUEUE_DEVICE_HIGH) = (unsigned int)(pa >> 32);
	fence();

	*vreg(VMMIO_QUEUE_READY) = 1;
	status |= VSTATUS_DRIVER_OK;
	*vreg(VMMIO_STATUS) = status;
	fence();

	/* ---- step 1: GET_DISPLAY_INFO -> scanout 0's preferred rect ---- */
	zero(&gpu_req, sizeof (gpu_req));
	zero(&gpu_resp, sizeof (gpu_resp));
	gpu_req.hdr.type = VIRTIO_GPU_CMD_GET_DISPLAY_INFO;
	resp = gpu_cmd(sizeof (struct virtio_gpu_ctrl_hdr), sizeof (gpu_resp));
	if (resp != VIRTIO_GPU_RESP_OK_DISPLAY_INFO)
		return (0);
	scan_w = gpu_resp.pmodes[0].r.width;
	scan_h = gpu_resp.pmodes[0].r.height;
	if (scan_w == 0 || scan_h == 0) {	/* headless default */
		scan_w = 1024;
		scan_h = 768;
	}
	if (scan_w > FB_MAX_W) scan_w = FB_MAX_W;
	if (scan_h > FB_MAX_H) scan_h = FB_MAX_H;
	scan_stride = scan_w * FB_BPP;		/* packed: see scan_stride comment */

	/* ---- step 2: RESOURCE_CREATE_2D (B8G8R8X8) ---- */
	zero(&gpu_req, sizeof (gpu_req));
	gpu_req.create2d.hdr.type = VIRTIO_GPU_CMD_RESOURCE_CREATE_2D;
	gpu_req.create2d.resource_id = GPU_RES_ID;
	gpu_req.create2d.format = VIRTIO_GPU_FORMAT_B8G8R8X8_UNORM;
	gpu_req.create2d.width = scan_w;
	gpu_req.create2d.height = scan_h;
	resp = gpu_cmd(sizeof (gpu_req.create2d), sizeof (gpu_resp));
	if (resp != VIRTIO_GPU_RESP_OK_NODATA)
		return (0);

	/* ---- step 3: RESOURCE_ATTACH_BACKING (our guest fb) ---- */
	zero(&gpu_req, sizeof (gpu_req));
	gpu_req.attach.hdr.type = VIRTIO_GPU_CMD_RESOURCE_ATTACH_BACKING;
	gpu_req.attach.resource_id = GPU_RES_ID;
	gpu_req.attach.nr_entries = 1;
	gpu_req.attach.entry0.addr = KVTOP(fb);
	gpu_req.attach.entry0.length = scan_stride * scan_h;
	resp = gpu_cmd(sizeof (gpu_req.attach), sizeof (gpu_resp));
	if (resp != VIRTIO_GPU_RESP_OK_NODATA)
		return (0);

	/* ---- step 4: SET_SCANOUT (bind resource -> display 0) ---- */
	zero(&gpu_req, sizeof (gpu_req));
	gpu_req.scanout.hdr.type = VIRTIO_GPU_CMD_SET_SCANOUT;
	gpu_req.scanout.r.width = scan_w;
	gpu_req.scanout.r.height = scan_h;
	gpu_req.scanout.scanout_id = 0;
	gpu_req.scanout.resource_id = GPU_RES_ID;
	resp = gpu_cmd(sizeof (gpu_req.scanout), sizeof (gpu_resp));
	if (resp != VIRTIO_GPU_RESP_OK_NODATA)
		return (0);

	gpu_ready = 1;
	return (1);
}

/*
 * virtio_gpu_flush_rect -- push the damage rect [x,y,w,h] of the guest fb to
 * the host resource and present it (TRANSFER_TO_HOST_2D + RESOURCE_FLUSH over
 * that rect only).  This is what FBIOFLUSH calls each frame.
 *
 * WHY a rect and not always the whole screen (seam doc gap item 4): a software
 * compositor's typical damage is a fraction of the screen, and the transfer is
 * O(w*h) memcpy work inside the device.  A blinking cursor should not cost a
 * 1080p copy.  A zero-sized rect means "whole screen".
 *
 * The rect is clamped to the scanout; the guest-memory `offset` is the byte
 * offset of pixel (x,y) in the backing, i.e. y*stride + x*bpp.
 *
 * Returns 0 on OK, -1 otherwise.
 */
int
virtio_gpu_flush_rect(unsigned int x, unsigned int y, unsigned int w,
    unsigned int h)
{
	unsigned int resp;

	if (!gpu_ready)
		return (-1);

	if (w == 0 || h == 0) {			/* whole screen */
		x = 0; y = 0; w = scan_w; h = scan_h;
	}
	if (x >= scan_w || y >= scan_h)
		return (-1);
	if (x + w > scan_w)
		w = scan_w - x;
	if (y + h > scan_h)
		h = scan_h - y;

	zero(&gpu_req, sizeof (gpu_req));
	gpu_req.xfer.hdr.type = VIRTIO_GPU_CMD_TRANSFER_TO_HOST_2D;
	gpu_req.xfer.r.x = x;
	gpu_req.xfer.r.y = y;
	gpu_req.xfer.r.width = w;
	gpu_req.xfer.r.height = h;
	gpu_req.xfer.offset = (unsigned long)y * scan_stride +
	    (unsigned long)x * FB_BPP;
	gpu_req.xfer.resource_id = GPU_RES_ID;
	resp = gpu_cmd(sizeof (gpu_req.xfer), sizeof (gpu_resp));
	if (resp != VIRTIO_GPU_RESP_OK_NODATA)
		return (-1);

	zero(&gpu_req, sizeof (gpu_req));
	gpu_req.flush.hdr.type = VIRTIO_GPU_CMD_RESOURCE_FLUSH;
	gpu_req.flush.r.x = x;
	gpu_req.flush.r.y = y;
	gpu_req.flush.r.width = w;
	gpu_req.flush.r.height = h;
	gpu_req.flush.resource_id = GPU_RES_ID;
	resp = gpu_cmd(sizeof (gpu_req.flush), sizeof (gpu_resp));
	if (resp != VIRTIO_GPU_RESP_OK_NODATA)
		return (-1);

	return (0);
}

/*
 * virtio_gpu_flush -- whole-screen present.  Retained as the simple form the
 * R-P64 harness and the kernel console path call.
 */
int
virtio_gpu_flush(void)
{
	return (virtio_gpu_flush_rect(0, 0, 0, 0));
}

/* framebuffer accessors -- the "DRM node" a compositor/console draws into. */
unsigned int *virtio_gpu_fb(void)      { return (fb); }
unsigned long virtio_gpu_fb_pa(void)   { return (KVTOP(fb)); }
unsigned int  virtio_gpu_width(void)   { return (scan_w); }
unsigned int  virtio_gpu_height(void)  { return (scan_h); }
unsigned int  virtio_gpu_stride(void)  { return (scan_stride); }
unsigned long virtio_gpu_fb_size(void) { return ((unsigned long)scan_stride *
					   scan_h); }
int           virtio_gpu_present(void) { return (gpu_ready); }
