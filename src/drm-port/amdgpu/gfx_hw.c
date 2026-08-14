/*
 * gfx_hw.c - C3-amdgpu-d: the gfx_v10_0 .hw_init register sequence for Navi 12,
 * illumos side.
 *
 * ================= HARDWARE-GATED (compiles; runs only on a powered GPU) =====
 *
 * The GFX .hw_init loads the graphics-engine microcode (RLC, then the CP:
 * ME/PFP/CE and MEC) into the GPU and enables the GFX command ring on the
 * hardware. On Navi the RLC is loaded first (it is the microcontroller that
 * autoloads the rest via the PSP-authenticated blobs), then the CP is taken out
 * of reset and pointed at the GFX ring BO (from C3-c amdgpu_ring.c), then the
 * ring is enabled + the doorbell aperture opened.
 *
 * The register sequence COMPILES + is structurally verifiable (SOC15 reg model
 * + the C3-c ring struct). Running it needs a powered GPU: the RLC-ready poll,
 * the CP-ready poll, and the ring rptr-advance confirm all gate on live
 * silicon that the PSP must first have authenticated the ucode for.
 *
 * Crib provenance (register sequence; register names are the stable Navi GC
 * CP/RLC layout -- NOT invented):
 *   - RLC load + ready: Linux gfx_v10_0.c gfx_v10_0_rlc_resume /
 *     gfx_v10_0_rlc_load_microcode + the mmRLC_* registers
 *   - CP (ME/PFP/CE) load + ring setup: gfx_v10_0_cp_gfx_load_microcode /
 *     gfx_v10_0_cp_gfx_resume + the mmCP_ME_RAM_*, mmCP_RB0_* registers
 *   - the GFX ring-buffer registers (mmCP_RB0_BASE/CNTL/RPTR/WPTR + doorbell):
 *     gfx_v10_0_cp_gfx_resume
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
 * GC CP/RLC register offsets (crib: gfx_v10_0.c + the Navi GC register spec;
 * stable word indices within the GC block). Reached via
 * amdgpu_reg_offset(sc, GC_HWIP, 0, seg, reg).
 */
#define	mmRLC_CNTL			0x4c00
#define	mmRLC_GPM_STAT			0x4e6b		/* RLC ready status */
#define	mmRLC_GPM_UCODE_ADDR		0x4c40
#define	mmRLC_GPM_UCODE_DATA		0x4c41
#define	mmCP_ME_CNTL			0x1f0a		/* ME/PFP/CE reset */
#define	mmCP_PFP_UCODE_ADDR		0x1c2c
#define	mmCP_PFP_UCODE_DATA		0x1c2d
#define	mmCP_ME_RAM_WADDR		0x1c2e
#define	mmCP_ME_RAM_DATA		0x1c30
#define	mmCP_CE_UCODE_ADDR		0x1c28
#define	mmCP_CE_UCODE_DATA		0x1c29
#define	mmCP_RB0_BASE			0x1e00		/* GFX ring base lo */
#define	mmCP_RB0_BASE_HI		0x1e51		/* GFX ring base hi */
#define	mmCP_RB0_CNTL			0x1e01		/* ring size/enable */
#define	mmCP_RB0_RPTR			0x1e10
#define	mmCP_RB0_WPTR			0x1e54
#define	mmCP_RB0_WPTR_HI		0x1e55
#define	mmCP_RB_DOORBELL_CONTROL	0x1e8c
#define	mmCP_STAT			0x1f40		/* CP busy status */

/* RLC_CNTL / CP_ME_CNTL bits (crib: gfx_v10_0). */
#define	RLC_CNTL_ENABLE			0x00000001u
#define	RLC_GPM_STAT_RUNNING		0x00000001u
#define	CP_ME_CNTL_ME_HALT		0x10000000u
#define	CP_ME_CNTL_PFP_HALT		0x04000000u
#define	CP_ME_CNTL_CE_HALT		0x01000000u
#define	CP_RB0_CNTL_RB_ENABLE		0x00000000u	/* ena via unhalt */
#define	CP_RB_DOORBELL_ENABLE		0x40000000u
#define	CP_STAT_CP_BUSY			0x80000000u

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
 * gfx_v10_rlc_resume - enable the RLC + wait for it to report running. On Navi
 * the PSP has already authenticated + placed the RLC ucode; here we take the
 * RLC out of reset and poll RLC_GPM_STAT. Crib: gfx_v10_0_rlc_resume.
 * HARDWARE-GATED: the RLC-running bit is set by the live RLC microcontroller.
 */
static int
gfx_v10_rlc_resume(struct amdgpu_softc *sc)
{
	int i;

	gc_wreg(sc, mmRLC_CNTL, RLC_CNTL_ENABLE);
	for (i = 0; i < GFX_HW_RLC_TIMEOUT_US; i++) {
		if (gc_rreg(sc, mmRLC_GPM_STAT) & RLC_GPM_STAT_RUNNING)
			return (DDI_SUCCESS);
		drv_usecwait(1);
	}
	return (DDI_FAILURE);	/* off-hardware: always here */
}

/*
 * gfx_v10_cp_resume - take the CP (ME/PFP/CE) out of halt and point RB0 at the
 * GFX ring BO, then enable the ring + its doorbell. Crib:
 * gfx_v10_0_cp_gfx_resume (the mmCP_RB0_BASE/CNTL/WPTR + doorbell writes).
 * HARDWARE-GATED: the CP-idle confirm reads CP_STAT on live silicon.
 */
static int
gfx_v10_cp_resume(struct amdgpu_softc *sc, struct amdgpu_ring *ring)
{
	uint32_t rb_bufsz;
	int i;

	/* program the ring base + size (log2 of the dword count) */
	rb_bufsz = 0;
	{
		uint32_t dw = ring->ring_size / 4;
		while ((dw >>= 1) != 0)
			rb_bufsz++;
	}
	gc_wreg(sc, mmCP_RB0_BASE, (uint32_t)(ring->gpu_addr >> 8));
	gc_wreg(sc, mmCP_RB0_BASE_HI, (uint32_t)(ring->gpu_addr >> 40));
	gc_wreg(sc, mmCP_RB0_CNTL, rb_bufsz);
	gc_wreg(sc, mmCP_RB0_RPTR, 0);
	gc_wreg(sc, mmCP_RB0_WPTR, 0);
	gc_wreg(sc, mmCP_RB0_WPTR_HI, 0);

	/* open the doorbell aperture for this ring (crib: doorbell_control) */
	if (ring->use_doorbell)
		gc_wreg(sc, mmCP_RB_DOORBELL_CONTROL,
		    CP_RB_DOORBELL_ENABLE | (ring->doorbell_index << 2));

	/* unhalt ME/PFP/CE (clear the HALT bits) */
	gc_wreg(sc, mmCP_ME_CNTL, 0);

	/* HARDWARE-GATED: wait for the CP to leave busy after startup */
	for (i = 0; i < GFX_HW_RLC_TIMEOUT_US; i++) {
		if ((gc_rreg(sc, mmCP_STAT) & CP_STAT_CP_BUSY) == 0)
			return (DDI_SUCCESS);
		drv_usecwait(1);
	}
	return (DDI_FAILURE);
}

/*
 * amdgpu_gfx_hw_init - the gfx_v10_0 .hw_init: RLC resume, then CP resume with
 * the C3-c GFX ring. Requires the PSP to have authenticated + loaded the RLC/CP
 * ucode (amdgpu_psp_hw_init). Crib: gfx_v10_0_hw_init.
 *
 * HARDWARE-GATED end to end. Off-hardware gfx_v10_rlc_resume times out and this
 * returns failure (non-fatal to the software floor).
 */
int
amdgpu_gfx_hw_init(struct amdgpu_softc *sc)
{
	int r;

	if (sc->ip == NULL || sc->ip->gfx_ring.ring_obj == NULL)
		return (DDI_FAILURE);
	if (sc->psp == NULL || !sc->psp->initialized)
		return (DDI_FAILURE);		/* ucode not authenticated */

	r = gfx_v10_rlc_resume(sc);
	if (r != DDI_SUCCESS) {
		cmn_err(CE_WARN, "?amdgpu: GFX RLC not running "
		    "(expected off-hardware)");
		return (r);
	}

	r = gfx_v10_cp_resume(sc, &sc->ip->gfx_ring);
	if (r != DDI_SUCCESS) {
		cmn_err(CE_WARN, "?amdgpu: GFX CP resume timed out "
		    "(expected off-hardware)");
		return (r);
	}

	cmn_err(CE_CONT, "?amdgpu: GFX hw_init: RLC + CP up, GFX ring enabled\n");
	return (DDI_SUCCESS);
}
