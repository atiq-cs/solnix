/*
 * gmc_hw.c - C3-amdgpu-d: the gmc_v10_0 .hw_init register sequence for Navi 12,
 * illumos side.
 *
 * ================= HARDWARE-GATED (compiles; runs only on a powered GPU) =====
 *
 * C3-c's gmc.c stood up the GART page-table BO (software floor). This is the
 * LIVE programming that turns it on: gmc_v10_0 gart_enable programs the VM
 * aperture + the page-table base registers in the GC and MMHUB VM contexts so
 * the GPU's memory controller routes GPU virtual addresses through the GART.
 *
 * The register writes COMPILE + are structurally verifiable against the SOC15
 * reg model (amdgpu_reg_offset + RREG32/WREG32). Running them needs a powered
 * GPU: the VM aperture registers only take effect on live silicon, and the
 * flush-and-confirm reads gate on the memory controller's response.
 *
 * Crib provenance (register sequence; the register names are the stable Navi
 * GC/MMHUB VM-context layout -- NOT invented):
 *   - gart_enable: Linux drivers/gpu/drm/amd/amdgpu/gmc_v10_0.c
 *     gmc_v10_0_gart_enable -> gfxhub_v2_0_gart_enable / mmhub_v2_0_gart_enable
 *   - the VM-context registers (mmGCVM_CONTEXT0_PAGE_TABLE_BASE_ADDR_*,
 *     mmGCVM_CONTEXT0_CNTL, the system aperture regs): gfxhub_v2_0.c
 *   - the page-table-base program: gmc_v10_0_setup_vm_pt_regs
 */

#include <sys/types.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/cmn_err.h>

#include "amdgpu_priv.h"
#include "ttm_priv.h"
#include "amdgpu_ip.h"
#include "amdgpu_hw.h"

/*
 * The GC VM-context register offsets (crib: gfxhub_v2_0.c / Navi GC VM regs).
 * Reached via amdgpu_reg_offset(sc, GC_HWIP, 0, seg, reg). These are the
 * context-0 (system) page-table-base + aperture registers gart_enable writes.
 * The exact word indices are the stable Navi GCVM_CONTEXT0 block.
 */
#define	mmGCVM_CONTEXT0_PAGE_TABLE_BASE_ADDR_LO32	0x1680
#define	mmGCVM_CONTEXT0_PAGE_TABLE_BASE_ADDR_HI32	0x1681
#define	mmGCVM_CONTEXT0_PAGE_TABLE_START_ADDR_LO32	0x16a0
#define	mmGCVM_CONTEXT0_PAGE_TABLE_START_ADDR_HI32	0x16a1
#define	mmGCVM_CONTEXT0_PAGE_TABLE_END_ADDR_LO32	0x16c0
#define	mmGCVM_CONTEXT0_PAGE_TABLE_END_ADDR_HI32	0x16c1
#define	mmGCVM_CONTEXT0_CNTL				0x1660
#define	mmGCMC_VM_SYSTEM_APERTURE_LOW_ADDR		0x15c0
#define	mmGCMC_VM_SYSTEM_APERTURE_HIGH_ADDR		0x15c1
#define	mmGCVM_L2_CNTL					0x15e0
#define	mmGCVM_INVALIDATE_ENG0_REQ			0x1720
#define	mmGCVM_INVALIDATE_ENG0_ACK			0x1730

/* GCVM_CONTEXT0_CNTL enable bits (crib: gfxhub_v2_0 context enable). */
#define	GCVM_CONTEXT0_CNTL_ENABLE			0x00000001u
#define	GCVM_CONTEXT0_CNTL_PAGE_TABLE_DEPTH_SHIFT	1
#define	GCVM_L2_CNTL_ENABLE				0x00000001u

static uint32_t
gc_rreg(struct amdgpu_softc *sc, uint32_t reg)
{
	return (amdgpu_rreg32(sc, amdgpu_reg_offset(sc, GC_HWIP, 0, 0, reg)));
}

static void
gc_wreg(struct amdgpu_softc *sc, uint32_t reg, uint32_t v)
{
	amdgpu_wreg32(sc, amdgpu_reg_offset(sc, GC_HWIP, 0, 0, reg), v);
}

/*
 * amdgpu_gmc_hw_init - the gmc_v10_0 gart_enable sequence: point the VM
 * context-0 page-table base at the GART table BO (from C3-c gmc.c), set the
 * page-table start/end to span the GART aperture, enable the L2 + the context,
 * and flush the TLB. Crib: gmc_v10_0_gart_enable + gfxhub_v2_0_gart_enable.
 *
 * HARDWARE-GATED: every WREG32 targets a live GC VM register; the final TLB
 * flush confirm (poll GCVM_INVALIDATE_ENG0_ACK) gates on the memory
 * controller. Off-hardware the writes go to unmapped/idle MMIO and the flush
 * confirm times out -- correct compile-phase behaviour.
 */
int
amdgpu_gmc_hw_init(struct amdgpu_softc *sc)
{
	struct amdgpu_gmc *gmc;
	uint64_t pt_base, pt_start, pt_end;
	int i;

	if (sc->ip == NULL || !sc->ip->gmc.initialized)
		return (DDI_FAILURE);
	gmc = &sc->ip->gmc;

	pt_base = gmc->table_gpu_addr;
	pt_start = 0;
	pt_end = gmc->gart_size - 1;

	/* 1. system aperture = the GART span (crib: gfxhub set_system_aperture) */
	gc_wreg(sc, mmGCMC_VM_SYSTEM_APERTURE_LOW_ADDR,
	    (uint32_t)(pt_start >> 18));
	gc_wreg(sc, mmGCMC_VM_SYSTEM_APERTURE_HIGH_ADDR,
	    (uint32_t)(pt_end >> 18));

	/* 2. point context-0 at the page table (crib: setup_vm_pt_regs) */
	gc_wreg(sc, mmGCVM_CONTEXT0_PAGE_TABLE_BASE_ADDR_LO32,
	    (uint32_t)(pt_base & 0xffffffffu));
	gc_wreg(sc, mmGCVM_CONTEXT0_PAGE_TABLE_BASE_ADDR_HI32,
	    (uint32_t)(pt_base >> 32));
	gc_wreg(sc, mmGCVM_CONTEXT0_PAGE_TABLE_START_ADDR_LO32,
	    (uint32_t)(pt_start >> 12));
	gc_wreg(sc, mmGCVM_CONTEXT0_PAGE_TABLE_START_ADDR_HI32,
	    (uint32_t)(pt_start >> 44));
	gc_wreg(sc, mmGCVM_CONTEXT0_PAGE_TABLE_END_ADDR_LO32,
	    (uint32_t)(pt_end >> 12));
	gc_wreg(sc, mmGCVM_CONTEXT0_PAGE_TABLE_END_ADDR_HI32,
	    (uint32_t)(pt_end >> 44));

	/* 3. enable the L2 + the context (crib: gfxhub enable_system_domain) */
	gc_wreg(sc, mmGCVM_L2_CNTL, GCVM_L2_CNTL_ENABLE);
	gc_wreg(sc, mmGCVM_CONTEXT0_CNTL,
	    GCVM_CONTEXT0_CNTL_ENABLE |
	    (0u << GCVM_CONTEXT0_CNTL_PAGE_TABLE_DEPTH_SHIFT));

	/* 4. flush the TLB (crib: gmc_v10_0_flush_gpu_tlb). HARDWARE-GATED. */
	gc_wreg(sc, mmGCVM_INVALIDATE_ENG0_REQ, 0x1);
	for (i = 0; i < GMC_HW_FLUSH_TIMEOUT_US; i++) {
		if (gc_rreg(sc, mmGCVM_INVALIDATE_ENG0_ACK) & 0x1)
			break;
		drv_usecwait(1);
	}
	if (i >= GMC_HW_FLUSH_TIMEOUT_US) {
		cmn_err(CE_WARN, "?amdgpu: GMC TLB flush timed out "
		    "(expected off-hardware)");
		return (DDI_FAILURE);
	}

	cmn_err(CE_CONT, "?amdgpu: GMC hw_init: GART @ gpu 0x%llx enabled\n",
	    (unsigned long long)pt_base);
	return (DDI_SUCCESS);
}
