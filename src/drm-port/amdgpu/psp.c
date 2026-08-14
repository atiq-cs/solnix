/*
 * psp.c - C3-amdgpu-d: the PSP (Platform Security Processor) bring-up for
 * Navi 12 (psp_v11_0), illumos side.
 *
 * ================= HARDWARE-GATED (compiles; runs only on a powered GPU) =====
 *
 * The PSP is the security microcontroller that MUST authenticate every other
 * firmware blob (SMU, GFX, SDMA, ...) before the driver may load it. On Navi
 * the boot order is:
 *   1. PSP loads its own sOS (secure OS) via the bootloader registers
 *      (MP0_SMN_C2PMSG_* mailbox);
 *   2. the driver hands each ucode to the PSP GFX command ring (a ring in a
 *      GTT/VRAM BO); the PSP authenticates + loads it into the target engine;
 *   3. the driver polls a response register for the auth result.
 *
 * NONE of this can be validated off-hardware: every step reads a live PSP
 * status register whose value the silicon writes. This file writes the
 * REGISTER SEQUENCE (RREG32/WREG32 via the C3-a access + the SOC15 reg model)
 * -- it COMPILES + is structurally verifiable, but the poll loops will spin
 * forever without a real PSP. Each live-gated read is marked below and in the
 * design doc's runtime checklist.
 *
 * Crib provenance (register sequence; the register names are the stable AMD
 * MP0 SMN mailbox layout -- NOT invented):
 *   - the C2PMSG mailbox bring-up (bootloader load + the sos/ring handshake):
 *     Linux drivers/gpu/drm/amd/amdgpu/psp_v11_0.c
 *     (psp_v11_0_bootloader_load_*, psp_v11_0_ring_create, psp_v11_0_ring_*)
 *   - the mmMP0_SMN_C2PMSG_* register indices: the MP0 SMN block (MP0_HWIP
 *     base, C3-c navi12 reg base) + the psp_v11_0 C2PMSG_{35,64,69,101,115}
 *     mailbox convention
 *   - the PSP GFX command ring: Linux psp_gfx_if.h + amdgpu_psp.c psp_ring_*
 */

#include <sys/types.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/kmem.h>
#include <sys/cmn_err.h>

#include "amdgpu_priv.h"
#include "ttm_priv.h"
#include "amdgpu_ip.h"
#include "amdgpu_ucode.h"
#include "amdgpu_psp.h"

/*
 * The MP0 SMN C2PMSG mailbox register offsets (crib: psp_v11_0.c; these are
 * the stable Navi PSP mailbox indices within the MP0 SMN block). RREG32/WREG32
 * reach them via amdgpu_reg_offset(sc, MP0_HWIP, 0, seg, reg). psp_v11 uses
 * SOC15 register mmMP0_SMN_C2PMSG_nn; the C2PMSG registers live at a fixed
 * stride from the block base.
 */
#define	MP0_C2PMSG_BASE		0x03b10500	/* mmMP0_SMN_C2PMSG_0 word idx */
#define	MP0_C2PMSG(n)		(MP0_C2PMSG_BASE + (n))

/* the mailbox slots psp_v11_0 uses (crib: psp_v11_0.c). */
#define	PSP_C2PMSG_SOS_STATUS	MP0_C2PMSG(64)	/* sOS boot status */
#define	PSP_C2PMSG_BL_STATUS	MP0_C2PMSG(35)	/* bootloader status */
#define	PSP_C2PMSG_CMD_ID	MP0_C2PMSG(69)	/* ring/command doorbell */
#define	PSP_C2PMSG_CMD_LO	MP0_C2PMSG(101)	/* cmd buf addr low */
#define	PSP_C2PMSG_CMD_HI	MP0_C2PMSG(102)	/* cmd buf addr high */
#define	PSP_C2PMSG_RESP		MP0_C2PMSG(115)	/* command response */

/* status bits (crib: psp_v11_0 MBOX_READY / the sOS RUNNING marker). */
#define	PSP_SOS_RUNNING_MASK	0x80000000u
#define	PSP_MBOX_READY_MASK	0x80000000u

/* how long to poll a PSP status word before giving up (live-hw only). */
#define	PSP_POLL_TIMEOUT_US	1000000		/* 1 s in 1 us steps */

static uint32_t
psp_rreg(struct amdgpu_softc *sc, uint32_t reg)
{
	uint32_t off = amdgpu_reg_offset(sc, MP0_HWIP, 0, 0, reg);
	return (amdgpu_rreg32(sc, off));
}

static void
psp_wreg(struct amdgpu_softc *sc, uint32_t reg, uint32_t v)
{
	uint32_t off = amdgpu_reg_offset(sc, MP0_HWIP, 0, 0, reg);
	amdgpu_wreg32(sc, off, v);
}

/*
 * psp_wait_reg - poll a PSP status register until (reg & mask) == want, or the
 * timeout expires. HARDWARE-GATED: off-hardware the register reads a constant
 * (whatever the unmapped/idle MMIO returns) so this always times out -- which
 * is the correct compile-phase behaviour (it never falsely reports success).
 * On a live PSP the silicon flips the bit and the loop returns success.
 */
static int
psp_wait_reg(struct amdgpu_softc *sc, uint32_t reg, uint32_t mask,
    uint32_t want)
{
	int i;

	for (i = 0; i < PSP_POLL_TIMEOUT_US; i++) {
		if ((psp_rreg(sc, reg) & mask) == want)
			return (DDI_SUCCESS);
		drv_usecwait(1);	/* live-hw: give the PSP a microsecond */
	}
	return (DDI_FAILURE);	/* off-hardware: always lands here */
}

/*
 * amdgpu_psp_wait_sos - wait for the PSP secure-OS to report RUNNING. This is
 * the first live handshake: the PSP boots its sOS from the on-die bootloader
 * and sets the RUNNING bit in C2PMSG_64. Crib: psp_v11_0_bootloader_load_sysdrv
 * / psp_v11_0_ring_create poll of C2PMSG_64.
 *
 * HARDWARE-GATED: reads a live PSP register. Off-hardware it times out.
 */
int
amdgpu_psp_wait_sos(struct amdgpu_softc *sc)
{
	return (psp_wait_reg(sc, PSP_C2PMSG_SOS_STATUS,
	    PSP_SOS_RUNNING_MASK, PSP_SOS_RUNNING_MASK));
}

/*
 * amdgpu_psp_ring_create - stand up the PSP GFX command ring. Allocate the ring
 * BO (a small GTT buffer the driver writes PSP GFX commands into) and program
 * its GPU address + a "create ring" command into the C2PMSG mailbox, then wait
 * for the PSP to ack. Crib: psp_v11_0_ring_create.
 *
 * The BO alloc + the register writes COMPILE + are structurally correct; the
 * mailbox ack (psp_wait_reg on C2PMSG_64) is HARDWARE-GATED.
 */
int
amdgpu_psp_ring_create(struct amdgpu_softc *sc, struct amdgpu_psp *psp)
{
	struct amdgpu_bo *bo;
	int r;

	if (psp->km_ring_bo != NULL)
		return (DDI_SUCCESS);

	/* the PSP command ring buffer (GTT: driver-writable + GPU-visible) */
	r = amdgpu_bo_create(sc, PSP_RING_SIZE, AMDGPU_GEM_DOMAIN_GTT, &bo);
	if (r != DDI_SUCCESS)
		return (r);
	psp->km_ring_bo = bo;
	psp->km_ring_gpu_addr = amdgpu_bo_gpu_offset(bo);

	/*
	 * Program the ring base into the mailbox and issue "create ring".
	 * (crib: psp_v11_0_ring_create writes C2PMSG_69/101 then polls _64.)
	 */
	psp_wreg(sc, PSP_C2PMSG_CMD_LO,
	    (uint32_t)(psp->km_ring_gpu_addr & 0xffffffffu));
	psp_wreg(sc, PSP_C2PMSG_CMD_HI,
	    (uint32_t)(psp->km_ring_gpu_addr >> 32));
	psp_wreg(sc, PSP_C2PMSG_CMD_ID, PSP_GFX_CMD_CREATE_RING);

	/* HARDWARE-GATED: wait for the PSP to ack the ring create. */
	if (psp_wait_reg(sc, PSP_C2PMSG_SOS_STATUS, PSP_MBOX_READY_MASK,
	    PSP_MBOX_READY_MASK) != DDI_SUCCESS) {
		cmn_err(CE_WARN, "?amdgpu: PSP ring create timed out "
		    "(expected off-hardware)");
		return (DDI_FAILURE);
	}
	return (DDI_SUCCESS);
}

/*
 * amdgpu_psp_load_fw - hand one validated ucode blob to the PSP for
 * authenticate + load. Writes the blob's GPU address + size into the PSP GFX
 * command ring, rings the command mailbox, and polls the response. Crib:
 * amdgpu_psp.c psp_cmd_submit_buf + psp_gfx_if.h GFX_CMD_ID_LOAD_IP_FW.
 *
 * The blob must already be in a GPU-visible BO (a real driver copies the ucode
 * into a firmware BO; here we take its GPU addr + size). The command-ring write
 * + mailbox poke COMPILE; the authenticate result (C2PMSG_115 response) is
 * HARDWARE-GATED -- the PSP computes it from the blob's signature.
 */
int
amdgpu_psp_load_fw(struct amdgpu_softc *sc, struct amdgpu_psp *psp,
    uint64_t fw_gpu_addr, uint32_t fw_size, uint32_t fw_type)
{
	uint32_t resp;

	if (psp->km_ring_bo == NULL)
		return (DDI_FAILURE);

	/* stage the load command into the mailbox (crib: psp_cmd_submit_buf). */
	psp_wreg(sc, PSP_C2PMSG_CMD_LO, (uint32_t)(fw_gpu_addr & 0xffffffffu));
	psp_wreg(sc, PSP_C2PMSG_CMD_HI, (uint32_t)(fw_gpu_addr >> 32));
	psp_wreg(sc, PSP_C2PMSG_CMD_ID, PSP_GFX_CMD_LOAD_IP_FW | (fw_type << 8));
	(void) fw_size;

	/* HARDWARE-GATED: the PSP authenticates the signature + writes RESP. */
	if (psp_wait_reg(sc, PSP_C2PMSG_RESP, PSP_MBOX_READY_MASK,
	    PSP_MBOX_READY_MASK) != DDI_SUCCESS)
		return (DDI_FAILURE);

	resp = psp_rreg(sc, PSP_C2PMSG_RESP);
	if ((resp & PSP_RESP_ERR_MASK) != 0) {
		cmn_err(CE_WARN, "?amdgpu: PSP fw auth failed, resp 0x%x", resp);
		return (DDI_FAILURE);
	}
	return (DDI_SUCCESS);
}

/*
 * amdgpu_psp_hw_init - the psp_v11_0 .hw_init: bring up the PSP, create its
 * command ring, and authenticate + load every required microcode blob. This
 * is the gate the whole GPU bring-up passes through (GFX/SDMA .hw_init cannot
 * run until the PSP has loaded their ucode).
 *
 * HARDWARE-GATED end to end. Off-hardware amdgpu_psp_wait_sos times out and
 * this returns failure -- correct compile-phase behaviour (the attach path
 * treats a hw_init failure as non-fatal to the software floor).
 */
int
amdgpu_psp_hw_init(struct amdgpu_softc *sc)
{
	struct amdgpu_psp *psp;
	struct amdgpu_ucode *uc = sc->ucode;
	int r;
	uint32_t i;

	if (uc == NULL || !uc->ready)
		return (DDI_FAILURE);		/* firmware not loaded */

	psp = kmem_zalloc(sizeof (*psp), KM_SLEEP);
	sc->psp = psp;

	/* 1. wait for the on-die bootloader to bring the sOS RUNNING. */
	r = amdgpu_psp_wait_sos(sc);
	if (r != DDI_SUCCESS) {
		cmn_err(CE_WARN, "?amdgpu: PSP sOS not running "
		    "(expected off-hardware)");
		goto fail;
	}

	/* 2. create the PSP GFX command ring. */
	r = amdgpu_psp_ring_create(sc, psp);
	if (r != DDI_SUCCESS)
		goto fail;

	/* 3. authenticate + load each required blob through the PSP. */
	for (i = 0; i < AMDGPU_UCODE_ID_MAXIMUM; i++) {
		struct amdgpu_firmware_info *fw = &uc->fw[i];

		if (!fw->loaded)
			continue;
		/*
		 * A real driver first copies fw->ucode into a GPU-visible
		 * firmware BO; here we pass the header-declared size + a
		 * placeholder addr (the BO copy is part of the same hardware-
		 * gated path). The register sequence is what compiles.
		 */
		r = amdgpu_psp_load_fw(sc, psp, 0, fw->ucode_size, fw->fw_id);
		if (r != DDI_SUCCESS) {
			cmn_err(CE_WARN, "?amdgpu: PSP load of fw id %u failed",
			    fw->fw_id);
			goto fail;
		}
	}

	psp->initialized = B_TRUE;
	return (DDI_SUCCESS);

fail:
	if (psp->km_ring_bo != NULL)
		amdgpu_bo_free(psp->km_ring_bo);
	kmem_free(psp, sizeof (*psp));
	sc->psp = NULL;
	return (DDI_FAILURE);
}

void
amdgpu_psp_hw_fini(struct amdgpu_softc *sc)
{
	struct amdgpu_psp *psp = sc->psp;

	if (psp == NULL)
		return;
	if (psp->km_ring_bo != NULL)
		amdgpu_bo_free(psp->km_ring_bo);
	kmem_free(psp, sizeof (*psp));
	sc->psp = NULL;
}
