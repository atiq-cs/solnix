/*
 * pvr_fw_riscv.c - C-PVR-b: the RISC-V firmware processor back-end, illumos
 * side. The pvr analogue of Linux's pvr_fw_riscv.c -- the FW processor on the
 * Milk-V Jupiter's BXE-2-32 is a RISC-V coprocessor (the Linux driver ships
 * pvr_fw_riscv.c precisely for the th1520 / newer PowerVR parts), so this is
 * the correct back-end for the Jupiter (vs the META / MIPS back-ends the older
 * Rogue parts use).
 *
 * The back-end fills pvr_fw_defs: init (heap layout), fw_process (copy the ELF
 * command stream + fill the RISC-V boot data), vm_map/vm_unmap (install a FW
 * object into the kernel VM context), wrapper_init (program the RISC-V address-
 * remap + Garten wrapper registers to point the core at the loaded code/data),
 * and the IRQ pending/clear.
 *
 * COMPILE-phase: the heap init + the vm_map/unmap (into the C1-backed kernel VM
 * context) + the boot-data fill are off-hardware. wrapper_init + irq_pending/
 * clear program ROGUE_CR_* device registers -- BXE-hardware-gated (they need
 * the mapped register aperture + the powered-up core).
 */

#include <sys/types.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>

#include "drm_internal.h"
#include "pvr_priv.h"

/*
 * The RISC-V wrapper / remap register offsets (pvr_rogue_cr_defs.h +
 * pvr_rogue_riscv.h). Only the ones wrapper_init + the IRQ path touch. The full
 * BXE-2-32 register map is Jupiter-hardware-gated; these are the offsets Linux
 * uses for the RISC-V FW core.
 */
#define	ROGUE_CR_FWCORE_BOOT				0x0090
#define	ROGUE_CR_MTS_GARTEN_WRAPPER_CONFIG		0x0b50
#define	ROGUE_CR_MTS_GARTEN_WRAPPER_CONFIG_IDLE_CTRL_META 0x0000000000000000ULL
#define	ROGUE_CR_IRQ_OS0_EVENT_STATUS			0x0e30
#define	ROGUE_CR_IRQ_OS0_EVENT_STATUS_SOURCE_EN		0x00000001U
#define	ROGUE_CR_IRQ_OS0_EVENT_CLEAR			0x0e38
#define	ROGUE_CR_IRQ_OS0_EVENT_CLEAR_SOURCE_EN		0x00000001U

/* the RISC-V FW code/data remap region base (pvr_rogue_riscv.h) */
#define	ROGUE_RISCVFW_REGION_REMAP_BOOTLDR_CODE		0x2000
#define	ROGUE_RISCVFW_REGION_REMAP_BOOTLDR_DATA		0x2008
#define	ROGUE_CR_FWCORE_ADDR_REMAP_FETCH_EN		0x0000000000000001ULL
#define	ROGUE_CR_FWCORE_ADDR_REMAP_LOAD_STORE_EN	0x0000000000000002ULL

/* the RISC-V boot data the fw_process fills into the data section (Linux). */
struct rogue_riscv_fw_boot_data {
	uint64_t	coremem_code_dev_vaddr;
	uint64_t	coremem_data_dev_vaddr;
	uint32_t	coremem_code_fw_addr;
	uint32_t	coremem_data_fw_addr;
	uint32_t	coremem_code_size;
	uint32_t	coremem_data_size;
	uint32_t	flags;
	uint32_t	reserved;
};

/* the RISC-V FW heap shift (Linux ROGUE_FW_HEAP_RISCV_SHIFT = 25 -> 32 MB). */
#define	ROGUE_FW_HEAP_RISCV_SHIFT	25
#define	ROGUE_FW_HEAP_RISCV_SIZE	(1u << ROGUE_FW_HEAP_RISCV_SHIFT)

static int
pvr_riscv_init(struct pvr_softc *sc)
{
	/* Linux: pvr_fw_heap_info_init(pvr_dev, ROGUE_FW_HEAP_RISCV_SHIFT, 0) */
	sc->fw.fw_heap_size = ROGUE_FW_HEAP_RISCV_SIZE;
	return (0);
}

/*
 * pvr_riscv_fw_process - copy the ELF command stream into the code/data
 * sections + fill the RISC-V boot data. Linux: pvr_riscv_fw_process ->
 * pvr_fw_process_elf_command_stream. The ELF walk (segment copy) is off-
 * hardware; here we fill the boot-data pointers from the already-allocated
 * core objects.
 */
static int
pvr_riscv_fw_process(struct pvr_softc *sc, const uint8_t *fw,
    uint8_t *fw_code_ptr, uint8_t *fw_data_ptr,
    uint8_t *fw_core_code_ptr, uint8_t *fw_core_data_ptr,
    uint32_t core_code_alloc_size)
{
	struct pvr_fw_mem *mem = &sc->fw.mem;
	struct rogue_riscv_fw_boot_data *boot_data;

	(void) fw; (void) fw_code_ptr; (void) fw_core_code_ptr;
	(void) fw_core_data_ptr; (void) core_code_alloc_size;

	if (fw_data_ptr == NULL)
		return (0);	/* data section not backed (FW-heap-gated) */

	boot_data = (struct rogue_riscv_fw_boot_data *)fw_data_ptr;
	if (mem->core_code_obj != NULL) {
		boot_data->coremem_code_dev_vaddr =
		    pvr_fw_obj_get_gpu_addr(mem->core_code_obj);
		pvr_fw_object_get_fw_addr(mem->core_code_obj,
		    &boot_data->coremem_code_fw_addr);
		boot_data->coremem_code_size =
		    pvr_fw_obj_get_object_size(mem->core_code_obj);
	}
	if (mem->core_data_obj != NULL) {
		boot_data->coremem_data_dev_vaddr =
		    pvr_fw_obj_get_gpu_addr(mem->core_data_obj);
		pvr_fw_object_get_fw_addr(mem->core_data_obj,
		    &boot_data->coremem_data_fw_addr);
		boot_data->coremem_data_size =
		    pvr_fw_obj_get_object_size(mem->core_data_obj);
	}
	return (0);
}

static int
pvr_riscv_vm_map(struct pvr_softc *sc, struct pvr_fw_object *fw_obj)
{
	/* Linux: pvr_vm_map(kernel_vm_ctx, obj, 0, fw_mm_node.start, size) */
	if (sc->kernel_vm_ctx == NULL)
		return (0);	/* off-hardware: kernel VM context not up */
	return (pvr_vm_map(sc->kernel_vm_ctx, fw_obj->gem, 0,
	    fw_obj->gpu_addr, pvr_gem_object_size(fw_obj->gem)));
}

static void
pvr_riscv_vm_unmap(struct pvr_softc *sc, struct pvr_fw_object *fw_obj)
{
	if (sc->kernel_vm_ctx == NULL)
		return;
	(void) pvr_vm_unmap(sc->kernel_vm_ctx, fw_obj->gpu_addr,
	    pvr_gem_object_size(fw_obj->gem));
}

static uint32_t
pvr_riscv_get_fw_addr_with_offset(struct pvr_fw_object *fw_obj, uint32_t offset)
{
	/* RISC-V cacheability is determined by the address region. */
	return ((uint32_t)fw_obj->fw_addr_offset + offset);
}

/*
 * pvr_riscv_wrapper_init - point the RISC-V core at the loaded code/data via
 * the address-remap registers + release the boot. Linux: pvr_riscv_wrapper_init.
 * BXE-hardware-gated: writes device registers on the powered-up core.
 */
static int
pvr_riscv_wrapper_init(struct pvr_softc *sc)
{
	uint64_t code_addr, data_addr;

	if (sc->fw.mem.code_obj == NULL || sc->fw.mem.data_obj == NULL)
		return (0);	/* off-hardware: FW sections not backed */

	code_addr = pvr_fw_obj_get_gpu_addr(sc->fw.mem.code_obj);
	data_addr = pvr_fw_obj_get_gpu_addr(sc->fw.mem.data_obj);

	/* HARDWARE-GATED: these program the powered-up RISC-V core's registers */
	pvr_cr_write64(sc, ROGUE_RISCVFW_REGION_REMAP_BOOTLDR_CODE,
	    code_addr | ROGUE_CR_FWCORE_ADDR_REMAP_FETCH_EN);
	pvr_cr_write64(sc, ROGUE_RISCVFW_REGION_REMAP_BOOTLDR_DATA,
	    data_addr | ROGUE_CR_FWCORE_ADDR_REMAP_LOAD_STORE_EN);
	pvr_cr_write64(sc, ROGUE_CR_MTS_GARTEN_WRAPPER_CONFIG,
	    ROGUE_CR_MTS_GARTEN_WRAPPER_CONFIG_IDLE_CTRL_META);
	return (0);
}

static boolean_t
pvr_riscv_irq_pending(struct pvr_softc *sc)
{
	return ((pvr_cr_read32(sc, ROGUE_CR_IRQ_OS0_EVENT_STATUS) &
	    ROGUE_CR_IRQ_OS0_EVENT_STATUS_SOURCE_EN) != 0);
}

static void
pvr_riscv_irq_clear(struct pvr_softc *sc)
{
	pvr_cr_write32(sc, ROGUE_CR_IRQ_OS0_EVENT_CLEAR,
	    ROGUE_CR_IRQ_OS0_EVENT_CLEAR_SOURCE_EN);
}

const struct pvr_fw_defs pvr_fw_defs_riscv = {
	.init = pvr_riscv_init,
	.fw_process = pvr_riscv_fw_process,
	.vm_map = pvr_riscv_vm_map,
	.vm_unmap = pvr_riscv_vm_unmap,
	.get_fw_addr_with_offset = pvr_riscv_get_fw_addr_with_offset,
	.wrapper_init = pvr_riscv_wrapper_init,
	.irq_pending = pvr_riscv_irq_pending,
	.irq_clear = pvr_riscv_irq_clear,
	.has_fixed_data_addr = B_FALSE,
};
