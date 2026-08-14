/*
 * amdgpu_job.c - C3-amdgpu-d: the ring -> C1 scheduler wiring for live
 * EXECBUFFER. Connects the C3-c GFX/SDMA rings' submit path to the C1
 * drm_sched run_job, so the (C1d-style) EXECBUFFER ioctl feeds real ring
 * packets on hardware.
 *
 * ============ COMPILES; the actual GPU execution is HARDWARE-GATED ==========
 *
 * The submit chain mirrors the virtio_gpu EXECBUFFER path (src/virtio_gpu_3d.c
 * virtio_gpu_submit / _submit_run / drm_sched_entity_push_job) but targets a
 * real amdgpu ring instead of the virtio controlq:
 *
 *   EXECBUFFER ioctl (an IB in a GTT BO)                       [C1d contract]
 *     -> amdgpu_job_alloc + amdgpu_job_submit                  [this file]
 *        -> drm_sched_job_init + drm_sched_entity_push_job     [C1c scheduler]
 *           -> (scheduler worker) amdgpu_job_run               [run_job]
 *              -> amdgpu_ib_schedule                           [this file]
 *                 -> amdgpu_ring_write the IB packet           [C3-c ring]
 *                 -> ring the doorbell (advance the hw wptr)   [HARDWARE-GATED]
 *              -> return a hardware dma_fence (the fence writeback slot)
 *
 * The job/IB structs, the ring-packet emit (amdgpu_ring_write of the PACKET3
 * INDIRECT_BUFFER / SDMA indirect packet), and the scheduler wiring all COMPILE
 * + are structurally verifiable. The doorbell write + the fence writeback poll
 * only do anything on a powered GPU (the wptr register + fence slot are live
 * silicon), so amdgpu_job_run returns NULL off-hardware (synchronous "done"
 * under the C1c FIFO) and the real hardware fence path is HARDWARE-GATED.
 *
 * Crib provenance (job/IB flow + packet layout; NO Linux/NetBSD .c lifted):
 *   - amdgpu_job / amdgpu_job_run / drm_sched wiring: Linux amdgpu_job.c
 *     (amdgpu_job_alloc / amdgpu_job_run) + the drm_sched backend
 *   - amdgpu_ib_schedule (emit the IB packet + WPTR/doorbell): amdgpu_ib.c
 *   - the PACKET3 INDIRECT_BUFFER opcode + the SDMA indirect packet:
 *     the stable Navi PM4 / SDMA packet spec (nvd.h PACKET3 macros)
 *   - the submit-job -> scheduler shape: src/virtio_gpu_3d.c virtio_gpu_submit
 */

#include <sys/types.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/kmem.h>
#include <sys/cmn_err.h>

#include "amdgpu_priv.h"
#include "ttm_priv.h"
#include "amdgpu_ip.h"
#include "drm_sched.h"
#include "linux-compat/linux_dma.h"
#include "amdgpu_job.h"

/*
 * PM4 / SDMA indirect-buffer packet encodings (crib: the stable Navi PM4
 * spec; nvd.h PACKET3 / SDMA_PKT). An IB is submitted to the GFX ring as a
 * PACKET3 INDIRECT_BUFFER carrying the IB's GPU address + dword size, and to
 * the SDMA ring as an SDMA_OP_INDIRECT packet.
 */
#define	PACKET3(op, n)		((3u << 30) | (((op) & 0xff) << 8) | \
				    ((n) & 0x3fff) << 16)
#define	PACKET3_INDIRECT_BUFFER	0x3f		/* IT_INDIRECT_BUFFER */
#define	INDIRECT_BUFFER_VALID	(1u << 23)

#define	SDMA_OP_INDIRECT	4
#define	SDMA_PKT_HEADER_OP(op)	((op) & 0xff)

/*
 * amdgpu_emit_ib_gfx - append a PACKET3 INDIRECT_BUFFER to the GFX ring so the
 * CP jumps to the IB. Crib: gfx_v10_0_ring_emit_ib_gfx.
 * amdgpu_ring_write (C3-c) fills the CPU-side ring; the doorbell/wptr advance
 * (amdgpu_ring_commit below) is what a live CP acts on.
 */
static void
amdgpu_emit_ib_gfx(struct amdgpu_ring *ring, uint64_t ib_gpu_addr,
    uint32_t ib_dwords)
{
	amdgpu_ring_write(ring, PACKET3(PACKET3_INDIRECT_BUFFER, 2));
	amdgpu_ring_write(ring, (uint32_t)(ib_gpu_addr & 0xfffffffcu));
	amdgpu_ring_write(ring, (uint32_t)(ib_gpu_addr >> 32));
	amdgpu_ring_write(ring, (ib_dwords & 0xfffff) | INDIRECT_BUFFER_VALID);
}

/*
 * amdgpu_emit_ib_sdma - append an SDMA indirect packet to the SDMA ring.
 * Crib: sdma_v5_0_ring_emit_ib. Same shape as the GFX emit for the reduced IB.
 */
static void
amdgpu_emit_ib_sdma(struct amdgpu_ring *ring, uint64_t ib_gpu_addr,
    uint32_t ib_dwords)
{
	amdgpu_ring_write(ring, SDMA_PKT_HEADER_OP(SDMA_OP_INDIRECT));
	amdgpu_ring_write(ring, (uint32_t)(ib_gpu_addr & 0xffffffe0u));
	amdgpu_ring_write(ring, (uint32_t)(ib_gpu_addr >> 32));
	amdgpu_ring_write(ring, ib_dwords);
}

/*
 * amdgpu_ring_commit - advance the hardware write pointer + ring the doorbell,
 * making the packets amdgpu_ring_write staged visible to the GPU. Crib:
 * amdgpu_ring.h amdgpu_ring_commit -> ring->funcs->set_wptr (gfx_v10 writes
 * mmCP_RB0_WPTR / the doorbell; sdma_v5 writes mmSDMA0_GFX_RB_WPTR).
 *
 * HARDWARE-GATED: the doorbell/WPTR write only kicks a powered GPU. On the
 * V520 the doorbell lives in BAR2 (mapped separately -- deferred; C3-a mapped
 * BAR0/BAR5). Off-hardware this is a no-op stub that just records the wptr.
 */
static void
amdgpu_ring_commit(struct amdgpu_ring *ring)
{
	/*
	 * On live hardware: write ring->wptr to the ring's WPTR register (or
	 * the BAR2 doorbell dword at ring->doorbell_index). Both are live MMIO
	 * the GPU polls; without a powered GPU + the BAR2 doorbell mapping this
	 * has no effect, so the submit completes synchronously (job_run returns
	 * NULL). The write itself is the HARDWARE-GATED step.
	 */
	(void) ring;
}

/*
 * amdgpu_ib_schedule - emit one IB onto its ring + commit. The core of the
 * live submit: pick the packet encoder for the ring type, stage the IB
 * pointer, advance the wptr/doorbell. Crib: amdgpu_ib.c amdgpu_ib_schedule
 * (reduced to a single IB, no vm-flush / cond-exec / preamble).
 */
int
amdgpu_ib_schedule(struct amdgpu_ring *ring, struct amdgpu_ib *ib)
{
	if (ring == NULL || ring->ring_obj == NULL)
		return (DDI_FAILURE);

	switch (ring->type) {
	case AMDGPU_RING_TYPE_GFX:
		amdgpu_emit_ib_gfx(ring, ib->gpu_addr, ib->length_dw);
		break;
	case AMDGPU_RING_TYPE_SDMA:
		amdgpu_emit_ib_sdma(ring, ib->gpu_addr, ib->length_dw);
		break;
	default:
		return (DDI_FAILURE);
	}

	amdgpu_ring_commit(ring);	/* HARDWARE-GATED doorbell/wptr */
	return (DDI_SUCCESS);
}

/* ---- the scheduler job (mirrors src/virtio_gpu_3d.c virtio_gpu_submit) ---- */

static void
amdgpu_job_free(struct drm_sched_job *sjob)
{
	struct amdgpu_job *job = (struct amdgpu_job *)sjob;

	kmem_free(job, sizeof (*job));
}

/*
 * amdgpu_job_run - the scheduler run_job. Emit the job's IB onto the target
 * ring + commit. On a real GPU this returns a hardware dma_fence tied to the
 * ring's fence writeback slot (the scheduler signals the job's finished fence
 * when that slot's seqno lands); off-hardware there is no live fence, so it
 * returns NULL (synchronous completion under the C1c FIFO scheduler). Crib:
 * amdgpu_job.c amdgpu_job_run.
 */
static struct dma_fence *
amdgpu_job_run(struct drm_sched_job *sjob)
{
	struct amdgpu_job *job = (struct amdgpu_job *)sjob;

	(void) amdgpu_ib_schedule(job->ring, &job->ib);

	/*
	 * HARDWARE-GATED: a live driver would return a dma_fence bound to
	 * job->ring's fence writeback slot (fence_offs), signalled when the GPU
	 * posts the fence seqno there. Without a powered GPU there is no such
	 * signal, so complete synchronously (NULL) -- the same contract the
	 * C1c FIFO virtio path uses. The fence-writeback wiring is the runtime
	 * checklist item.
	 */
	return (NULL);
}

/*
 * amdgpu_job_alloc - build a scheduler job carrying one IB (the IB is a GTT BO
 * the EXECBUFFER ioctl already filled with the command stream). The ring is
 * chosen by ip block (GFX for graphics/compute, SDMA for copy). Crib:
 * amdgpu_job.c amdgpu_job_alloc.
 */
struct amdgpu_job *
amdgpu_job_alloc(struct amdgpu_softc *sc, struct amdgpu_ring *ring,
    uint64_t ib_gpu_addr, uint32_t ib_length_dw)
{
	struct amdgpu_job *job;

	job = kmem_zalloc(sizeof (*job), KM_SLEEP);
	job->sc = sc;
	job->ring = ring;
	job->ib.gpu_addr = ib_gpu_addr;
	job->ib.length_dw = ib_length_dw;
	return (job);
}

/*
 * amdgpu_job_submit - push the job onto the C1 scheduler + return its finished
 * dma-fence (the caller's ref, what the EXECBUFFER out-fence exports / waits).
 * Mirrors virtio_gpu_ioctl_execbuffer's drm_sched_job_init +
 * drm_sched_entity_push_job. The scheduler serializes submits (C1c FIFO), so
 * per-BO dma-resv fencing is not needed for correctness at this stage.
 */
struct dma_fence *
amdgpu_job_submit(struct drm_gpu_scheduler *sched, struct amdgpu_job *job)
{
	(void) drm_sched_job_init(sched, &job->base);
	job->base.run_job = amdgpu_job_run;
	job->base.free_job = amdgpu_job_free;
	return (drm_sched_entity_push_job(&job->base));
}
