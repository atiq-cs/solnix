/*
 * ttm.c - the smallest useful TTM for illumos amdgpu (C3-amdgpu-b): the
 * buffer-object core + the two memory-type managers.
 *
 *   1. the VRAM manager  = a vmem arena over the BAR0 VRAM aperture;
 *   2. the GTT  manager  = ddi_dma_* DMA-able system RAM + GPU-visible cookies;
 *   3. the ttm_bo core    = a refcounted object placed in VRAM or GTT at init.
 *
 * NO migration, NO eviction, NO swap (all DEFERRED per design-gpu-amdgpu.md +
 * STATUS.md C3-amdgpu-b: "no migration/eviction"). A BO is placed once, at
 * create; it stays there until freed. That is the smallest thing the IP-block
 * bring-up (ring buffers, page tables) needs from TTM.
 *
 * Crib provenance (struct shapes + the manager algorithm; NO Linux/NetBSD .c
 * lifted, all re-expressed over the illumos vmem + ddi_dma KPI):
 *   - the range-manager shape: Linux drm/ttm/ttm_range_manager.c + amdgpu's
 *     amdgpu_vram_mgr (a drm_mm range allocator over the aperture) -> vmem here.
 *   - the ttm_bo init/get/put lifecycle: netbsd-ref .../ttm/ttm_bo_api.h +
 *     Linux drm/ttm/ttm_bo.c ttm_bo_init_reserved -> reduced to a kref + a
 *     placement + a backing here.
 *   - the GTT ddi_dma pattern: the illumos nvme/vioif DMA-buffer idiom
 *     (alloc_handle -> mem_alloc -> addr_bind_handle -> cookies) that C1b's
 *     virtio backing also uses for device-visible system memory.
 */

#include <sys/types.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/vmem.h>
#include <sys/kmem.h>
#include <sys/ksynch.h>
#include <sys/sysmacros.h>	/* P2ROUNDUP */
#include <sys/cmn_err.h>

#include "amdgpu_priv.h"
#include "ttm_priv.h"

/* ======================================================================
 * VRAM manager: a vmem arena over the BAR0 VRAM aperture.
 *
 * vmem_create(name, base, size, quantum, ...) creates an arena spanning
 * [base, base+size). We span [TTM_VRAM_VMEM_BASE, +aperture_size) so a NULL
 * return unambiguously means "out of VRAM" (vmem address 0 == NULL == error).
 * The quantum is the GPU page size: all VRAM ranges are page-multiples, which
 * is what the GART / GPU address math assumes.
 *
 * VMC_IDENTIFIER: the arena is NOT backed by real kernel memory -- it manages
 * an abstract range (device VRAM offsets), exactly what VMC_IDENTIFIER is for.
 * Without it, vmem would try to import/populate real pages for the span.
 * ====================================================================== */

int
ttm_range_man_init(struct ttm_range_mgr *mgr, const char *name,
    uint64_t aperture_size)
{
	bzero(mgr, sizeof (*mgr));
	mgr->aperture_size = aperture_size;
	mutex_init(&mgr->lock, NULL, MUTEX_DRIVER, NULL);

	mgr->arena = vmem_create(name,
	    (void *)TTM_VRAM_VMEM_BASE,		/* base */
	    (size_t)aperture_size,		/* size */
	    (size_t)AMDGPU_GPU_PAGE_SIZE,	/* quantum = GPU page */
	    NULL, NULL, NULL,			/* afunc/ffunc/source */
	    0,					/* qcache_max */
	    VMC_IDENTIFIER | VM_SLEEP);
	if (mgr->arena == NULL) {
		mutex_destroy(&mgr->lock);
		return (DDI_FAILURE);
	}
	return (DDI_SUCCESS);
}

void
ttm_range_man_fini(struct ttm_range_mgr *mgr)
{
	if (mgr->arena != NULL) {
		vmem_destroy(mgr->arena);
		mgr->arena = NULL;
	}
	mutex_destroy(&mgr->lock);
}

/*
 * ttm_range_man_alloc - carve a VRAM range. size is rounded to the GPU page;
 * align (0 => GPU page) requests an aligned start (vmem_xalloc). The returned
 * ttm_resource.start is the VRAM BYTE OFFSET into the aperture (vmem address
 * minus the arena base), which is what the GPU addresses VRAM by.
 */
int
ttm_range_man_alloc(struct ttm_range_mgr *mgr, uint64_t size, uint64_t align,
    struct ttm_resource *out)
{
	void *addr;
	size_t asize;

	if (align == 0)
		align = AMDGPU_GPU_PAGE_SIZE;
	asize = (size_t)P2ROUNDUP(size, AMDGPU_GPU_PAGE_SIZE);

	/*
	 * vmem_xalloc with a phase/nocross/min/max of 0 and the requested
	 * alignment. VM_BESTFIT keeps VRAM tightly packed (there is no
	 * eviction to reclaim fragmentation, so best-fit matters).
	 */
	addr = vmem_xalloc(mgr->arena, asize, (size_t)align,
	    0, 0, NULL, NULL, VM_BESTFIT | VM_NOSLEEP);
	if (addr == NULL)
		return (DDI_FAILURE);

	mutex_enter(&mgr->lock);
	mgr->used += asize;
	mutex_exit(&mgr->lock);

	bzero(out, sizeof (*out));
	out->mem_type = TTM_PL_VRAM;
	out->size = asize;
	out->num_pages = asize / AMDGPU_GPU_PAGE_SIZE;
	/* the caller keeps the vmem address for free; expose the byte offset */
	out->start = (uint64_t)((uintptr_t)addr - TTM_VRAM_VMEM_BASE);
	return (DDI_SUCCESS);
}

void
ttm_range_man_free(struct ttm_range_mgr *mgr, struct ttm_resource *res)
{
	uintptr_t addr;

	if (res->mem_type != TTM_PL_VRAM || res->size == 0)
		return;
	addr = (uintptr_t)res->start + TTM_VRAM_VMEM_BASE;
	vmem_xfree(mgr->arena, (void *)addr, (size_t)res->size);

	mutex_enter(&mgr->lock);
	if (mgr->used >= res->size)
		mgr->used -= res->size;
	mutex_exit(&mgr->lock);
	res->size = 0;
}

/* ======================================================================
 * GTT manager: DMA-able system RAM via ddi_dma_*.
 *
 * GTT is system memory the GPU accesses through its page tables. On illumos:
 *   ddi_dma_alloc_handle  -> a DMA handle constrained by our attr
 *   ddi_dma_mem_alloc     -> DMA-able kernel pages (CPU-visible via acc_hdl)
 *   ddi_dma_addr_bind_handle -> the GPU-visible DMA cookies (dmac_laddress =
 *                            the address the GPU / GART programs to reach the
 *                            page); ccount cookies == the scatter-gather list.
 *
 * The "GTT manager" here is a byte budget (gtt_size/gtt_used): each allocation
 * carries its own cookies, so there is no shared linear GART offset space to
 * range-allocate -- the smallest useful GTT manager (anti-wedge plan). Wiring
 * the cookies into an actual GART page table is the GMC IP block (deferred).
 * ====================================================================== */

/*
 * The DMA attributes for GTT system memory. 44-bit GPU DMA range is the Navi
 * GART reach; page alignment + page granularity; a generous s/g length so a
 * multi-page BO can scatter. Modeled on the attr illumos nvme/vioif use.
 */
static ddi_dma_attr_t ttm_gtt_dma_attr = {
	.dma_attr_version	= DMA_ATTR_V0,
	.dma_attr_addr_lo	= 0,
	.dma_attr_addr_hi	= 0xffffffffffffull,	/* 48-bit */
	.dma_attr_count_max	= 0xffffffffull,
	.dma_attr_align		= AMDGPU_GPU_PAGE_SIZE,
	.dma_attr_burstsizes	= 0xfff,
	.dma_attr_minxfer	= 1,
	.dma_attr_maxxfer	= 0xffffffffull,
	.dma_attr_seg		= 0xffffffffffffffffull,
	.dma_attr_sgllen	= 0x100,		/* up to 256 s/g entries */
	.dma_attr_granular	= AMDGPU_GPU_PAGE_SIZE,
	.dma_attr_flags		= 0,
};

/* GTT pages are DMA-coherent system RAM: never-swap endianness, mergeable. */
static ddi_device_acc_attr_t ttm_gtt_acc_attr = {
	.devacc_attr_version	= DDI_DEVICE_ATTR_V0,
	.devacc_attr_endian_flags = DDI_NEVERSWAP_ACC,
	.devacc_attr_dataorder	= DDI_STRICTORDER_ACC,
};

int
ttm_gtt_man_alloc(struct ttm_device *bdev, uint64_t size,
    struct ttm_resource *out, struct ttm_gtt_alloc *gtt)
{
	uint64_t asize;

	asize = P2ROUNDUP(size, AMDGPU_GPU_PAGE_SIZE);

	mutex_enter(&bdev->gtt_lock);
	if (bdev->gtt_used + asize > bdev->gtt_size) {
		mutex_exit(&bdev->gtt_lock);
		return (DDI_FAILURE);
	}
	mutex_exit(&bdev->gtt_lock);

	bzero(gtt, sizeof (*gtt));

	if (ddi_dma_alloc_handle(bdev->dip, &ttm_gtt_dma_attr,
	    DDI_DMA_DONTWAIT, NULL, &gtt->dma_hdl) != DDI_SUCCESS)
		return (DDI_FAILURE);

	if (ddi_dma_mem_alloc(gtt->dma_hdl, (size_t)asize, &ttm_gtt_acc_attr,
	    DDI_DMA_CONSISTENT, DDI_DMA_DONTWAIT, NULL,
	    &gtt->kaddr, &gtt->real_len, &gtt->acc_hdl) != DDI_SUCCESS)
		goto fail_hdl;

	if (ddi_dma_addr_bind_handle(gtt->dma_hdl, NULL, gtt->kaddr,
	    gtt->real_len, DDI_DMA_RDWR | DDI_DMA_CONSISTENT,
	    DDI_DMA_DONTWAIT, NULL, &gtt->cookie0, &gtt->ncookies)
	    != DDI_DMA_MAPPED)
		goto fail_mem;

	mutex_enter(&bdev->gtt_lock);
	bdev->gtt_used += asize;
	mutex_exit(&bdev->gtt_lock);

	bzero(out, sizeof (*out));
	out->mem_type = TTM_PL_TT;
	out->size = asize;
	out->num_pages = asize / AMDGPU_GPU_PAGE_SIZE;
	/* GTT GPU address is cookie0.dmac_laddress (the GART/IOMMU base) */
	out->start = (uint64_t)gtt->cookie0.dmac_laddress;
	return (DDI_SUCCESS);

fail_mem:
	ddi_dma_mem_free(&gtt->acc_hdl);
fail_hdl:
	ddi_dma_free_handle(&gtt->dma_hdl);
	bzero(gtt, sizeof (*gtt));
	return (DDI_FAILURE);
}

void
ttm_gtt_man_free(struct ttm_device *bdev, struct ttm_resource *res,
    struct ttm_gtt_alloc *gtt)
{
	if (res->mem_type != TTM_PL_TT || gtt->dma_hdl == NULL)
		return;
	(void) ddi_dma_unbind_handle(gtt->dma_hdl);
	ddi_dma_mem_free(&gtt->acc_hdl);
	ddi_dma_free_handle(&gtt->dma_hdl);

	mutex_enter(&bdev->gtt_lock);
	if (bdev->gtt_used >= res->size)
		bdev->gtt_used -= res->size;
	mutex_exit(&bdev->gtt_lock);

	bzero(gtt, sizeof (*gtt));
	res->size = 0;
}

/* ======================================================================
 * The TTM device + BO core.
 * ====================================================================== */

int
ttm_device_init(struct ttm_device *bdev, struct amdgpu_softc *sc,
    uint64_t vram_size, uint64_t gtt_size)
{
	bzero(bdev, sizeof (*bdev));
	bdev->sc = sc;
	bdev->dip = sc->dip;
	bdev->gtt_size = gtt_size;
	mutex_init(&bdev->gtt_lock, NULL, MUTEX_DRIVER, NULL);

	if (ttm_range_man_init(&bdev->vram_mgr, "amdgpu_vram",
	    vram_size) != DDI_SUCCESS) {
		mutex_destroy(&bdev->gtt_lock);
		return (DDI_FAILURE);
	}
	return (DDI_SUCCESS);
}

void
ttm_device_fini(struct ttm_device *bdev)
{
	ttm_range_man_fini(&bdev->vram_mgr);
	mutex_destroy(&bdev->gtt_lock);
}

/*
 * ttm_bo_init - the reduced ttm_bo_init: place a fresh BO into mem_type
 * (TTM_PL_VRAM or TTM_PL_TT) at create time. No validate/migrate loop -- the
 * placement is final (eviction deferred). Crib: Linux ttm_bo_init_reserved /
 * netbsd-ref ttm_bo_api.h, reduced to alloc-the-backing-once.
 */
int
ttm_bo_init(struct ttm_device *bdev, struct ttm_buffer_object *bo,
    uint64_t size, uint32_t type, uint32_t mem_type)
{
	int r;

	bzero(bo, sizeof (*bo));
	kref_init(&bo->kref);
	bo->bdev = bdev;
	bo->type = type;
	bo->size = P2ROUNDUP(size, AMDGPU_GPU_PAGE_SIZE);

	switch (mem_type) {
	case TTM_PL_VRAM:
		r = ttm_range_man_alloc(&bdev->vram_mgr, bo->size, 0, &bo->mem);
		if (r != DDI_SUCCESS)
			return (r);
		bo->vram_addr = (uintptr_t)bo->mem.start + TTM_VRAM_VMEM_BASE;
		break;
	case TTM_PL_TT:
		r = ttm_gtt_man_alloc(bdev, bo->size, &bo->mem, &bo->gtt);
		if (r != DDI_SUCCESS)
			return (r);
		break;
	default:
		/* SYSTEM placement is the C1 GEM ddi_umem path, not TTM here */
		return (DDI_FAILURE);
	}
	return (DDI_SUCCESS);
}

/* the destroy path, run when the last ttm_bo_put drops the refcount */
static void
ttm_bo_release(struct kref *kref)
{
	struct ttm_buffer_object *bo =
	    (struct ttm_buffer_object *)(void *)
	    ((caddr_t)kref - offsetof(struct ttm_buffer_object, kref));

	switch (bo->mem.mem_type) {
	case TTM_PL_VRAM:
		ttm_range_man_free(&bo->bdev->vram_mgr, &bo->mem);
		break;
	case TTM_PL_TT:
		ttm_gtt_man_free(bo->bdev, &bo->mem, &bo->gtt);
		break;
	default:
		break;
	}
	/* the struct itself is owned by the amdgpu_bo wrapper (kmem_free'd
	 * there); ttm_bo_release only tears down the backing. */
}

void
ttm_bo_get(struct ttm_buffer_object *bo)
{
	kref_get(&bo->kref);
}

void
ttm_bo_put(struct ttm_buffer_object *bo)
{
	(void) kref_put(&bo->kref, ttm_bo_release);
}
