/*
 * pvr_device.c - C-PVR-b: the PowerVR device attach + register access,
 * illumos side. The pvr analogue of amdgpu.c (C3-amdgpu's attach) and Linux's
 * pvr_device.c + pvr_probe (pvr_drv.c).
 *
 * The PowerVR GPU is an SoC block, not a PCI device -- Linux binds it as a
 * platform_driver off the "img,img-rogue" / "thead,th1520-gpu" OF compatible.
 * On illumos it attaches as a nexus child; the control-register aperture is a
 * single "reg" property (rnumber 0) rather than PCI BARs. pvr_transport_attach
 * is called from the C1 drm_attach exactly like amdgpu_transport_attach /
 * virtio_gpu_transport_attach, and returns NULL on a non-PowerVR parent (clean
 * no-op, same contract).
 *
 * What it does (COMPILE-phase -- does NOT bring up the FW processor):
 *   1. map the control-register aperture (ddi_regs_map_setup rnumber 0);
 *   2. read the GPU id (BVNC) from CORE_ID (hardware-gated on the BXE-2-32);
 *   3. provide pvr_cr_read32/write32/read64/write64 (ioread32 -> ddi_get32);
 *   4. allocate the FW IRQ vector;
 *   5. stand up the kernel VM context + the FW CCB + load the FW blob (RISC-V
 *      back-end) + init the per-device scheduler -- each non-fatal to the
 *      attach floor, hardware-gated on the real BXE + the SpacemiT FW blob.
 */

#include <sys/types.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/cmn_err.h>

#include "drm_internal.h"
#include "pvr_priv.h"

/* ROGUE_CR_CORE_ID register offset (pvr_rogue_cr_defs.h). */
#define	ROGUE_CR_CORE_ID	0x0020

/*
 * The DDI regs-map access attributes for the PowerVR control aperture:
 * little-endian, strict order (device registers are strictly ordered), same
 * as C3-amdgpu's amdgpu_reg_acc.
 */
static ddi_device_acc_attr_t pvr_reg_acc = {
	DDI_DEVICE_ATTR_V0,
	DDI_STRUCTURE_LE_ACC,
	DDI_STRICTORDER_ACC,
};

/*
 * pvr_cr_read32 / pvr_cr_write32 - the register access the whole pvr FW-wrapper
 * path reads control registers through. Linux (pvr_device.h) does
 * ioread32(pvr_dev->regs + reg); the direct illumos analogue is ddi_get32 on
 * the mapped aperture at byte offset reg (PowerVR addresses registers by byte
 * offset, NOT word index -- so no *4, unlike amdgpu's RREG32).
 */
uint32_t
pvr_cr_read32(struct pvr_softc *sc, uint32_t reg)
{
	return (ddi_get32(sc->regs_hdl,
	    (uint32_t *)(void *)(sc->regs_base + reg)));
}

void
pvr_cr_write32(struct pvr_softc *sc, uint32_t reg, uint32_t v)
{
	ddi_put32(sc->regs_hdl,
	    (uint32_t *)(void *)(sc->regs_base + reg), v);
}

uint64_t
pvr_cr_read64(struct pvr_softc *sc, uint32_t reg)
{
	return (ddi_get64(sc->regs_hdl,
	    (uint64_t *)(void *)(sc->regs_base + reg)));
}

void
pvr_cr_write64(struct pvr_softc *sc, uint32_t reg, uint64_t v)
{
	ddi_put64(sc->regs_hdl,
	    (uint64_t *)(void *)(sc->regs_base + reg), v);
}

/*
 * pvr_read_gpu_id - read the BVNC from CORE_ID. Hardware-gated: off the real
 * BXE-2-32 the register read returns garbage/0, so we do not gate the attach on
 * a specific BVNC (Mesa 24.0.9 does not even carry the BXE-2-32 device table --
 * see ../powervr/POWERVR-STATUS.md). The full decode is pvr_gpu_id_init
 * (pvr_device.c); here we record the raw fields for dev_query to report.
 */
static void
pvr_read_gpu_id(struct pvr_softc *sc)
{
	uint64_t core_id = pvr_cr_read64(sc, ROGUE_CR_CORE_ID);

	/* BVNC packing per pvr_device.c pvr_gpu_id_init (B.V.N.C). */
	sc->gpu_id.b = (uint16_t)((core_id >> 48) & 0xffff);
	sc->gpu_id.v = (uint16_t)((core_id >> 32) & 0xffff);
	sc->gpu_id.n = (uint16_t)((core_id >> 16) & 0xffff);
	sc->gpu_id.c = (uint16_t)(core_id & 0xffff);
}

/*
 * pvr_map_regs - map the control-register aperture. Linux devm_platform_
 * ioremap_resource(0); illumos ddi_regs_map_setup rnumber 0 (the first "reg"
 * entry of the SoC GPU node).
 */
static int
pvr_map_regs(struct pvr_softc *sc)
{
	(void) ddi_dev_regsize(sc->dip, 0, &sc->regs_size);
	if (ddi_regs_map_setup(sc->dip, 0, &sc->regs_base, 0, 0,
	    &pvr_reg_acc, &sc->regs_hdl) != DDI_SUCCESS)
		return (DDI_FAILURE);
	return (DDI_SUCCESS);
}

/*
 * pvr_intr_stub - the FW-IRQ handler placeholder. The real handler drains the
 * FWCCB (firmware-to-kernel commands) + signals the completed jobs' fences;
 * that lands with the live FW boot (hardware-gated). This only reserves the
 * vector, like amdgpu_intr_stub.
 */
static uint_t
pvr_intr_stub(caddr_t arg1, caddr_t arg2)
{
	(void) arg1; (void) arg2;
	return (DDI_INTR_CLAIMED);
}

static int
pvr_setup_intr(struct pvr_softc *sc)
{
	int types = 0, navail = 0, actual = 0, itype;

	if (ddi_intr_get_supported_types(sc->dip, &types) != DDI_SUCCESS)
		return (DDI_FAILURE);
	itype = (types & DDI_INTR_TYPE_MSI) ? DDI_INTR_TYPE_MSI :
	    DDI_INTR_TYPE_FIXED;

	if (ddi_intr_get_navail(sc->dip, itype, &navail) != DDI_SUCCESS ||
	    navail < 1)
		return (DDI_FAILURE);

	sc->intr_htable = kmem_zalloc(sizeof (ddi_intr_handle_t), KM_SLEEP);
	if (ddi_intr_alloc(sc->dip, sc->intr_htable, itype, 0, 1,
	    &actual, DDI_INTR_ALLOC_NORMAL) != DDI_SUCCESS || actual < 1) {
		kmem_free(sc->intr_htable, sizeof (ddi_intr_handle_t));
		sc->intr_htable = NULL;
		return (DDI_FAILURE);
	}
	sc->intr_count = actual;

	if (ddi_intr_add_handler(sc->intr_htable[0], pvr_intr_stub,
	    (caddr_t)sc, NULL) != DDI_SUCCESS) {
		(void) ddi_intr_free(sc->intr_htable[0]);
		kmem_free(sc->intr_htable, sizeof (ddi_intr_handle_t));
		sc->intr_htable = NULL;
		sc->intr_count = 0;
		return (DDI_FAILURE);
	}
	(void) ddi_intr_enable(sc->intr_htable[0]);
	return (DDI_SUCCESS);
}

/*
 * pvr_transport_attach - the reduced pvr_device_init + pvr_probe, called from
 * the C1 drm_attach the way amdgpu/virtio-gpu are. Returns NULL on a non-
 * PowerVR parent. Mirrors Linux's pvr_probe order: context_device_init ->
 * queue init -> device_init (regs + fw) -> drm_dev_register.
 */
struct pvr_softc *
pvr_transport_attach(dev_info_t *dip, struct drm_device *drm)
{
	struct pvr_softc *sc;

	sc = kmem_zalloc(sizeof (*sc), KM_SLEEP);
	sc->dip = dip;
	sc->drm = drm;
	mutex_init(&sc->lock, NULL, MUTEX_DRIVER, NULL);
	init_rwsem(&sc->reset_sem);
	idr_init(&sc->free_list_ids);
	idr_init(&sc->job_ids);

	if (pvr_map_regs(sc) != DDI_SUCCESS)
		goto fail_free;

	pvr_read_gpu_id(sc);
	cmn_err(CE_CONT, "?pvr: attaching PowerVR GPU BVNC %u.%u.%u.%u\n",
	    sc->gpu_id.b, sc->gpu_id.v, sc->gpu_id.n, sc->gpu_id.c);

	if (pvr_setup_intr(sc) != DDI_SUCCESS)
		goto fail_regs;

	/* the per-device scheduler backing every context's queues */
	(void) drm_sched_init(&sc->sched, "pvr");

	/* per-device context state (Linux: pvr_context_device_init) */
	pvr_context_device_init(sc);

	/*
	 * Stand up the kernel VM context -- the FW-heap mappings live here.
	 * Non-fatal: a failure leaves regs valid but the FW path unavailable.
	 */
	sc->kernel_vm_ctx = pvr_vm_create_context(sc, B_TRUE);
	if (sc->kernel_vm_ctx == NULL)
		cmn_err(CE_WARN, "?pvr: kernel VM context init failed");

	/*
	 * Load + boot the firmware (RISC-V back-end for the BXE-2-32). The FW
	 * blob comes from the SpacemiT BSP via firmware(9F) -- the driver LOADS
	 * it, does not contain it (like amdgpu's signed microcode). Off-hardware
	 * / without the blob installed this fails cleanly; the attach floor
	 * (regs + VM) stays valid. HARDWARE-GATED on the real BXE + the blob.
	 */
	if (sc->kernel_vm_ctx != NULL && pvr_fw_init(sc) != 0)
		cmn_err(CE_WARN, "?pvr: firmware load/boot failed "
		    "(hardware-gated: needs the BXE-2-32 + the SpacemiT blob)");

	return (sc);

fail_regs:
	ddi_regs_map_free(&sc->regs_hdl);
fail_free:
	fini_rwsem(&sc->reset_sem);
	mutex_destroy(&sc->lock);
	kmem_free(sc, sizeof (*sc));
	return (NULL);
}

void
pvr_transport_detach(struct pvr_softc *sc)
{
	if (sc == NULL)
		return;
	pvr_fw_fini(sc);
	if (sc->kernel_vm_ctx != NULL)
		pvr_vm_context_put(sc->kernel_vm_ctx);
	pvr_context_device_fini(sc);
	drm_sched_fini(&sc->sched);
	if (sc->intr_htable != NULL) {
		(void) ddi_intr_disable(sc->intr_htable[0]);
		(void) ddi_intr_remove_handler(sc->intr_htable[0]);
		(void) ddi_intr_free(sc->intr_htable[0]);
		kmem_free(sc->intr_htable, sizeof (ddi_intr_handle_t));
	}
	if (sc->regs_hdl != NULL)
		ddi_regs_map_free(&sc->regs_hdl);
	idr_destroy(&sc->job_ids);
	idr_destroy(&sc->free_list_ids);
	fini_rwsem(&sc->reset_sem);
	mutex_destroy(&sc->lock);
	kmem_free(sc, sizeof (*sc));
}

/*
 * pvr_file_open / pvr_file_close - per-open client state (Linux:
 * pvr_drm_driver_open / _postclose). The C1 drm_attach calls these when a
 * client opens/closes the renderD* node. Each client gets its four handle
 * tables (contexts, free lists, hwrt datasets, vm contexts).
 */
struct pvr_file *
pvr_file_open(struct pvr_softc *sc)
{
	struct pvr_file *pf = kmem_zalloc(sizeof (*pf), KM_SLEEP);

	pf->pvr = sc;
	idr_init(&pf->ctx_handles);
	idr_init(&pf->free_list_handles);
	idr_init(&pf->hwrt_handles);
	idr_init(&pf->vm_ctx_handles);
	pvr_file_contexts_init(pf);
	return (pf);
}

void
pvr_file_close(struct pvr_file *pf)
{
	if (pf == NULL)
		return;
	/*
	 * Real pvr tears down remaining contexts/free-lists/hwrt/vm-contexts
	 * here (pvr_drm_driver_postclose); the per-subsystem destroy-for-file
	 * helpers do the drops. For the compile milestone the idr_destroy frees
	 * the tables; the object drops land with the live submission path.
	 */
	idr_destroy(&pf->vm_ctx_handles);
	idr_destroy(&pf->hwrt_handles);
	idr_destroy(&pf->free_list_handles);
	idr_destroy(&pf->ctx_handles);
	pvr_file_contexts_fini(pf);
	kmem_free(pf, sizeof (*pf));
}
