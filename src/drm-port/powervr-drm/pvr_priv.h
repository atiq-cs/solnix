/*
 * pvr_priv.h - C-PVR-b: the illumos-side PowerVR (Imagination) DRM softc +
 * subsystem model. The kernel half of driving the Milk-V Jupiter's PowerVR
 * BXE-2-32; the userspace half (libvulkan_powervr_mesa.so, the 15 pvr_drm
 * ioctls) is C-PVR-a (../powervr/POWERVR-STATUS.md).
 *
 * This is the pvr analogue of amdgpu_priv.h + Linux's pvr_device.h. Where the
 * Linux driver holds `struct pvr_device` (embedding `struct drm_device base`
 * + `void __iomem *regs`), the illumos side holds a softc bound to the C1
 * `struct drm_device` (drm_internal.h) with the DDI register-access handle,
 * exactly the way C3-amdgpu's `struct amdgpu_softc` does.
 *
 * The PowerVR GPU is NOT a PCI device -- it is an SoC block (the Linux driver
 * is a platform_driver keyed off the "img,img-rogue" / "thead,th1520-gpu" OF
 * compatible). On illumos it attaches as a nexus child; the register aperture
 * is a single reg entry (rnumber 0) instead of PCI BARs. The FW processor on
 * the BXE-2-32 is a RISC-V coprocessor (pvr_fw_riscv.c) -- the driver loads a
 * signed FW blob from the SpacemiT BSP (firmware(9F)-style), it does not
 * contain it.
 *
 *   Linux pvr_device field           illumos pvr_softc field
 *   -----------------------------     --------------------------------------
 *   base (struct drm_device)          drm (struct drm_device *) back-pointer
 *   regs (void __iomem *)             regs_hdl (ddi_acc_handle_t) + regs_base
 *   gpu_id (struct pvr_gpu_id)        gpu_id (bvnc)
 *   fw_dev (struct pvr_fw_device)     fw (struct pvr_fw_device)
 *   kernel_vm_ctx                     kernel_vm_ctx (struct pvr_vm_context *)
 *   fwccb (struct pvr_ccb)            fwccb (struct pvr_ccb)
 *   pvr_cr_read32/write32 (ioread32)  pvr_cr_read32/write32 (ddi_get32)
 */

#ifndef _PVR_PRIV_H_
#define _PVR_PRIV_H_

#include <sys/types.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/list.h>
#include <sys/firmload.h>	/* firmware_handle_t (firmware(9F)) */

#include "drm_internal.h"
#include "drm_sched.h"
#include "linux-compat/linux_compat.h"
#include "linux-compat/linux_dma.h"

struct pvr_softc;
struct pvr_gem_object;
struct pvr_vm_context;
struct pvr_context;
struct pvr_queue;
struct pvr_free_list;
struct pvr_hwrt_dataset;
struct pvr_fw_object;

/*
 * pvr_gpu_id - the BVNC (Branch.Version.NumberOfScalables.Config) that
 * identifies the exact PowerVR part. The Jupiter is the BXE-2-32; its BVNC is
 * read from the CORE_ID register at attach (hardware-gated -- off-hardware the
 * softc carries a zeroed id). Linux: struct pvr_gpu_id (pvr_device.h).
 */
struct pvr_gpu_id {
	uint16_t	b;	/* branch */
	uint16_t	v;	/* version */
	uint16_t	n;	/* number of scalable units */
	uint16_t	c;	/* config */
};

/*
 * pvr_fw_object - a firmware-visible buffer object: a GEM object plus its GPU
 * (device-virtual) address and firmware address offset. Linux: struct
 * pvr_fw_object (pvr_fw.h). Backed by the C1 GEM (ddi_umem) like every other
 * pvr BO; the FW-visible mapping is installed into kernel_vm_ctx.
 */
struct pvr_fw_object {
	struct pvr_gem_object	*gem;
	uint64_t		fw_addr_offset;	/* offset within the FW heap */
	uint64_t		gpu_addr;	/* device-virtual address */
	list_node_t		node;
};

/*
 * pvr_fw_mem - the firmware memory layout: the code/data/core objects the FW
 * processor boots from. Linux: struct pvr_fw_mem (pvr_fw.h).
 */
struct pvr_fw_mem {
	struct pvr_fw_object	*code_obj;
	struct pvr_fw_object	*data_obj;
	struct pvr_fw_object	*core_code_obj;
	struct pvr_fw_object	*core_data_obj;
	struct pvr_fw_object	*fwif_connection_ctl_obj;
	struct pvr_fw_object	*osinit_obj;
	struct pvr_fw_object	*sysinit_obj;
};

/*
 * pvr_fw_defs - the per-FW-processor operations vtable. Linux has three
 * back-ends (META, MIPS, RISC-V); the BXE-2-32 uses RISC-V (pvr_fw_riscv.c).
 * On illumos we keep the same indirection so the RISC-V and (future) META/MIPS
 * back-ends coexist; pvr_fw_riscv.c fills this in. Linux: struct pvr_fw_defs.
 */
struct pvr_fw_defs {
	int	(*init)(struct pvr_softc *);
	int	(*fw_process)(struct pvr_softc *, const uint8_t *fw,
		    uint8_t *code, uint8_t *data,
		    uint8_t *core_code, uint8_t *core_data,
		    uint32_t core_code_alloc_size);
	int	(*vm_map)(struct pvr_softc *, struct pvr_fw_object *);
	void	(*vm_unmap)(struct pvr_softc *, struct pvr_fw_object *);
	uint32_t (*get_fw_addr_with_offset)(struct pvr_fw_object *,
		    uint32_t offset);
	int	(*wrapper_init)(struct pvr_softc *);
	boolean_t (*irq_pending)(struct pvr_softc *);
	void	(*irq_clear)(struct pvr_softc *);
	boolean_t has_fixed_data_addr;
};

/* the RISC-V FW back-end (pvr_fw_riscv.c) -- the BXE-2-32 path */
extern const struct pvr_fw_defs pvr_fw_defs_riscv;

/*
 * pvr_fw_device - the aggregate firmware state: the loaded blob, the parsed
 * header, the memory layout, and the processor-specific vtable. Linux: struct
 * pvr_fw_device (pvr_fw.h).
 */
struct pvr_fw_device {
	const struct pvr_fw_defs *defs;
	const uint8_t		*firmware;	/* firmware(9F) blob data */
	size_t			firmware_size;
	firmware_handle_t	fw_h;		/* firmware(9F) handle */
	void			*header;	/* parsed FW header */
	struct pvr_fw_mem	mem;
	uint64_t		fw_heap_base;	/* device-virtual heap base */
	uint32_t		fw_heap_size;
	boolean_t		booted;
};

/*
 * pvr_ccb - a firmware command control block (the FW command ring). PowerVR's
 * FW does most of the work; the kernel driver talks to it over these rings
 * rather than banging registers. Linux: struct pvr_ccb (pvr_ccb.h). Backed by
 * a FW object (a GEM BO mapped into the FW heap); the control block tracks the
 * read/write offsets. The kernel CCB (KCCB) carries commands to the FW; the
 * firmware CCB (FWCCB) carries them back.
 */
struct pvr_ccb {
	struct pvr_fw_object	*ctrl_obj;	/* the control struct BO */
	struct pvr_fw_object	*ccb_obj;	/* the command buffer BO */
	void			*ctrl;		/* kernel-VA of ctrl_obj */
	void			*ccb;		/* kernel-VA of ccb_obj */
	uint32_t		ctrl_fw_addr;	/* FW address of ctrl */
	uint32_t		ccb_fw_addr;	/* FW address of ccb */
	uint32_t		num_cmds;
	uint32_t		cmd_size;
	kmutex_t		lock;
};

/*
 * pvr_softc - one attached PowerVR GPU. The reduced pvr_device. Owns the C1
 * drm_device back-pointer, the register aperture handle, the FW state, the
 * kernel VM context, and the FW CCB. Per-client state (contexts, free lists,
 * hwrt datasets, vm contexts) hangs off struct pvr_file below.
 */
struct pvr_softc {
	dev_info_t		*dip;
	struct drm_device	*drm;		/* the C1 drm_device */

	/* the control register aperture (a single OF reg entry, rnumber 0) */
	ddi_acc_handle_t	regs_hdl;
	caddr_t			regs_base;
	off_t			regs_size;

	/* interrupt (the FW IRQ line) */
	ddi_intr_handle_t	*intr_htable;
	int			intr_count;

	struct pvr_gpu_id	gpu_id;		/* the BXE-2-32 BVNC */

	/* firmware state (pvr_fw.c + pvr_fw_riscv.c) */
	struct pvr_fw_device	fw;

	/* the kernel VM context (FW-heap mappings live here) */
	struct pvr_vm_context	*kernel_vm_ctx;

	/* the firmware command ring */
	struct pvr_ccb		fwccb;
	struct pvr_ccb		kccb;

	/* the per-device GPU scheduler backing every context's queues */
	struct drm_gpu_scheduler sched;

	/* device-wide id allocators (Linux: xa free_list_ids/job_ids) */
	struct idr		free_list_ids;
	struct idr		job_ids;

	kmutex_t		lock;
	struct rw_semaphore	reset_sem;
};

/*
 * pvr_file - the per-open (per drm_file) state. Linux: struct pvr_file
 * (pvr_device.h). Holds the four per-client handle tables the ioctls allocate
 * into (contexts, free lists, hwrt datasets, vm contexts). The C1 framework's
 * handle table is device-global today (see drm_internal.h drm_file note); we
 * key these off the pvr_softc for the compile milestone and note the per-file
 * scoping as the same upgrade the C1 drm_file note tracks.
 */
struct pvr_file {
	struct pvr_softc	*pvr;
	struct idr		ctx_handles;
	struct idr		free_list_handles;
	struct idr		hwrt_handles;
	struct idr		vm_ctx_handles;
	list_t			contexts;
};

/* --- register access: the pvr_cr_read/write mapping (pvr_device.c) --- */
extern uint32_t	pvr_cr_read32(struct pvr_softc *, uint32_t reg);
extern uint64_t	pvr_cr_read64(struct pvr_softc *, uint32_t reg);
extern void	pvr_cr_write32(struct pvr_softc *, uint32_t reg, uint32_t v);
extern void	pvr_cr_write64(struct pvr_softc *, uint32_t reg, uint64_t v);

/* --- attach/detach: called from the C1 drm_attach like amdgpu/virtio-gpu --- */
extern struct pvr_softc *pvr_transport_attach(dev_info_t *, struct drm_device *);
extern void	pvr_transport_detach(struct pvr_softc *);

/* --- the 15-ioctl dispatch (pvr_drv.c) -- matches C-PVR-a's pvr_drm.h --- */
extern int	pvr_ioctl(struct pvr_softc *, struct pvr_file *, int cmd,
		    intptr_t arg, int mode);
extern struct pvr_file *pvr_file_open(struct pvr_softc *);
extern void	pvr_file_close(struct pvr_file *);

/* --- pvr_gem: BO alloc over the C1 GEM (ddi_umem) --- */
extern struct pvr_gem_object *pvr_gem_object_create(struct pvr_softc *,
		    uint64_t size, uint64_t flags);
extern void	pvr_gem_object_put(struct pvr_gem_object *);
extern void	pvr_gem_object_get_ref(struct pvr_gem_object *);
extern uint64_t	pvr_gem_object_size(struct pvr_gem_object *);
extern void	*pvr_gem_object_vmap(struct pvr_gem_object *);
extern void	pvr_gem_object_vunmap(struct pvr_gem_object *);
extern int	pvr_gem_create_bo_ioctl(struct pvr_softc *, struct pvr_file *,
		    intptr_t arg, int mode);
extern int	pvr_gem_get_bo_mmap_offset_ioctl(struct pvr_softc *,
		    struct pvr_file *, intptr_t arg, int mode);

/* --- pvr_vm: the GPU MMU (device-virtual address space) --- */
extern struct pvr_vm_context *pvr_vm_create_context(struct pvr_softc *,
		    boolean_t is_kernel);
extern void	pvr_vm_context_put(struct pvr_vm_context *);
extern int	pvr_vm_map(struct pvr_vm_context *, struct pvr_gem_object *,
		    uint64_t bo_offset, uint64_t device_addr, uint64_t size);
extern int	pvr_vm_unmap(struct pvr_vm_context *, uint64_t device_addr,
		    uint64_t size);
extern int	pvr_vm_map_ioctl(struct pvr_softc *, struct pvr_file *,
		    intptr_t arg, int mode);
extern int	pvr_vm_unmap_ioctl(struct pvr_softc *, struct pvr_file *,
		    intptr_t arg, int mode);
extern int	pvr_create_vm_context_ioctl(struct pvr_softc *,
		    struct pvr_file *, intptr_t arg, int mode);
extern int	pvr_destroy_vm_context_ioctl(struct pvr_softc *,
		    struct pvr_file *, intptr_t arg, int mode);

/* --- pvr_context / pvr_queue / pvr_job: submission over the C1 drm_sched --- */
extern int	pvr_create_context_ioctl(struct pvr_softc *, struct pvr_file *,
		    intptr_t arg, int mode);
extern int	pvr_destroy_context_ioctl(struct pvr_softc *, struct pvr_file *,
		    intptr_t arg, int mode);
extern int	pvr_submit_jobs_ioctl(struct pvr_softc *, struct pvr_file *,
		    intptr_t arg, int mode);
extern void	pvr_context_device_init(struct pvr_softc *);
extern void	pvr_context_device_fini(struct pvr_softc *);
extern void	pvr_file_contexts_init(struct pvr_file *);
extern void	pvr_file_contexts_fini(struct pvr_file *);

/* --- pvr_free_list --- */
extern int	pvr_create_free_list_ioctl(struct pvr_softc *,
		    struct pvr_file *, intptr_t arg, int mode);
extern int	pvr_destroy_free_list_ioctl(struct pvr_softc *,
		    struct pvr_file *, intptr_t arg, int mode);

/* --- pvr_hwrt --- */
extern int	pvr_create_hwrt_dataset_ioctl(struct pvr_softc *,
		    struct pvr_file *, intptr_t arg, int mode);
extern int	pvr_destroy_hwrt_dataset_ioctl(struct pvr_softc *,
		    struct pvr_file *, intptr_t arg, int mode);

/* --- dev_query (feeds C-PVR-a's pvr_device_info) --- */
extern int	pvr_dev_query_ioctl(struct pvr_softc *, struct pvr_file *,
		    intptr_t arg, int mode);

/* --- pvr_ccb: the FW command ring --- */
extern int	pvr_ccb_init(struct pvr_softc *, struct pvr_ccb *,
		    uint32_t num_cmds_log2, uint32_t cmd_size);
extern void	pvr_ccb_fini(struct pvr_ccb *);
extern int	pvr_kccb_send_cmd(struct pvr_softc *, const void *cmd,
		    size_t cmd_size);

/* --- pvr_fw: firmware load + boot (pvr_fw.c + pvr_fw_riscv.c) --- */
extern int	pvr_fw_init(struct pvr_softc *);
extern void	pvr_fw_fini(struct pvr_softc *);
extern int	pvr_fw_validate(struct pvr_softc *);
extern struct pvr_fw_object *pvr_fw_object_create(struct pvr_softc *,
		    size_t size, uint64_t flags);
extern void	pvr_fw_object_destroy(struct pvr_softc *,
		    struct pvr_fw_object *);
extern uint64_t	pvr_fw_obj_get_gpu_addr(struct pvr_fw_object *);
extern void	pvr_fw_object_get_fw_addr(struct pvr_fw_object *,
		    uint32_t *fw_addr_out);
extern uint32_t	pvr_fw_obj_get_object_size(struct pvr_fw_object *);
extern int	pvr_fw_startstop_start(struct pvr_softc *);
extern void	pvr_fw_startstop_stop(struct pvr_softc *);

/* --- pvr_sync: sync -> the C1 dma-fence --- */
extern struct dma_fence *pvr_sync_create_output_fence(struct pvr_softc *);

/* PVR BO flags subset (pvr_drm.h DRM_PVR_BO_*) used by pvr_gem/pvr_fw */
#define	PVR_BO_FW_FLAGS_DEVICE_UNCACHED	(1ULL << 1)

#endif	/* _PVR_PRIV_H_ */
