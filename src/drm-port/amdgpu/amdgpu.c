/*
 * amdgpu.c - C3-amdgpu-a: the smallest load-bearing amdgpu device-init piece,
 * compiled against illumos headers + the C1 DRM framework.
 *
 * This is the reduced amdgpu_device_init (../amdgpu-ref/src/amdgpu_device.c:2937)
 * expressed against the illumos DDI, following the C1b virtio_gpu_transport_attach
 * pattern (src/virtio_gpu.c) but for a RAW PCI device -- amdgpu is a bare PCI GPU,
 * not a virtio child, so it uses ddi_regs_map_setup / pci_config_setup / ddi_intr_*
 * directly instead of the illumos virtio framework.
 *
 * What it does (the C3-amdgpu-a milestone -- COMPILE only, does NOT run):
 *   1. attach to the AMD GPU PCI id (1002:7362 = Navi 12 = the g4ad V520);
 *   2. read the asic id from PCI config space (vendor/device/rev) + classify
 *      it as CHIP_NAVI12 (the amdgpu_asic_type the Navi IP path keys off);
 *   3. map the MMIO register BAR (BAR5) + the VRAM aperture BAR (BAR0);
 *   4. provide the RREG32/WREG32 register access (bus_space_read_4 ->
 *      ddi_get32) the whole amdgpu IP stack indexes registers through;
 *   5. allocate an MSI/MSI-X vector (the amdgpu interrupt-handler registration
 *      the IH -- interrupt handler -- ring needs).
 *
 * What it deliberately does NOT do (the crib names each, deferred to later
 * C3-amdgpu phases, see design-gpu-amdgpu.md):
 *   - amdgpu_device_ip_early_init -> nv_set_ip_blocks -> navi12_reg_base_init
 *     (the IP-block table + per-IP-block .early_init): the enormous asic bring-up;
 *   - TTM VRAM/GTT manager (amdgpu_ttm.c): the biggest NEW subsystem vs C1;
 *   - GART page table, firmware (psp) load, the GFX/SDMA/IH rings, DC (display).
 *
 * Every symbol it references is a real illumos DDI export (verified against the
 * kernel symbol table by verify-syms.sh) or a C1 framework symbol; the
 * amdgpu-specific gaps beyond C1's linux-compat shims are enumerated in
 * design-gpu-amdgpu.md (TTM, request_firmware, the IH ring, per-asic ip funcs).
 */

#include <sys/types.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/pci.h>
#include <sys/cmn_err.h>

#include "drm_internal.h"
#include "amdgpu_priv.h"

/*
 * The DDI regs-map access attributes for a PCI memory BAR: little-endian
 * (PCI is LE), no data reordering (device registers are strictly ordered).
 * Same attr the illumos nvme/mlxcx/i40e drivers use for their register BAR.
 */
static ddi_device_acc_attr_t amdgpu_reg_acc = {
	.devacc_attr_version		= DDI_DEVICE_ATTR_V0,
	.devacc_attr_endian_flags	= DDI_STRUCTURE_LE_ACC,
	.devacc_attr_dataorder		= DDI_STRICTORDER_ACC,
};

/*
 * The VRAM aperture BAR is a large framebuffer window; merging + prefetch are
 * fine there (it is memory, not registers), so use DDI_MERGING_OK_ACC.
 */
static ddi_device_acc_attr_t amdgpu_vram_acc = {
	.devacc_attr_version		= DDI_DEVICE_ATTR_V0,
	.devacc_attr_endian_flags	= DDI_NEVERSWAP_ACC,
	.devacc_attr_dataorder		= DDI_MERGING_OK_ACC,
};

/*
 * amdgpu_rreg32 / amdgpu_wreg32 - the RREG32/WREG32 the whole amdgpu IP stack
 * reads registers through. NetBSD's amdgpu_mm_rreg does
 *   bus_space_read_4(adev->rmmiot, adev->rmmioh, 4*reg)
 * (../amdgpu-ref/src/amdgpu_device.c:235); the direct illumos analogue is
 * ddi_get32 on the BAR5 access handle at byte offset (4*reg). Registers are
 * addressed by 32-bit word index, hence the *4.
 */
uint32_t
amdgpu_rreg32(struct amdgpu_softc *sc, uint32_t reg)
{
	/* ddi_get32 wants a uint32_t* into the mapped BAR */
	return (ddi_get32(sc->rmmio_hdl,
	    (uint32_t *)(void *)(sc->rmmio_base + 4 * (off_t)reg)));
}

void
amdgpu_wreg32(struct amdgpu_softc *sc, uint32_t reg, uint32_t v)
{
	ddi_put32(sc->rmmio_hdl,
	    (uint32_t *)(void *)(sc->rmmio_base + 4 * (off_t)reg), v);
}

/*
 * amdgpu_read_asic_id - the asic detection prologue of amdgpu_device_init.
 * Reads vendor/device/rev from PCI config space and classifies the device.
 * The full driver derives asic_type from the pci_driver id-table match's
 * driver_data (amdgpu_drv.c:1018 -> CHIP_NAVI12); here we read config space
 * directly and map the known Navi 12 device ids.
 */
static int
amdgpu_read_asic_id(struct amdgpu_softc *sc)
{
	sc->pci_vid = pci_config_get16(sc->pci_conf, PCI_CONF_VENID);
	sc->pci_did = pci_config_get16(sc->pci_conf, PCI_CONF_DEVID);
	sc->pci_rev = pci_config_get8(sc->pci_conf, PCI_CONF_REVID);

	if (sc->pci_vid != AMDGPU_PCI_VENDOR_AMD)
		return (DDI_FAILURE);

	switch (sc->pci_did) {
	case AMDGPU_PCI_DEV_NAVI12_A:
	case AMDGPU_PCI_DEV_NAVI12_B:
		sc->asic_type = CHIP_NAVI12;
		break;
	default:
		/* an AMD GPU we don't yet classify -- attach refuses it */
		return (DDI_FAILURE);
	}
	return (DDI_SUCCESS);
}

/*
 * amdgpu_map_bars - the "Registers mapping" + VRAM aperture block of
 * amdgpu_device_init (amdgpu_device.c ~3037). For Navi (>= CHIP_BONAIRE) the
 * MMIO registers are BAR5 and VRAM is BAR0. ddi_regs_map_setup rnumber is
 * 1-based over BARs (rnumber 0 = config space), so BARn -> rnumber n+1.
 */
static int
amdgpu_map_bars(struct amdgpu_softc *sc)
{
	(void) ddi_dev_regsize(sc->dip, AMDGPU_RNUM(AMDGPU_BAR_MMIO),
	    &sc->rmmio_size);
	if (ddi_regs_map_setup(sc->dip, AMDGPU_RNUM(AMDGPU_BAR_MMIO),
	    &sc->rmmio_base, 0, 0, &amdgpu_reg_acc,
	    &sc->rmmio_hdl) != DDI_SUCCESS)
		return (DDI_FAILURE);

	(void) ddi_dev_regsize(sc->dip, AMDGPU_RNUM(AMDGPU_BAR_VRAM),
	    &sc->vram_size);
	if (ddi_regs_map_setup(sc->dip, AMDGPU_RNUM(AMDGPU_BAR_VRAM),
	    &sc->vram_base, 0, 0, &amdgpu_vram_acc,
	    &sc->vram_hdl) != DDI_SUCCESS) {
		ddi_regs_map_free(&sc->rmmio_hdl);
		return (DDI_FAILURE);
	}
	return (DDI_SUCCESS);
}

/*
 * amdgpu_setup_intr - the MSI/MSI-X allocation. amdgpu registers an interrupt
 * handler for its IH (interrupt handler) ring; NetBSD/Linux use pci_intr_*
 * / pci_alloc_irq_vectors, the illumos analogue is ddi_intr_alloc after
 * ddi_intr_get_supported_types picks MSI-X. The handler itself (the IH ring
 * dispatch) is deferred -- this only reserves the vector, so this stub passes
 * a no-op handler.
 */
static uint_t
amdgpu_intr_stub(caddr_t arg1, caddr_t arg2)
{
	/* the real IH-ring dispatch lands with the IH IP block (deferred) */
	(void) arg1;
	(void) arg2;
	return (DDI_INTR_CLAIMED);
}

static int
amdgpu_setup_intr(struct amdgpu_softc *sc)
{
	int types = 0, navail = 0, actual = 0;

	if (ddi_intr_get_supported_types(sc->dip, &types) != DDI_SUCCESS)
		return (DDI_FAILURE);
	/* prefer MSI-X (amdgpu wants many vectors for its rings), fall to MSI */
	int itype = (types & DDI_INTR_TYPE_MSIX) ? DDI_INTR_TYPE_MSIX :
	    (types & DDI_INTR_TYPE_MSI) ? DDI_INTR_TYPE_MSI :
	    DDI_INTR_TYPE_FIXED;

	if (ddi_intr_get_navail(sc->dip, itype, &navail) != DDI_SUCCESS ||
	    navail < 1)
		return (DDI_FAILURE);

	sc->intr_htable = kmem_zalloc(sizeof (ddi_intr_handle_t) * 1, KM_SLEEP);
	if (ddi_intr_alloc(sc->dip, sc->intr_htable, itype, 0, 1,
	    &actual, DDI_INTR_ALLOC_NORMAL) != DDI_SUCCESS || actual < 1) {
		kmem_free(sc->intr_htable, sizeof (ddi_intr_handle_t) * 1);
		sc->intr_htable = NULL;
		return (DDI_FAILURE);
	}
	sc->intr_count = actual;

	if (ddi_intr_add_handler(sc->intr_htable[0], amdgpu_intr_stub,
	    (caddr_t)sc, NULL) != DDI_SUCCESS) {
		(void) ddi_intr_free(sc->intr_htable[0]);
		kmem_free(sc->intr_htable, sizeof (ddi_intr_handle_t) * 1);
		sc->intr_htable = NULL;
		sc->intr_count = 0;
		return (DDI_FAILURE);
	}
	(void) ddi_intr_enable(sc->intr_htable[0]);
	return (DDI_SUCCESS);
}

/*
 * amdgpu_transport_attach - the reduced device-init entry, called from the C1
 * drm_attach exactly like virtio_gpu_transport_attach. Returns NULL on a
 * non-AMD-GPU parent (so the drm core stays a clean no-op, same contract the
 * virtio path uses). On success returns a softc bound to the drm_device.
 */
struct amdgpu_softc *
amdgpu_transport_attach(dev_info_t *dip, struct drm_device *drm)
{
	struct amdgpu_softc *sc;

	sc = kmem_zalloc(sizeof (*sc), KM_SLEEP);
	sc->dip = dip;
	sc->drm = drm;

	if (pci_config_setup(dip, &sc->pci_conf) != DDI_SUCCESS)
		goto fail_free;

	if (amdgpu_read_asic_id(sc) != DDI_SUCCESS)
		goto fail_conf;

	cmn_err(CE_CONT, "?amdgpu: attaching %04x:%04x rev %02x (CHIP_NAVI12)\n",
	    sc->pci_vid, sc->pci_did, sc->pci_rev);

	if (amdgpu_map_bars(sc) != DDI_SUCCESS)
		goto fail_conf;

	if (amdgpu_setup_intr(sc) != DDI_SUCCESS)
		goto fail_bars;

	/*
	 * At this point a real amdgpu would call amdgpu_device_init's IP-init
	 * chain (amdgpu_device_ip_early_init -> nv_set_ip_blocks). That is the
	 * deferred bulk; C3-amdgpu-a stops here with BARs mapped + asic id read.
	 */
	return (sc);

fail_bars:
	ddi_regs_map_free(&sc->vram_hdl);
	ddi_regs_map_free(&sc->rmmio_hdl);
fail_conf:
	pci_config_teardown(&sc->pci_conf);
fail_free:
	kmem_free(sc, sizeof (*sc));
	return (NULL);
}

void
amdgpu_transport_detach(struct amdgpu_softc *sc)
{
	if (sc == NULL)
		return;
	if (sc->intr_htable != NULL) {
		(void) ddi_intr_disable(sc->intr_htable[0]);
		(void) ddi_intr_remove_handler(sc->intr_htable[0]);
		(void) ddi_intr_free(sc->intr_htable[0]);
		kmem_free(sc->intr_htable,
		    sizeof (ddi_intr_handle_t) * 1);
	}
	if (sc->vram_hdl != NULL)
		ddi_regs_map_free(&sc->vram_hdl);
	if (sc->rmmio_hdl != NULL)
		ddi_regs_map_free(&sc->rmmio_hdl);
	if (sc->pci_conf != NULL)
		pci_config_teardown(&sc->pci_conf);
	kmem_free(sc, sizeof (*sc));
}
