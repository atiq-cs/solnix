/*
 * amdgpu_priv.h - the C3-amdgpu-a softc + register/BAR/asic model, illumos side.
 *
 * The amdgpu analogue of virtio_gpu_priv.h: a per-instance softc that a raw
 * PCI attach (NOT the virtio bus -- amdgpu is a bare PCI GPU) fills in. Where
 * the Linux/NetBSD amdgpu driver holds `struct amdgpu_device *adev` with a
 * `struct pci_dev *pdev` + `void __iomem *rmmio` (or NetBSD's
 * bus_space_tag/handle rmmiot/rmmioh), the illumos side holds the DDI
 * equivalents:
 *
 *   Linux/NetBSD adev field         illumos amdgpu_softc field
 *   -----------------------------   --------------------------------------
 *   pdev (struct pci_dev)           dip (dev_info_t) + pci_config_handle_t
 *   adev->rmmio  / rmmiot,rmmioh    rmmio_hdl (ddi_acc_handle_t) + rmmio_base
 *   adev->rmmio_size                rmmio_size
 *   adev->gmc.aper_base (VRAM BAR0) vram_hdl + vram_base + vram_size
 *   RREG32(reg)  (bus_space_read_4) ddi_get32(rmmio_hdl, base + 4*reg)
 *   WREG32(reg,v)(bus_space_write_4)ddi_put32(rmmio_hdl, base + 4*reg, v)
 *   adev->asic_type (enum)          asic_type (CHIP_NAVI12 for the V520)
 *   pdev->device / ->vendor         pci_vid / pci_did (config space)
 *
 * This is compile-phase scaffolding: it attaches to the AMD GPU PCI id, maps
 * the BARs, and reads the asic id. It does NOT bring up any IP block. The full
 * amdgpu_device_init IP-init chain (amdgpu_device_ip_early_init ->
 * nv_set_ip_blocks -> navi12_reg_base_init) is the crib in
 * ../amdgpu-ref/src/amdgpu_device.c + amdgpu_nv.c; see design-gpu-amdgpu.md.
 */

#ifndef _AMDGPU_PRIV_H_
#define _AMDGPU_PRIV_H_

#include <sys/types.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/pci.h>

/*
 * The AMD GPU PCI identity for the g4ad target (EC2, Radeon Pro V520).
 * From ../amdgpu-ref/src/amdgpu_drv.c:1018-1019:
 *   {0x1002, 0x7360, ..., CHIP_NAVI12|AMD_EXP_HW_SUPPORT}
 *   {0x1002, 0x7362, ..., CHIP_NAVI12|AMD_EXP_HW_SUPPORT}
 */
#define	AMDGPU_PCI_VENDOR_AMD	0x1002
#define	AMDGPU_PCI_DEV_NAVI12_A	0x7360
#define	AMDGPU_PCI_DEV_NAVI12_B	0x7362	/* the V520 */

/*
 * amd_asic_type subset (the full enum is amd/include/amd_shared.h in the crib).
 * Only CHIP_NAVI12 is load-bearing for the V520; CHIP_LAST bounds the range.
 */
enum amdgpu_asic_type {
	CHIP_NAVI10 = 24,
	CHIP_NAVI14,
	CHIP_NAVI12,		/* the g4ad V520 target (gfx1011) */
	CHIP_LAST,
};

/*
 * BAR layout for Navi (>= CHIP_BONAIRE), from amdgpu_device.c device-init:
 *   BAR0 = VRAM aperture (the framebuffer / visible VRAM window)
 *   BAR2 = doorbell
 *   BAR5 = MMIO registers (rmmio) -- what RREG32/WREG32 index into
 * (pre-Bonaire asics put MMIO in BAR2; the V520 is Navi so BAR5.)
 */
#define	AMDGPU_BAR_VRAM		0
#define	AMDGPU_BAR_DOORBELL	2
#define	AMDGPU_BAR_MMIO		5

/*
 * ddi_regs_map_setup uses 1-based rnumber (rnumber 0 == PCI config space,
 * rnumber 1 == the first BAR = BAR0, etc). So BARn -> rnumber (n+1).
 */
#define	AMDGPU_RNUM(bar)	((bar) + 1)

/*
 * struct amdgpu_softc - one attached AMD GPU. The reduced adev.
 */
struct amdgpu_softc {
	dev_info_t		*dip;
	struct drm_device	*drm;		/* back-pointer to the C1 drm_device */

	/* PCI config space */
	ddi_acc_handle_t	pci_conf;	/* pci_config_setup handle */
	uint16_t		pci_vid;	/* 0x1002 */
	uint16_t		pci_did;	/* 0x7362 for the V520 */
	uint8_t			pci_rev;

	/* MMIO register aperture (BAR5) -- RREG32/WREG32 target */
	ddi_acc_handle_t	rmmio_hdl;
	caddr_t			rmmio_base;
	off_t			rmmio_size;

	/* VRAM aperture (BAR0) -- the discrete-VRAM window (the TTM VRAM manager) */
	ddi_acc_handle_t	vram_hdl;
	caddr_t			vram_base;
	off_t			vram_size;

	/* interrupt (MSI/MSI-X) */
	ddi_intr_handle_t	*intr_htable;
	int			intr_count;
	int			intr_cap;

	enum amdgpu_asic_type	asic_type;	/* CHIP_NAVI12 */

	/* C3-amdgpu-b TTM: the VRAM (vmem/BAR0) + GTT (ddi_dma) managers */
	struct ttm_device	*ttm;		/* NULL until amdgpu_ttm_init */

	/* C3-amdgpu-c IP blocks: reg_offset table + GMC + GFX/SDMA/IH rings */
	struct amdgpu_ip	*ip;		/* NULL until amdgpu_ip_blocks_init */

	/* C3-amdgpu-d: microcode (firmware(9F) blobs) + PSP bring-up state */
	struct amdgpu_ucode	*ucode;		/* NULL until amdgpu_ucode_init */
	struct amdgpu_psp	*psp;		/* NULL until amdgpu_psp_hw_init */
};

/* the register access primitives -- the RREG32/WREG32 illumos mapping */
extern uint32_t	amdgpu_rreg32(struct amdgpu_softc *, uint32_t reg);
extern void	amdgpu_wreg32(struct amdgpu_softc *, uint32_t reg, uint32_t v);

/* attach/detach, called from the C1 drm_attach the way virtio-gpu is */
extern struct amdgpu_softc *amdgpu_transport_attach(dev_info_t *, struct drm_device *);
extern void	amdgpu_transport_detach(struct amdgpu_softc *);

/* C3-amdgpu-b: the TTM device is defined in ttm_priv.h (included by ttm.c /
 * amdgpu_ttm.c). Forward-declared here so the softc can hold a pointer. */
struct ttm_device;

/* C3-amdgpu-c: the IP-block aggregate (reg_offset + GMC + rings + IH) is
 * defined in amdgpu_ip.h. Forward-declared so the softc can hold a pointer. */
struct amdgpu_ip;

/* C3-amdgpu-d: the microcode store (amdgpu_ucode.h) + the PSP context
 * (amdgpu_psp.h). Forward-declared so the softc can hold pointers. */
struct amdgpu_ucode;
struct amdgpu_psp;

#endif	/* _AMDGPU_PRIV_H_ */
