/*
 * amdgpu_ttm.c - the amdgpu<->TTM glue (C3-amdgpu-b): wire the reduced TTM
 * (ttm.c) into the amdgpu device + the amdgpu_bo create path, and let the C1
 * GEM handle table wrap an amdgpu_bo.
 *
 * The chain a GEM_CREATE(VRAM|GTT) ioctl drives:
 *
 *   GEM_CREATE(size, domain)
 *     -> amdgpu_bo_create(sc, size, AMDGPU_GEM_DOMAIN_{VRAM,GTT}, &bo)
 *       -> kmem_zalloc(struct amdgpu_bo)
 *       -> ttm_bo_init(sc->ttm, &bo->tbo, size, ttm_bo_type_device, mem_type)
 *          -> TTM_PL_VRAM: vmem_xalloc a range in the BAR0 aperture, OR
 *          -> TTM_PL_TT:   ddi_dma-alloc + bind DMA-able system RAM (cookies)
 *       -> attach a C1 drm_gem_object so a GEM handle resolves to this bo
 *     the caller (the amdgpu GEM ioctl, C3-amdgpu-c) puts bo->gem in the C1
 *     handle table and returns the handle to userland.
 *
 * Crib: ../amdgpu-ref/src/amdgpu_object.h amdgpu_bo_create + amdgpu_bo_do_create
 * (the domain->placement->ttm_bo_init flow) and amdgpu_ttm.h amdgpu_ttm_init
 * (the ttm_bo_device + VRAM/GTT manager setup), reduced HARD: no placement
 * fallback list (VRAM-then-GTT retry), no pin/kmap/validate, no sub-allocator.
 * No Linux/NetBSD .c lifted; re-expressed over ttm.c's vmem+ddi_dma managers.
 */

#include <sys/types.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/kmem.h>
#include <sys/sysmacros.h>
#include <sys/cmn_err.h>

#include "drm_internal.h"	/* struct drm_gem_object */
#include "amdgpu_priv.h"
#include "ttm_priv.h"

/*
 * amdgpu_ttm_init - stand up the TTM device for this GPU. The VRAM manager
 * spans the BAR0 aperture that C3-amdgpu-a mapped (sc->vram_size). The GTT
 * budget is a conservative system-RAM cap; a real amdgpu sizes GTT from
 * gmc.gart_size (deferred to the GMC IP block) -- here a fixed budget is the
 * smallest useful thing (anti-wedge plan).
 *
 * Crib: amdgpu_ttm_init (amdgpu_ttm.c) -> ttm_bo_device_init + the per-manager
 * ttm_range_man_init / amdgpu_gtt_mgr_init, reduced to ttm_device_init.
 */

/* GTT budget: 512 MB of DMA-able system RAM for the GPU's page tables + BOs.
 * A real driver derives this from gmc.gart_size; this is a bring-up default. */
#define	AMDGPU_TTM_DEFAULT_GTT_SIZE	(512ULL * 1024 * 1024)

int
amdgpu_ttm_init(struct amdgpu_softc *sc)
{
	struct ttm_device *bdev;
	int r;

	if (sc->ttm != NULL)
		return (DDI_SUCCESS);	/* idempotent */

	bdev = kmem_zalloc(sizeof (*bdev), KM_SLEEP);
	r = ttm_device_init(bdev, sc, (uint64_t)sc->vram_size,
	    AMDGPU_TTM_DEFAULT_GTT_SIZE);
	if (r != DDI_SUCCESS) {
		kmem_free(bdev, sizeof (*bdev));
		return (r);
	}
	sc->ttm = bdev;

	cmn_err(CE_CONT, "?amdgpu: TTM up: VRAM %llu MB (BAR0 aperture), "
	    "GTT %llu MB (ddi_dma system RAM)\n",
	    (unsigned long long)(sc->vram_size >> 20),
	    (unsigned long long)(AMDGPU_TTM_DEFAULT_GTT_SIZE >> 20));
	return (DDI_SUCCESS);
}

void
amdgpu_ttm_fini(struct amdgpu_softc *sc)
{
	if (sc->ttm == NULL)
		return;
	ttm_device_fini(sc->ttm);
	kmem_free(sc->ttm, sizeof (*sc->ttm));
	sc->ttm = NULL;
}

/*
 * amdgpu_domain_to_mem_type - the amdgpu_mem_type_to_domain inverse (crib:
 * amdgpu_object.h). A GEM domain bit picks the ttm memory type. We honor the
 * single preferred domain (VRAM over GTT if both set); the VRAM->GTT eviction
 * fallback is deferred.
 */
static uint32_t
amdgpu_domain_to_mem_type(uint32_t domain)
{
	if (domain & AMDGPU_GEM_DOMAIN_VRAM)
		return (TTM_PL_VRAM);
	if (domain & AMDGPU_GEM_DOMAIN_GTT)
		return (TTM_PL_TT);
	return (TTM_PL_SYSTEM);
}

/*
 * amdgpu_bo_create - the reduced amdgpu_bo_create: allocate an amdgpu_bo,
 * place its ttm_bo in VRAM or GTT, and attach a C1 GEM object so the handle
 * table can wrap it. On success *bo_out owns one reference; free with
 * amdgpu_bo_free.
 */
int
amdgpu_bo_create(struct amdgpu_softc *sc, uint64_t size, uint32_t domain,
    struct amdgpu_bo **bo_out)
{
	struct amdgpu_bo *abo;
	struct drm_gem_object *gem;
	uint32_t mem_type;
	int r;

	if (sc->ttm == NULL)
		return (DDI_FAILURE);

	mem_type = amdgpu_domain_to_mem_type(domain);
	if (mem_type != TTM_PL_VRAM && mem_type != TTM_PL_TT)
		return (DDI_FAILURE);	/* SYSTEM is the C1 GEM umem path */

	abo = kmem_zalloc(sizeof (*abo), KM_SLEEP);
	abo->sc = sc;
	abo->domain = domain;

	r = ttm_bo_init(sc->ttm, &abo->tbo, size, ttm_bo_type_device, mem_type);
	if (r != DDI_SUCCESS) {
		kmem_free(abo, sizeof (*abo));
		return (r);
	}

	/*
	 * Attach a C1 GEM object as the userland-facing wrapper. Its backing is
	 * VRAM/GTT (not ddi_umem), so kaddr/umem_cookie stay NULL -- the GEM
	 * object is the handle-table anchor + the size record; the actual bytes
	 * live in the tbo's VRAM range or GTT DMA allocation. (mmap of a VRAM
	 * BO -- devmap over the BAR0 aperture -- is the fault path deferred with
	 * eviction; GEM here provides the handle, not yet the mapping.)
	 */
	gem = kmem_zalloc(sizeof (*gem), KM_SLEEP);
	kref_init(&gem->refcount);
	gem->size = (size_t)abo->tbo.size;
	abo->gem = gem;

	*bo_out = abo;
	return (DDI_SUCCESS);
}

void
amdgpu_bo_free(struct amdgpu_bo *abo)
{
	if (abo == NULL)
		return;
	if (abo->gem != NULL) {
		/* GEM wrapper has no ddi_umem backing; free the anchor. */
		kmem_free(abo->gem, sizeof (*abo->gem));
		abo->gem = NULL;
	}
	ttm_bo_put(&abo->tbo);		/* releases the VRAM/GTT backing */
	kmem_free(abo, sizeof (*abo));
}

/*
 * amdgpu_bo_gpu_offset - the GPU-visible address of the BO. Crib:
 * amdgpu_object.h amdgpu_bo_gpu_offset. For VRAM it is the byte offset into
 * the aperture (ttm_resource.start); for GTT it is the base DMA cookie address
 * (what the GART would map). This is the address an IP block programs into a
 * ring-buffer base register / page-table entry.
 */
uint64_t
amdgpu_bo_gpu_offset(struct amdgpu_bo *abo)
{
	return (abo->tbo.mem.start);
}
