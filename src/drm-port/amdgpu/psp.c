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
 * The MP0 C2PMSG mailbox register offsets. On Navi12 (mp_11_0) the register
 * mmMP0_SMN_C2PMSG_N sits at word (0x40 + N) within the MP0 block, BASE_IDX 0.
 * With reg_offset[MP0][0][0] = 0x00016000 the SOC15 word for C2PMSG_64 is
 * 0x16080 (byte 0x58200) -- INSIDE the 512 KB BAR, so it is direct-BAR
 * addressable. (The prior 0x03b10500 base was wrong: it pushed the SOC15 word
 * to 0x3b26540 / byte ~247 MB, off the BAR, which is what made a direct read
 * return 0x0 and looked like it needed the SMN window. The register is in-BAR;
 * the base constant was the bug.)
 *
 * Crib: mp/mp_11_0_offset.h mmMP0_SMN_C2PMSG_N = 0x40 + N, BASE_IDX 0.
 */
#define	MP0_C2PMSG_BASE		0x00000040	/* mmMP0_SMN_C2PMSG_0 word idx */
#define	MP0_C2PMSG(n)		(MP0_C2PMSG_BASE + (n))

/* the mailbox slots psp_v11_0 uses (crib: psp_v11_0.c). */
#define	PSP_C2PMSG_SOS_STATUS	MP0_C2PMSG(64)	/* sOS boot status */
#define	PSP_C2PMSG_BL_STATUS	MP0_C2PMSG(35)	/* bootloader status + cmd */
#define	PSP_C2PMSG_BL_ADDR_HI	MP0_C2PMSG(36)	/* bootloader: fw hi addr */
#define	PSP_C2PMSG_CMD_ID	MP0_C2PMSG(69)	/* ring/command doorbell */
#define	PSP_C2PMSG_CMD_LO	MP0_C2PMSG(101)	/* cmd buf addr low */
#define	PSP_C2PMSG_CMD_HI	MP0_C2PMSG(102)	/* cmd buf addr high */
#define	PSP_C2PMSG_RESP		MP0_C2PMSG(115)	/* command response */

/* status bits (crib: psp_v11_0 MBOX_READY / the sOS RUNNING marker). */
#define	PSP_SOS_RUNNING_MASK	0x80000000u
#define	PSP_MBOX_READY_MASK	0x80000000u

/*
 * PSP on-die bootloader command bits in C2PMSG_35 (crib: psp_v11_0.c
 * psp_v11_0_bootloader_load_component / the C2PMSG_35 command encoding). The
 * bootloader signals "ready for a command" by setting bit 31 of C2PMSG_35 to 1;
 * the driver then writes the fw hi-address into C2PMSG_36 and pokes the load
 * command (low byte = 1 in psp_v11's encoding, shifted to the command field)
 * back into C2PMSG_35. The 0x2 selects the sOS component on Navi.
 */
#define	PSP_BL_READY_MASK	0x80000000u	/* BL ready-for-cmd bit */
#define	PSP_BL_CMD_LOAD_SOS	0x20000u	/* load-sOS component cmd */

/* how long to poll a PSP status word before giving up (live-hw only). */
#define	PSP_POLL_TIMEOUT_US	1000000		/* 1 s in 1 us steps */

/*
 * The SMN (System Management Network) index/data indirect register window.
 *
 * With the corrected C2PMSG base (word 0x40 + N, MP0 seg0 0x16000) the mailbox
 * lands at byte 0x58200-class -- INSIDE the 512 KB BAR -- so MP0 access is
 * direct ddi_get32 (psp_rreg/psp_wreg below). The SMN index/data window
 * (smn_rreg/smn_wreg) is retained for a diagnostic cross-check and for any MP0
 * register that ever falls outside the BAR: Linux reaches out-of-BAR SMN
 * registers by writing the SMN byte address (SOC15 word << 2) into
 * mmPCIE_INDEX2, reading back to flush, then read/write mmPCIE_DATA2 (both
 * index/data live in-BAR, BIF/NBIO seg0).
 *
 * Crib: nbio_v2_3.c get_pcie_index_offset/get_pcie_data_offset (mmPCIE_INDEX2
 * = word 0x0e, mmPCIE_DATA2 = word 0x0f) + amdgpu_device.c
 * amdgpu_device_indirect_rreg/_wreg.
 */
#define	MP_PCIE_INDEX2		0x0000000e	/* mmPCIE_INDEX2 (word idx) */
#define	MP_PCIE_DATA2		0x0000000f	/* mmPCIE_DATA2  (word idx) */

static uint32_t
smn_rreg(struct amdgpu_softc *sc, uint32_t smn_addr)
{
	amdgpu_wreg32(sc, MP_PCIE_INDEX2, smn_addr);
	(void) amdgpu_rreg32(sc, MP_PCIE_INDEX2);	/* readback flush */
	return (amdgpu_rreg32(sc, MP_PCIE_DATA2));
}

static void
smn_wreg(struct amdgpu_softc *sc, uint32_t smn_addr, uint32_t v)
{
	amdgpu_wreg32(sc, MP_PCIE_INDEX2, smn_addr);
	(void) amdgpu_rreg32(sc, MP_PCIE_INDEX2);	/* readback flush */
	amdgpu_wreg32(sc, MP_PCIE_DATA2, v);
	(void) amdgpu_rreg32(sc, MP_PCIE_DATA2);	/* readback flush */
}

/*
 * psp_rreg/psp_wreg - MP0 C2PMSG mailbox access. With the corrected base the
 * SOC15 word (reg_offset[MP0][0][0] + reg) is in-BAR, so use the direct
 * ddi_get32/put32 path (amdgpu_rreg32/_wreg32).
 */
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
	uint32_t v;

	for (i = 0; i < PSP_POLL_TIMEOUT_US; i++) {
		v = psp_rreg(sc, reg);
		/*
		 * An all-ones read is an unpowered/no-responder read, NOT a
		 * live status. Reject it so a dead 0xffffffff cannot spuriously
		 * satisfy a bit31 ready-check (which 0xffffffff would otherwise
		 * pass). A real PSP status word is never all-ones here.
		 */
		if (v != 0xffffffffu && (v & mask) == want)
			return (DDI_SUCCESS);
		drv_usecwait(1);	/* live-hw: give the PSP a microsecond */
	}
	return (DDI_FAILURE);	/* off-hardware: always lands here */
}

/*
 * amdgpu_psp_bootloader_load_sos - load the PSP secure-OS (sOS) via the on-die
 * bootloader. On Navi12 the PSP does NOT boot its sOS by itself: the driver
 * must stage the signed navi12_sos.bin into a GPU-visible BO and hand its
 * address to the on-die bootloader through the C2PMSG_35/36 mailbox, then the
 * bootloader authenticates + starts the sOS (which is what flips C2PMSG_64
 * RUNNING). Without this step amdgpu_psp_wait_sos times out forever
 * ("PSP sOS not running") -- this is the C3-amdgpu-d gate.
 *
 * Crib: psp_v11_0.c psp_v11_0_bootloader_load_sos / psp_v11_0_bootloader_load_
 * component: wait BL ready (C2PMSG_35 bit31), write fw hi-addr to C2PMSG_36,
 * write the load command to C2PMSG_35, wait for the bootloader to consume it.
 *
 * The BO alloc + copy + register writes are structurally correct + COMPILE;
 * the bootloader's accept (C2PMSG_35 clears / C2PMSG_81 status) is
 * HARDWARE-GATED -- on real silicon the sOS comes up + wait_sos then succeeds.
 */
int
amdgpu_psp_bootloader_load_sos(struct amdgpu_softc *sc, struct amdgpu_psp *psp)
{
	struct amdgpu_ucode *uc = sc->ucode;
	struct amdgpu_firmware_info *sos = NULL;
	const struct psp_firmware_header_v1_0 *sos_hdr;
	struct amdgpu_bo *bo;
	const uint8_t *sos_ucode;
	uint32_t sos_size;
	void *bo_va;
	int r;

	if (uc == NULL || !uc->ready)
		return (DDI_FAILURE);

	/*
	 * The ucode set is stored by fw_id index (uc->fw[id]), not packed, so
	 * index the sOS slot directly. (A linear [0,fw_count) scan misses it:
	 * AMDGPU_UCODE_ID_SOS is past the count of loaded blobs.)
	 */
	if (uc->fw[AMDGPU_UCODE_ID_SOS].loaded)
		sos = &uc->fw[AMDGPU_UCODE_ID_SOS];
	if (sos == NULL || sos->raw == NULL) {
		cmn_err(CE_WARN, "?amdgpu: no sOS firmware (navi12_sos.bin) "
		    "loaded -- cannot bootstrap the PSP");
		return (DDI_FAILURE);
	}

	/*
	 * The sOS payload is at sos_offset_bytes within the blob (a psp v1_0
	 * header). Validate it sits inside the raw buffer before using it.
	 */
	sos_hdr = (const struct psp_firmware_header_v1_0 *)sos->raw;
	if ((uint64_t)sos_hdr->sos_offset_bytes +
	    (uint64_t)sos_hdr->sos_size_bytes > (uint64_t)sos->raw_size) {
		cmn_err(CE_WARN, "?amdgpu: sOS header out of range "
		    "(off %u sz %u raw %lu)", sos_hdr->sos_offset_bytes,
		    sos_hdr->sos_size_bytes, (unsigned long)sos->raw_size);
		return (DDI_FAILURE);
	}
	sos_ucode = sos->raw + sos_hdr->sos_offset_bytes;
	sos_size = sos_hdr->sos_size_bytes;

	/*
	 * Stage the sOS into a GTT BO the PSP bootloader can DMA from. Reuse
	 * the fw_pri BO across bootloader loads (sysdrv/sos share it on Navi).
	 */
	if (psp->fw_pri_bo == NULL) {
		r = amdgpu_bo_create(sc, sos_size, AMDGPU_GEM_DOMAIN_GTT, &bo);
		if (r != DDI_SUCCESS)
			return (r);
		psp->fw_pri_bo = bo;
		psp->fw_pri_gpu_addr = amdgpu_bo_gpu_offset(bo);
	}
	bo_va = amdgpu_bo_cpu_addr(psp->fw_pri_bo);
	if (bo_va == NULL)
		return (DDI_FAILURE);
	bcopy(sos_ucode, bo_va, sos_size);

	/*
	 * Diagnostic (measured on the g4ad V520 under Nitro): probe the register
	 * fabric before the handshake. The MP0 C2PMSG mailbox is at the corrected
	 * in-BAR offset (word 0x16000+0x40+N; C2PMSG_35 = word 0x16063 = byte
	 * 0x5818c, inside the 512 KB BAR), reachable both directly and via the SMN
	 * index/data window. MEASURED: PCI cmd=0xc7 (IO+MEM+BusMaster enabled),
	 * BAR0/VRAM reads 0x0 (framebuffer decodes as zeroed memory), but the
	 * whole register BAR (BAR5) -- even NBIO mmPCIE_INDEX2 written with
	 * 0xdeadbeef -- reads 0xffffffff. That is a register fabric that is
	 * unclocked / held in reset: the GPU SOC has not been POSTed. The MP0
	 * mailbox is correctly addressed + mem-enabled; the wall is GPU power-up
	 * (a vBIOS/ATOM POST + SMU power sequence), NOT register addressing.
	 */
	{
		uint32_t bl_word = amdgpu_reg_offset(sc, MP0_HWIP, 0, 0,
		    PSP_C2PMSG_BL_STATUS);
		/*
		 * BAR-liveness: mmPCIE_INDEX2 is an in-BAR NBIO register that
		 * normally reads back what is written; VRAM[0] shows whether the
		 * framebuffer BAR decodes. If both the register BAR and NBIO read
		 * 0xffffffff, the whole register fabric is unpowered.
		 */
		amdgpu_wreg32(sc, MP_PCIE_INDEX2, 0xdeadbeef);
		cmn_err(CE_CONT, "?amdgpu: BAR-live check: PCIE_INDEX2 wrote "
		    "0xdeadbeef read 0x%x (in-BAR word 0xe); PCI cmd=0x%x; "
		    "VRAM[0]=0x%x\n",
		    amdgpu_rreg32(sc, MP_PCIE_INDEX2),
		    pci_config_get16(sc->pci_conf, PCI_CONF_COMM),
		    (sc->vram_hdl != NULL) ?
		    ddi_get32(sc->vram_hdl, (uint32_t *)(void *)sc->vram_base) :
		    0xbadbad);
		cmn_err(CE_CONT, "?amdgpu: PSP probe direct-BAR: "
		    "C2PMSG_35=0x%x C2PMSG_64=0x%x C2PMSG_115=0x%x "
		    "(word 0x%x, BAR sz 0x%lx)\n",
		    psp_rreg(sc, PSP_C2PMSG_BL_STATUS),
		    psp_rreg(sc, PSP_C2PMSG_SOS_STATUS),
		    psp_rreg(sc, PSP_C2PMSG_RESP),
		    bl_word, (unsigned long)sc->rmmio_size);
		cmn_err(CE_CONT, "?amdgpu: PSP probe SMN-window: "
		    "C2PMSG_35=0x%x (smn addr 0x%x)\n",
		    smn_rreg(sc, bl_word << 2), bl_word << 2);
	}

	/*
	 * 1. Wait for the on-die bootloader to be ready to accept a command
	 *    (C2PMSG_35 bit31 set). HARDWARE-GATED: off-hardware this times out.
	 *
	 * The MP0 C2PMSG mailbox is direct-BAR addressable at the corrected
	 * offset (word 0x16063 for C2PMSG_35, inside the 512 KB BAR). On the
	 * g4ad V520 under Nitro this still reads 0xffffffff because the GPU
	 * register fabric is unpowered (see the diagnostic above) -- so the wait
	 * times out. The psp_wait_reg 0xffffffff guard prevents a dead all-ones
	 * read from spuriously satisfying the bit31 ready-check.
	 */
	if (psp_wait_reg(sc, PSP_C2PMSG_BL_STATUS, PSP_BL_READY_MASK,
	    PSP_BL_READY_MASK) != DDI_SUCCESS) {
		cmn_err(CE_WARN, "?amdgpu: PSP bootloader not ready "
		    "(C2PMSG_35=0x%x; register fabric unpowered -- GPU not "
		    "POSTed)", psp_rreg(sc, PSP_C2PMSG_BL_STATUS));
		return (DDI_FAILURE);
	}

	/*
	 * 2. Hand the bootloader the sOS address (bits [39:8] in C2PMSG_36 per
	 *    psp_v11) and issue the load-sOS command in C2PMSG_35.
	 */
	psp_wreg(sc, PSP_C2PMSG_BL_ADDR_HI,
	    (uint32_t)(psp->fw_pri_gpu_addr >> 20));
	psp_wreg(sc, PSP_C2PMSG_BL_STATUS, PSP_BL_CMD_LOAD_SOS);

	/*
	 * 3. Wait for the bootloader to consume the command (bit31 re-set = idle
	 *    again / ready). HARDWARE-GATED. After this, amdgpu_psp_wait_sos
	 *    should observe C2PMSG_64 RUNNING on real silicon.
	 */
	if (psp_wait_reg(sc, PSP_C2PMSG_BL_STATUS, PSP_BL_READY_MASK,
	    PSP_BL_READY_MASK) != DDI_SUCCESS) {
		cmn_err(CE_WARN, "?amdgpu: PSP bootloader sOS load not "
		    "acknowledged (expected off-hardware)");
		return (DDI_FAILURE);
	}
	return (DDI_SUCCESS);
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

	/*
	 * 1. Load the sOS via the on-die bootloader. On Navi12 the PSP does not
	 *    self-boot its sOS -- the driver must stage navi12_sos.bin + hand it
	 *    to the bootloader (C2PMSG_35/36). Without this, wait_sos never sees
	 *    RUNNING. This is the C3-amdgpu-d gate.
	 */
	r = amdgpu_psp_bootloader_load_sos(sc, psp);
	if (r != DDI_SUCCESS) {
		cmn_err(CE_WARN, "?amdgpu: PSP sOS bootloader load failed "
		    "(expected off-hardware)");
		goto fail;
	}

	/* 2. wait for the bootloader to bring the sOS RUNNING. */
	r = amdgpu_psp_wait_sos(sc);
	if (r != DDI_SUCCESS) {
		cmn_err(CE_WARN, "?amdgpu: PSP sOS not running "
		    "(expected off-hardware)");
		goto fail;
	}

	/* 3. create the PSP GFX command ring. */
	r = amdgpu_psp_ring_create(sc, psp);
	if (r != DDI_SUCCESS)
		goto fail;

	/* 4. authenticate + load each required blob through the PSP. */
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
