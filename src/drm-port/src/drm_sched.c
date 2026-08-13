/*
 * drm_sched.c - a minimal single-queue GPU job scheduler over dma-fence.
 *
 * Provenance: the shape (one run-queue of jobs, a scheduler kthread, each job
 * carries a "finished" dma_fence signalled on completion, entities push jobs)
 * follows Linux drivers/gpu/drm/scheduler/sched_main.c and NetBSD's drm2
 * scheduler use, cut down to the single hardware queue virtio-gpu needs. Linux
 * drm_sched fans out across rings + does credit accounting + timeout handling;
 * virtio-gpu submits serialized commands on one controlq, so C1c uses a single
 * FIFO run-queue drained by one worker thread. No NetBSD/Linux .c is lifted.
 *
 * The scheduler is deliberately transport-agnostic: a job's ->run op does the
 * actual submission (for virtio-gpu that is the virtio_gpu_exec chain from
 * virtio_gpu.c). run() returns a "hardware" dma_fence, or NULL for synchronous
 * completion; when that fence signals (or immediately if NULL) the scheduler
 * signals the job's finished fence, which is what a waiting Mesa/Vulkan submit
 * blocks on.
 *
 * C1c simplification: single run-queue, single worker, FIFO, no priorities, no
 * job timeout/reset (a hung job wedges the queue). virtio-gpu's serialized
 * controlq does not need more; wider fan-out / GPU-reset is C3-era work for a
 * real multi-ring GPU.
 */

#include <sys/types.h>
#include <sys/ksynch.h>
#include <sys/kmem.h>
#include <sys/list.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>

#include "linux-compat/linux_dma.h"
#include "drm_sched.h"

/* the finished-fence ops: a plain sw fence, nothing to enable/poll. */
static const char *
sched_fence_driver_name(struct dma_fence *f)
{
	(void) f;
	return ("drm_sched");
}
static const char *
sched_fence_timeline_name(struct dma_fence *f)
{
	(void) f;
	return ("drm_sched_entity");
}
static boolean_t
sched_fence_enable_signaling(struct dma_fence *f)
{
	(void) f;
	return (B_TRUE);	/* signalled explicitly by the worker */
}
static void
sched_fence_release(struct dma_fence *f)
{
	struct drm_sched_fence *sf = (struct drm_sched_fence *)f;
	kmem_free(sf, sizeof (*sf));
}
static const struct dma_fence_ops drm_sched_fence_ops = {
	.get_driver_name = sched_fence_driver_name,
	.get_timeline_name = sched_fence_timeline_name,
	.enable_signaling = sched_fence_enable_signaling,
	.signaled = NULL,
	.wait = NULL,
	.release = sched_fence_release,
};

/* the callback fired when a job's hardware fence signals -> finish the job. */
static void
drm_sched_hw_done(struct dma_fence *hw, struct dma_fence_cb *cb)
{
	struct drm_sched_job *job = (struct drm_sched_job *)((char *)cb -
	    offsetof(struct drm_sched_job, s_cb));

	(void) hw;
	(void) dma_fence_signal(&job->s_finished->base);
	dma_fence_put(&job->s_finished->base);	/* worker's ref */
	if (job->free_job != NULL)
		job->free_job(job);
}

/*
 * The scheduler worker: pull jobs FIFO, run each, and arrange to signal its
 * finished fence when the run's hardware fence signals. A NULL hardware fence
 * means the run completed synchronously, so finish immediately.
 */
static void
drm_sched_worker(void *arg)
{
	struct drm_gpu_scheduler *sched = arg;

	mutex_enter(&sched->job_lock);
	for (;;) {
		struct drm_sched_job *job;
		struct dma_fence *hw;

		while (list_is_empty(&sched->pending) && !sched->stop)
			cv_wait(&sched->job_cv, &sched->job_lock);
		if (sched->stop && list_is_empty(&sched->pending))
			break;

		job = list_remove_head(&sched->pending);
		mutex_exit(&sched->job_lock);

		hw = job->run_job(job);
		if (hw == NULL) {
			/* synchronous completion. */
			(void) dma_fence_signal(&job->s_finished->base);
			dma_fence_put(&job->s_finished->base);
			if (job->free_job != NULL)
				job->free_job(job);
		} else {
			if (dma_fence_add_callback(hw, &job->s_cb,
			    drm_sched_hw_done) != 0) {
				/* already signalled: finish inline. */
				drm_sched_hw_done(hw, &job->s_cb);
			}
			dma_fence_put(hw);
		}
		mutex_enter(&sched->job_lock);
	}
	sched->worker_exited = B_TRUE;
	cv_broadcast(&sched->job_cv);
	mutex_exit(&sched->job_lock);
}

int
drm_sched_init(struct drm_gpu_scheduler *sched, const char *name)
{
	mutex_init(&sched->job_lock, NULL, MUTEX_DRIVER, NULL);
	cv_init(&sched->job_cv, NULL, CV_DRIVER, NULL);
	list_create(&sched->pending, sizeof (struct drm_sched_job),
	    offsetof(struct drm_sched_job, s_node));
	sched->fence_context = dma_fence_context_alloc(1);
	sched->fence_seqno = 0;
	sched->stop = B_FALSE;
	sched->worker_exited = B_FALSE;
	sched->worker = kthread_run(drm_sched_worker, sched, name);
	return (sched->worker != NULL ? 0 : -1);
}

void
drm_sched_fini(struct drm_gpu_scheduler *sched)
{
	mutex_enter(&sched->job_lock);
	sched->stop = B_TRUE;
	cv_broadcast(&sched->job_cv);
	while (!sched->worker_exited)
		cv_wait(&sched->job_cv, &sched->job_lock);
	mutex_exit(&sched->job_lock);
	list_destroy(&sched->pending);
	cv_destroy(&sched->job_cv);
	mutex_destroy(&sched->job_lock);
}

/*
 * drm_sched_job_init - attach a fresh finished-fence to the job. The caller
 * fills job->run_job / job->free_job. The returned fence (job->s_finished) is
 * what a submitter waits on; the scheduler holds one ref until completion.
 */
int
drm_sched_job_init(struct drm_gpu_scheduler *sched, struct drm_sched_job *job)
{
	struct drm_sched_fence *sf;

	sf = kmem_zalloc(sizeof (*sf), KM_SLEEP);
	dma_fence_init(&sf->base, &drm_sched_fence_ops, NULL,
	    sched->fence_context,
	    atomic_add_64_nv(&sched->fence_seqno, 1));
	job->s_finished = sf;
	job->sched = sched;
	return (0);
}

/*
 * drm_sched_entity_push_job - enqueue a job. Takes the worker's ref on the
 * finished fence and wakes the worker. Returns the finished fence (extra ref
 * for the caller to wait on / put).
 */
struct dma_fence *
drm_sched_entity_push_job(struct drm_sched_job *job)
{
	struct drm_gpu_scheduler *sched = job->sched;
	struct dma_fence *fin = &job->s_finished->base;

	(void) dma_fence_get(fin);	/* worker's ref (put on completion) */
	(void) dma_fence_get(fin);	/* caller's ref */
	mutex_enter(&sched->job_lock);
	list_insert_tail(&sched->pending, job);
	cv_broadcast(&sched->job_cv);
	mutex_exit(&sched->job_lock);
	return (fin);
}
