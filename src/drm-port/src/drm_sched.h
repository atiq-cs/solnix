/*
 * drm_sched.h - minimal single-queue GPU scheduler (C1c). See drm_sched.c for
 * the crib provenance (Linux drm/scheduler cut to one FIFO run-queue).
 */

#ifndef _DRM_SCHED_H_
#define _DRM_SCHED_H_

#include <sys/types.h>
#include <sys/ksynch.h>
#include <sys/list.h>
#include "linux-compat/linux_dma.h"

struct drm_gpu_scheduler;
struct drm_sched_job;

/*
 * struct drm_sched_fence - a scheduler-owned dma_fence embedded first in the
 * struct so the container == the fence pointer (release frees it).
 */
struct drm_sched_fence {
	struct dma_fence	base;
};

/*
 * struct drm_sched_job - one unit of work. run_job() performs the actual
 * transport submission and returns a hardware dma_fence (or NULL for
 * synchronous completion); free_job() releases the job memory.
 */
struct drm_sched_job {
	list_node_t		s_node;		/* run-queue linkage */
	struct drm_gpu_scheduler *sched;
	struct drm_sched_fence	*s_finished;	/* signalled on completion */
	struct dma_fence_cb	s_cb;		/* hooks the hardware fence */
	struct dma_fence	*(*run_job)(struct drm_sched_job *);
	void			(*free_job)(struct drm_sched_job *);
};

struct drm_gpu_scheduler {
	kmutex_t		job_lock;
	kcondvar_t		job_cv;
	list_t			pending;	/* struct drm_sched_job FIFO */
	struct task_struct	*worker;
	uint64_t		fence_context;
	volatile uint64_t	fence_seqno;
	volatile boolean_t	stop;
	volatile boolean_t	worker_exited;
};

int	drm_sched_init(struct drm_gpu_scheduler *, const char *name);
void	drm_sched_fini(struct drm_gpu_scheduler *);
int	drm_sched_job_init(struct drm_gpu_scheduler *, struct drm_sched_job *);
struct dma_fence *drm_sched_entity_push_job(struct drm_sched_job *);

#endif /* _DRM_SCHED_H_ */
