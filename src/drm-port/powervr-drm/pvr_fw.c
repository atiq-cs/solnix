/*
 * pvr_fw.c - C-PVR-b: PowerVR firmware load + boot, illumos side. The pvr
 * analogue of Linux's pvr_fw.c + pvr_device.c's pvr_request_firmware, over
 * illumos firmware(9F) (the same request_firmware->firmware_open mapping
 * C3-amdgpu's amdgpu_ucode.c uses).
 *
 * PowerVR's FW does most of the GPU work; the kernel driver's main job is to
 * load the signed FW blob (from the SpacemiT BSP, redistributed into the
 * illumos firmware path), parse its header + layout table, allocate the FW
 * memory sections (code/data/core) as FW objects, process them into the FW
 * heap, and start the FW processor. The BXE-2-32's FW processor is RISC-V
 * (pvr_fw_riscv.c supplies the pvr_fw_defs back-end).
 *
 * The blob naming (Linux pvr_build_firmware_filename): "rogue_B.V.N.C_vM.fw".
 * The blob layout: the info header sits at (size - 4K); the layout table +
 * device-info follow. request_firmware -> firmware_open("powervr", name).
 *
 * COMPILE-phase: the load (firmware_open/get_size/read/close) + the header
 * parse/validate + the FW-object allocator + the startstop *interface* are
 * complete + off-hardware-runnable (given the blob, or the self-check's
 * synthetic header). Handing the processed FW to the RISC-V processor + the
 * boot handshake (the ROGUE_CR_* wrapper-init registers) is BXE-hardware-gated.
 */

#include <sys/types.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/firmload.h>
#include <sys/cmn_err.h>
#include <sys/errno.h>

#include "drm_internal.h"
#include "pvr_priv.h"

#define	PVR_FW_DIR		"powervr"
#define	PVR_FW_VERSION_MAJOR	1
#define	PVR_FW_INFO_VERSION	3
#define	SZ_4K			0x1000
#define	FW_BLOCK_SIZE		SZ_4K
#define	PVR_FW_HEAP_BASE	0xe1c0000000ULL	/* FW heap dev-VA (rogue heap) */

/* struct pvr_fw_info_header (pvr_fw_info.h) -- the blob's trailing header. */
struct pvr_fw_info_header {
	uint32_t	info_version;
	uint32_t	header_len;
	uint32_t	layout_entry_num;
	uint32_t	layout_entry_size;
	uint64_t	bvnc;
	uint32_t	fw_page_size;
	uint32_t	flags;
	uint16_t	fw_version_major;
	uint16_t	fw_version_minor;
	uint32_t	fw_version_build;
	uint32_t	device_info_size;
	uint32_t	padding;
};

/*
 * pvr_fw_object_create - allocate a firmware-visible buffer object: a pvr GEM
 * BO plus its FW-heap device address. Linux: pvr_fw_object_create_and_map.
 * The BO is backed by ddi_umem (the C1 GEM); the FW-heap mapping is installed
 * into the kernel VM context. FW-heap-gated: if the kernel VM context is not
 * up (off-hardware) it allocates the BO but the fw_addr_offset is a bump
 * pointer (still valid for the compile milestone's bookkeeping).
 */
static uint64_t pvr_fw_next_offset = 0;	/* bump allocator within the FW heap */

struct pvr_fw_object *
pvr_fw_object_create(struct pvr_softc *sc, size_t size, uint64_t flags)
{
	struct pvr_fw_object *fw_obj;

	fw_obj = kmem_zalloc(sizeof (*fw_obj), KM_SLEEP);
	fw_obj->gem = pvr_gem_object_create(sc, size, flags);
	if (fw_obj->gem == NULL) {
		kmem_free(fw_obj, sizeof (*fw_obj));
		return (NULL);
	}
	/* the FW-heap device address (bump-allocated; real: pvr_vm heap alloc) */
	fw_obj->fw_addr_offset = pvr_fw_next_offset;
	fw_obj->gpu_addr = PVR_FW_HEAP_BASE + pvr_fw_next_offset;
	pvr_fw_next_offset += P2ROUNDUP(size, 4096);

	/* map the object into the FW heap via the processor back-end */
	if (sc->fw.defs != NULL && sc->fw.defs->vm_map != NULL)
		(void) sc->fw.defs->vm_map(sc, fw_obj);
	return (fw_obj);
}

void
pvr_fw_object_destroy(struct pvr_softc *sc, struct pvr_fw_object *fw_obj)
{
	if (fw_obj == NULL)
		return;
	if (sc != NULL && sc->fw.defs != NULL && sc->fw.defs->vm_unmap != NULL)
		sc->fw.defs->vm_unmap(sc, fw_obj);
	if (fw_obj->gem != NULL)
		pvr_gem_object_put(fw_obj->gem);
	kmem_free(fw_obj, sizeof (*fw_obj));
}

uint64_t
pvr_fw_obj_get_gpu_addr(struct pvr_fw_object *fw_obj)
{
	return (fw_obj->gpu_addr);
}

void
pvr_fw_object_get_fw_addr(struct pvr_fw_object *fw_obj, uint32_t *fw_addr_out)
{
	*fw_addr_out = (uint32_t)fw_obj->fw_addr_offset;
}

uint32_t
pvr_fw_obj_get_object_size(struct pvr_fw_object *fw_obj)
{
	return ((uint32_t)pvr_gem_object_size(fw_obj->gem));
}

/*
 * pvr_fw_validate - parse the FW info header at (size - 4K) + check
 * compatibility. Linux: pvr_fw_validate. The header must be info_version 3,
 * the blob a multiple of FW_BLOCK_SIZE, and the layout table inside the blob.
 */
int
pvr_fw_validate(struct pvr_softc *sc)
{
	const uint8_t *fw = sc->fw.firmware;
	size_t size = sc->fw.firmware_size;
	const struct pvr_fw_info_header *hdr;
	size_t fw_offset, layout_table_size;

	if (fw == NULL || size < SZ_4K || (size % FW_BLOCK_SIZE) != 0)
		return (EINVAL);

	fw_offset = size - SZ_4K;
	hdr = (const struct pvr_fw_info_header *)(fw + fw_offset);

	if (hdr->info_version != PVR_FW_INFO_VERSION)
		return (EINVAL);
	if (hdr->header_len < sizeof (struct pvr_fw_info_header))
		return (EINVAL);

	/* the layout table must fit inside the blob */
	layout_table_size =
	    (size_t)hdr->layout_entry_num * hdr->layout_entry_size;
	if (fw_offset + hdr->header_len + layout_table_size > size)
		return (EINVAL);

	sc->fw.header = (void *)hdr;
	cmn_err(CE_CONT, "?pvr: FW header v%u BVNC %llu fw %u.%u.%u\n",
	    hdr->info_version, (unsigned long long)hdr->bvnc,
	    hdr->fw_version_major, hdr->fw_version_minor, hdr->fw_version_build);
	return (0);
}

/*
 * pvr_request_firmware - the request_firmware analogue over firmware(9F).
 * Builds the "rogue_B.V.N.C_vM.fw" name from the BVNC + loads the blob. The
 * blob comes from the SpacemiT BSP redistributed into the illumos firmware
 * path (PVR_FW_DIR); the driver LOADS it, does not contain it.
 */
static int
pvr_request_firmware(struct pvr_softc *sc)
{
	char name[64];
	firmware_handle_t h;
	off_t sz;
	uint8_t *buf;
	struct pvr_gpu_id *id = &sc->gpu_id;

	(void) snprintf(name, sizeof (name), "rogue_%u.%u.%u.%u_v%u.fw",
	    id->b, id->v, id->n, id->c, PVR_FW_VERSION_MAJOR);

	if (firmware_open(PVR_FW_DIR, name, &h) != 0) {
		cmn_err(CE_WARN, "?pvr: firmware %s/%s not found",
		    PVR_FW_DIR, name);
		return (ENOENT);
	}
	sz = firmware_get_size(h);
	if (sz < SZ_4K) {
		(void) firmware_close(h);
		return (EINVAL);
	}
	buf = kmem_alloc((size_t)sz, KM_SLEEP);
	if (firmware_read(h, 0, buf, (size_t)sz) != 0) {
		(void) firmware_close(h);
		kmem_free(buf, (size_t)sz);
		return (EIO);
	}
	(void) firmware_close(h);

	sc->fw.firmware = buf;
	sc->fw.firmware_size = (size_t)sz;
	return (0);
}

/*
 * pvr_fw_process - allocate the FW memory sections + process the FW image
 * through the processor back-end. Linux: pvr_fw_process. Allocates the code /
 * data / core objects, then the back-end's fw_process copies the ELF sections
 * in + fills the boot data. The section copy is off-hardware; the wrapper_init
 * (register program) is the boot step.
 */
static int
pvr_fw_process(struct pvr_softc *sc)
{
	struct pvr_fw_mem *mem = &sc->fw.mem;
	const uint8_t *fw = sc->fw.firmware;
	int err;

	/*
	 * The section sizes come from the layout table (Linux parses each
	 * pvr_fw_layout_entry). For the compile milestone we allocate nominal
	 * code/data objects; the real sizes are read from the parsed header.
	 * Code must be at the start of the FW heap (the processor boots from 0).
	 */
	mem->code_obj = pvr_fw_object_create(sc, 0x40000,
	    PVR_BO_FW_FLAGS_DEVICE_UNCACHED);
	mem->data_obj = pvr_fw_object_create(sc, 0x40000,
	    PVR_BO_FW_FLAGS_DEVICE_UNCACHED);
	if (mem->code_obj == NULL || mem->data_obj == NULL)
		return (ENOMEM);

	if (sc->fw.defs != NULL && sc->fw.defs->fw_process != NULL) {
		err = sc->fw.defs->fw_process(sc, fw,
		    pvr_gem_object_vmap(mem->code_obj->gem),
		    pvr_gem_object_vmap(mem->data_obj->gem),
		    NULL, NULL, 0);
		if (err != 0)
			return (err);
	}
	return (0);
}

/*
 * pvr_fw_init - the full FW bring-up: pick the processor back-end (RISC-V for
 * the BXE-2-32), load the blob, validate the header, init the FW heap, process
 * the image, set up the FW CCBs, and start the processor. Linux: pvr_fw_init +
 * pvr_device_init's FW steps. Each register-touching step is BXE-hardware-
 * gated; the load + parse + section alloc + CCB setup are off-hardware.
 */
int
pvr_fw_init(struct pvr_softc *sc)
{
	int err;

	/* the BXE-2-32 FW processor is RISC-V */
	sc->fw.defs = &pvr_fw_defs_riscv;
	sc->fw.fw_heap_base = PVR_FW_HEAP_BASE;

	err = pvr_request_firmware(sc);
	if (err != 0)
		return (err);	/* HARDWARE-GATED: needs the SpacemiT blob */

	err = pvr_fw_validate(sc);
	if (err != 0)
		goto fail_fw;

	if (sc->fw.defs->init != NULL &&
	    (err = sc->fw.defs->init(sc)) != 0)
		goto fail_fw;

	err = pvr_fw_process(sc);
	if (err != 0)
		goto fail_fw;

	/* the FW command rings (KCCB kernel->FW, FWCCB FW->kernel) */
	(void) pvr_ccb_init(sc, &sc->kccb, 7, 64);
	(void) pvr_ccb_init(sc, &sc->fwccb, 7, 64);

	/* start the FW processor (register program -- BXE-hardware-gated) */
	err = pvr_fw_startstop_start(sc);
	if (err == 0)
		sc->fw.booted = B_TRUE;
	return (err);

fail_fw:
	if (sc->fw.firmware != NULL) {
		kmem_free((void *)sc->fw.firmware, sc->fw.firmware_size);
		sc->fw.firmware = NULL;
	}
	return (err);
}

void
pvr_fw_fini(struct pvr_softc *sc)
{
	if (sc->fw.booted)
		pvr_fw_startstop_stop(sc);
	pvr_ccb_fini(&sc->fwccb);
	pvr_ccb_fini(&sc->kccb);
	if (sc->fw.mem.data_obj != NULL)
		pvr_fw_object_destroy(sc, sc->fw.mem.data_obj);
	if (sc->fw.mem.code_obj != NULL)
		pvr_fw_object_destroy(sc, sc->fw.mem.code_obj);
	if (sc->fw.firmware != NULL) {
		kmem_free((void *)sc->fw.firmware, sc->fw.firmware_size);
		sc->fw.firmware = NULL;
	}
	sc->fw.booted = B_FALSE;
}
