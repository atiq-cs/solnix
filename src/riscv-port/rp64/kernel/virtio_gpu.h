/*
 * virtio_gpu.h -- R-P64 virtio-gpu driver interface + the address-map shims.
 *
 * The driver hands the device PHYSICAL addresses for the rings and the
 * framebuffer, so it needs to convert a kernel pointer to a PA.  Two maps exist
 * in this tree and both are selected at build time:
 *
 *   -DGPU_IDENTITY_MAP  (or -DGPU_HARNESS): PA == VA.  This covers BOTH the
 *       standalone R-P64 harness (no MMU at all under -bios none) AND the
 *       solnix riscv64 uts kernel, whose boot HAT identity-maps the whole
 *       0x80000000 RAM gigabyte -- the same assumption virtio.c/vioblk.c
 *       already rely on for their DMA rings.
 *   default: the high-VA direct map from mmu_riscv.h (KERNEL_DMAP_BASE), for a
 *       kernel that has moved its text/data above KERNELBASE.
 *
 * GPU_HARNESS is kept as an alias so the existing harness build script does not
 * change; GPU_IDENTITY_MAP is the name that says what it actually means.
 */
#ifndef	_VIRTIO_GPU_H
#define	_VIRTIO_GPU_H

#if defined(GPU_HARNESS) || defined(GPU_IDENTITY_MAP)
/* identity map: PA == VA (no paging, or an identity-mapped RAM gigapage). */
#define	KERNEL_DMAP_BASE	0UL
#define	KVTOP(va)		((unsigned long)(va))
#else
#include "mmu_riscv.h"
#endif

#ifdef __cplusplus
extern "C" {
#endif

int  virtio_gpu_init(void);		/* probe + 6-step scanout bring-up */
int  virtio_gpu_flush(void);		/* present the whole fb */
/*
 * present just the damage rect (w==0 || h==0 means whole screen).  This is the
 * backend of the /dev/fb FBIOFLUSH ioctl; a SW compositor's damage is usually a
 * fraction of the screen, so the rect keeps the per-frame transfer honest.
 */
int  virtio_gpu_flush_rect(unsigned int x, unsigned int y, unsigned int w,
    unsigned int h);
void virtio_gpu_set_mmio_base(unsigned long base);	/* DTB-discovered base */
unsigned int *virtio_gpu_fb(void);	/* the framebuffer (B8G8R8X8) */
unsigned long virtio_gpu_fb_pa(void);	/* its PA, for the devmap/mmap path */
unsigned long virtio_gpu_fb_size(void);	/* stride * height, bytes to mmap */
unsigned int  virtio_gpu_width(void);
unsigned int  virtio_gpu_height(void);
unsigned int  virtio_gpu_stride(void);	/* BYTES per row (>= width * 4) */
int           virtio_gpu_present(void);

#ifdef __cplusplus
}
#endif

#endif	/* _VIRTIO_GPU_H */
