/*
 * ttm_priv.h - the smallest useful TTM (Translation Table Manager) for the
 * illumos amdgpu port (C3-amdgpu-b). The KEY new kernel subsystem C1 deferred:
 * virtio-gpu had no VRAM, so C1's DESIGN.md left TTM as "for when a real VRAM
 * GPU is targeted (C3)". amdgpu on the g4ad V520 (Navi 12) is that GPU.
 *
 * TTM manages *where* a buffer object lives:
 *   VRAM  = the AMD GPU's onboard memory, reached through the BAR0 aperture
 *           (mapped in C3-amdgpu-a as sc->vram_hdl/vram_base/vram_size). A
 *           range allocator carves this aperture into buffer offsets.
 *   GTT   = system RAM the GPU accesses through its page tables / an IOMMU
 *           aperture, allocated DMA-able + bound to GPU-visible DMA addresses.
 *   SYSTEM= plain pageable kernel memory (the C1 GEM ddi_umem backing) -- the
 *           un-accelerated fallback; TTM tracks it but amdgpu_bo_create here
 *           only places into VRAM or GTT.
 *
 * The illumos-TTM design (the load-bearing insight of this phase):
 *
 *   TTM concept        Linux/NetBSD ttm            illumos primitive
 *   ----------------   -------------------------   ---------------------------
 *   VRAM manager       ttm_range_manager /         vmem_create over the BAR0
 *   (device memory)    drm_mm range allocator      aperture; vmem_xalloc /
 *                                                  vmem_free carve byte ranges.
 *                                                  vmem IS the kernel's general
 *                                                  resource allocator -- a
 *                                                  perfect fit for a VRAM range.
 *   GTT manager        ttm_tt + the GART table     ddi_dma_alloc_handle +
 *   (system RAM the    (page table over sysram)    ddi_dma_mem_alloc +
 *    GPU sees)                                     ddi_dma_addr_bind_handle ->
 *                                                  the DMA cookies are the
 *                                                  GPU-visible scatter-gather
 *                                                  addresses (what the GART
 *                                                  table would be programmed
 *                                                  with; the same cookie
 *                                                  pattern C1b's virtio backing
 *                                                  used).
 *   ttm_resource       ttm_mem_reg / ttm_resource  struct ttm_resource below
 *   ttm_buffer_object  ttm_buffer_object           struct ttm_buffer_object
 *                      (huge in Linux)             below (reduced HARD)
 *   placement/migrate  ttm_bo_validate + SDMA      DEFERRED (design doc): a BO
 *                      copy engine                 is placed once, at create.
 *   eviction / LRU     ttm LRU + ww_mutex resv     DEFERRED (design doc): no
 *                                                  eviction, no swap.
 *
 * Reduced HARD per the design + STATUS.md C3-amdgpu-b plan: "smallest TTM =
 * vmem range allocator over BAR0 + GTT via ddi_dma_*, no migration/eviction".
 * The full ttm_buffer_object (crib: netbsd-ref .../ttm/ttm_bo_api.h;
 * ../amdgpu-ref/src/amdgpu_object.h's struct amdgpu_bo) carries LRU list heads,
 * a ttm_tt, swap storage, mmu notifiers, shadow BOs, sub-allocation -- none of
 * which this bring-up needs. What is kept is the load-bearing core: a
 * refcounted object, its size, its placement (mem_type), and its backing
 * (a VRAM range OR a GTT dma allocation).
 *
 * Crib provenance (struct shapes; NO Linux/NetBSD .c lifted):
 *   - TTM_PL_* / ttm_place / ttm_placement: netbsd-ref .../ttm/ttm_placement.h
 *   - ttm_mem_reg (-> ttm_resource here): .../ttm/ttm_bo_api.h
 *   - ttm_buffer_object core fields: .../ttm/ttm_bo_api.h
 *   - amdgpu_bo (VRAM/GTT domain wrapper): ../amdgpu-ref/src/amdgpu_object.h
 *   - the ttm_range_manager (vmem here) shape: Linux drm/ttm/ttm_range_manager.c
 *   - AMDGPU_GEM_DOMAIN_*: the Linux DRM uapi amdgpu_drm.h (stable ABI values)
 */

#ifndef _TTM_PRIV_H_
#define _TTM_PRIV_H_

#include <sys/types.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/vmem.h>
#include <sys/kmem.h>
#include <sys/ksynch.h>

#include "linux-compat/linux_compat.h"	/* struct kref, kref_* */

struct amdgpu_softc;

/*
 * TTM memory-type ids, cribbed VERBATIM from netbsd-ref .../ttm/ttm_placement.h
 * (the stable ttm ABI). amdgpu maps its GEM domains onto these:
 *   TTM_PL_SYSTEM -> AMDGPU_GEM_DOMAIN_CPU  (plain pages, un-accelerated)
 *   TTM_PL_TT     -> AMDGPU_GEM_DOMAIN_GTT  (GART / ddi_dma system RAM)
 *   TTM_PL_VRAM   -> AMDGPU_GEM_DOMAIN_VRAM (BAR0 aperture, vmem range)
 */
#define	TTM_PL_SYSTEM	0
#define	TTM_PL_TT	1
#define	TTM_PL_VRAM	2

/*
 * amdgpu GEM domains, from the Linux DRM uapi amdgpu_drm.h (stable kernel<->
 * userland ABI; the crib's amdgpu_object.h amdgpu_mem_type_to_domain() maps
 * TTM_PL_* <-> these). A GEM_CREATE ioctl carries one of these; the amdgpu_bo
 * create path below turns it into a ttm placement + a VRAM/GTT backing.
 */
#define	AMDGPU_GEM_DOMAIN_CPU	0x1
#define	AMDGPU_GEM_DOMAIN_GTT	0x2
#define	AMDGPU_GEM_DOMAIN_VRAM	0x4

/* the GPU page size amdgpu addresses VRAM/GART in (crib: amdgpu.h). */
#define	AMDGPU_GPU_PAGE_SIZE	4096

/*
 * struct ttm_resource - the reduced ttm_mem_reg / ttm_resource: where a BO
 * currently lives and how much space it uses. Crib: netbsd-ref
 * .../ttm/ttm_bo_api.h struct ttm_mem_reg (dropped: mm_node opaque ptr,
 * page_alignment, placement caching flags, the ttm_bus_placement -- none
 * load-bearing without eviction/mmap-of-VRAM, both deferred).
 *
 *   mem_type   TTM_PL_VRAM | TTM_PL_TT | TTM_PL_SYSTEM
 *   size       requested size in bytes (rounded to AMDGPU_GPU_PAGE_SIZE)
 *   num_pages  size / AMDGPU_GPU_PAGE_SIZE
 *   start      for VRAM: the byte offset into the BAR0 aperture (the vmem
 *              range start); for GTT/SYSTEM: 0 (the GPU address comes from the
 *              DMA cookie, see struct ttm_gtt_alloc).
 */
struct ttm_resource {
	uint32_t	mem_type;
	uint64_t	size;
	uint64_t	num_pages;
	uint64_t	start;
};

/*
 * struct ttm_range_mgr - the VRAM manager: a vmem arena over the BAR0 VRAM
 * aperture. The load-bearing illumos fit -- vmem_create is the kernel's
 * general resource allocator, and a VRAM aperture is exactly "a span of a
 * resource to hand out non-overlapping ranges of". Crib: Linux
 * drm/ttm/ttm_range_manager.c (drm_mm) + amdgpu_vram_mgr; re-expressed over
 * vmem instead of drm_mm.
 *
 * vmem addresses cannot be 0 (a NULL return means "out of space"), so the
 * arena spans [TTM_VRAM_VMEM_BASE, TTM_VRAM_VMEM_BASE + size): a returned
 * vmem address V maps to VRAM byte offset (V - TTM_VRAM_VMEM_BASE). The base
 * is one page so offset 0 is representable.
 */
#define	TTM_VRAM_VMEM_BASE	((uintptr_t)AMDGPU_GPU_PAGE_SIZE)

struct ttm_range_mgr {
	vmem_t		*arena;		/* vmem_create over the aperture */
	uint64_t	aperture_size;	/* == sc->vram_size */
	kmutex_t	lock;
	uint64_t	used;		/* bytes handed out (bookkeeping) */
};

/*
 * struct ttm_gtt_alloc - one GTT allocation's DMA state. GTT = system RAM the
 * GPU reaches via DMA; ddi_dma_alloc_handle + ddi_dma_mem_alloc get DMA-able
 * kernel pages and ddi_dma_addr_bind_handle yields the GPU-visible DMA cookies
 * (the scatter-gather list a real GART table would be programmed from). Crib:
 * the ddi_dma pattern the illumos nvme/vioif drivers + C1b's virtio backing
 * use for device-visible system memory.
 *
 *   dma_hdl   ddi_dma_alloc_handle
 *   acc_hdl   ddi_dma_mem_alloc access handle
 *   kaddr     the CPU-visible kernel VA of the allocation
 *   real_len  bytes actually allocated (ddi_dma_mem_alloc may round up)
 *   ncookies  number of scatter-gather cookies (GTT pages, roughly)
 *   cookie0   the first cookie (dmac_laddress = the base GPU DMA address);
 *             additional cookies are walked via ddi_dma_nextcookie at bind.
 */
struct ttm_gtt_alloc {
	ddi_dma_handle_t	dma_hdl;
	ddi_acc_handle_t	acc_hdl;
	caddr_t			kaddr;
	size_t			real_len;
	uint_t			ncookies;
	ddi_dma_cookie_t	cookie0;
};

/*
 * struct ttm_buffer_object - the reduced ttm_bo. Crib: netbsd-ref
 * .../ttm/ttm_bo_api.h struct ttm_buffer_object. Kept: the refcount, the
 * bdev/device back-pointer, the type, the size/num_pages, and the current
 * placement (mem). Dropped (all DEFERRED per the design): the drm_gem_object
 * base (C1's GEM wraps this from the outside instead), lru/ddestroy/swap list
 * heads, ttm_tt, persistent_swap_storage, the moving fence, mmu notifiers.
 *
 * The backing is a discriminated union keyed by mem.mem_type:
 *   TTM_PL_VRAM -> vram_addr is the vmem range start (byte offset + base)
 *   TTM_PL_TT   -> gtt is the ddi_dma allocation
 */
struct ttm_buffer_object {
	struct kref		kref;
	struct ttm_device	*bdev;		/* the per-GPU TTM device */
	uint32_t		type;		/* ttm_bo_type_{device,kernel} */
	uint64_t		size;		/* bytes, page-rounded */
	struct ttm_resource	mem;		/* current placement */

	/* backing, keyed by mem.mem_type */
	uintptr_t		vram_addr;	/* TTM_PL_VRAM: vmem address */
	struct ttm_gtt_alloc	gtt;		/* TTM_PL_TT: ddi_dma state */
};

/* ttm_bo_type (crib: ttm_bo_api.h). Only device/kernel are load-bearing. */
#define	ttm_bo_type_device	0
#define	ttm_bo_type_kernel	1

/*
 * struct ttm_device - the per-GPU TTM instance (the reduced ttm_bo_device /
 * amdgpu_mman). Holds the two memory-type managers. Crib:
 * ../amdgpu-ref/src/amdgpu_ttm.h struct amdgpu_mman (dropped: the buffer_funcs
 * / SDMA move ring / scheduler entity -- migration is deferred).
 *
 * The GTT manager is a simple accounting cap (a byte budget) rather than a
 * range allocator, because each GTT allocation's GPU address comes from its
 * own DMA cookies, not from a shared linear GART offset space -- the smallest
 * useful GTT manager, per the anti-wedge plan.
 */
struct ttm_device {
	struct amdgpu_softc	*sc;		/* the GPU (BAR0 aperture etc.) */
	struct ttm_range_mgr	vram_mgr;	/* TTM_PL_VRAM over BAR0 */

	/* the GTT manager: a byte budget over system RAM (ddi_dma allocs) */
	kmutex_t		gtt_lock;
	uint64_t		gtt_size;	/* GTT budget in bytes */
	uint64_t		gtt_used;	/* bytes handed out */
	dev_info_t		*dip;		/* for ddi_dma_alloc_handle */
};

/* --- the VRAM range manager (ttm.c) --- */
int	ttm_range_man_init(struct ttm_range_mgr *, const char *name,
	    uint64_t aperture_size);
void	ttm_range_man_fini(struct ttm_range_mgr *);
int	ttm_range_man_alloc(struct ttm_range_mgr *, uint64_t size,
	    uint64_t align, struct ttm_resource *out);
void	ttm_range_man_free(struct ttm_range_mgr *, struct ttm_resource *);

/* --- the GTT (ddi_dma) manager (ttm.c) --- */
int	ttm_gtt_man_alloc(struct ttm_device *, uint64_t size,
	    struct ttm_resource *out, struct ttm_gtt_alloc *gtt);
void	ttm_gtt_man_free(struct ttm_device *, struct ttm_resource *,
	    struct ttm_gtt_alloc *gtt);

/* --- the TTM device + BO core (ttm.c) --- */
int	ttm_device_init(struct ttm_device *, struct amdgpu_softc *,
	    uint64_t vram_size, uint64_t gtt_size);
void	ttm_device_fini(struct ttm_device *);
int	ttm_bo_init(struct ttm_device *, struct ttm_buffer_object *bo,
	    uint64_t size, uint32_t type, uint32_t mem_type);
void	ttm_bo_get(struct ttm_buffer_object *);
void	ttm_bo_put(struct ttm_buffer_object *);

/*
 * struct amdgpu_bo - the amdgpu buffer object: a ttm_buffer_object plus the
 * amdgpu placement domain, plus the C1 GEM object that wraps it so a GEM
 * handle (from a GEM_CREATE ioctl) resolves to this BO. Crib:
 * ../amdgpu-ref/src/amdgpu_object.h struct amdgpu_bo, reduced HARD -- kept the
 * tbo + the domain; dropped placements[3]/placement/kmap/pin_count/tiling/
 * metadata/shadow/vm_bo/mn/kfd_bo (all deferred subsystems).
 *
 * The layering:  GEM handle  ->  drm_gem_object *gem  ->  amdgpu_bo  ->  tbo
 *                              (C1 handle table)      (this)        (ttm.c)
 */
struct drm_gem_object;			/* C1 GEM (drm_internal.h) */

struct amdgpu_bo {
	struct ttm_buffer_object	tbo;	/* the ttm core (backing) */
	uint32_t			domain;	/* AMDGPU_GEM_DOMAIN_* placed */
	struct drm_gem_object		*gem;	/* the C1 GEM wrapper, or NULL */
	struct amdgpu_softc		*sc;
};

/* --- the amdgpu<->TTM glue (amdgpu_ttm.c) --- */
int	amdgpu_ttm_init(struct amdgpu_softc *);
void	amdgpu_ttm_fini(struct amdgpu_softc *);
int	amdgpu_bo_create(struct amdgpu_softc *, uint64_t size, uint32_t domain,
	    struct amdgpu_bo **bo_out);
void	amdgpu_bo_free(struct amdgpu_bo *);
uint64_t amdgpu_bo_gpu_offset(struct amdgpu_bo *);

#endif	/* _TTM_PRIV_H_ */
