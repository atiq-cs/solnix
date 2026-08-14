/*
 * gmc.c - C3-amdgpu-c: the reduced GMC (graphics memory controller) / GART IP
 * block for Navi 12 (GMC 10), illumos side.
 *
 * The GMC owns the GPU's memory apertures + the GART -- the GPU's page table
 * over system RAM (== the TTM GTT, C3-amdgpu-b). Every GTT buffer the GPU
 * reaches goes through a GART PTE that maps a GPU virtual page to the
 * ddi_dma-bound system-RAM physical page.
 *
 * Reduced HARD (the smallest useful GMC, per the anti-wedge plan):
 *   - pick a GART size (gart_size), derive num_gpu_pages + the PTE table size
 *     (8 bytes/PTE, crib: amdgpu_gart.c amdgpu_gart_init);
 *   - allocate the page-table BO from amdgpu_bo_create (C3-amdgpu-b) -- in GTT
 *     here so it has a CPU-visible mapping (real amdgpu puts it in VRAM +
 *     kmaps it; VRAM CPU-mmap is the deferred devmap path, design doc);
 *   - zero the table (all PTEs invalid) -- the ready-to-be-programmed GART.
 *
 * NOT done (deferred to C3-amdgpu-d, needs live registers / firmware):
 *   - programming the GMC aperture registers (mmMC_VM_*_BASE, the VM context
 *     page-table base) -- gmc_v10_0 gart_enable writes live MMIO;
 *   - the per-page PTE fill loop (amdgpu_gart_bind walks the GTT DMA cookies
 *     and writes PTEs; needs the SDMA copy engine or CPU access to a live GART);
 *   - the VM (per-process page directories) + TLB flush.
 *
 * Crib provenance (flow + sizes; NO Linux/NetBSD .c lifted):
 *   - the GART model (bo + table_size = num_gpu_pages*8 + ready flag):
 *     ../amdgpu-ref/src/amdgpu_gart.h struct amdgpu_gart + amdgpu_gart.c
 *     amdgpu_gart_init / amdgpu_gart_table_vram_alloc
 *   - gart_size default: ../amdgpu-ref/src/amdgpu_gmc_v10_0.c (Navi gart_size)
 *   - the GMC IP-block position (after common, before the rings):
 *     ../amdgpu-ref/src/amdgpu_nv.c nv_set_ip_blocks
 */

#include <sys/types.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/kmem.h>
#include <sys/sysmacros.h>
#include <sys/cmn_err.h>

#include "amdgpu_priv.h"
#include "ttm_priv.h"
#include "amdgpu_ip.h"

/*
 * amdgpu_gmc_init - stand up the reduced GMC: size the GART + allocate + zero
 * the page-table BO. Crib: amdgpu_gart_init (table_size math) +
 * amdgpu_gart_table_vram_alloc (the table BO), reduced to a GTT BO with a CPU
 * mapping so the reduced bring-up can touch the table without a live VRAM
 * mmap.
 */
int
amdgpu_gmc_init(struct amdgpu_softc *sc)
{
	struct amdgpu_gmc *gmc = &sc->ip->gmc;
	struct amdgpu_bo *bo;
	void *cpu;
	int r;

	if (gmc->initialized)
		return (DDI_SUCCESS);

	gmc->gart_size = AMDGPU_GMC_DEFAULT_GART_SIZE;
	gmc->num_gpu_pages = gmc->gart_size / AMDGPU_GPU_PAGE_SIZE;
	gmc->table_size = gmc->num_gpu_pages * AMDGPU_GART_PTE_SIZE;

	/*
	 * The GART table itself. Real GMC 10 places it in VRAM and kmaps it;
	 * the reduced bring-up places it in GTT (ddi_dma system RAM) so it has
	 * a CPU-visible pointer without the deferred VRAM devmap path. The GPU
	 * address (table_gpu_addr) is what gmc_v10_0 would program into the VM
	 * page-table base register (deferred, needs live MMIO).
	 */
	r = amdgpu_bo_create(sc, gmc->table_size, AMDGPU_GEM_DOMAIN_GTT, &bo);
	if (r != DDI_SUCCESS)
		return (r);

	cpu = amdgpu_bo_cpu_addr(bo);
	if (cpu == NULL) {
		amdgpu_bo_free(bo);
		return (DDI_FAILURE);
	}
	gmc->table_bo = bo;
	gmc->table_gpu_addr = amdgpu_bo_gpu_offset(bo);
	gmc->table_cpu_addr = cpu;

	/* all PTEs invalid until amdgpu_gart_bind programs them (deferred) */
	bzero(gmc->table_cpu_addr, (size_t)gmc->table_size);

	/*
	 * The default PTE flags a valid GART entry carries (crib: gmc_v10_0
	 * gart_pte_flags = VALID|SYSTEM|SNOOPED|EXECUTABLE|READABLE|WRITEABLE).
	 * Recorded for the deferred PTE-fill loop; not applied here.
	 */
	gmc->gart_pte_flags = 0;
	gmc->initialized = B_TRUE;

	cmn_err(CE_CONT, "?amdgpu: GMC/GART: %llu MB, %llu GPU pages, "
	    "PTE table %llu KB @ gpu 0x%llx\n",
	    (unsigned long long)(gmc->gart_size >> 20),
	    (unsigned long long)gmc->num_gpu_pages,
	    (unsigned long long)(gmc->table_size >> 10),
	    (unsigned long long)gmc->table_gpu_addr);
	return (DDI_SUCCESS);
}

void
amdgpu_gmc_fini(struct amdgpu_softc *sc)
{
	struct amdgpu_gmc *gmc = &sc->ip->gmc;

	if (gmc->table_bo != NULL) {
		amdgpu_bo_free(gmc->table_bo);
		gmc->table_bo = NULL;
		gmc->table_cpu_addr = NULL;
	}
	gmc->initialized = B_FALSE;
}
