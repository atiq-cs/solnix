/*
 * amdgpu_job.h - C3-amdgpu-d: the amdgpu scheduler job + indirect buffer (IB),
 * the ring -> C1 drm_sched wiring for live EXECBUFFER.
 *
 * See amdgpu_job.c for the submit chain + the HARDWARE-GATED marking. Adds a
 * per-ring GPU scheduler to the IP aggregate so the C1d-style EXECBUFFER path
 * can push amdgpu jobs.
 *
 * Crib provenance:
 *   - struct amdgpu_ib (reduced): Linux amdgpu.h struct amdgpu_ib
 *   - struct amdgpu_job (reduced): Linux amdgpu_job.h struct amdgpu_job
 *   - the drm_sched_job base + push flow: src/drm_sched.h + virtio_gpu_3d.c
 */

#ifndef _AMDGPU_JOB_H_
#define _AMDGPU_JOB_H_

#include <sys/types.h>
#include "amdgpu_ip.h"		/* struct amdgpu_ring, struct amdgpu_softc */
#include "drm_sched.h"		/* struct drm_sched_job, drm_gpu_scheduler */

struct dma_fence;

/*
 * struct amdgpu_ib - one indirect buffer: a span of a GTT BO the EXECBUFFER
 * ioctl filled with the command stream. The ring's IB packet points the engine
 * at it. Reduced (crib: amdgpu.h struct amdgpu_ib): kept gpu_addr + length_dw;
 * dropped the sa_bo sub-allocator / flags / vm ptr (deferred).
 */
struct amdgpu_ib {
	uint64_t	gpu_addr;	/* GPU addr of the IB in a GTT BO */
	uint32_t	length_dw;	/* IB size in dwords */
};

/*
 * struct amdgpu_job - one scheduler job carrying an IB for a ring. The
 * drm_sched_job base MUST be first (the scheduler up-casts job==base). Crib:
 * amdgpu_job.h struct amdgpu_job, reduced to one IB + the target ring.
 */
struct amdgpu_job {
	struct drm_sched_job	base;	/* first: scheduler up-casts */
	struct amdgpu_softc	*sc;
	struct amdgpu_ring	*ring;	/* GFX or SDMA */
	struct amdgpu_ib	ib;
};

/* --- IB emit onto a ring (amdgpu_job.c) --- */
int	amdgpu_ib_schedule(struct amdgpu_ring *, struct amdgpu_ib *);

/* --- the scheduler job path (amdgpu_job.c) --- */
struct amdgpu_job *amdgpu_job_alloc(struct amdgpu_softc *, struct amdgpu_ring *,
	    uint64_t ib_gpu_addr, uint32_t ib_length_dw);
struct dma_fence *amdgpu_job_submit(struct drm_gpu_scheduler *,
	    struct amdgpu_job *);

#endif	/* _AMDGPU_JOB_H_ */
