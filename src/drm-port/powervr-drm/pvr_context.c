/*
 * pvr_context.c - C-PVR-b: PowerVR contexts + queues + job submission,
 * illumos side. The pvr analogue of Linux's pvr_context.c + pvr_queue.c +
 * pvr_job.c, wired onto the C1 drm_sched (src/drm_sched.c) + the C1 dma-fence.
 * Handles CREATE_CONTEXT (0x07), DESTROY_CONTEXT (0x08), SUBMIT_JOBS (0x0d).
 *
 * A pvr_context is a GPU submission context of a given type (RENDER / COMPUTE
 * / TRANSFER_FRAG). Each context has one or more queues (Linux pvr_queue: a
 * geometry + a fragment queue for RENDER; one for COMPUTE/TRANSFER); a queue is
 * a client circular command buffer (CCCB) fed to the FW, driven by a
 * drm_gpu_scheduler entity. On illumos we back each context's submission with
 * the C1 single-FIFO scheduler (the per-device sc->sched): a SUBMIT_JOBS ioctl
 * builds a drm_sched_job whose run_job ships the command stream to the FW via
 * the CCCB (pvr_cccb) and whose finished dma-fence is the out fence.
 *
 * For the COMPILE milestone: the context/queue lifecycle + the job build +
 * the scheduler wiring + the ioctl ABI are complete on the C1 framework. The
 * actual CCCB write + the FW kick (ROGUE_CR_MTS_* doorbell) is BXE-hardware-
 * gated -- it needs the booted FW + real device registers. run_job records +
 * signals immediately (the FIFO serializes) the same way C1d's virtio 3D
 * SUBMIT does; a real async transport returns a hardware fence on the FW IRQ.
 */

#include <sys/types.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/errno.h>
#include <sys/list.h>

#include "drm_internal.h"
#include "drm_sched.h"
#include "pvr_priv.h"
#include "uapi/pvr_drm.h"

/*
 * pvr_queue - one submission queue (a CCCB fed to the FW). Linux: struct
 * pvr_queue (pvr_queue.c) with an embedded drm_gpu_scheduler entity. Here it
 * carries the CCCB backing object + the scheduler the jobs push into.
 */
struct pvr_queue {
	list_node_t		node;
	struct pvr_context	*ctx;
	uint32_t		type;		/* DRM_PVR_JOB_TYPE_* */
	struct pvr_fw_object	*cccb_obj;	/* the client CCB backing */
	struct drm_gpu_scheduler *sched;	/* the C1 scheduler */
};

/*
 * pvr_context - a GPU submission context. Linux: struct pvr_context.
 */
struct pvr_context {
	list_node_t		file_node;	/* pvr_file->contexts linkage */
	struct kref		ref;
	struct pvr_softc	*pvr;
	struct pvr_vm_context	*vm_ctx;	/* the address space it runs in */
	uint32_t		type;		/* DRM_PVR_CTX_TYPE_* */
	int32_t			priority;
	uint32_t		handle;
	list_t			queues;		/* struct pvr_queue */
};

/*
 * pvr_job - one unit of work submitted through SUBMIT_JOBS. Embeds a
 * drm_sched_job (the C1 scheduler unit) whose finished dma-fence is the out
 * fence. Linux: struct pvr_job (pvr_job.c).
 */
struct pvr_job {
	struct drm_sched_job	base;		/* the C1 scheduler job */
	struct pvr_context	*ctx;
	uint32_t		type;
	void			*cmd_stream;	/* copied-in command stream */
	uint32_t		cmd_stream_len;
};

extern struct pvr_vm_context *pvr_file_vm_ctx_find(struct pvr_file *,
    uint32_t handle);

static void pvr_context_free(struct pvr_context *ctx);

void
pvr_context_device_init(struct pvr_softc *sc)
{
	(void) sc;	/* per-device context state is the sc->sched, already up */
}

void
pvr_context_device_fini(struct pvr_softc *sc)
{
	(void) sc;
}

/*
 * pvr_file_contexts_init/_fini - create/destroy the per-file contexts list.
 * Lives here because the file_node offset into struct pvr_context is private
 * to this file (pvr_device.c holds only the opaque struct pvr_file).
 */
void
pvr_file_contexts_init(struct pvr_file *pf)
{
	list_create(&pf->contexts, sizeof (struct pvr_context),
	    offsetof(struct pvr_context, file_node));
}

void
pvr_file_contexts_fini(struct pvr_file *pf)
{
	struct pvr_context *ctx;

	while ((ctx = list_remove_head(&pf->contexts)) != NULL) {
		if (atomic_dec_uint_nv(&ctx->ref.refcount) == 0)
			pvr_context_free(ctx);
	}
	list_destroy(&pf->contexts);
}

/*
 * pvr_job_run - the scheduler run_job callback. Ships the command stream to the
 * FW via the CCCB + kicks the FW doorbell, returns the hardware fence. For the
 * compile milestone this is synchronous: it returns NULL so the C1 scheduler
 * signals the job's finished fence immediately (the FIFO serializes). The real
 * CCCB write + doorbell kick is BXE-hardware-gated.
 */
static struct dma_fence *
pvr_job_run(struct drm_sched_job *sjob)
{
	struct pvr_job *job = (struct pvr_job *)sjob;

	(void) job;
	/*
	 * HARDWARE-GATED: pvr_cccb_write the command stream into the queue's
	 * client CCB, pvr_cccb_finalise, then kick the FW via ROGUE_CR_MTS_*.
	 * The FW runs the job + signals via the FWCCB on the IRQ; that hardware
	 * fence would be returned here. Off-hardware: synchronous completion.
	 */
	return (NULL);
}

static void
pvr_job_free(struct drm_sched_job *sjob)
{
	struct pvr_job *job = (struct pvr_job *)sjob;

	if (job->cmd_stream != NULL)
		kmem_free(job->cmd_stream, job->cmd_stream_len);
	if (job->ctx != NULL &&
	    atomic_dec_uint_nv(&job->ctx->ref.refcount) == 0)
		/* the last ref is dropped by pvr_context_destroy path */
		(void) 0;
	kmem_free(job, sizeof (*job));
}

/*
 * pvr_queue_create - stand up one queue of a given type on the per-device
 * scheduler. The CCCB backing is a FW object (FW-heap-gated). Linux:
 * pvr_queue_create.
 */
static struct pvr_queue *
pvr_queue_create(struct pvr_context *ctx, uint32_t type)
{
	struct pvr_queue *q = kmem_zalloc(sizeof (*q), KM_SLEEP);

	q->ctx = ctx;
	q->type = type;
	q->sched = &ctx->pvr->sched;
	/* the client CCB: a FW object mapped into the FW heap (gated) */
	q->cccb_obj = pvr_fw_object_create(ctx->pvr, 4096, 0);
	return (q);
}

static void
pvr_queue_destroy(struct pvr_queue *q)
{
	if (q->cccb_obj != NULL)
		pvr_fw_object_destroy(q->ctx->pvr, q->cccb_obj);
	kmem_free(q, sizeof (*q));
}

/*
 * pvr_context_create - allocate a context of the requested type + priority,
 * bound to a VM context, and create its queues. Linux: pvr_context_create.
 */
static struct pvr_context *
pvr_context_create(struct pvr_softc *sc, struct pvr_file *pf,
    struct drm_pvr_ioctl_create_context_args *a)
{
	struct pvr_context *ctx;
	struct pvr_vm_context *vm;

	switch (a->type) {
	case DRM_PVR_CTX_TYPE_RENDER:
	case DRM_PVR_CTX_TYPE_COMPUTE:
	case DRM_PVR_CTX_TYPE_TRANSFER_FRAG:
		break;
	default:
		return (NULL);
	}
	switch (a->priority) {
	case DRM_PVR_CTX_PRIORITY_LOW:
	case DRM_PVR_CTX_PRIORITY_NORMAL:
	case DRM_PVR_CTX_PRIORITY_HIGH:
		break;
	default:
		return (NULL);
	}
	vm = idr_find(&pf->vm_ctx_handles, a->vm_context_handle);
	if (vm == NULL)
		return (NULL);

	ctx = kmem_zalloc(sizeof (*ctx), KM_SLEEP);
	kref_init(&ctx->ref);
	ctx->pvr = sc;
	ctx->vm_ctx = vm;
	ctx->type = a->type;
	ctx->priority = a->priority;
	list_create(&ctx->queues, sizeof (struct pvr_queue),
	    offsetof(struct pvr_queue, node));

	/* RENDER has geometry + fragment queues; others have one */
	if (a->type == DRM_PVR_CTX_TYPE_RENDER) {
		list_insert_tail(&ctx->queues,
		    pvr_queue_create(ctx, DRM_PVR_JOB_TYPE_GEOMETRY));
		list_insert_tail(&ctx->queues,
		    pvr_queue_create(ctx, DRM_PVR_JOB_TYPE_FRAGMENT));
	} else {
		list_insert_tail(&ctx->queues, pvr_queue_create(ctx, a->type));
	}
	return (ctx);
}

static void
pvr_context_free(struct pvr_context *ctx)
{
	struct pvr_queue *q;

	while ((q = list_remove_head(&ctx->queues)) != NULL)
		pvr_queue_destroy(q);
	list_destroy(&ctx->queues);
	kmem_free(ctx, sizeof (*ctx));
}

int
pvr_create_context_ioctl(struct pvr_softc *sc, struct pvr_file *pf,
    intptr_t arg, int mode)
{
	struct drm_pvr_ioctl_create_context_args a;
	struct pvr_context *ctx;

	if (ddi_copyin((void *)arg, &a, sizeof (a), mode) != 0)
		return (EFAULT);

	ctx = pvr_context_create(sc, pf, &a);
	if (ctx == NULL)
		return (EINVAL);

	ctx->handle = idr_alloc(&pf->ctx_handles, ctx);
	list_insert_tail(&pf->contexts, ctx);
	a.handle = ctx->handle;
	if (ddi_copyout(&a, (void *)arg, sizeof (a), mode) != 0) {
		list_remove(&pf->contexts, ctx);
		(void) idr_remove(&pf->ctx_handles, ctx->handle);
		pvr_context_free(ctx);
		return (EFAULT);
	}
	return (0);
}

int
pvr_destroy_context_ioctl(struct pvr_softc *sc, struct pvr_file *pf,
    intptr_t arg, int mode)
{
	struct drm_pvr_ioctl_destroy_context_args a;
	struct pvr_context *ctx;

	(void) sc;
	if (ddi_copyin((void *)arg, &a, sizeof (a), mode) != 0)
		return (EFAULT);
	if (a._padding_4 != 0)
		return (EINVAL);

	ctx = idr_remove(&pf->ctx_handles, a.handle);
	if (ctx == NULL)
		return (EINVAL);
	list_remove(&pf->contexts, ctx);
	if (atomic_dec_uint_nv(&ctx->ref.refcount) == 0)
		pvr_context_free(ctx);
	return (0);
}

/*
 * pvr_submit_one_job - build + push one drm_pvr_job. Copies in the command
 * stream, builds a pvr_job (a C1 drm_sched_job), and pushes it onto the
 * per-device scheduler; the job's finished dma-fence is the completion the
 * caller's sync_ops wait on. Linux: pvr_submit_job -> pvr_queue_job_push.
 */
static int
pvr_submit_one_job(struct pvr_softc *sc, struct pvr_file *pf,
    struct drm_pvr_job *j, int mode)
{
	struct pvr_context *ctx;
	struct pvr_job *job;
	struct dma_fence *fence;

	switch (j->type) {
	case DRM_PVR_JOB_TYPE_GEOMETRY:
	case DRM_PVR_JOB_TYPE_FRAGMENT:
	case DRM_PVR_JOB_TYPE_COMPUTE:
	case DRM_PVR_JOB_TYPE_TRANSFER_FRAG:
		break;
	default:
		return (EINVAL);
	}
	ctx = idr_find(&pf->ctx_handles, j->context_handle);
	if (ctx == NULL)
		return (EINVAL);
	if (j->cmd_stream_len == 0 || j->cmd_stream == 0)
		return (EINVAL);

	job = kmem_zalloc(sizeof (*job), KM_SLEEP);
	job->ctx = ctx;
	job->type = j->type;
	job->cmd_stream_len = j->cmd_stream_len;
	job->cmd_stream = kmem_alloc(j->cmd_stream_len, KM_SLEEP);
	if (ddi_copyin((void *)(uintptr_t)j->cmd_stream, job->cmd_stream,
	    j->cmd_stream_len, mode) != 0) {
		kmem_free(job->cmd_stream, j->cmd_stream_len);
		kmem_free(job, sizeof (*job));
		return (EFAULT);
	}
	kref_get(&ctx->ref);
	job->base.run_job = pvr_job_run;
	job->base.free_job = pvr_job_free;

	if (drm_sched_job_init(&sc->sched, &job->base) != 0) {
		kmem_free(job->cmd_stream, j->cmd_stream_len);
		(void) atomic_dec_uint_nv(&ctx->ref.refcount);
		kmem_free(job, sizeof (*job));
		return (ENOMEM);
	}
	/* push onto the FIFO; the returned fence is the job's out fence */
	fence = drm_sched_entity_push_job(&job->base);
	if (fence != NULL)
		dma_fence_put(fence);	/* sync_ops out-fence export is gated */
	return (0);
}

/*
 * pvr_submit_jobs_ioctl - DRM_IOCTL_PVR_SUBMIT_JOBS (0x0d). ABI:
 * drm_pvr_ioctl_submit_jobs_args { struct drm_pvr_obj_array jobs; }. Each
 * element is a drm_pvr_job. Linux: pvr_ioctl_submit_jobs -> pvr_submit_jobs.
 */
int
pvr_submit_jobs_ioctl(struct pvr_softc *sc, struct pvr_file *pf,
    intptr_t arg, int mode)
{
	struct drm_pvr_ioctl_submit_jobs_args a;
	struct drm_pvr_job j;
	uint32_t i;
	int err = 0;

	if (ddi_copyin((void *)arg, &a, sizeof (a), mode) != 0)
		return (EFAULT);
	if (a.jobs.count == 0)
		return (0);
	if (a.jobs.stride < sizeof (struct drm_pvr_job))
		return (EINVAL);

	for (i = 0; i < a.jobs.count; i++) {
		uintptr_t elem = (uintptr_t)a.jobs.array +
		    (uintptr_t)i * a.jobs.stride;
		if (ddi_copyin((void *)elem, &j, sizeof (j), mode) != 0)
			return (EFAULT);
		err = pvr_submit_one_job(sc, pf, &j, mode);
		if (err != 0)
			break;
	}
	return (err);
}
