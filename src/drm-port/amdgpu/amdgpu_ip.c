/*
 * amdgpu_ip.c - C3-amdgpu-c: the Navi 12 IP-block bring-up, illumos side.
 *
 * The aggregate IP-block init the attach path (amdgpu.c) calls after TTM:
 *   navi12_reg_base_init  -- fill reg_offset[hwip][inst] from the AMD
 *                            IP-base table so RREG32/WREG32 (amdgpu.c) can
 *                            address each block (GC/SDMA/GMC/IH/...);
 *   amdgpu_wb_init        -- the writeback buffer (a GTT BO of dwords the GPU
 *                            writes ring rptr/wptr into);
 *   amdgpu_gmc_init       -- the GART page table (gmc.c);
 *   amdgpu_ring_init x2   -- the GFX + SDMA command rings (amdgpu_ring.c);
 *   amdgpu_ih_ring_init   -- the interrupt-handler ring (amdgpu_ring.c).
 *
 * This is COMPILE-PHASE: it allocates the BOs + sets up the pointers + reg
 * bases, but does NOT power up the GPU, load firmware, or program live
 * registers (that is C3-amdgpu-d and needs real hardware). The reg_offset
 * table + the ring/GMC/IH BOs are the last software floor before that.
 *
 * Crib provenance (register bases + flow; NO Linux/NetBSD .c lifted):
 *   - navi12_reg_base_init + the IP_BASE numbers: ../amdgpu-ref/src/
 *     amdgpu_navi12_reg_init.c + navi12_ip_offset.h (VERBATIM base values)
 *   - reg_offset[][] + SOC15_REG_OFFSET: ../amdgpu-ref/src/soc15_common.h
 *   - the IP-block set (common/gmc/ih/gfx/sdma) + order:
 *     ../amdgpu-ref/src/amdgpu_nv.c nv_set_ip_blocks CHIP_NAVI12 case
 *   - the writeback buffer: ../amdgpu-ref/src/amdgpu.h struct amdgpu_wb +
 *     amdgpu_device.c amdgpu_device_wb_init/get
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
 * The Navi 12 IP-base table, cribbed VERBATIM from
 * ../amdgpu-ref/src/navi12_ip_offset.h (the AMD register bases -- these are
 * the real MMIO segment bases for gfx1011, NOT invented). Only the blocks the
 * reduced bring-up uses are materialized (GC, HDP, MMHUB, ATHUB, NBIF0, MP0,
 * OSSSYS, SDMA=GC, SMUIO, THM, CLK, DF); each is one instance-0 segment array.
 * navi12_reg_base_init points reg_offset[hwip][inst] at these.
 */
#define	IPBASE(...)	{ { { { __VA_ARGS__ } } } }

static const struct ip_base navi12_GC_BASE =
    { { { { 0x00001260, 0x0000A000, 0x02402C00, 0, 0 } } } };
static const struct ip_base navi12_HDP_BASE =
    { { { { 0x00000F20, 0x0240A400, 0, 0, 0 } } } };
static const struct ip_base navi12_MMHUB_BASE =
    { { { { 0x0001A000, 0x02408800, 0, 0, 0 } } } };
static const struct ip_base navi12_ATHUB_BASE =
    { { { { 0x00000C00, 0x02408C00, 0, 0, 0 } } } };
static const struct ip_base navi12_NBIF0_BASE =
    { { { { 0x00000000, 0x00000014, 0x00000D20, 0x00010400, 0x0241B000 } } } };
static const struct ip_base navi12_MP0_BASE =
    { { { { 0x00016000, 0x00DC0000, 0x00E00000, 0x00E40000, 0x0243FC00 } } } };
static const struct ip_base navi12_MP1_BASE =
    { { { { 0x00016000, 0x00E80000, 0x00EC0000, 0x00F00000, 0x02400400 } } } };
static const struct ip_base navi12_OSSSYS_BASE =
    { { { { 0x000010A0, 0x0240A000, 0, 0, 0 } } } };
static const struct ip_base navi12_SMUIO_BASE =
    { { { { 0x00016800, 0x00016A00, 0x00440000, 0x02401000, 0 } } } };
static const struct ip_base navi12_THM_BASE =
    { { { { 0x00016600, 0x02400C00, 0, 0, 0 } } } };
static const struct ip_base navi12_CLK_BASE =
    { { { { 0x00016C00, 0x02401800, 0, 0, 0 } } } };
static const struct ip_base navi12_DF_BASE =
    { { { { 0x00007000, 0x0240B800, 0, 0, 0 } } } };
static const struct ip_base navi12_UVD0_BASE =
    { { { { 0x00007800, 0x00007E00, 0x02403000, 0, 0 } } } };

/*
 * navi12_reg_base_init - point reg_offset[hwip][inst] at the per-block segment
 * base arrays. Crib: ../amdgpu-ref/src/amdgpu_navi12_reg_init.c
 * navi12_reg_base_init (the exact same assignments; SDMA0/1 alias GC on Navi,
 * as in the crib). On illumos the adev is sc->ip.
 */
int
navi12_reg_base_init(struct amdgpu_softc *sc)
{
	struct amdgpu_ip *ip = sc->ip;
	uint32_t i;

	for (i = 0; i < AMDGPU_MAX_INSTANCE; i++) {
		ip->reg_offset[GC_HWIP][i] = navi12_GC_BASE.instance[i].segment;
		ip->reg_offset[HDP_HWIP][i] = navi12_HDP_BASE.instance[i].segment;
		ip->reg_offset[MMHUB_HWIP][i] =
		    navi12_MMHUB_BASE.instance[i].segment;
		ip->reg_offset[ATHUB_HWIP][i] =
		    navi12_ATHUB_BASE.instance[i].segment;
		ip->reg_offset[NBIO_HWIP][i] =
		    navi12_NBIF0_BASE.instance[i].segment;
		ip->reg_offset[MP0_HWIP][i] = navi12_MP0_BASE.instance[i].segment;
		ip->reg_offset[MP1_HWIP][i] = navi12_MP1_BASE.instance[i].segment;
		ip->reg_offset[VCN_HWIP][i] =
		    navi12_UVD0_BASE.instance[i].segment;
		ip->reg_offset[DF_HWIP][i] = navi12_DF_BASE.instance[i].segment;
		ip->reg_offset[OSSSYS_HWIP][i] =
		    navi12_OSSSYS_BASE.instance[i].segment;
		/* SDMA0/1 share the GC base on Navi (crib: reg_init.c) */
		ip->reg_offset[SDMA0_HWIP][i] =
		    navi12_GC_BASE.instance[i].segment;
		ip->reg_offset[SDMA1_HWIP][i] =
		    navi12_GC_BASE.instance[i].segment;
		ip->reg_offset[SMUIO_HWIP][i] =
		    navi12_SMUIO_BASE.instance[i].segment;
		ip->reg_offset[THM_HWIP][i] = navi12_THM_BASE.instance[i].segment;
		ip->reg_offset[CLK_HWIP][i] = navi12_CLK_BASE.instance[i].segment;
	}
	return (DDI_SUCCESS);
}

/*
 * amdgpu_reg_offset - the SOC15_REG_OFFSET runtime helper:
 *   reg_offset[hwip][inst][seg] + reg
 * (crib: soc15_common.h SOC15_REG_OFFSET). The register's absolute MMIO word
 * index, which RREG32/WREG32 (amdgpu.c) then multiplies by 4 for the byte
 * offset into BAR5. A NULL base (a block not materialized above) returns just
 * reg -- harmless in compile-phase (no live access).
 */
uint32_t
amdgpu_reg_offset(struct amdgpu_softc *sc, enum amdgpu_hwip hwip,
    uint32_t inst, uint32_t seg, uint32_t reg)
{
	const uint32_t *base;

	if (hwip >= MAX_HWIP || inst >= AMDGPU_MAX_INSTANCE ||
	    seg >= AMDGPU_MAX_SEGMENT)
		return (reg);
	base = sc->ip->reg_offset[hwip][inst];
	if (base == NULL)
		return (reg);
	return (base[seg] + reg);
}

/* ======================================================================
 * Writeback buffer: a GTT BO of uint32_t slots (crib: amdgpu.h amdgpu_wb +
 * amdgpu_device.c amdgpu_device_wb_init/get). The GPU writes ring rptr/wptr
 * and fence values here; the CPU reads them. Each ring reserves a few slots.
 * ====================================================================== */

int
amdgpu_wb_init(struct amdgpu_softc *sc)
{
	struct amdgpu_wb *wb = &sc->ip->wb;
	struct amdgpu_bo *bo;
	void *cpu;
	int r;

	/* AMDGPU_MAX_WB dwords, in GTT (CPU-visible + GPU-visible). */
	r = amdgpu_bo_create(sc, AMDGPU_MAX_WB * sizeof (uint32_t),
	    AMDGPU_GEM_DOMAIN_GTT, &bo);
	if (r != DDI_SUCCESS)
		return (r);

	cpu = amdgpu_bo_cpu_addr(bo);
	if (cpu == NULL) {
		amdgpu_bo_free(bo);
		return (DDI_FAILURE);
	}
	wb->wb_obj = bo;
	wb->wb = (volatile uint32_t *)cpu;
	wb->gpu_addr = amdgpu_bo_gpu_offset(bo);
	wb->num_wb = AMDGPU_MAX_WB;
	wb->used = 0;
	bzero((void *)wb->wb, AMDGPU_MAX_WB * sizeof (uint32_t));
	bzero(wb->bitmap, sizeof (wb->bitmap));
	return (DDI_SUCCESS);
}

void
amdgpu_wb_fini(struct amdgpu_softc *sc)
{
	struct amdgpu_wb *wb = &sc->ip->wb;

	if (wb->wb_obj != NULL) {
		amdgpu_bo_free(wb->wb_obj);
		wb->wb_obj = NULL;
		wb->wb = NULL;
	}
}

/*
 * amdgpu_wb_get - reserve one writeback dword slot. Returns the dword index
 * (the ring stores it as *_offs; the GPU addr is wb.gpu_addr + slot*4). Crib:
 * amdgpu_device_wb_get (find_first_zero_bit) reduced to a linear scan.
 * The O(n) scan of 128 slots is fine at this count; a bitmap-find would only
 * matter if the ring count ever grew large.
 */
int
amdgpu_wb_get(struct amdgpu_softc *sc, uint32_t *slot)
{
	struct amdgpu_wb *wb = &sc->ip->wb;
	uint32_t i;

	for (i = 0; i < wb->num_wb; i++) {
		if (wb->bitmap[i] == 0) {
			wb->bitmap[i] = 1;
			wb->used++;
			*slot = i;
			return (DDI_SUCCESS);
		}
	}
	return (DDI_FAILURE);
}

void
amdgpu_wb_free(struct amdgpu_softc *sc, uint32_t slot)
{
	struct amdgpu_wb *wb = &sc->ip->wb;

	if (slot < wb->num_wb && wb->bitmap[slot] != 0) {
		wb->bitmap[slot] = 0;
		if (wb->used > 0)
			wb->used--;
	}
}

/* ======================================================================
 * The aggregate IP-block bring-up.
 * ====================================================================== */

/*
 * amdgpu_ip_blocks_init - the reduced amdgpu_device_ip_init for Navi 12: set
 * the register bases, then stand up the writeback + GMC + GFX/SDMA rings + IH.
 * Crib: ../amdgpu-ref/src/amdgpu_nv.c nv_set_ip_blocks (the common/gmc/ih/gfx/
 * sdma order) + amdgpu_device.c amdgpu_device_ip_init (the .sw_init loop).
 * PSP/SMU/DCE/VCN are skipped (deferred / not needed for compute bring-up).
 */
int
amdgpu_ip_blocks_init(struct amdgpu_softc *sc)
{
	struct amdgpu_ip *ip;
	int r;

	if (sc->ip != NULL)
		return (DDI_SUCCESS);		/* idempotent */
	if (sc->ttm == NULL)
		return (DDI_FAILURE);		/* rings/GMC need amdgpu_bo */

	ip = kmem_zalloc(sizeof (*ip), KM_SLEEP);
	sc->ip = ip;

	/* 1. register bases -- must precede any RREG32/WREG32 addressing */
	(void) navi12_reg_base_init(sc);

	/* 2. writeback buffer (ring rptr/wptr slots) */
	r = amdgpu_wb_init(sc);
	if (r != DDI_SUCCESS) {
		cmn_err(CE_WARN, "?amdgpu: wb init failed");
		goto fail;
	}

	/* 3. GMC / GART page table (gmc.c) */
	r = amdgpu_gmc_init(sc);
	if (r != DDI_SUCCESS) {
		cmn_err(CE_WARN, "?amdgpu: GMC init failed");
		goto fail_wb;
	}

	/* 4. GFX + SDMA command rings (amdgpu_ring.c) */
	r = amdgpu_ring_init(sc, &ip->gfx_ring, AMDGPU_RING_TYPE_GFX,
	    AMDGPU_GFX_RING_MAX_DW, "gfx");
	if (r != DDI_SUCCESS) {
		cmn_err(CE_WARN, "?amdgpu: GFX ring init failed");
		goto fail_gmc;
	}
	r = amdgpu_ring_init(sc, &ip->sdma_ring, AMDGPU_RING_TYPE_SDMA,
	    AMDGPU_SDMA_RING_MAX_DW, "sdma");
	if (r != DDI_SUCCESS) {
		cmn_err(CE_WARN, "?amdgpu: SDMA ring init failed");
		goto fail_gfx;
	}

	/* 5. IH (interrupt handler) ring (amdgpu_ring.c) */
	r = amdgpu_ih_ring_init(sc);
	if (r != DDI_SUCCESS) {
		cmn_err(CE_WARN, "?amdgpu: IH ring init failed");
		goto fail_sdma;
	}

	ip->initialized = B_TRUE;
	cmn_err(CE_CONT, "?amdgpu: IP blocks up: navi12 reg base + GMC "
	    "(GART %llu MB) + GFX/SDMA rings + IH ring\n",
	    (unsigned long long)(ip->gmc.gart_size >> 20));
	return (DDI_SUCCESS);

fail_sdma:
	amdgpu_ring_fini(&ip->sdma_ring);
fail_gfx:
	amdgpu_ring_fini(&ip->gfx_ring);
fail_gmc:
	amdgpu_gmc_fini(sc);
fail_wb:
	amdgpu_wb_fini(sc);
fail:
	kmem_free(ip, sizeof (*ip));
	sc->ip = NULL;
	return (r);
}

void
amdgpu_ip_blocks_fini(struct amdgpu_softc *sc)
{
	struct amdgpu_ip *ip = sc->ip;

	if (ip == NULL)
		return;
	amdgpu_ih_ring_fini(sc);
	amdgpu_ring_fini(&ip->sdma_ring);
	amdgpu_ring_fini(&ip->gfx_ring);
	amdgpu_gmc_fini(sc);
	amdgpu_wb_fini(sc);
	kmem_free(ip, sizeof (*ip));
	sc->ip = NULL;
}
