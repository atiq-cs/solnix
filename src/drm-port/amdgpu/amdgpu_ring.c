/*
 * amdgpu_ring.c - C3-amdgpu-c: the GPU command rings (GFX + SDMA) + the IH
 * (interrupt handler) ring, illumos side.
 *
 * A ring is a command buffer in a GTT amdgpu_bo (C3-amdgpu-b) the CPU writes
 * packets into and the GPU reads via a read/write pointer:
 *
 *   CPU: amdgpu_ring_write(ring, packet_dword) -> ring->ring[wptr++]
 *        then rings the doorbell (BAR2) / writes the wptr register
 *   GPU: reads from rptr up to wptr, executes, advances rptr (written back
 *        into the writeback buffer so the CPU can see progress)
 *
 * This is the transport EXECBUFFER (the C1d 3D submit path) ultimately feeds
 * on real hardware: a drm_sched_job's run_job writes the indirect-buffer (IB)
 * pointer into the GFX ring + advances the wptr.
 *
 * C3-amdgpu-c does the ring BRING-UP (alloc the ring BO + set rptr/wptr/
 * ptr_mask/doorbell), NOT the live submit (that needs firmware + a powered
 * GPU, C3-amdgpu-d). amdgpu_ring_write is provided so the submit path can be
 * wired; without a live GPU it just fills the CPU-side ring buffer.
 *
 * Crib provenance (struct + flow; NO Linux/NetBSD .c lifted):
 *   - the ring_size/buf_mask/ptr_mask math + the GTT ring BO:
 *     ../amdgpu-ref/src/amdgpu_ring.c amdgpu_ring_init (ring_size =
 *     roundup_pow_of_two(max_dw*4*sched_hw_submission); GEM_DOMAIN_GTT)
 *   - amdgpu_ring_write / the wptr wrap: amdgpu_ring.h amdgpu_ring_write
 *   - the doorbell index: gfx_v10_0 / sdma_v5_0 ring->doorbell_index setup
 *   - the IH ring (ring BO + rptr/wptr): ../amdgpu-ref/src/amdgpu_ih.h
 *     struct amdgpu_ih_ring + amdgpu_navi10_ih.c navi10_ih_irq_init
 */

#include <sys/types.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/kmem.h>
#include <sys/sysmacros.h>
#include <sys/cmn_err.h>

#include "amdgpu_priv.h"
#include "ttm_priv.h"
#include "amdgpu_ip.h"

/* roundup to the next power of two (crib: roundup_pow_of_two). */
static uint32_t
amdgpu_roundup_pow2(uint32_t v)
{
	uint32_t p = 1;

	if (v == 0)
		return (1);
	while (p < v)
		p <<= 1;
	return (p);
}

/*
 * amdgpu_ring_init - the reduced amdgpu_ring_init: allocate the ring BO in GTT
 * and set up the ring pointers + writeback slots + doorbell. Crib:
 * ../amdgpu-ref/src/amdgpu_ring.c amdgpu_ring_init, reduced (no fence driver,
 * no drm_sched, no wb for cond_exec/trail_fence -- just rptr/wptr/fence).
 *
 *   ring_size = pow2(max_dw * 4 * sched_hw_submission)  [bytes]
 *   buf_mask  = ring_size/4 - 1                         [dword index mask]
 *   ptr_mask  = buf_mask (32-bit wptr wrap)
 *   ring BO   = amdgpu_bo_create(GTT, ring_size)  -> CPU ptr + GPU addr
 *   rptr/wptr/fence = writeback dword slots
 */
int
amdgpu_ring_init(struct amdgpu_softc *sc, struct amdgpu_ring *ring,
    enum amdgpu_ring_type type, uint32_t max_dw, const char *name)
{
	struct amdgpu_bo *bo;
	void *cpu;
	int r;

	bzero(ring, sizeof (*ring));
	ring->sc = sc;
	ring->type = type;
	ring->max_dw = max_dw;
	(void) snprintf(ring->name, sizeof (ring->name), "%s", name);

	ring->ring_size =
	    amdgpu_roundup_pow2(max_dw * 4 * AMDGPU_SCHED_HW_SUBMISSION);
	ring->buf_mask = (ring->ring_size / 4) - 1;
	ring->ptr_mask = ring->buf_mask;

	/* the ring buffer BO (GTT: CPU-writable + GPU-visible) */
	r = amdgpu_bo_create(sc, ring->ring_size, AMDGPU_GEM_DOMAIN_GTT, &bo);
	if (r != DDI_SUCCESS)
		return (r);
	cpu = amdgpu_bo_cpu_addr(bo);
	if (cpu == NULL) {
		amdgpu_bo_free(bo);
		return (DDI_FAILURE);
	}
	ring->ring_obj = bo;
	ring->ring = (volatile uint32_t *)cpu;
	ring->gpu_addr = amdgpu_bo_gpu_offset(bo);
	ring->wptr = 0;

	/* rptr/wptr/fence writeback slots (the GPU posts progress here) */
	if (amdgpu_wb_get(sc, &ring->rptr_offs) != DDI_SUCCESS)
		goto fail_bo;
	if (amdgpu_wb_get(sc, &ring->wptr_offs) != DDI_SUCCESS)
		goto fail_rptr;
	if (amdgpu_wb_get(sc, &ring->fence_offs) != DDI_SUCCESS)
		goto fail_wptr;

	/*
	 * The doorbell: a BAR2 dword the CPU writes the new wptr to, kicking
	 * the GPU. gfx_v10_0/sdma_v5_0 assign fixed per-ring doorbell indices;
	 * here we key off the ring type (GFX=0, SDMA=1) as the reduced index.
	 * Programming the doorbell aperture is deferred (needs live MMIO).
	 */
	ring->use_doorbell = B_TRUE;
	ring->doorbell_index = (type == AMDGPU_RING_TYPE_GFX) ? 0 : 1;

	/* NOP-fill the ring (crib: amdgpu_ring_clear_ring); NOP == 0 here */
	bzero((void *)ring->ring, ring->ring_size);

	cmn_err(CE_CONT, "?amdgpu: ring '%s': %u bytes @ gpu 0x%llx, "
	    "doorbell %u\n", ring->name, ring->ring_size,
	    (unsigned long long)ring->gpu_addr, ring->doorbell_index);
	return (DDI_SUCCESS);

fail_wptr:
	amdgpu_wb_free(sc, ring->wptr_offs);
fail_rptr:
	amdgpu_wb_free(sc, ring->rptr_offs);
fail_bo:
	amdgpu_bo_free(ring->ring_obj);
	ring->ring_obj = NULL;
	ring->ring = NULL;
	return (DDI_FAILURE);
}

void
amdgpu_ring_fini(struct amdgpu_ring *ring)
{
	if (ring->sc == NULL)
		return;
	if (ring->ring_obj != NULL) {
		amdgpu_wb_free(ring->sc, ring->fence_offs);
		amdgpu_wb_free(ring->sc, ring->wptr_offs);
		amdgpu_wb_free(ring->sc, ring->rptr_offs);
		amdgpu_bo_free(ring->ring_obj);
		ring->ring_obj = NULL;
		ring->ring = NULL;
	}
	ring->sc = NULL;
}

/*
 * amdgpu_ring_write - append one dword to the ring, wrapping at buf_mask.
 * Crib: amdgpu_ring.h amdgpu_ring_write. On a live GPU the caller then
 * advances the hardware wptr / rings the doorbell; here it fills the CPU-side
 * ring buffer (the submit path is wired in C3-amdgpu-d).
 */
void
amdgpu_ring_write(struct amdgpu_ring *ring, uint32_t v)
{
	ring->ring[ring->wptr & ring->buf_mask] = v;
	ring->wptr = (ring->wptr + 1) & ring->ptr_mask;
}

/* ======================================================================
 * The IH (interrupt handler) ring.
 *
 * The GPU writes interrupt-vector (IV) entries into this ring; the ISR
 * (amdgpu.c amdgpu_intr_stub, on the MSI-X vector C3-amdgpu-a reserved) drains
 * from rptr to the hardware wptr and dispatches each IV to the owning IP
 * block. C3-amdgpu-c stands up the ring BO + the rptr; the IV decode + the
 * .process dispatch are deferred (need live interrupts, C3-amdgpu-d).
 *
 * Crib: ../amdgpu-ref/src/amdgpu_ih.h struct amdgpu_ih_ring (ring/gpu_addr/
 * ring_size/ptr_mask/rptr) + amdgpu_navi10_ih.c navi10_ih_irq_init (the ring
 * BO + the WPTR/RPTR register wiring, deferred).
 * ====================================================================== */

int
amdgpu_ih_ring_init(struct amdgpu_softc *sc)
{
	struct amdgpu_ih *ih = &sc->ip->ih;
	struct amdgpu_bo *bo;
	void *cpu;
	int r;

	if (ih->ring_obj != NULL)
		return (DDI_SUCCESS);

	r = amdgpu_bo_create(sc, AMDGPU_IH_RING_SIZE, AMDGPU_GEM_DOMAIN_GTT,
	    &bo);
	if (r != DDI_SUCCESS)
		return (r);
	cpu = amdgpu_bo_cpu_addr(bo);
	if (cpu == NULL) {
		amdgpu_bo_free(bo);
		return (DDI_FAILURE);
	}
	ih->ring_obj = bo;
	ih->ring = (volatile uint32_t *)cpu;
	ih->gpu_addr = amdgpu_bo_gpu_offset(bo);
	ih->ring_size = AMDGPU_IH_RING_SIZE;
	ih->ptr_mask = (AMDGPU_IH_RING_SIZE / 4) - 1;
	ih->rptr = 0;
	ih->enabled = B_FALSE;		/* enabled when the GPU powers up */
	bzero((void *)ih->ring, ih->ring_size);

	cmn_err(CE_CONT, "?amdgpu: IH ring: %u bytes @ gpu 0x%llx\n",
	    ih->ring_size, (unsigned long long)ih->gpu_addr);
	return (DDI_SUCCESS);
}

void
amdgpu_ih_ring_fini(struct amdgpu_softc *sc)
{
	struct amdgpu_ih *ih = &sc->ip->ih;

	if (ih->ring_obj != NULL) {
		amdgpu_bo_free(ih->ring_obj);
		ih->ring_obj = NULL;
		ih->ring = NULL;
	}
	ih->enabled = B_FALSE;
}
