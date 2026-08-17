/*
 * kfd_chardev.c - C3-KFD: the /dev/kfd char-device ioctl surface.
 *
 * This is the ROCm/HIP compute entry point on illumos. libhsakmt (the HSA
 * kernel-mode thunk under ROCr) opens /dev/kfd and drives the AMDKFD_IOC_*
 * ioctls this file dispatches: negotiate the version, discover the topology
 * (get_process_apertures), acquire the render-node VM, allocate + map GPU
 * memory, and create the user-mode compute queues whose doorbell submission is
 * the low-latency compute dispatch path.
 *
 * On illumos /dev/kfd is NOT a separate driver instance: it is a SECOND minor
 * node (KFD_MINOR) on the SAME char device the C1 drm core registers (which the
 * C3-amdgpu transport attaches to). drm_core.c's cb_ioctl routes a call whose
 * minor == KFD_MINOR here (kfd_ioctl); the DRI minors (card0/renderD128) stay
 * on the DRM dispatch. This mirrors Linux, where /dev/kfd and /dev/dri/renderD*
 * are distinct char devices that share the one amdgpu device -- same device,
 * two ABIs (graphics DRM vs compute KFD).
 *
 * Crib: drivers/gpu/drm/amd/amdkfd/kfd_chardev.c (kfd_ioctl + the per-command
 * handlers). The ioctl arg copyin/out uses the illumos ddi_copyin/ddi_copyout
 * (mode-aware) exactly as the C1 drm ioctls do. Handlers return positive
 * illumos errnos (the cb_ioctl boundary).
 *
 * COMPILE-phase / HARDWARE-GATED: version/topology/apertures/acquire_vm/memory-
 * alloc/queue-create all run + return the correct ABI reply off-hardware (the
 * bookkeeping is real). What needs a powered V520 (firmware + HWS/MES): the live
 * MQD write + runlist map for a created queue, the GPUVM PTE program for a
 * mapped allocation, and the doorbell BAR2 mmap (the aperture is empty without a
 * device). Those are the C3-amdgpu-d gates, marked at each site.
 */

#include <sys/types.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/kmem.h>
#include <sys/cmn_err.h>
#include <sys/errno.h>
#include "kfd_priv.h"
#include "uapi/kfd_ioctl.h"

/* the single amdgpu device the KFD chardev binds to (single-GPU solnix) */
static struct amdgpu_softc	*kfd_bound_adev = NULL;
static struct kfd_dev		*kfd_bound_dev = NULL;

/*
 * kfd_chardev_bind - called from the C3-amdgpu attach after the device is up:
 * create the KFD device view (kfd_device_init) + the process table. The KFD
 * minor node itself is created by drm_core.c's attach (it owns the char dev);
 * this just stands up the KFD state behind it.
 */
void
kfd_chardev_bind(struct amdgpu_softc *adev)
{
	if (kfd_bound_adev != NULL)
		return;			/* already bound (single GPU) */
	kfd_process_table_init();
	kfd_bound_dev = kfd_device_init(adev);
	kfd_bound_adev = adev;
	cmn_err(CE_CONT, "?kfd: /dev/kfd bound to amdgpu device\n");
}

void
kfd_chardev_unbind(void)
{
	if (kfd_bound_dev != NULL) {
		kfd_device_fini(kfd_bound_dev);
		kfd_bound_dev = NULL;
	}
	kfd_process_table_fini();
	kfd_bound_adev = NULL;
}

/* the calling process's KFD context, created lazily on first use */
static struct kfd_process *
kfd_current_process(void)
{
	pid_t pid = ddi_get_pid();

	if (kfd_bound_dev == NULL)
		return (NULL);
	return (kfd_process_create(kfd_bound_dev, pid));
}

/* ---- per-ioctl handlers (crib: kfd_chardev.c kfd_ioctl_*) ---- */

static int
kfd_ioctl_get_version(intptr_t arg, int mode)
{
	struct kfd_ioctl_get_version_args a;

	a.major_version = KFD_IOCTL_MAJOR_VERSION;
	a.minor_version = KFD_IOCTL_MINOR_VERSION;
	if (ddi_copyout(&a, (void *)arg, sizeof (a), mode) != 0)
		return (EFAULT);
	return (0);
}

/*
 * GET_PROCESS_APERTURES / _NEW: report the device's gfx10 apertures. This is
 * how libhsakmt lays out its process address space (GPUVM/LDS/scratch windows).
 * The _NEW form copies into a user-supplied array pointer + returns the count.
 */
static int
kfd_fill_aperture(struct kfd_dev *kdev, struct kfd_process_device_apertures *ap)
{
	bzero(ap, sizeof (*ap));
	ap->gpu_id = kdev->gpu_id;
	ap->lds_base = kdev->lds_base;
	ap->lds_limit = kdev->lds_limit;
	ap->scratch_base = kdev->scratch_base;
	ap->scratch_limit = kdev->scratch_limit;
	ap->gpuvm_base = kdev->gpuvm_base;
	ap->gpuvm_limit = kdev->gpuvm_limit;
	return (0);
}

static int
kfd_ioctl_get_process_apertures(intptr_t arg, int mode)
{
	struct kfd_ioctl_get_process_apertures_args a;

	if (kfd_bound_dev == NULL)
		return (ENODEV);
	bzero(&a, sizeof (a));
	(void) kfd_fill_aperture(kfd_bound_dev, &a.process_apertures[0]);
	a.num_of_nodes = 1;		/* single GPU */
	if (ddi_copyout(&a, (void *)arg, sizeof (a), mode) != 0)
		return (EFAULT);
	return (0);
}

static int
kfd_ioctl_get_process_apertures_new(intptr_t arg, int mode)
{
	struct kfd_ioctl_get_process_apertures_new_args a;
	struct kfd_process_device_apertures ap;

	if (kfd_bound_dev == NULL)
		return (ENODEV);
	if (ddi_copyin((void *)arg, &a, sizeof (a), mode) != 0)
		return (EFAULT);
	/* a.num_of_nodes (IN) = array size the caller allocated */
	if (a.num_of_nodes >= 1 && a.kfd_process_device_apertures_ptr != 0) {
		(void) kfd_fill_aperture(kfd_bound_dev, &ap);
		if (ddi_copyout(&ap,
		    (void *)(uintptr_t)a.kfd_process_device_apertures_ptr,
		    sizeof (ap), mode) != 0)
			return (EFAULT);
	}
	a.num_of_nodes = 1;		/* filled */
	if (ddi_copyout(&a, (void *)arg, sizeof (a), mode) != 0)
		return (EFAULT);
	return (0);
}

/*
 * ACQUIRE_VM: bind the KFD process to a DRM render-node fd (drm_fd) so KFD
 * memory allocations share the same GPUVM as the graphics context. Records the
 * fd + marks the vm acquired; the live path attaches the amdgpu VM to the
 * process (hardware-gated GPUVM). The compute runtime calls this once at init.
 */
static int
kfd_ioctl_acquire_vm(intptr_t arg, int mode)
{
	struct kfd_ioctl_acquire_vm_args a;
	struct kfd_process *p;

	if (ddi_copyin((void *)arg, &a, sizeof (a), mode) != 0)
		return (EFAULT);
	if (kfd_device_by_gpu_id(a.gpu_id) == NULL)
		return (ENODEV);
	p = kfd_current_process();
	if (p == NULL)
		return (ENODEV);
	mutex_enter(&p->lock);
	p->vm_acquired = B_TRUE;
	p->drm_fd = a.drm_fd;
	mutex_exit(&p->lock);
	return (0);
}

static int
kfd_ioctl_set_scratch_backing_va(intptr_t arg, int mode)
{
	struct kfd_ioctl_set_scratch_backing_va_args a;
	struct kfd_process *p;

	if (ddi_copyin((void *)arg, &a, sizeof (a), mode) != 0)
		return (EFAULT);
	if (kfd_device_by_gpu_id(a.gpu_id) == NULL)
		return (ENODEV);
	p = kfd_current_process();
	if (p == NULL)
		return (ENODEV);
	mutex_enter(&p->lock);
	p->scratch_va = a.va_addr;
	mutex_exit(&p->lock);
	return (0);
}

/*
 * CREATE_QUEUE: the load-bearing compute-dispatch ioctl. Registers the
 * user-mode ring + ptr addresses, assigns a doorbell dword, and returns the
 * queue_id + doorbell_offset the runtime mmaps to ring the doorbell.
 */
static int
kfd_ioctl_create_queue(intptr_t arg, int mode)
{
	struct kfd_ioctl_create_queue_args a;
	struct kfd_process *p;
	struct kfd_dev *kdev;
	struct kfd_queue *q;
	int rc;

	if (ddi_copyin((void *)arg, &a, sizeof (a), mode) != 0)
		return (EFAULT);
	kdev = kfd_device_by_gpu_id(a.gpu_id);
	if (kdev == NULL)
		return (ENODEV);
	p = kfd_current_process();
	if (p == NULL)
		return (ENODEV);

	rc = kfd_queue_create(p, kdev, a.queue_type, a.ring_base_address,
	    a.ring_size, a.read_pointer_address, a.write_pointer_address,
	    a.queue_percentage, a.queue_priority, &q);
	if (rc != 0)
		return (rc);

	a.queue_id = q->queue_id;
	a.doorbell_offset = q->doorbell_offset;
	/*
	 * read/write_pointer_address are echoed back unchanged (the runtime
	 * supplied them); on Linux gfx10 the KFD may relocate the wptr into a
	 * kernel-doorbell page -- that is the hardware MQD step, deferred.
	 */
	if (ddi_copyout(&a, (void *)arg, sizeof (a), mode) != 0) {
		(void) kfd_queue_destroy(p, q->queue_id);
		return (EFAULT);
	}
	return (0);
}

static int
kfd_ioctl_destroy_queue(intptr_t arg, int mode)
{
	struct kfd_ioctl_destroy_queue_args a;
	struct kfd_process *p;

	if (ddi_copyin((void *)arg, &a, sizeof (a), mode) != 0)
		return (EFAULT);
	p = kfd_current_process();
	if (p == NULL)
		return (ENODEV);
	return (kfd_queue_destroy(p, a.queue_id));
}

/*
 * ALLOC_MEMORY_OF_GPU: allocate a GPU buffer (VRAM/GTT via C3-amdgpu TTM) and
 * return an opaque handle + a CPU mmap offset. FREE_MEMORY_OF_GPU releases it.
 */
static int
kfd_ioctl_alloc_memory_of_gpu(intptr_t arg, int mode)
{
	struct kfd_ioctl_alloc_memory_of_gpu_args a;
	struct kfd_process *p;
	struct kfd_dev *kdev;
	struct kfd_mem *m;
	int rc;

	if (ddi_copyin((void *)arg, &a, sizeof (a), mode) != 0)
		return (EFAULT);
	kdev = kfd_device_by_gpu_id(a.gpu_id);
	if (kdev == NULL)
		return (ENODEV);
	p = kfd_current_process();
	if (p == NULL)
		return (ENODEV);

	rc = kfd_mem_alloc(p, kdev, a.va_addr, a.size, a.flags, &m);
	if (rc != 0)
		return (rc);

	a.handle = m->handle;
	a.mmap_offset = m->mmap_offset;
	if (ddi_copyout(&a, (void *)arg, sizeof (a), mode) != 0) {
		(void) kfd_mem_free(p, m->handle);
		return (EFAULT);
	}
	return (0);
}

static int
kfd_ioctl_free_memory_of_gpu(intptr_t arg, int mode)
{
	struct kfd_ioctl_free_memory_of_gpu_args a;
	struct kfd_process *p;

	if (ddi_copyin((void *)arg, &a, sizeof (a), mode) != 0)
		return (EFAULT);
	p = kfd_current_process();
	if (p == NULL)
		return (ENODEV);
	return (kfd_mem_free(p, a.handle));
}

/*
 * MAP_MEMORY_TO_GPU / UNMAP: map an allocation into the process GPUVM across a
 * device array. n_success reports how many devices mapped (single-GPU: all or
 * none). The live PTE program is hardware-gated (C3-amdgpu-d gart).
 */
static int
kfd_ioctl_map_memory_to_gpu(intptr_t arg, int mode)
{
	struct kfd_ioctl_map_memory_to_gpu_args a;
	struct kfd_process *p;
	int rc;

	if (ddi_copyin((void *)arg, &a, sizeof (a), mode) != 0)
		return (EFAULT);
	p = kfd_current_process();
	if (p == NULL)
		return (ENODEV);
	rc = kfd_mem_map_to_gpu(p, a.handle);
	if (rc != 0)
		return (rc);
	a.n_success = a.n_devices;	/* single GPU: all requested mapped */
	if (ddi_copyout(&a, (void *)arg, sizeof (a), mode) != 0)
		return (EFAULT);
	return (0);
}

static int
kfd_ioctl_unmap_memory_from_gpu(intptr_t arg, int mode)
{
	struct kfd_ioctl_unmap_memory_from_gpu_args a;
	struct kfd_process *p;
	int rc;

	if (ddi_copyin((void *)arg, &a, sizeof (a), mode) != 0)
		return (EFAULT);
	p = kfd_current_process();
	if (p == NULL)
		return (ENODEV);
	rc = kfd_mem_unmap_from_gpu(p, a.handle);
	if (rc != 0)
		return (rc);
	a.n_success = a.n_devices;
	if (ddi_copyout(&a, (void *)arg, sizeof (a), mode) != 0)
		return (EFAULT);
	return (0);
}

static int
kfd_ioctl_get_clock_counters(intptr_t arg, int mode)
{
	struct kfd_ioctl_get_clock_counters_args a;

	if (ddi_copyin((void *)arg, &a, sizeof (a), mode) != 0)
		return (EFAULT);
	if (kfd_device_by_gpu_id(a.gpu_id) == NULL)
		return (ENODEV);
	/*
	 * The GPU clock counter is a live register read (hardware-gated); the
	 * CPU/system counters come from the illumos high-res clock. Off-hardware
	 * the GPU counter is 0. gethrtime() is a real genunix KPI.
	 */
	a.gpu_clock_counter = 0;
	a.cpu_clock_counter = (uint64_t)gethrtime();
	a.system_clock_counter = (uint64_t)gethrtime();
	a.system_clock_freq = 1000000000ULL;	/* gethrtime is nanoseconds */
	if (ddi_copyout(&a, (void *)arg, sizeof (a), mode) != 0)
		return (EFAULT);
	return (0);
}

static int
kfd_ioctl_available_memory(intptr_t arg, int mode)
{
	struct kfd_ioctl_get_available_memory_args a;
	struct kfd_dev *kdev;

	if (ddi_copyin((void *)arg, &a, sizeof (a), mode) != 0)
		return (EFAULT);
	kdev = kfd_device_by_gpu_id(a.gpu_id);
	if (kdev == NULL)
		return (ENODEV);
	/* the VRAM size the C3-amdgpu attach recorded (0 off-hardware) */
	a.available = kdev->adev != NULL ? (uint64_t)kdev->adev->vram_size : 0;
	if (ddi_copyout(&a, (void *)arg, sizeof (a), mode) != 0)
		return (EFAULT);
	return (0);
}

/*
 * kfd_ioctl - the /dev/kfd dispatch, keyed on the AMDKFD ioctl nr. Called from
 * drm_core.c's cb_ioctl when the open minor == KFD_MINOR. Unimplemented /
 * deferred commands (events, SVM, CRIU, debugger, tile-config, dmabuf) return
 * ENOTTY -- libhsakmt probes capabilities and does not require them for the
 * core compute path; they append here as they are wired.
 */
int
kfd_ioctl(dev_t d, int cmd, intptr_t arg, int mode, cred_t *credp, int *rvalp)
{
	int err;

	(void) d; (void) credp;
	*rvalp = 0;

	switch (AMDKFD_IOC_NR((unsigned)cmd)) {
	case AMDKFD_IOC_NR(AMDKFD_IOC_GET_VERSION):
		err = kfd_ioctl_get_version(arg, mode);
		break;
	case AMDKFD_IOC_NR(AMDKFD_IOC_CREATE_QUEUE):
		err = kfd_ioctl_create_queue(arg, mode);
		break;
	case AMDKFD_IOC_NR(AMDKFD_IOC_DESTROY_QUEUE):
		err = kfd_ioctl_destroy_queue(arg, mode);
		break;
	case AMDKFD_IOC_NR(AMDKFD_IOC_GET_CLOCK_COUNTERS):
		err = kfd_ioctl_get_clock_counters(arg, mode);
		break;
	case AMDKFD_IOC_NR(AMDKFD_IOC_GET_PROCESS_APERTURES):
		err = kfd_ioctl_get_process_apertures(arg, mode);
		break;
	case AMDKFD_IOC_NR(AMDKFD_IOC_GET_PROCESS_APERTURES_NEW):
		err = kfd_ioctl_get_process_apertures_new(arg, mode);
		break;
	case AMDKFD_IOC_NR(AMDKFD_IOC_ACQUIRE_VM):
		err = kfd_ioctl_acquire_vm(arg, mode);
		break;
	case AMDKFD_IOC_NR(AMDKFD_IOC_SET_SCRATCH_BACKING_VA):
		err = kfd_ioctl_set_scratch_backing_va(arg, mode);
		break;
	case AMDKFD_IOC_NR(AMDKFD_IOC_ALLOC_MEMORY_OF_GPU):
		err = kfd_ioctl_alloc_memory_of_gpu(arg, mode);
		break;
	case AMDKFD_IOC_NR(AMDKFD_IOC_FREE_MEMORY_OF_GPU):
		err = kfd_ioctl_free_memory_of_gpu(arg, mode);
		break;
	case AMDKFD_IOC_NR(AMDKFD_IOC_MAP_MEMORY_TO_GPU):
		err = kfd_ioctl_map_memory_to_gpu(arg, mode);
		break;
	case AMDKFD_IOC_NR(AMDKFD_IOC_UNMAP_MEMORY_FROM_GPU):
		err = kfd_ioctl_unmap_memory_from_gpu(arg, mode);
		break;
	case AMDKFD_IOC_NR(AMDKFD_IOC_AVAILABLE_MEMORY):
		err = kfd_ioctl_available_memory(arg, mode);
		break;
	/*
	 * Deferred (return ENOTTY; not on the core compute path). Their ABI
	 * numbers + struct shapes are in uapi/kfd_ioctl.h so the handlers slot
	 * in without touching the dispatch key:
	 *   0x04 SET_MEMORY_POLICY, 0x07 UPDATE_QUEUE, 0x08-0x0C events,
	 *   0x11 (done) 0x12 GET_TILE_CONFIG, 0x13 SET_TRAP_HANDLER,
	 *   0x1A SET_CU_MASK, 0x1B GET_QUEUE_WAVE_STATE, 0x1C-0x1D dmabuf,
	 *   0x1E ALLOC_QUEUE_GWS, 0x1F SMI_EVENTS, 0x20 SVM, 0x21 XNACK,
	 *   0x22 CRIU, 0x24 EXPORT_DMABUF, 0x26 DBG_TRAP.
	 */
	default:
		err = ENOTTY;
		break;
	}
	return (err);
}
