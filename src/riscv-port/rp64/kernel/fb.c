/*
 * fb.c -- the /dev/fb scanout node: the OS half of the riscv64 scanout seam.
 *
 * This is what docs/riscv64-scanout-seam.md section 2 specifies and gap items
 * 5, 6 and 7 of its section 5 list as MISSING.  It promotes the virtio_gpu.c
 * triple (buffer / mode / present) into a device node a userland software
 * compositor can open, mmap and flush:
 *
 *   fd = open("/dev/fb", O_RDWR);
 *   ioctl(fd, FBIOGMODE, &mode);          -- width/height/stride/format/size
 *   fb = mmap(NULL, mode.size, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0);
 *   ... blit a finished frame into fb, honoring mode.stride ...
 *   ioctl(fd, FBIOFLUSH, &damage);        -- CMO + TRANSFER_TO_HOST_2D + FLUSH
 *
 * BACKEND INDIRECTION (why this file is separate from virtio_gpu.c): the node
 * is generic, not virtio-specific.  Everything K1-specific about a real Jupiter
 * lives behind fb_backend: the DPU variant supplies a different present()
 * (nothing per-frame if the plane already points at the framebuffer and the
 * panel self-refreshes from RAM) and a different base PA (U-Boot's inherited
 * plane), and reuses this file unchanged.  That is the whole point of finishing
 * items 5-7 against QEMU virtio-gpu first.
 *
 * ILLUMOS IDIOM, AND THE HONEST DEVIATION: upstream illumos would express this
 * as a cb_ops with d_open/d_close/d_ioctl/d_devmap and let devmap_devmem_setup
 * build the user mapping.  The solnix riscv64 kernel has no DDI, no devfs and no
 * seg_dev yet (its fd layer is uproc.c's 8-slot per-process table), so the SAME
 * SHAPE is implemented as direct entry points that uproc.c's open/ioctl/mmap
 * paths route to: fb_open/fb_ioctl/fb_mmap/fb_close below correspond 1:1 to the
 * cb_ops slots.  The USERLAND-VISIBLE contract -- the ioctl numbers, the struct
 * layouts, the mmap semantics in fbio.h -- is exactly the specified one, so the
 * compositor side does not change when a real DDI arrives underneath.
 */

#include "sbi.h"
#include "riscv_regs.h"
#include "cmo.h"
#include "fbio.h"

/* virtio_gpu.c: the device half (QEMU-scanout-proven). */
extern int virtio_gpu_present(void);
extern unsigned int *virtio_gpu_fb(void);
extern unsigned long virtio_gpu_fb_pa(void);
extern unsigned long virtio_gpu_fb_size(void);
extern unsigned int virtio_gpu_width(void);
extern unsigned int virtio_gpu_height(void);
extern unsigned int virtio_gpu_stride(void);
extern int virtio_gpu_flush_rect(unsigned int x, unsigned int y,
    unsigned int w, unsigned int h);

/* copy.S: fault-safe user-memory access.  0 = ok, -1 = fault. */
extern long copyin(const void *uaddr, void *kaddr, unsigned long n);
extern long copyout(const void *kaddr, void *uaddr, unsigned long n);

/* hat_riscv.c: install a user leaf VA->PA (adds PTE_U). */
extern void hat_as_map(unsigned long root, unsigned long va, unsigned long pa,
    unsigned long perm);

/* console helpers (startup.c). */
extern void kputdec(unsigned long v);
extern void kputhex(unsigned long v);

#define	EFAULT		14
#define	EINVAL		22
#define	ENOTSUP		48
#define	ENXIO		6

/*
 * FB_MMAP_BASE -- the fixed user VA the framebuffer mapping lands at.
 *
 * WHY fixed rather than a real mmap arena: the solnix riscv64 kernel has no
 * segment list (as.c is explicit about this: no seg_vn, no demand paging, no
 * mmap), so there is nothing to allocate a VA range FROM yet.  One process maps
 * one framebuffer, which is exactly what a single compositor needs.
 *
 * Placement: userland text is linked at 0xC0010000 and the stack sits at
 * 0xfffff000, both inside Sv39 level-2 slot 3 (0xC0000000..0xFFFFFFFF), a slot
 * with no kernel entry.  0xC4000000 is 64 MiB clear of the image+heap and
 * ~960 MiB below the stack, so a 1920x1080 (8.3 MiB) mapping cannot collide
 * with either.
 *
 * NOTE: fixed single-mapping VA, one mapper at a time; a real seg_dev/mmap
 * arena is the upgrade if more than one process ever needs the framebuffer.
 */
#define	FB_MMAP_BASE	0xC4000000UL

/*
 * fb_backend -- which scanout engine is behind the node.  Only the virtio-gpu
 * backend exists today; the K1 DPU is the second one and slots in here.
 */
typedef enum fb_backend {
	FB_BACKEND_NONE = 0,
	FB_BACKEND_VIRTIO_GPU = 1
} fb_backend_t;

static fb_backend_t fb_backend;
static int fb_opens;			/* open reference count */
static unsigned long fb_user_va;	/* current user mapping VA, 0 = none */

/* Per-frame accounting, so the boot log can show the seam actually carried
 * frames rather than merely initializing. */
static unsigned long fb_flush_count;
static unsigned long fb_flush_pixels;

/*
 * fb_init -- bind the node to whatever scanout engine came up.  Called from
 * startup_root() after virtio_discover()/the GPU bring-up.  Returns 1 if
 * /dev/fb is live, 0 if there is no scanout engine (the node then returns ENXIO
 * on open, which is the correct answer on a serial-only boot).
 */
int
fb_init(void)
{
	fb_backend = FB_BACKEND_NONE;
	fb_opens = 0;
	fb_user_va = 0;
	fb_flush_count = 0;
	fb_flush_pixels = 0;

	if (virtio_gpu_present()) {
		fb_backend = FB_BACKEND_VIRTIO_GPU;
		sbi_console_puts("[fb] /dev/fb online: virtio-gpu scanout ");
		kputdec(virtio_gpu_width());
		sbi_console_puts("x");
		kputdec(virtio_gpu_height());
		sbi_console_puts(", stride ");
		kputdec(virtio_gpu_stride());
		sbi_console_puts(" bytes, XRGB8888, fb PA ");
		kputhex(virtio_gpu_fb_pa());
		sbi_console_puts(" (");
		kputdec(virtio_gpu_fb_size() >> 10);
		sbi_console_puts(" KiB mmap-able)\n");
		return (1);
	}

	sbi_console_puts("[fb] /dev/fb NOT created: no scanout engine "
	    "(no virtio-gpu device, no DPU)\n");
	return (0);
}

/* fb_live -- is there a scanout engine behind the node? */
int
fb_live(void)
{
	return (fb_backend != FB_BACKEND_NONE);
}

/*
 * fb_open -- the d_open slot.  Succeeds only if a scanout engine is bound.
 * Returns 0 on success, negative errno otherwise.  Multiple opens are allowed
 * (they share the one framebuffer); the mapping is per-process.
 */
long
fb_open(void)
{
	if (fb_backend == FB_BACKEND_NONE)
		return (-ENXIO);
	fb_opens++;
	return (0);
}

/* fb_close -- the d_close slot.  The mapping outlives close (as.c reclaims it
 * at process exit), matching what a compositor expects. */
long
fb_close(void)
{
	if (fb_opens > 0)
		fb_opens--;
	return (0);
}

/*
 * fb_getmode -- fill a kernel-side struct fb_mode from the live backend.
 * Split out from fb_ioctl so the in-kernel selftest can use it without a user
 * pointer.
 */
static void
fb_getmode(struct fb_mode *m)
{
	m->width = virtio_gpu_width();
	m->height = virtio_gpu_height();
	m->stride = virtio_gpu_stride();
	m->format = FB_FMT_XRGB8888;	/* B,G,R,X in memory; no conversion */
	m->size = (unsigned int)virtio_gpu_fb_size();
	m->pad = 0;
}

/*
 * fb_flush -- the present path, and the only place the hardware's requirements
 * live.  Two steps, in this order:
 *
 *   1. CACHE MAINTENANCE.  The compositor wrote the framebuffer through a
 *      plain cacheable mapping, so on a non-coherent part (the K1's X60 is
 *      T-Head-derived and its DMA is non-coherent) those stores may still be
 *      sitting in the D-cache when the scanout engine reads DRAM.  cmo_dma_wb
 *      cleans the damage range and ends in a `fence rw, rw`.  Under QEMU DMA is
 *      coherent and the CMO ops are harmless no-ops, which is exactly why this
 *      must be written now rather than discovered on silicon.
 *
 *   2. DEVICE PRESENT.  virtio-gpu: TRANSFER_TO_HOST_2D + RESOURCE_FLUSH over
 *      the rect.  A DPU backend does nothing here beyond an optional vsync
 *      wait, since its plane already points at this memory.
 *
 * Clean only the damage rows, not the whole framebuffer: cleaning 8.3 MiB to
 * present a blinking cursor is precisely the waste the damage rect exists to
 * avoid.
 *
 * Returns 0 on success, negative errno otherwise.
 */
static long
fb_flush(unsigned int x, unsigned int y, unsigned int w, unsigned int h)
{
	unsigned long base = (unsigned long)virtio_gpu_fb();
	unsigned int stride = virtio_gpu_stride();
	unsigned int sw = virtio_gpu_width();
	unsigned int sh = virtio_gpu_height();
	unsigned long row_off, len;

	if (fb_backend == FB_BACKEND_NONE)
		return (-ENXIO);

	if (w == 0 || h == 0) {			/* whole screen */
		x = 0; y = 0; w = sw; h = sh;
	}
	if (x >= sw || y >= sh)
		return (-EINVAL);
	if (x + w > sw)
		w = sw - x;
	if (y + h > sh)
		h = sh - y;

	/*
	 * Clean [row y .. row y+h) in full rows.  Partial-row precision would
	 * mean h separate cache-op loops for no gain: the lines are 64 bytes and
	 * a row is stride bytes, so full rows cost at most stride/64 extra ops
	 * per row versus a byte-exact range.
	 */
	row_off = (unsigned long)y * stride;
	len = (unsigned long)h * stride;
	cmo_dma_wb(base + row_off, len);

	if (virtio_gpu_flush_rect(x, y, w, h) != 0)
		return (-ENXIO);

	fb_flush_count++;
	fb_flush_pixels += (unsigned long)w * h;
	return (0);
}

/*
 * fb_ioctl -- the d_ioctl slot.  `arg` is a USER pointer, so every access goes
 * through copyin/copyout: a bad pointer must return EFAULT, never panic the
 * kernel.  Returns 0 on success, negative errno otherwise.
 */
long
fb_ioctl(int cmd, unsigned long arg)
{
	if (fb_backend == FB_BACKEND_NONE)
		return (-ENXIO);

	switch (cmd) {
	case FBIOGMODE: {
		struct fb_mode m;

		if (arg == 0)
			return (-EFAULT);
		fb_getmode(&m);
		if (copyout(&m, (void *)arg, sizeof (m)) != 0)
			return (-EFAULT);
		return (0);
	}

	case FBIOFLUSH: {
		struct fb_damage d;

		/* A NULL argument means "the whole screen" (fbio.h). */
		if (arg == 0)
			return (fb_flush(0, 0, 0, 0));
		if (copyin((const void *)arg, &d, sizeof (d)) != 0)
			return (-EFAULT);
		return (fb_flush(d.x, d.y, d.w, d.h));
	}

	case FBIOSMODE:
		/*
		 * Deliberately unimplemented, and fbio.h says so: for first
		 * light the mode the firmware/device left is correct, and
		 * ENOTSUP is a conforming answer.  The desktop must not be
		 * gated on mode setting.
		 */
		return (-ENOTSUP);

	default:
		return (-EINVAL);
	}
}

/*
 * fb_mmap -- the d_devmap slot: map the framebuffer's physical pages into the
 * calling process's address space and return the user VA.
 *
 * The framebuffer is one physically contiguous, page-aligned region (virtio_gpu
 * attaches it to the resource with a single RESOURCE_ATTACH_BACKING entry, and
 * a scanout engine takes a single base PA), so this is a straight per-page
 * hat_as_map loop -- no scatter list, no bounce buffer, and the mapping is
 * linear in user VA exactly as the seam contract requires: row y is at
 * offset y * stride, and offset 0 is pixel (0,0).
 *
 * `root` is the caller's AS root PA (uproc.c passes as_root(p->p_as)); `len` is
 * the requested length, which must not exceed the framebuffer.
 *
 * Returns the user VA on success, or a negative errno.  Re-mapping in the same
 * process returns the existing VA rather than building a second mapping.
 */
long
fb_mmap(unsigned long root, unsigned long len)
{
	unsigned long fbsize, pa, va, off;

	if (fb_backend == FB_BACKEND_NONE)
		return (-ENXIO);
	if (root == 0)
		return (-EINVAL);

	fbsize = virtio_gpu_fb_size();
	if (len == 0)
		len = fbsize;
	if (len > fbsize)
		return (-EINVAL);		/* would run off the buffer */

	if (fb_user_va != 0)
		return ((long)fb_user_va);	/* already mapped */

	pa = virtio_gpu_fb_pa();
	if ((pa & (PAGESIZE - 1)) != 0)
		return (-EINVAL);		/* backing must be page aligned */

	va = FB_MMAP_BASE;
	for (off = 0; off < len; off += PAGESIZE)
		hat_as_map(root, va + off, pa + off, PTE_R | PTE_W);

	/*
	 * The mapping is installed in a live satp (we are on the caller's AS,
	 * having trapped from U-mode), so its TLB must be told.  sfence.vma with
	 * no operands flushes the whole local TLB, which is correct and happens
	 * once per process rather than once per frame.
	 */
	__asm__ __volatile__("sfence.vma" ::: "memory");

	fb_user_va = va;

	sbi_console_puts("[fb] mmap: ");
	kputdec(len >> 10);
	sbi_console_puts(" KiB of scanout PA ");
	kputhex(pa);
	sbi_console_puts(" mapped at user VA ");
	kputhex(va);
	sbi_console_puts(" (linear, stride ");
	kputdec(virtio_gpu_stride());
	sbi_console_puts(")\n");

	return ((long)va);
}

/*
 * fb_report -- print the per-frame tally.  The boot gate wants evidence the
 * seam CARRIED frames, not merely that it initialized.
 */
void
fb_report(void)
{
	sbi_console_puts("[fb] seam carried ");
	kputdec(fb_flush_count);
	sbi_console_puts(" flush(es), ");
	kputdec(fb_flush_pixels);
	sbi_console_puts(" pixels presented (CMO clean + TRANSFER_TO_HOST_2D + "
	    "RESOURCE_FLUSH per flush)\n");
}

/*
 * fb_selftest -- prove the node in-kernel, before any userland exists.
 *
 * WHY this is worth having on top of the userland test: it isolates a failure.
 * If this passes and the userland test does not, the bug is in the syscall /
 * mmap plumbing, not in the mode/flush/CMO path.  It writes through the KERNEL
 * mapping (no mmap involved) and calls the same fb_flush the ioctl calls.
 *
 * Paints four quadrant colors plus a white diagonal, addressed via `stride`
 * rather than width so a stride != width * 4 backend would visibly shear here
 * first.  Returns 1 on success.
 */
int
fb_selftest(void)
{
	struct fb_mode m;
	unsigned char *base;
	unsigned int x, y;

	if (fb_backend == FB_BACKEND_NONE) {
		sbi_console_puts("[fb] selftest skipped: no scanout engine\n");
		return (0);
	}

	fb_getmode(&m);
	if (m.width == 0 || m.height == 0 || m.stride < m.width * 4 ||
	    m.size != m.stride * m.height) {
		sbi_console_puts("[fb] SELFTEST FAIL: incoherent mode "
		    "(stride/size do not agree with width/height)\n");
		return (0);
	}

	base = (unsigned char *)virtio_gpu_fb();
	for (y = 0; y < m.height; y++) {
		unsigned int *row = (unsigned int *)(base + y * m.stride);

		for (x = 0; x < m.width; x++) {
			unsigned int px;

			/* B8G8R8X8 in memory: 0x00RRGGBB as a LE u32. */
			if (y < m.height / 2)
				px = (x < m.width / 2) ? 0x00ff0000 :
				    0x0000ff00;
			else
				px = (x < m.width / 2) ? 0x000000ff :
				    0x00ffffff;
			/* White diagonal: proves stride addressing, since a
			 * wrong stride turns a diagonal into a shear. */
			if (x * m.height == y * m.width)
				px = 0x00ffffff;
			row[x] = px;
		}
	}

	if (fb_flush(0, 0, 0, 0) != 0) {
		sbi_console_puts("[fb] SELFTEST FAIL: flush returned error\n");
		return (0);
	}

	/* Damage-rect path: a small rect must also present cleanly. */
	if (fb_flush(0, 0, 64, 64) != 0) {
		sbi_console_puts("[fb] SELFTEST FAIL: damage-rect flush "
		    "returned error\n");
		return (0);
	}

	sbi_console_puts("[fb] selftest OK: mode ");
	kputdec(m.width);
	sbi_console_puts("x");
	kputdec(m.height);
	sbi_console_puts(" stride ");
	kputdec(m.stride);
	sbi_console_puts(" size ");
	kputdec(m.size);
	sbi_console_puts(", painted + full flush + 64x64 damage flush\n");
	return (1);
}
