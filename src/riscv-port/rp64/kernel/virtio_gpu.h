/*
 * virtio_gpu.h -- R-P64 virtio-gpu driver interface + the address-map shims.
 *
 * When compiled into the illumos riscv64 kernel, KERNEL_DMAP_BASE / KVTOP come
 * from mmu_riscv.h (the direct map).  The standalone R-P64 harness compiles
 * with -DGPU_HARNESS so the map is the identity (no MMU, PA == VA under
 * -bios none), which is exactly how the kernel's early virtio_blk probe runs
 * too (both use the direct map / identity map for ring PAs).
 */
#ifndef	_VIRTIO_GPU_H
#define	_VIRTIO_GPU_H

#ifdef	GPU_HARNESS
/* standalone harness: identity map, PA == VA (no paging). */
#define	KERNEL_DMAP_BASE	0UL
#define	KVTOP(va)		((unsigned long)(va))
#else
#include "mmu_riscv.h"
#endif

#ifdef __cplusplus
extern "C" {
#endif

int  virtio_gpu_init(void);		/* probe + 6-step scanout bring-up */
int  virtio_gpu_flush(void);		/* present the current fb */
void virtio_gpu_set_mmio_base(unsigned long base);	/* DTB-discovered base */
unsigned int *virtio_gpu_fb(void);	/* the framebuffer (B8G8R8X8) */
unsigned int  virtio_gpu_width(void);
unsigned int  virtio_gpu_height(void);
int           virtio_gpu_present(void);

#ifdef __cplusplus
}
#endif

#endif	/* _VIRTIO_GPU_H */
