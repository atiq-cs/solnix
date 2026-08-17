/*
 * kfd_device_queue_manager.c - C3-KFD: user-mode compute queue create/destroy
 * + the doorbell allocation + the GPU memory alloc/map path.
 *
 * Crib: drivers/gpu/drm/amd/amdkfd/kfd_device_queue_manager.c
 * (create_queue_cpsch / destroy_queue) + kfd_queue.c (init_queue) +
 * kfd_doorbell.c (allocate_doorbell) + kfd_chardev.c
 * kfd_ioctl_alloc_memory_of_gpu / _map_memory_to_gpu, reduced to the
 * compile-phase compute floor.
 *
 * A KFD user-mode queue is the low-latency compute-dispatch primitive: the ROCm
 * runtime allocates the ring + the read/write-pointer dwords in GPU-mapped
 * memory (ALLOC_MEMORY_OF_GPU), then CREATE_QUEUE registers those addresses,
 * assigns a doorbell dword, and (on hardware) writes the MQD + maps the queue
 * onto the HWS/MES packet manager via a runlist so the GPU's scheduler picks it
 * up. Thereafter userland submits by writing the wptr to its ring and ringing
 * the doorbell -- NO syscall per submit. This file does the queue bookkeeping +
 * the doorbell assignment (real); the MQD write + runlist map (HWS/MES packet
 * manager, PM4 MAP_QUEUES) are HARDWARE-GATED (need firmware + a powered GPU)
 * and marked as such.
 *
 * The memory path wires ALLOC_MEMORY_OF_GPU onto the C3-amdgpu amdgpu_bo_create
 * (TTM VRAM/GTT); MAP_MEMORY_TO_GPU records the mapping (the live GPUVM PTE
 * program is the C3-amdgpu-d gart path, hardware-gated).
 */

#include <sys/types.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/kmem.h>
#include <sys/list.h>
#include <sys/ksynch.h>
#include <sys/cmn_err.h>
#include "kfd_priv.h"
#include "amdgpu_ip.h"		/* amdgpu_bo, amdgpu_bo_create/destroy */
#include "uapi/kfd_ioctl.h"	/* KFD_IOC_QUEUE_TYPE_*, MEM_FLAGS, max queue */

/* map a KFD queue_type + memory flag to the amdgpu domain the BO lives in */
#define	KFD_ALLOC_DOMAIN(flags)						\
	(((flags) & KFD_IOC_ALLOC_MEM_FLAGS_VRAM) ? AMDGPU_GEM_DOMAIN_VRAM : \
	    AMDGPU_GEM_DOMAIN_GTT)

/*
 * kfd_queue_create - the AMDKFD_IOC_CREATE_QUEUE core. Allocates a kfd_queue,
 * a doorbell dword within the process's page, records the ring/ptr VAs, and
 * (hardware) would write the MQD + map the queue. Returns the queue with its
 * queue_id + doorbell_offset filled for the ABI reply.
 */
int
kfd_queue_create(struct kfd_process *p, struct kfd_dev *kdev,
    uint32_t queue_type, uint64_t ring_base, uint64_t ring_size,
    uint64_t rptr_va, uint64_t wptr_va, uint32_t percentage,
    uint32_t priority, struct kfd_queue **q_out)
{
	struct kfd_queue *q;
	uint32_t qid;
	uint32_t doorbell_id;

	if (p == NULL || kdev == NULL)
		return (EINVAL);
	if (queue_type != KFD_IOC_QUEUE_TYPE_COMPUTE &&
	    queue_type != KFD_IOC_QUEUE_TYPE_COMPUTE_AQL &&
	    queue_type != KFD_IOC_QUEUE_TYPE_SDMA &&
	    queue_type != KFD_IOC_QUEUE_TYPE_SDMA_XGMI)
		return (EINVAL);
	if (percentage > KFD_MAX_QUEUE_PERCENTAGE ||
	    priority > KFD_MAX_QUEUE_PRIORITY)
		return (EINVAL);

	mutex_enter(&p->lock);
	if (p->queue_count >= kdev->max_queues) {
		mutex_exit(&p->lock);
		return (ENOSPC);
	}

	q = kmem_zalloc(sizeof (*q), KM_SLEEP);
	q->proc = p;
	q->dev = kdev;
	q->queue_type = queue_type;
	q->queue_percentage = percentage;
	q->queue_priority = priority;
	q->ring_base_address = ring_base;
	q->ring_size = ring_size;
	q->read_pointer_address = rptr_va;
	q->write_pointer_address = wptr_va;

	/*
	 * The doorbell dword id within the process page == the per-process
	 * queue index (crib: allocate_doorbell uses q->properties.queue_id as
	 * the doorbell slot for non-SDMA on gfx10). queue_count is that index.
	 */
	doorbell_id = p->queue_count;
	q->doorbell_id = doorbell_id;
	q->doorbell_offset = p->doorbell_page_assigned ?
	    kfd_doorbell_offset(kdev, p->doorbell_page, doorbell_id) : 0;

	qid = idr_alloc(&p->queue_ids, q);
	q->queue_id = qid;

	list_insert_tail(&p->queues, q);
	p->queue_count++;

	/*
	 * HARDWARE-GATED: write the MQD (memory queue descriptor) into a GTT BO
	 * and map the queue onto the HWS/MES via a PM4 MAP_QUEUES runlist packet
	 * so the GPU scheduler dispatches it. Needs the CP/MES firmware + a
	 * powered V520 (C3-amdgpu-d). Off-hardware the queue is "created" (the
	 * ABI reply is complete + the doorbell slot is real) but not GPU-mapped.
	 */
	q->mapped = B_FALSE;

	mutex_exit(&p->lock);

	cmn_err(CE_CONT, "?kfd: create_queue pid=%d qid=%u type=%u "
	    "doorbell_off=0x%llx ring=0x%llx sz=0x%llx\n", (int)p->pid, qid,
	    queue_type, (unsigned long long)q->doorbell_offset,
	    (unsigned long long)ring_base, (unsigned long long)ring_size);

	*q_out = q;
	return (0);
}

int
kfd_queue_destroy(struct kfd_process *p, uint32_t queue_id)
{
	struct kfd_queue *q;

	if (p == NULL)
		return (EINVAL);
	mutex_enter(&p->lock);
	q = idr_find(&p->queue_ids, queue_id);
	if (q == NULL) {
		mutex_exit(&p->lock);
		return (EINVAL);
	}
	/*
	 * HARDWARE-GATED: unmap the queue from the HWS/MES (PM4 UNMAP_QUEUES)
	 * + free the MQD BO before dropping the record. Off-hardware there is
	 * nothing mapped, so just drop the bookkeeping.
	 */
	idr_remove(&p->queue_ids, queue_id);
	list_remove(&p->queues, q);
	if (p->queue_count > 0)
		p->queue_count--;
	mutex_exit(&p->lock);

	kmem_free(q, sizeof (*q));
	return (0);
}

/*
 * kfd_mem_alloc - AMDKFD_IOC_ALLOC_MEMORY_OF_GPU: allocate a GPU buffer object
 * (VRAM or GTT) via the C3-amdgpu amdgpu_bo_create, wrap it in a kfd_mem, and
 * hand userland an opaque handle (the mem_handles idr token). The ring buffers,
 * kernel argument buffers, and compute allocations HIP/rocBLAS use all flow
 * through here.
 */
int
kfd_mem_alloc(struct kfd_process *p, struct kfd_dev *kdev, uint64_t va_addr,
    uint64_t size, uint32_t flags, struct kfd_mem **mem_out)
{
	struct kfd_mem *m;
	uint32_t token;
	int rc;

	if (p == NULL || kdev == NULL || size == 0)
		return (EINVAL);

	m = kmem_zalloc(sizeof (*m), KM_SLEEP);
	m->proc = p;
	m->dev = kdev;
	m->va_addr = va_addr;
	m->size = size;
	m->flags = flags;

	/*
	 * DOORBELL / MMIO_REMAP allocations are not TTM buffers -- they map a
	 * slice of the doorbell / HDP-flush MMIO. Off-hardware there is no BO;
	 * record the request (the mmap_offset path resolves it). The load-
	 * bearing compute allocations are VRAM/GTT, backed by amdgpu_bo_create.
	 */
	if (flags & (KFD_IOC_ALLOC_MEM_FLAGS_DOORBELL |
	    KFD_IOC_ALLOC_MEM_FLAGS_MMIO_REMAP |
	    KFD_IOC_ALLOC_MEM_FLAGS_USERPTR)) {
		m->bo = NULL;
	} else {
		rc = amdgpu_bo_create(kdev->adev, size, KFD_ALLOC_DOMAIN(flags),
		    &m->bo);
		if (rc != DDI_SUCCESS) {
			kmem_free(m, sizeof (*m));
			return (ENOMEM);
		}
	}

	mutex_enter(&p->lock);
	token = idr_alloc(&p->mem_handles, m);
	m->handle = (uint64_t)token;
	m->mmap_offset = va_addr;	/* CPU-mmap offset the render node uses */
	list_insert_tail(&p->mems, m);
	mutex_exit(&p->lock);

	*mem_out = m;
	return (0);
}

int
kfd_mem_free(struct kfd_process *p, uint64_t handle)
{
	struct kfd_mem *m;

	if (p == NULL)
		return (EINVAL);
	mutex_enter(&p->lock);
	m = idr_find(&p->mem_handles, (uint32_t)handle);
	if (m == NULL) {
		mutex_exit(&p->lock);
		return (EINVAL);
	}
	idr_remove(&p->mem_handles, (uint32_t)handle);
	list_remove(&p->mems, m);
	mutex_exit(&p->lock);

	if (m->bo != NULL)
		amdgpu_bo_free(m->bo);
	kmem_free(m, sizeof (*m));
	return (0);
}

/*
 * kfd_mem_map_to_gpu - AMDKFD_IOC_MAP_MEMORY_TO_GPU: map an allocation into the
 * GPUVM aperture so a compute shader can reach it. Records the mapping; the
 * live per-page GPUVM PTE program (walk the BO's DMA cookies, write the GART/
 * page-table entries, flush the TLB) is the C3-amdgpu-d gart path --
 * HARDWARE-GATED. Off-hardware the mapping is recorded (n_success accounting
 * works) but no PTE is written.
 */
int
kfd_mem_map_to_gpu(struct kfd_process *p, uint64_t handle)
{
	struct kfd_mem *m;

	if (p == NULL)
		return (EINVAL);
	mutex_enter(&p->lock);
	m = idr_find(&p->mem_handles, (uint32_t)handle);
	if (m == NULL) {
		mutex_exit(&p->lock);
		return (EINVAL);
	}
	m->mapped_to_gpu = B_TRUE;
	mutex_exit(&p->lock);
	return (0);
}

int
kfd_mem_unmap_from_gpu(struct kfd_process *p, uint64_t handle)
{
	struct kfd_mem *m;

	if (p == NULL)
		return (EINVAL);
	mutex_enter(&p->lock);
	m = idr_find(&p->mem_handles, (uint32_t)handle);
	if (m == NULL) {
		mutex_exit(&p->lock);
		return (EINVAL);
	}
	m->mapped_to_gpu = B_FALSE;
	mutex_exit(&p->lock);
	return (0);
}
