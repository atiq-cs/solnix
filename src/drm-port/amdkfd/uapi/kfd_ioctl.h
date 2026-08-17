/*
 * kfd_ioctl.h - the AMDKFD (Kernel Fusion Driver) userland ABI, preserved
 * verbatim for illumos.
 *
 * This is the ROCm/HIP compute entry point: /dev/kfd + the AMDKFD_IOC_* ioctl
 * surface libhsakmt (the HSA kernel-mode thunk under ROCr/HSA) drives. The
 * struct layouts + the ioctl command numbers ARE the Linux amdkfd UAPI
 * (crib: Linux include/uapi/linux/kfd_ioctl.h @ v1.14), so an unmodified
 * libhsakmt talks to the illumos /dev/kfd node exactly as on Linux -- the same
 * ABI-preservation payoff the C1 DRM port gets from drm.h.
 *
 * Only the illumos-side _IOC encoding differs (the same shim RADV/ANV and the
 * C1 drm.h use): the Linux _IOR/_IOW/_IOWR macros are re-expressed here over
 * the DRM/KFD _IOC bit layout (dir/type/nr/size), base 'K', so the numbers a
 * userland compiled against the real Linux header produces match the numbers
 * this kernel switches on. No Linux <linux/ioctl.h> is included.
 *
 * The full debugger (kfd_ioctl_dbg_trap_*), CRIU, and SMI-event structs from
 * the Linux header are OMITTED here: the compute path (queues + memory +
 * doorbells + events + topology) is the load-bearing KFD surface for the ROCm
 * runtime; the debugger/CRIU/SMI ioctls return ENOTTY (see kfd_chardev.c) and
 * their struct shapes can be appended verbatim from the crib when a debugger/
 * checkpoint path is wired. The ioctl NUMBERS for all of 0x01-0x26 are kept so
 * the dispatch table is complete.
 */

#ifndef _KFD_IOCTL_H_
#define _KFD_IOCTL_H_

#include <sys/types.h>

/*
 * The KFD ABI version libhsakmt negotiates via AMDKFD_IOC_GET_VERSION. Kept at
 * the crib pin (1.14) so the thunk's version check passes.
 */
#define	KFD_IOCTL_MAJOR_VERSION	1
#define	KFD_IOCTL_MINOR_VERSION	14

/*
 * The KFD _IOC encoding, matching the Linux _IOC bit layout the userland
 * header uses (identical to the DRM one in uapi/drm/drm.h; base 'K' not 'd').
 */
#define	_KFD_IOC_NONE	0U
#define	_KFD_IOC_WRITE	1U
#define	_KFD_IOC_READ	2U
#define	_KFD_IOC_NRBITS		8
#define	_KFD_IOC_TYPEBITS	8
#define	_KFD_IOC_SIZEBITS	14
#define	_KFD_IOC_NRSHIFT	0
#define	_KFD_IOC_TYPESHIFT	(_KFD_IOC_NRSHIFT + _KFD_IOC_NRBITS)
#define	_KFD_IOC_SIZESHIFT	(_KFD_IOC_TYPESHIFT + _KFD_IOC_TYPEBITS)
#define	_KFD_IOC_DIRSHIFT	(_KFD_IOC_SIZESHIFT + _KFD_IOC_SIZEBITS)
#define	_KFD_IOC(dir, type, nr, size) \
	(((dir) << _KFD_IOC_DIRSHIFT) | \
	 ((type) << _KFD_IOC_TYPESHIFT) | \
	 ((nr) << _KFD_IOC_NRSHIFT) | \
	 ((size) << _KFD_IOC_SIZESHIFT))

#define	AMDKFD_IOCTL_BASE	'K'
#define	AMDKFD_IO(nr)		_KFD_IOC(_KFD_IOC_NONE, AMDKFD_IOCTL_BASE, (nr), 0)
#define	AMDKFD_IOR(nr, type)	\
	_KFD_IOC(_KFD_IOC_READ, AMDKFD_IOCTL_BASE, (nr), sizeof (type))
#define	AMDKFD_IOW(nr, type)	\
	_KFD_IOC(_KFD_IOC_WRITE, AMDKFD_IOCTL_BASE, (nr), sizeof (type))
#define	AMDKFD_IOWR(nr, type)	\
	_KFD_IOC(_KFD_IOC_READ | _KFD_IOC_WRITE, AMDKFD_IOCTL_BASE, (nr), \
	    sizeof (type))

/* extract the ioctl nr (the switch key) from a full cmd, dir/size-agnostic */
#define	AMDKFD_IOC_NR(n)	(((n) >> _KFD_IOC_NRSHIFT) & \
				    ((1 << _KFD_IOC_NRBITS) - 1))

/* ---- struct layouts (verbatim from the Linux kfd_ioctl.h crib) ---- */

struct kfd_ioctl_get_version_args {
	uint32_t major_version;		/* from KFD */
	uint32_t minor_version;		/* from KFD */
};

/* kfd_ioctl_create_queue_args.queue_type */
#define	KFD_IOC_QUEUE_TYPE_COMPUTE	0x0
#define	KFD_IOC_QUEUE_TYPE_SDMA		0x1
#define	KFD_IOC_QUEUE_TYPE_COMPUTE_AQL	0x2
#define	KFD_IOC_QUEUE_TYPE_SDMA_XGMI	0x3

#define	KFD_MAX_QUEUE_PERCENTAGE	100
#define	KFD_MAX_QUEUE_PRIORITY		15

struct kfd_ioctl_create_queue_args {
	uint64_t ring_base_address;	/* to KFD */
	uint64_t write_pointer_address;	/* from KFD */
	uint64_t read_pointer_address;	/* from KFD */
	uint64_t doorbell_offset;	/* from KFD */

	uint32_t ring_size;		/* to KFD */
	uint32_t gpu_id;		/* to KFD */
	uint32_t queue_type;		/* to KFD */
	uint32_t queue_percentage;	/* to KFD */
	uint32_t queue_priority;	/* to KFD */
	uint32_t queue_id;		/* from KFD */

	uint64_t eop_buffer_address;	/* to KFD */
	uint64_t eop_buffer_size;	/* to KFD */
	uint64_t ctx_save_restore_address; /* to KFD */
	uint32_t ctx_save_restore_size;	/* to KFD */
	uint32_t ctl_stack_size;	/* to KFD */
};

struct kfd_ioctl_destroy_queue_args {
	uint32_t queue_id;		/* to KFD */
	uint32_t pad;
};

struct kfd_ioctl_update_queue_args {
	uint64_t ring_base_address;	/* to KFD */
	uint32_t queue_id;		/* to KFD */
	uint32_t ring_size;		/* to KFD */
	uint32_t queue_percentage;	/* to KFD */
	uint32_t queue_priority;	/* to KFD */
};

struct kfd_ioctl_set_cu_mask_args {
	uint32_t queue_id;		/* to KFD */
	uint32_t num_cu_mask;		/* to KFD */
	uint64_t cu_mask_ptr;		/* to KFD */
};

struct kfd_ioctl_get_queue_wave_state_args {
	uint64_t ctl_stack_address;	/* to KFD */
	uint32_t ctl_stack_used_size;	/* from KFD */
	uint32_t save_area_used_size;	/* from KFD */
	uint32_t queue_id;		/* to KFD */
	uint32_t pad;
};

struct kfd_ioctl_get_available_memory_args {
	uint64_t available;		/* from KFD */
	uint32_t gpu_id;		/* to KFD */
	uint32_t pad;
};

/* kfd_ioctl_set_memory_policy_args.{default,alternate}_policy */
#define	KFD_IOC_CACHE_POLICY_COHERENT	0
#define	KFD_IOC_CACHE_POLICY_NONCOHERENT 1

struct kfd_ioctl_set_memory_policy_args {
	uint64_t alternate_aperture_base;	/* to KFD */
	uint64_t alternate_aperture_size;	/* to KFD */
	uint32_t gpu_id;			/* to KFD */
	uint32_t default_policy;		/* to KFD */
	uint32_t alternate_policy;		/* to KFD */
	uint32_t pad;
};

struct kfd_ioctl_get_clock_counters_args {
	uint64_t gpu_clock_counter;	/* from KFD */
	uint64_t cpu_clock_counter;	/* from KFD */
	uint64_t system_clock_counter;	/* from KFD */
	uint64_t system_clock_freq;	/* from KFD */
	uint32_t gpu_id;		/* to KFD */
	uint32_t pad;
};

struct kfd_process_device_apertures {
	uint64_t lds_base;		/* from KFD */
	uint64_t lds_limit;		/* from KFD */
	uint64_t scratch_base;		/* from KFD */
	uint64_t scratch_limit;		/* from KFD */
	uint64_t gpuvm_base;		/* from KFD */
	uint64_t gpuvm_limit;		/* from KFD */
	uint32_t gpu_id;		/* from KFD */
	uint32_t pad;
};

#define	NUM_OF_SUPPORTED_GPUS	7
struct kfd_ioctl_get_process_apertures_args {
	struct kfd_process_device_apertures
	    process_apertures[NUM_OF_SUPPORTED_GPUS];	/* from KFD */
	uint32_t num_of_nodes;		/* from KFD [1 - NUM_OF_SUPPORTED_GPUS] */
	uint32_t pad;
};

struct kfd_ioctl_get_process_apertures_new_args {
	uint64_t kfd_process_device_apertures_ptr; /* user ptr, filled by KFD */
	uint32_t num_of_nodes;		/* to KFD (size) / from KFD (filled) */
	uint32_t pad;
};

#define	KFD_INVALID_FD	0xffffffff

/* HSA_EVENTTYPE */
#define	KFD_IOC_EVENT_SIGNAL		0
#define	KFD_IOC_EVENT_NODECHANGE	1
#define	KFD_IOC_EVENT_DEVICESTATECHANGE	2
#define	KFD_IOC_EVENT_HW_EXCEPTION	3
#define	KFD_IOC_EVENT_SYSTEM_EVENT	4
#define	KFD_IOC_EVENT_DEBUG_EVENT	5
#define	KFD_IOC_EVENT_PROFILE_EVENT	6
#define	KFD_IOC_EVENT_QUEUE_EVENT	7
#define	KFD_IOC_EVENT_MEMORY		8

#define	KFD_IOC_WAIT_RESULT_COMPLETE	0
#define	KFD_IOC_WAIT_RESULT_TIMEOUT	1
#define	KFD_IOC_WAIT_RESULT_FAIL	2

#define	KFD_SIGNAL_EVENT_LIMIT		4096

struct kfd_ioctl_create_event_args {
	uint64_t event_page_offset;	/* from KFD */
	uint32_t event_trigger_data;	/* from KFD - signal events only */
	uint32_t event_type;		/* to KFD */
	uint32_t auto_reset;		/* to KFD */
	uint32_t node_id;		/* to KFD - certain event types */
	uint32_t event_id;		/* from KFD */
	uint32_t event_slot_index;	/* from KFD */
};

struct kfd_ioctl_destroy_event_args {
	uint32_t event_id;		/* to KFD */
	uint32_t pad;
};

struct kfd_ioctl_set_event_args {
	uint32_t event_id;		/* to KFD */
	uint32_t pad;
};

struct kfd_ioctl_reset_event_args {
	uint32_t event_id;		/* to KFD */
	uint32_t pad;
};

struct kfd_memory_exception_failure {
	uint32_t NotPresent;
	uint32_t ReadOnly;
	uint32_t NoExecute;
	uint32_t imprecise;
};

struct kfd_hsa_memory_exception_data {
	struct kfd_memory_exception_failure failure;
	uint64_t va;
	uint32_t gpu_id;
	uint32_t ErrorType;
};

struct kfd_hsa_hw_exception_data {
	uint32_t reset_type;
	uint32_t reset_cause;
	uint32_t memory_lost;
	uint32_t gpu_id;
};

struct kfd_hsa_signal_event_data {
	uint64_t last_event_age;	/* to and from KFD */
};

struct kfd_event_data {
	union {
		struct kfd_hsa_memory_exception_data memory_exception_data;
		struct kfd_hsa_hw_exception_data hw_exception_data;
		struct kfd_hsa_signal_event_data signal_event_data;
	};
	uint64_t kfd_event_data_ext;	/* ptr to extension struct */
	uint32_t event_id;		/* to KFD */
	uint32_t pad;
};

struct kfd_ioctl_wait_events_args {
	uint64_t events_ptr;		/* struct kfd_event_data array, to KFD */
	uint32_t num_events;		/* to KFD */
	uint32_t wait_for_all;		/* to KFD */
	uint32_t timeout;		/* to KFD */
	uint32_t wait_result;		/* from KFD */
};

struct kfd_ioctl_set_scratch_backing_va_args {
	uint64_t va_addr;		/* to KFD */
	uint32_t gpu_id;		/* to KFD */
	uint32_t pad;
};

struct kfd_ioctl_get_tile_config_args {
	uint64_t tile_config_ptr;	/* to KFD */
	uint64_t macro_tile_config_ptr;	/* to KFD */
	uint32_t num_tile_configs;	/* to/from KFD */
	uint32_t num_macro_tile_configs; /* to/from KFD */
	uint32_t gpu_id;		/* to KFD */
	uint32_t gb_addr_config;	/* from KFD */
	uint32_t num_banks;		/* from KFD */
	uint32_t num_ranks;		/* from KFD */
};

struct kfd_ioctl_set_trap_handler_args {
	uint64_t tba_addr;		/* to KFD */
	uint64_t tma_addr;		/* to KFD */
	uint32_t gpu_id;		/* to KFD */
	uint32_t pad;
};

struct kfd_ioctl_acquire_vm_args {
	uint32_t drm_fd;		/* to KFD */
	uint32_t gpu_id;		/* to KFD */
};

/* Allocation flags: memory types */
#define	KFD_IOC_ALLOC_MEM_FLAGS_VRAM		(1 << 0)
#define	KFD_IOC_ALLOC_MEM_FLAGS_GTT		(1 << 1)
#define	KFD_IOC_ALLOC_MEM_FLAGS_USERPTR		(1 << 2)
#define	KFD_IOC_ALLOC_MEM_FLAGS_DOORBELL	(1 << 3)
#define	KFD_IOC_ALLOC_MEM_FLAGS_MMIO_REMAP	(1 << 4)
/* Allocation flags: attributes/access options */
#define	KFD_IOC_ALLOC_MEM_FLAGS_WRITABLE	(1 << 31)
#define	KFD_IOC_ALLOC_MEM_FLAGS_EXECUTABLE	(1 << 30)
#define	KFD_IOC_ALLOC_MEM_FLAGS_PUBLIC		(1 << 29)
#define	KFD_IOC_ALLOC_MEM_FLAGS_NO_SUBSTITUTE	(1 << 28)
#define	KFD_IOC_ALLOC_MEM_FLAGS_AQL_QUEUE_MEM	(1 << 27)
#define	KFD_IOC_ALLOC_MEM_FLAGS_COHERENT	(1 << 26)
#define	KFD_IOC_ALLOC_MEM_FLAGS_UNCACHED	(1 << 25)

struct kfd_ioctl_alloc_memory_of_gpu_args {
	uint64_t va_addr;	/* to KFD */
	uint64_t size;		/* to KFD */
	uint64_t handle;	/* from KFD */
	uint64_t mmap_offset;	/* to KFD (userptr), from KFD (mmap offset) */
	uint32_t gpu_id;	/* to KFD */
	uint32_t flags;
};

struct kfd_ioctl_free_memory_of_gpu_args {
	uint64_t handle;	/* to KFD */
};

struct kfd_ioctl_map_memory_to_gpu_args {
	uint64_t handle;		/* to KFD */
	uint64_t device_ids_array_ptr;	/* to KFD */
	uint32_t n_devices;		/* to KFD */
	uint32_t n_success;		/* to/from KFD */
};

struct kfd_ioctl_unmap_memory_from_gpu_args {
	uint64_t handle;		/* to KFD */
	uint64_t device_ids_array_ptr;	/* to KFD */
	uint32_t n_devices;		/* to KFD */
	uint32_t n_success;		/* to/from KFD */
};

struct kfd_ioctl_alloc_queue_gws_args {
	uint32_t queue_id;	/* to KFD */
	uint32_t num_gws;	/* to KFD */
	uint32_t first_gws;	/* from KFD */
	uint32_t pad;
};

struct kfd_ioctl_get_dmabuf_info_args {
	uint64_t size;		/* from KFD */
	uint64_t metadata_ptr;	/* to KFD */
	uint32_t metadata_size;	/* to/from KFD */
	uint32_t gpu_id;	/* from KFD */
	uint32_t flags;		/* from KFD */
	uint32_t dmabuf_fd;	/* to KFD */
};

struct kfd_ioctl_import_dmabuf_args {
	uint64_t va_addr;	/* to KFD */
	uint64_t handle;	/* from KFD */
	uint32_t gpu_id;	/* to KFD */
	uint32_t dmabuf_fd;	/* to KFD */
};

struct kfd_ioctl_export_dmabuf_args {
	uint64_t handle;	/* to KFD */
	uint32_t flags;		/* to KFD */
	uint32_t dmabuf_fd;	/* from KFD */
};

struct kfd_ioctl_smi_events_args {
	uint32_t gpuid;		/* to KFD */
	uint32_t anon_fd;	/* from KFD */
};

struct kfd_ioctl_set_xnack_mode_args {
	int32_t xnack_enabled;	/* in/out */
};

/* ---- ioctl command numbers (verbatim; 0x01 .. 0x26) ---- */

#define	AMDKFD_IOC_GET_VERSION	\
	AMDKFD_IOR(0x01, struct kfd_ioctl_get_version_args)
#define	AMDKFD_IOC_CREATE_QUEUE	\
	AMDKFD_IOWR(0x02, struct kfd_ioctl_create_queue_args)
#define	AMDKFD_IOC_DESTROY_QUEUE	\
	AMDKFD_IOWR(0x03, struct kfd_ioctl_destroy_queue_args)
#define	AMDKFD_IOC_SET_MEMORY_POLICY	\
	AMDKFD_IOW(0x04, struct kfd_ioctl_set_memory_policy_args)
#define	AMDKFD_IOC_GET_CLOCK_COUNTERS	\
	AMDKFD_IOWR(0x05, struct kfd_ioctl_get_clock_counters_args)
#define	AMDKFD_IOC_GET_PROCESS_APERTURES	\
	AMDKFD_IOR(0x06, struct kfd_ioctl_get_process_apertures_args)
#define	AMDKFD_IOC_UPDATE_QUEUE	\
	AMDKFD_IOW(0x07, struct kfd_ioctl_update_queue_args)
#define	AMDKFD_IOC_CREATE_EVENT	\
	AMDKFD_IOWR(0x08, struct kfd_ioctl_create_event_args)
#define	AMDKFD_IOC_DESTROY_EVENT	\
	AMDKFD_IOW(0x09, struct kfd_ioctl_destroy_event_args)
#define	AMDKFD_IOC_SET_EVENT	\
	AMDKFD_IOW(0x0A, struct kfd_ioctl_set_event_args)
#define	AMDKFD_IOC_RESET_EVENT	\
	AMDKFD_IOW(0x0B, struct kfd_ioctl_reset_event_args)
#define	AMDKFD_IOC_WAIT_EVENTS	\
	AMDKFD_IOWR(0x0C, struct kfd_ioctl_wait_events_args)
/* 0x0D .. 0x10 = the deprecated debugger register/watch/wave ioctls (ENOTTY) */
#define	AMDKFD_IOC_SET_SCRATCH_BACKING_VA	\
	AMDKFD_IOWR(0x11, struct kfd_ioctl_set_scratch_backing_va_args)
#define	AMDKFD_IOC_GET_TILE_CONFIG	\
	AMDKFD_IOWR(0x12, struct kfd_ioctl_get_tile_config_args)
#define	AMDKFD_IOC_SET_TRAP_HANDLER	\
	AMDKFD_IOW(0x13, struct kfd_ioctl_set_trap_handler_args)
#define	AMDKFD_IOC_GET_PROCESS_APERTURES_NEW	\
	AMDKFD_IOWR(0x14, struct kfd_ioctl_get_process_apertures_new_args)
#define	AMDKFD_IOC_ACQUIRE_VM	\
	AMDKFD_IOW(0x15, struct kfd_ioctl_acquire_vm_args)
#define	AMDKFD_IOC_ALLOC_MEMORY_OF_GPU	\
	AMDKFD_IOWR(0x16, struct kfd_ioctl_alloc_memory_of_gpu_args)
#define	AMDKFD_IOC_FREE_MEMORY_OF_GPU	\
	AMDKFD_IOW(0x17, struct kfd_ioctl_free_memory_of_gpu_args)
#define	AMDKFD_IOC_MAP_MEMORY_TO_GPU	\
	AMDKFD_IOWR(0x18, struct kfd_ioctl_map_memory_to_gpu_args)
#define	AMDKFD_IOC_UNMAP_MEMORY_FROM_GPU	\
	AMDKFD_IOWR(0x19, struct kfd_ioctl_unmap_memory_from_gpu_args)
#define	AMDKFD_IOC_SET_CU_MASK	\
	AMDKFD_IOW(0x1A, struct kfd_ioctl_set_cu_mask_args)
#define	AMDKFD_IOC_GET_QUEUE_WAVE_STATE	\
	AMDKFD_IOWR(0x1B, struct kfd_ioctl_get_queue_wave_state_args)
#define	AMDKFD_IOC_GET_DMABUF_INFO	\
	AMDKFD_IOWR(0x1C, struct kfd_ioctl_get_dmabuf_info_args)
#define	AMDKFD_IOC_IMPORT_DMABUF	\
	AMDKFD_IOWR(0x1D, struct kfd_ioctl_import_dmabuf_args)
#define	AMDKFD_IOC_ALLOC_QUEUE_GWS	\
	AMDKFD_IOWR(0x1E, struct kfd_ioctl_alloc_queue_gws_args)
#define	AMDKFD_IOC_SMI_EVENTS	\
	AMDKFD_IOWR(0x1F, struct kfd_ioctl_smi_events_args)
/* 0x20 = SVM, 0x22 = CRIU, 0x26 = DBG_TRAP: variable/large, deferred (ENOTTY) */
#define	AMDKFD_IOC_SET_XNACK_MODE	\
	AMDKFD_IOWR(0x21, struct kfd_ioctl_set_xnack_mode_args)
#define	AMDKFD_IOC_AVAILABLE_MEMORY	\
	AMDKFD_IOWR(0x23, struct kfd_ioctl_get_available_memory_args)
#define	AMDKFD_IOC_EXPORT_DMABUF	\
	AMDKFD_IOWR(0x24, struct kfd_ioctl_export_dmabuf_args)

#define	AMDKFD_COMMAND_START	0x01
#define	AMDKFD_COMMAND_END	0x27

#endif	/* _KFD_IOCTL_H_ */
