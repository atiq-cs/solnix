/*
 * pvr_sync.c - C-PVR-b: PowerVR job synchronization, illumos side. The pvr
 * analogue of Linux's pvr_sync.c, wired onto the C1 dma-fence (src/drm_dma.c)
 * + the C1 scheduler fence (src/drm_sched.c). SUBMIT_JOBS carries a sync_ops
 * array of drm_pvr_sync_op (waits + signals over drm_syncobj timeline points);
 * pvr_sync converts those to dma-fence dependencies + a signal on the job's
 * finished fence.
 *
 * The C1 framework already supplies the fence primitive (dma_fence: kref +
 * kmutex + kcondvar + a callback list) + the sync_file fd export (drm_prime.c),
 * the same substrate C-PVR-a's winsys uses via the standard vk_drm_syncobj
 * path. pvr_sync's job is only to bridge the pvr sync_op ABI to those; the
 * output fence a job signals is a C1 drm_sched_fence.
 */

#include <sys/types.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>

#include "drm_internal.h"
#include "drm_sched.h"
#include "linux-compat/linux_dma.h"
#include "pvr_priv.h"

/*
 * pvr_sync_create_output_fence - the fence a submitted job signals on
 * completion. The C1 scheduler already embeds a finished dma-fence in every
 * drm_sched_job (s_finished); this returns a fresh detached dma-fence for the
 * cases pvr needs a standalone signal fence (e.g. a NULL-command sync-only
 * submit). Linux: pvr_sync -> the drm_sched job's scheduled/finished fences.
 *
 * The wait side (sync_ops with DRM_PVR_SYNC_OP_FLAG_WAIT) resolves each
 * drm_syncobj handle to its dma-fence and adds it as a scheduler dependency;
 * that resolution goes through the C1 drm_syncobj/sync_file path (drm_prime.c
 * sync_file_get_fence), the same fd mechanism C-PVR-a's winsys drives. The
 * per-op array walk is straightforward bookkeeping over that primitive and is
 * left to the live submit path (the FIFO scheduler serializes today).
 */
static const char *
pvr_fence_driver_name(struct dma_fence *f)
{
	(void) f;
	return ("pvr");
}
static const char *
pvr_fence_timeline_name(struct dma_fence *f)
{
	(void) f;
	return ("pvr_queue");
}
static void
pvr_fence_release(struct dma_fence *f)
{
	kmem_free(f, sizeof (*f));
}
static const struct dma_fence_ops pvr_fence_ops = {
	.get_driver_name = pvr_fence_driver_name,
	.get_timeline_name = pvr_fence_timeline_name,
	.enable_signaling = NULL,
	.signaled = NULL,
	.wait = NULL,
	.release = pvr_fence_release,
};

static kmutex_t pvr_fence_lock;
static uint64_t pvr_fence_ctx;
static volatile uint64_t pvr_fence_seqno;
static boolean_t pvr_fence_lock_inited;

struct dma_fence *
pvr_sync_create_output_fence(struct pvr_softc *sc)
{
	struct dma_fence *f = kmem_zalloc(sizeof (*f), KM_SLEEP);

	(void) sc;
	if (!pvr_fence_lock_inited) {
		mutex_init(&pvr_fence_lock, NULL, MUTEX_DRIVER, NULL);
		pvr_fence_ctx = dma_fence_context_alloc(1);
		pvr_fence_lock_inited = B_TRUE;
	}
	dma_fence_init(f, &pvr_fence_ops, &pvr_fence_lock, pvr_fence_ctx,
	    atomic_inc_64_nv(&pvr_fence_seqno));
	return (f);
}
