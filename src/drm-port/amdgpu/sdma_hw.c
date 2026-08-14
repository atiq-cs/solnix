/*
 * sdma_hw.c - C3-amdgpu-d: the sdma_v5_0 .hw_init register sequence for
 * Navi 12, illumos side.
 *
 * ================= HARDWARE-GATED (compiles; runs only on a powered GPU) =====
 *
 * The SDMA (system DMA / copy engine) .hw_init loads the SDMA microcode (or, on
 * Navi with PSP fw-load, relies on the PSP having placed it) and enables the
 * SDMA command ring on the hardware: point the ring registers at the C3-c SDMA
 * ring BO, set the rptr/wptr writeback address, and unhalt the engine.
 *
 * The register sequence COMPILES + is structurally verifiable. Running it needs
 * a powered GPU: the engine-enable confirm + the ring rptr-advance gate on live
 * silicon (and, on Navi, on the PSP having authenticated the SDMA ucode).
 *
 * Crib provenance (register sequence; register names are the stable Navi SDMA0
 * ring layout -- NOT invented):
 *   - SDMA ring enable: Linux sdma_v5_0.c sdma_v5_0_gfx_resume /
 *     sdma_v5_0_enable + the mmSDMA0_GFX_RB_* registers
 *   - the ucode load (non-PSP path): sdma_v5_0_load_microcode + mmSDMA0_UCODE_*
 *   - the rptr/wptr writeback: sdma_v5_0_gfx_resume (RB_RPTR_ADDR_*)
 */

#include <sys/types.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/cmn_err.h>

#include "amdgpu_priv.h"
#include "ttm_priv.h"
#include "amdgpu_ip.h"
#include "amdgpu_ucode.h"
#include "amdgpu_psp.h"
#include "amdgpu_hw.h"

/*
 * SDMA0 ring register offsets (crib: sdma_v5_0.c + the Navi SDMA0 register
 * spec; stable word indices within the SDMA0 block, which aliases the GC base
 * on Navi -- see C3-c navi12_reg_base_init SDMA0_HWIP = GC base). Reached via
 * amdgpu_reg_offset(sc, SDMA0_HWIP, 0, seg, reg).
 */
#define	mmSDMA0_F32_CNTL		0x0001		/* engine halt/reset */
#define	mmSDMA0_UCODE_ADDR		0x005a
#define	mmSDMA0_UCODE_DATA		0x005b
#define	mmSDMA0_GFX_RB_CNTL		0x0080		/* ring size/enable */
#define	mmSDMA0_GFX_RB_BASE		0x0081		/* ring base lo */
#define	mmSDMA0_GFX_RB_BASE_HI		0x0082		/* ring base hi */
#define	mmSDMA0_GFX_RB_RPTR		0x0083
#define	mmSDMA0_GFX_RB_WPTR		0x0085
#define	mmSDMA0_GFX_RB_RPTR_ADDR_LO	0x0089		/* rptr writeback lo */
#define	mmSDMA0_GFX_RB_RPTR_ADDR_HI	0x0088		/* rptr writeback hi */
#define	mmSDMA0_GFX_DOORBELL		0x0092
#define	mmSDMA0_STATUS_REG		0x0034		/* engine idle status */

/* SDMA0_F32_CNTL / RB_CNTL bits (crib: sdma_v5_0). */
#define	SDMA0_F32_CNTL_HALT		0x00000001u
#define	SDMA0_GFX_RB_CNTL_ENABLE	0x00000001u
#define	SDMA0_GFX_RB_CNTL_RPTR_WB_ENABLE 0x00001000u
#define	SDMA0_GFX_DOORBELL_ENABLE	0x10000000u
#define	SDMA0_STATUS_IDLE		0x00000001u

static uint32_t
sdma_rreg(struct amdgpu_softc *sc, uint32_t reg)
{
	return (amdgpu_rreg32(sc, amdgpu_reg_offset(sc, SDMA0_HWIP, 0, 0, reg)));
}
static void
sdma_wreg(struct amdgpu_softc *sc, uint32_t reg, uint32_t v)
{
	amdgpu_wreg32(sc, amdgpu_reg_offset(sc, SDMA0_HWIP, 0, 0, reg), v);
}

/*
 * amdgpu_sdma_hw_init - the sdma_v5_0 .hw_init: halt the engine, point the ring
 * registers at the C3-c SDMA ring BO + set the rptr writeback address, enable
 * the ring + doorbell, unhalt. Crib: sdma_v5_0_gfx_resume + sdma_v5_0_enable.
 *
 * The rptr writeback address is a writeback-buffer slot the C3-c ring reserved
 * (wb.gpu_addr + rptr_offs*4). HARDWARE-GATED: the unhalt-and-idle confirm
 * (poll SDMA0_STATUS_REG) gates on live silicon; off-hardware it times out.
 */
int
amdgpu_sdma_hw_init(struct amdgpu_softc *sc)
{
	struct amdgpu_ring *ring;
	struct amdgpu_wb *wb;
	uint64_t rptr_wb_addr;
	uint32_t rb_bufsz, cntl;
	int i;

	if (sc->ip == NULL || sc->ip->sdma_ring.ring_obj == NULL)
		return (DDI_FAILURE);
	if (sc->psp == NULL || !sc->psp->initialized)
		return (DDI_FAILURE);		/* ucode not authenticated */

	ring = &sc->ip->sdma_ring;
	wb = &sc->ip->wb;
	rptr_wb_addr = wb->gpu_addr + (uint64_t)ring->rptr_offs * 4;

	/* 1. halt the engine before reprogramming (crib: sdma_v5_0_enable(0)) */
	sdma_wreg(sc, mmSDMA0_F32_CNTL, SDMA0_F32_CNTL_HALT);

	/* 2. ring base + size (log2 dword count) */
	rb_bufsz = 0;
	{
		uint32_t dw = ring->ring_size / 4;
		while ((dw >>= 1) != 0)
			rb_bufsz++;
	}
	sdma_wreg(sc, mmSDMA0_GFX_RB_BASE, (uint32_t)(ring->gpu_addr >> 8));
	sdma_wreg(sc, mmSDMA0_GFX_RB_BASE_HI, (uint32_t)(ring->gpu_addr >> 40));
	sdma_wreg(sc, mmSDMA0_GFX_RB_RPTR, 0);
	sdma_wreg(sc, mmSDMA0_GFX_RB_WPTR, 0);

	/* 3. rptr writeback address (the GPU posts rptr progress here) */
	sdma_wreg(sc, mmSDMA0_GFX_RB_RPTR_ADDR_LO,
	    (uint32_t)(rptr_wb_addr & 0xfffffffcu));
	sdma_wreg(sc, mmSDMA0_GFX_RB_RPTR_ADDR_HI,
	    (uint32_t)(rptr_wb_addr >> 32));

	/* 4. doorbell (crib: sdma_v5_0 RB doorbell) */
	if (ring->use_doorbell)
		sdma_wreg(sc, mmSDMA0_GFX_DOORBELL,
		    SDMA0_GFX_DOORBELL_ENABLE | (ring->doorbell_index << 2));

	/* 5. enable the ring + rptr writeback, then unhalt */
	cntl = (rb_bufsz << 1) | SDMA0_GFX_RB_CNTL_ENABLE |
	    SDMA0_GFX_RB_CNTL_RPTR_WB_ENABLE;
	sdma_wreg(sc, mmSDMA0_GFX_RB_CNTL, cntl);
	sdma_wreg(sc, mmSDMA0_F32_CNTL, 0);	/* clear HALT */

	/* 6. HARDWARE-GATED: wait for the engine to report idle-ready */
	for (i = 0; i < SDMA_HW_TIMEOUT_US; i++) {
		if (sdma_rreg(sc, mmSDMA0_STATUS_REG) & SDMA0_STATUS_IDLE)
			break;
		drv_usecwait(1);
	}
	if (i >= SDMA_HW_TIMEOUT_US) {
		cmn_err(CE_WARN, "?amdgpu: SDMA engine not idle "
		    "(expected off-hardware)");
		return (DDI_FAILURE);
	}

	cmn_err(CE_CONT, "?amdgpu: SDMA hw_init: engine up, SDMA ring "
	    "enabled\n");
	return (DDI_SUCCESS);
}
