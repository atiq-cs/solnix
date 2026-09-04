/*
 * fbio.h -- the riscv64 scanout seam ABI: the /dev/fb contract between the
 * solnix kernel's scanout driver and a userland software compositor.
 *
 * This is the header BOTH sides include, so the kernel driver (fb.c) and the
 * compositor/test program cannot disagree about struct layout or ioctl numbers.
 * It is the literal encoding of docs/riscv64-scanout-seam.md section 2.
 *
 * WHAT the compositor gets, and deliberately nothing more (seam doc section 1):
 *   1. a mmap-able linear framebuffer to blit into,
 *   2. mode info: width, height, stride-in-BYTES, pixel format,
 *   3. a present/flush call meaning "the bytes I wrote are complete, show them".
 *
 * WHY no DRM/KMS/GBM/dmabuf: smallvil composites in software (see
 * docs/cosmic-comp-illumos-finding.md) and needs only a destination surface.
 * A DRM stack would be strictly more code for strictly zero benefit on a part
 * whose GPU (PowerVR BXE-2-32) has no open driver.
 *
 * ioctl NUMBERING: the illumos framebuffer family is FIOC = ('F' << 8), used by
 * sys/fbio.h for FBIOGTYPE (FIOC|0) .. FBIOGXINFO (FIOC|39) and by
 * sys/visual_io.h for the VIS_* console ops.  These three are solnix-private
 * additions, so they sit at FIOC|100.. -- far above the highest allocated
 * upstream code, which keeps the node idiomatic (a future illumos-native
 * console can share it) without risking a collision if more FBIO* codes are
 * imported later.
 */
#ifndef	_SOLNIX_FBIO_H
#define	_SOLNIX_FBIO_H

#ifdef __cplusplus
extern "C" {
#endif

#define	SOLNIX_FIOC	('F' << 8)		/* == 0x4600, sys/fbio.h FIOC */

/*
 * fb_mode -- what the compositor must know to blit a frame correctly.
 *
 * `stride` is a REAL field, separate from width * 4, on purpose: real display
 * controllers require row alignment (the K1 DPU wants its plane pitch aligned;
 * QEMU's virtio-gpu does not).  The compositor MUST honor stride and never
 * recompute it from width -- recomputing is the single most common cause of a
 * diagonally-sheared desktop.
 *
 * Fixed-width types only, and no pointers, so the struct is identical whether
 * the caller is the freestanding solnix libc slice or a Rust FFI binding.
 */
struct fb_mode {
	unsigned int	width;		/* visible pixels per row */
	unsigned int	height;		/* visible rows */
	unsigned int	stride;		/* BYTES per row (>= width * 4) */
	unsigned int	format;		/* FB_FMT_* below */
	unsigned int	size;		/* bytes to mmap (== stride * height) */
	unsigned int	pad;		/* keep the struct 8-byte aligned */
};

/*
 * Pixel formats.  The whole chain already agrees on 32-bit BGRX little-endian
 * (virtio-gpu B8G8R8X8_UNORM == WL_SHM_FORMAT_XRGB8888 == smithay pixman XRGB
 * == a K1 DPU XRGB8888 plane), so FB_FMT_XRGB8888 is the required format and
 * there is deliberately NO conversion path in the driver: a per-frame CPU
 * format conversion would cost more than the compositing does.
 */
#define	FB_FMT_XRGB8888	1	/* 32bpp; byte order B,G,R,X in memory (LE) */
#define	FB_FMT_XBGR8888	2	/* 32bpp; byte order R,G,B,X in memory (LE) */

/*
 * fb_damage -- the rect that changed, in pixels.  A NULL argument, or w == 0
 * or h == 0, means "the whole screen".
 */
struct fb_damage {
	unsigned int	x, y, w, h;
};

/*
 * FBIOGMODE -- get the current mode.  MUST succeed on an open /dev/fb.
 *   ioctl(fd, FBIOGMODE, &mode)      arg: struct fb_mode * (written)
 *
 * FBIOFLUSH -- present.  Synchronous: on return the bytes are committed to the
 * scanout engine.  That is the semantics a compositor frame loop wants (submit
 * a frame, then send frame callbacks to clients).  The kernel does all the work
 * the hardware needs and the compositor must not know about: the RISC-V cache
 * maintenance (fence + CMO clean of the dirty range) so the scanout engine sees
 * the written bytes, then the device present (on virtio-gpu:
 * TRANSFER_TO_HOST_2D + RESOURCE_FLUSH over the damage rect).
 *   ioctl(fd, FBIOFLUSH, &damage)    arg: struct fb_damage * (read), or NULL
 *
 * FBIOSMODE -- set the mode.  DELIBERATELY OPTIONAL; returning ENOTSUP is a
 * correct implementation, and the desktop must not be gated on mode setting.
 * For first light on the Jupiter, whatever mode U-Boot left is fine.
 *   ioctl(fd, FBIOSMODE, &mode)      arg: struct fb_mode * (read)
 */
#define	FBIOGMODE	(SOLNIX_FIOC | 100)
#define	FBIOFLUSH	(SOLNIX_FIOC | 101)
#define	FBIOSMODE	(SOLNIX_FIOC | 102)

/*
 * The mmap contract (seam doc section 2.1):
 *
 *   fd = open("/dev/fb", O_RDWR);
 *   ioctl(fd, FBIOGMODE, &mode);
 *   fb = mmap(NULL, mode.size, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0);
 *
 * - The mapping is LINEAR and CONTIGUOUS in userland VA: row y starts at byte
 *   offset y * stride.  No tiling, no swizzle, no per-row padding beyond stride.
 * - Offset 0 maps the byte the scanout engine treats as pixel (0,0).
 * - The kernel keeps the framebuffer physically contiguous, because the scanout
 *   engine takes a single base PA.
 * - Plain cacheable is fine: FBIOFLUSH performs the cache maintenance.
 */
#define	FB_DEV_PATH	"/dev/fb"

#ifdef __cplusplus
}
#endif

#endif	/* _SOLNIX_FBIO_H */
