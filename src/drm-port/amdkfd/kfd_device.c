/*
 * kfd_device.c - C3-KFD: the KFD device (kfd_dev) init, gfx10 topology
 * apertures, and the doorbell (BAR2) aperture manager.
 *
 * Crib: drivers/gpu/drm/amd/amdkfd/kfd_device.c (kgd2kfd_device_init) +
 * kfd_doorbell.c (kfd_doorbell_init / kfd_get_doorbell_dw_offset_in_bar) +
 * kfd_flat_memory.c (the gfx10 SVM apertures). Reduced HARD to the compute
 * floor: one kfd_dev per amdgpu device, the constant gfx10 apertures, and a
 * per-process doorbell-page bitmap over the BAR2 aperture.
 *
 * The doorbell aperture is BAR2 on Navi (mapped by amdgpu_map_bars, C3-amdgpu).
 * kgd2kfd on Linux queries the doorbell BAR base/size from the KGD (amdgpu);
 * here we read the amdgpu softc's doorbell_base/size the C3-amdgpu attach
 * recorded. Off-hardware the BAR may be zero-sized (no device), in which case
 * the aperture is empty but the bookkeeping still compiles + self-checks.
 */

#include <sys/types.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/kmem.h>
#include <sys/cmn_err.h>
#include "kfd_priv.h"

/*
 * The gfx10 (Navi 1x) flat-address apertures, cribbed from kfd_flat_memory.c
 * kfd_init_apertures_v9/v10 (GFXv9+ uses the same 48-bit canonical split).
 * These are the virtual-address windows the ROCm runtime maps LDS/scratch/
 * GPUVM allocations into; constant per asic family, reported verbatim by
 * GET_PROCESS_APERTURES so libhsakmt lays out its address space correctly.
 *
 * SVM (GFXv9+): the GPUVM aperture is a bounded low window below the LDS/
 * scratch private apertures; LDS + scratch are the high per-queue windows.
 * The GPUVM app window is bounded (well below LDS_BASE) so the three apertures
 * are strictly ordered and non-overlapping, matching the amdkfd v9/v10 layout.
 */
#define	KFD_GFX10_GPUVM_BASE	0x1000000ULL		/* SVM user base */
#define	KFD_GFX10_GPUVM_LIMIT	0x000001ffffffffffULL	/* bounded app window */
#define	KFD_GFX10_LDS_BASE	0x0000100000000000ULL
#define	KFD_GFX10_LDS_LIMIT	0x00001000ffffffffULL
#define	KFD_GFX10_SCRATCH_BASE	0x0000200000000000ULL
#define	KFD_GFX10_SCRATCH_LIMIT	0x00002000ffffffffULL

/* single-GPU solnix: exactly one kfd_dev, findable by gpu_id from the ioctls */
static struct kfd_dev *kfd_the_dev = NULL;

/*
 * kfd_device_init - stand up the KFD view of an amdgpu device. Called from the
 * KFD chardev bind after the amdgpu attach has the BARs/TTM up.
 */
struct kfd_dev *
kfd_device_init(struct amdgpu_softc *adev)
{
	struct kfd_dev *kdev;

	kdev = kmem_zalloc(sizeof (*kdev), KM_SLEEP);
	kdev->adev = adev;
	kdev->gpu_id = KFD_GPU_ID_NAVI12;

	kdev->gpuvm_base = KFD_GFX10_GPUVM_BASE;
	kdev->gpuvm_limit = KFD_GFX10_GPUVM_LIMIT;
	kdev->lds_base = KFD_GFX10_LDS_BASE;
	kdev->lds_limit = KFD_GFX10_LDS_LIMIT;
	kdev->scratch_base = KFD_GFX10_SCRATCH_BASE;
	kdev->scratch_limit = KFD_GFX10_SCRATCH_LIMIT;

	kdev->max_queues = KFD_MAX_QUEUES_PER_PROCESS;

	/*
	 * The doorbell aperture over BAR2. amdgpu records the doorbell BAR
	 * base/size in the softc (doorbell_base/doorbell_size); off-hardware
	 * (no device attached) these are 0 and the aperture is empty -- the
	 * page allocator then returns ENOSPC, which the queue path treats as
	 * a (non-fatal, compile-phase) hardware-gated condition.
	 */
	mutex_init(&kdev->doorbells.lock, NULL, MUTEX_DRIVER, NULL);
	kdev->doorbells.base = adev != NULL ? adev->doorbell_base : 0;
	kdev->doorbells.size = adev != NULL ? adev->doorbell_size : 0;
	kdev->doorbells.page_count =
	    (uint32_t)(kdev->doorbells.size / KFD_DOORBELL_PAGE_SIZE);
	if (kdev->doorbells.page_count > KFD_MAX_DOORBELL_PROCESSES)
		kdev->doorbells.page_count = KFD_MAX_DOORBELL_PROCESSES;

	kdev->initialized = B_TRUE;
	kfd_the_dev = kdev;

	cmn_err(CE_CONT, "?kfd: device init gpu_id=0x%x doorbell pages=%u "
	    "(BAR2 base=0x%llx size=0x%llx)\n", kdev->gpu_id,
	    kdev->doorbells.page_count,
	    (unsigned long long)kdev->doorbells.base,
	    (unsigned long long)kdev->doorbells.size);
	return (kdev);
}

void
kfd_device_fini(struct kfd_dev *kdev)
{
	if (kdev == NULL)
		return;
	mutex_destroy(&kdev->doorbells.lock);
	if (kfd_the_dev == kdev)
		kfd_the_dev = NULL;
	kmem_free(kdev, sizeof (*kdev));
}

/*
 * kfd_device_by_gpu_id - the ioctl-side lookup: map an ABI gpu_id to the
 * kfd_dev. Single-GPU, so any matching id returns the one device; a zero id
 * (some libhsakmt calls default it) also resolves to the single device.
 */
struct kfd_dev *
kfd_device_by_gpu_id(uint32_t gpu_id)
{
	if (kfd_the_dev == NULL)
		return (NULL);
	if (gpu_id == 0 || gpu_id == kfd_the_dev->gpu_id)
		return (kfd_the_dev);
	return (NULL);
}

/*
 * kfd_doorbell_alloc_page - assign a per-process doorbell page out of the BAR2
 * aperture. Crib: kfd_doorbell.c allocate_doorbell / the doorbell_bitmap. One
 * page per process; the process's queues take doorbell dwords within it.
 */
int
kfd_doorbell_alloc_page(struct kfd_dev *kdev, uint32_t *page_out)
{
	uint32_t i;

	if (kdev == NULL)
		return (ENODEV);
	mutex_enter(&kdev->doorbells.lock);
	if (kdev->doorbells.page_count == 0) {
		/* hardware-gated: no BAR2 aperture off a real device */
		mutex_exit(&kdev->doorbells.lock);
		return (ENOSPC);
	}
	for (i = 0; i < kdev->doorbells.page_count; i++) {
		if (kdev->doorbells.page_used[i] == 0) {
			kdev->doorbells.page_used[i] = 1;
			*page_out = i;
			mutex_exit(&kdev->doorbells.lock);
			return (0);
		}
	}
	mutex_exit(&kdev->doorbells.lock);
	return (ENOSPC);
}

void
kfd_doorbell_free_page(struct kfd_dev *kdev, uint32_t page)
{
	if (kdev == NULL)
		return;
	mutex_enter(&kdev->doorbells.lock);
	if (page < kdev->doorbells.page_count)
		kdev->doorbells.page_used[page] = 0;
	mutex_exit(&kdev->doorbells.lock);
}

/*
 * kfd_doorbell_offset - the mmap offset (into the /dev/kfd doorbell mapping)
 * for a given process page + queue doorbell id. Crib: kfd_doorbell.c
 * kfd_get_doorbell_dw_offset_in_bar: page*PAGE_SIZE + doorbell_id*DWORD_SIZE.
 * This is the doorbell_offset the CREATE_QUEUE reply hands userland; libhsakmt
 * mmaps /dev/kfd at this offset to get the queue's doorbell MMIO slot.
 */
uint64_t
kfd_doorbell_offset(struct kfd_dev *kdev, uint32_t page, uint32_t doorbell_id)
{
	(void) kdev;
	return ((uint64_t)page * KFD_DOORBELL_PAGE_SIZE +
	    (uint64_t)doorbell_id * KFD_DOORBELL_DWORD_SIZE);
}
