/*
 * kfd_priv.h - the amdkfd (KFD) kernel-side model, illumos edition.
 *
 * The KFD is a SECOND char device (/dev/kfd) that shares the amdgpu device
 * (the C3-amdgpu softc). Where the DRI node (/dev/dri/renderD*) is the graphics
 * path, /dev/kfd is the COMPUTE path: the ROCm/HSA runtime (ROCr) via libhsakmt
 * opens /dev/kfd, discovers the topology, allocates GPU memory, and creates
 * user-mode compute queues whose submission is a doorbell ring (no per-submit
 * syscall) -- the low-latency compute dispatch HIP/rocBLAS/the ML runtime need.
 *
 * This header maps the Linux amdkfd structures onto illumos + the C1/C3-amdgpu
 * substrate (crib: drivers/gpu/drm/amd/amdkfd/kfd_priv.h + kfd_device.c +
 * kfd_process.c + kfd_device_queue_manager.c + kfd_doorbell.c):
 *
 *   Linux amdkfd struct        illumos / solnix substrate
 *   -------------------------  --------------------------------------------
 *   struct kfd_dev             struct kfd_dev (below): the amdgpu_softc it
 *                              shares + the doorbell aperture (BAR2) + the
 *                              per-device queue manager
 *   struct kfd_process         struct kfd_process: keyed by illumos pid_t
 *                              (Linux keys off mm_struct); the per-open
 *                              compute context libhsakmt drives
 *   struct queue / mqd         struct kfd_queue: the user-mode queue (ring
 *                              base VA + read/write-ptr VAs + doorbell offset)
 *   struct kfd_doorbell        a slot in the doorbell page carved from BAR2
 *   idr / hash of processes    the C1 idr shim (avl-backed) + a process list
 *   amdgpu bo (kgd_mem)        the C3-amdgpu amdgpu_bo (TTM VRAM/GTT) for
 *                              ALLOC_MEMORY_OF_GPU
 *
 * COMPILE-phase, HARDWARE-GATED runtime: creating a queue here allocates the
 * doorbell slot + records the ring/ptr addresses + returns the ABI reply; the
 * live path (write the MQD, map the queue onto the HWS/MES via a runlist
 * packet, so the GPU actually schedules it) needs firmware + a powered V520 --
 * the same C3-amdgpu-d gate. The doorbell page mmap + the queue create/destroy
 * bookkeeping compile + are self-checkable off-hardware.
 */

#ifndef _KFD_PRIV_H_
#define _KFD_PRIV_H_

#include <sys/types.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/list.h>
#include <sys/ksynch.h>
#include "amdgpu_priv.h"		/* struct amdgpu_softc */
#include "linux-compat/linux_compat.h"	/* idr shim, kmem, atomic */

struct kfd_process;
struct kfd_queue;

/*
 * The doorbell aperture. amdgpu maps BAR2 (the doorbell BAR) in the C3-amdgpu
 * attach; the KFD carves per-process doorbell pages out of it. A doorbell is a
 * 32-bit (or 64-bit for AQL) MMIO slot: userland writes its queue's new write
 * pointer there and the GPU's scheduler notices -- the whole point of a
 * user-mode queue (submit without a syscall).
 *
 * Navi (gfx10) doorbell geometry (crib: kfd_doorbell.c + kfd_device.c
 * doorbell_process_limit / doorbell size): the BAR2 aperture is divided into
 * per-process pages; each page holds KFD_DOORBELLS_PER_PROCESS doorbell dwords.
 */
#define	KFD_DOORBELL_DWORD_SIZE		4
#define	KFD_DOORBELL_PAGE_SIZE		4096
#define	KFD_DOORBELLS_PER_PAGE		(KFD_DOORBELL_PAGE_SIZE / \
					    KFD_DOORBELL_DWORD_SIZE)
/* max concurrent processes with a doorbell page (crib: doorbell_process_limit) */
#define	KFD_MAX_DOORBELL_PROCESSES	128
/* per-process usable doorbells (a subset of the page reserved for queues) */
#define	KFD_MAX_QUEUES_PER_PROCESS	128

struct kfd_doorbell_aperture {
	uint64_t	base;		/* BAR2 aperture physical base */
	uint64_t	size;		/* aperture size in bytes */
	uint32_t	page_count;	/* base/KFD_DOORBELL_PAGE_SIZE cap */
	/* bitmap of used per-process doorbell pages */
	uint8_t		page_used[KFD_MAX_DOORBELL_PROCESSES];
	kmutex_t	lock;
};

/*
 * struct kfd_dev - one KFD-managed GPU. Shares the amdgpu_softc (the C3-amdgpu
 * device that owns the BARs/TTM/rings). One per amdgpu device; the KFD topology
 * (get_process_apertures) reports it as gpu_id.
 *
 * gpu_id: the KFD's stable per-device id the ABI uses (Linux hashes the PCI
 * location; a single-GPU solnix uses a fixed non-zero id). The apertures are
 * the GPUVM/LDS/scratch virtual-address windows libhsakmt maps its allocations
 * into -- constant per asic family (gfx10 here), cribbed from kfd_flat_memory.c.
 */
struct kfd_dev {
	struct amdgpu_softc	*adev;		/* the shared amdgpu device */
	uint32_t		gpu_id;		/* KFD topology id (ABI) */

	struct kfd_doorbell_aperture doorbells;

	/* the gfx10 (Navi 12) virtual-address apertures (constant per family) */
	uint64_t		lds_base;
	uint64_t		lds_limit;
	uint64_t		scratch_base;
	uint64_t		scratch_limit;
	uint64_t		gpuvm_base;
	uint64_t		gpuvm_limit;

	uint32_t		max_queues;	/* device queue ceiling */

	boolean_t		initialized;
};

/*
 * struct kfd_queue - a user-mode compute (or SDMA) queue. Created by
 * AMDKFD_IOC_CREATE_QUEUE; the load-bearing compute-dispatch object.
 *
 * ring_base_address / {read,write}_pointer_address are USER virtual addresses
 * (libhsakmt allocated the ring + the ptr dwords with ALLOC_MEMORY_OF_GPU and
 * hands the VAs in); the KFD records them, assigns a doorbell slot, and (on
 * hardware) writes the MQD (memory queue descriptor) + maps the queue onto the
 * HWS/MES so the GPU schedules it. Compile-phase: everything but the live MQD
 * write + runlist map is done; the doorbell_offset returned is the real slot.
 */
struct kfd_queue {
	list_node_t		link;		/* on kfd_process.queues */
	struct kfd_process	*proc;
	struct kfd_dev		*dev;

	uint32_t		queue_id;	/* per-process id (ABI) */
	uint32_t		queue_type;	/* KFD_IOC_QUEUE_TYPE_* */
	uint32_t		queue_percentage;
	uint32_t		queue_priority;

	uint64_t		ring_base_address;	/* user VA */
	uint64_t		ring_size;
	uint64_t		read_pointer_address;	/* user VA */
	uint64_t		write_pointer_address;	/* user VA */

	uint64_t		eop_buffer_address;
	uint64_t		eop_buffer_size;
	uint64_t		ctx_save_restore_address;
	uint32_t		ctx_save_restore_size;
	uint32_t		ctl_stack_size;

	uint32_t		doorbell_id;	/* index within the page */
	uint64_t		doorbell_offset;/* mmap offset returned (ABI) */

	boolean_t		mapped;		/* HWS/MES-mapped (hardware) */
};

/*
 * struct kfd_mem - a GPU memory allocation (AMDKFD_IOC_ALLOC_MEMORY_OF_GPU).
 * Wraps a C3-amdgpu amdgpu_bo (TTM VRAM or GTT). The KFD hands userland an
 * opaque 64-bit handle (this pointer, tokenized through the process idr) and
 * MAP_MEMORY_TO_GPU maps it into the GPUVM aperture. Compile-phase: the BO is
 * created + the handle issued; the GPUVM PTE program is the hardware step.
 */
struct kfd_mem {
	list_node_t		link;		/* on kfd_process.mems */
	struct kfd_process	*proc;
	struct kfd_dev		*dev;

	uint64_t		handle;		/* ABI handle (== id token) */
	uint64_t		va_addr;	/* GPUVM VA userland requested */
	uint64_t		size;
	uint32_t		flags;		/* KFD_IOC_ALLOC_MEM_FLAGS_* */
	uint64_t		mmap_offset;	/* CPU mmap offset (from KFD) */

	struct amdgpu_bo	*bo;		/* C3-amdgpu TTM-backed BO */
	boolean_t		mapped_to_gpu;
};

/*
 * struct kfd_process - the per-process compute context. Linux keys this off
 * the mm_struct (one per address space); solnix keys it off the illumos pid
 * (ddi_get_pid via drv_getparm(UPROCP)-adjacent -- see kfd_process.c). Holds
 * the process's queues, memory allocations, doorbell page, and the acquired
 * DRM render-node vm (ACQUIRE_VM). Torn down on the last /dev/kfd close.
 */
struct kfd_process {
	list_node_t		link;		/* on the global process list */
	pid_t			pid;		/* illumos process id (key) */

	struct kfd_dev		*dev;		/* single-GPU: the one device */

	kmutex_t		lock;
	struct idr		queue_ids;	/* queue_id -> kfd_queue */
	struct idr		mem_handles;	/* handle -> kfd_mem */
	list_t			queues;		/* struct kfd_queue */
	list_t			mems;		/* struct kfd_mem */

	uint32_t		doorbell_page;	/* this proc's doorbell page idx */
	boolean_t		doorbell_page_assigned;

	boolean_t		vm_acquired;	/* ACQUIRE_VM done */
	uint32_t		drm_fd;		/* the render-node fd (ACQUIRE_VM) */

	/* per-process scratch backing VA (SET_SCRATCH_BACKING_VA) */
	uint64_t		scratch_va;

	uint32_t		queue_count;
};

/* --- kfd_device.c: device init / topology / doorbell aperture --- */
struct kfd_dev *kfd_device_init(struct amdgpu_softc *adev);
void	kfd_device_fini(struct kfd_dev *kdev);
struct kfd_dev *kfd_device_by_gpu_id(uint32_t gpu_id);
int	kfd_doorbell_alloc_page(struct kfd_dev *kdev, uint32_t *page_out);
void	kfd_doorbell_free_page(struct kfd_dev *kdev, uint32_t page);
uint64_t kfd_doorbell_offset(struct kfd_dev *kdev, uint32_t page,
	    uint32_t doorbell_id);

/* --- kfd_process.c: per-process compute context --- */
struct kfd_process *kfd_process_create(struct kfd_dev *kdev, pid_t pid);
struct kfd_process *kfd_process_find(pid_t pid);
void	kfd_process_destroy(struct kfd_process *p);
void	kfd_process_table_init(void);
void	kfd_process_table_fini(void);

/* --- kfd_device_queue_manager.c: user-mode queue create/destroy --- */
int	kfd_queue_create(struct kfd_process *p, struct kfd_dev *kdev,
	    uint32_t queue_type, uint64_t ring_base, uint64_t ring_size,
	    uint64_t rptr_va, uint64_t wptr_va, uint32_t percentage,
	    uint32_t priority, struct kfd_queue **q_out);
int	kfd_queue_destroy(struct kfd_process *p, uint32_t queue_id);
int	kfd_mem_alloc(struct kfd_process *p, struct kfd_dev *kdev,
	    uint64_t va_addr, uint64_t size, uint32_t flags,
	    struct kfd_mem **mem_out);
int	kfd_mem_free(struct kfd_process *p, uint64_t handle);
int	kfd_mem_map_to_gpu(struct kfd_process *p, uint64_t handle);
int	kfd_mem_unmap_from_gpu(struct kfd_process *p, uint64_t handle);

/* --- kfd_chardev.c: the /dev/kfd ioctl entry (called from drm_core.c) --- */
int	kfd_ioctl(dev_t d, int cmd, intptr_t arg, int mode, cred_t *credp,
	    int *rvalp);
void	kfd_chardev_bind(struct amdgpu_softc *adev);
void	kfd_chardev_unbind(void);

/*
 * The KFD minor node number on the shared drm/amdgpu char device. The DRI
 * nodes use minors 0 (card0) + 128 (renderD128); PRIME/sync_file use
 * >= DRM_PRIME_MINOR_BASE. The KFD gets its own fixed minor below that base so
 * cb_ioctl can route a /dev/kfd open to kfd_ioctl by minor.
 */
#define	KFD_MINOR	64	/* /dev/kfd (distinct from card0=0, render=128) */

/* the fixed single-GPU KFD topology id (non-zero; Linux hashes PCI location) */
#define	KFD_GPU_ID_NAVI12	0x8000

#endif	/* _KFD_PRIV_H_ */
