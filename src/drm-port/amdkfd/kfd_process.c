/*
 * kfd_process.c - C3-KFD: the per-process compute context (kfd_process).
 *
 * Crib: drivers/gpu/drm/amd/amdkfd/kfd_process.c (kfd_create_process /
 * kfd_lookup_process_by_mm / kfd_process_destroy). Linux keys the process off
 * the mm_struct (one KFD context per address space) and stores them in a hash
 * keyed by mm; solnix keys off the illumos pid_t (one context per process),
 * held on a global mutex-guarded list. The lookup the ioctls need is
 * "the calling process's KFD context", found by pid.
 *
 * A kfd_process owns the process's compute queues, GPU memory allocations, its
 * doorbell page, and the acquired render-node VM (ACQUIRE_VM). It is created
 * lazily on the first ioctl that needs it and torn down on the last /dev/kfd
 * close (kfd_chardev.c cb_close) -- freeing the queues (releasing their
 * doorbell slots) and the memory allocations (releasing their amdgpu_bo).
 */

#include <sys/types.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/kmem.h>
#include <sys/list.h>
#include <sys/ksynch.h>
#include <sys/cmn_err.h>
#include "kfd_priv.h"

/*
 * The global process table. Linux uses a hashtable keyed by mm; a single-GPU
 * solnix compute node has few concurrent ROCm processes, so a mutex-guarded
 * list is the right size (O(n) lookup, n small). Swap to a mod_hash keyed by
 * pid if a node ever runs many concurrent ROCm processes.
 */
static kmutex_t		kfd_proc_lock;
static list_t		kfd_proc_list;
static boolean_t	kfd_proc_table_ready = B_FALSE;

void
kfd_process_table_init(void)
{
	if (kfd_proc_table_ready)
		return;
	mutex_init(&kfd_proc_lock, NULL, MUTEX_DRIVER, NULL);
	list_create(&kfd_proc_list, sizeof (struct kfd_process),
	    offsetof(struct kfd_process, link));
	kfd_proc_table_ready = B_TRUE;
}

void
kfd_process_table_fini(void)
{
	if (!kfd_proc_table_ready)
		return;
	list_destroy(&kfd_proc_list);
	mutex_destroy(&kfd_proc_lock);
	kfd_proc_table_ready = B_FALSE;
}

/*
 * kfd_process_find - the calling-process lookup the ioctls use. pid is the
 * illumos process id (the chardev derives it via ddi_get_pid).
 */
struct kfd_process *
kfd_process_find(pid_t pid)
{
	struct kfd_process *p;

	mutex_enter(&kfd_proc_lock);
	for (p = list_head(&kfd_proc_list); p != NULL;
	    p = list_next(&kfd_proc_list, p)) {
		if (p->pid == pid) {
			mutex_exit(&kfd_proc_lock);
			return (p);
		}
	}
	mutex_exit(&kfd_proc_lock);
	return (NULL);
}

/*
 * kfd_process_create - create (or return the existing) KFD context for pid.
 * Assigns the process a doorbell page (hardware-gated: ENOSPC off a real
 * device is non-fatal here -- the context still exists, queue-create is what
 * needs the doorbell). Idempotent per pid.
 */
struct kfd_process *
kfd_process_create(struct kfd_dev *kdev, pid_t pid)
{
	struct kfd_process *p;
	uint32_t page;

	p = kfd_process_find(pid);
	if (p != NULL)
		return (p);

	p = kmem_zalloc(sizeof (*p), KM_SLEEP);
	p->pid = pid;
	p->dev = kdev;
	mutex_init(&p->lock, NULL, MUTEX_DRIVER, NULL);
	idr_init(&p->queue_ids);
	idr_init(&p->mem_handles);
	list_create(&p->queues, sizeof (struct kfd_queue),
	    offsetof(struct kfd_queue, link));
	list_create(&p->mems, sizeof (struct kfd_mem),
	    offsetof(struct kfd_mem, link));

	if (kfd_doorbell_alloc_page(kdev, &page) == 0) {
		p->doorbell_page = page;
		p->doorbell_page_assigned = B_TRUE;
	}

	mutex_enter(&kfd_proc_lock);
	list_insert_tail(&kfd_proc_list, p);
	mutex_exit(&kfd_proc_lock);

	cmn_err(CE_CONT, "?kfd: process create pid=%d doorbell_page=%u%s\n",
	    (int)pid, p->doorbell_page,
	    p->doorbell_page_assigned ? "" : " (unassigned, hw-gated)");
	return (p);
}

/*
 * kfd_process_destroy - tear down a KFD context: free every queue (releasing
 * its doorbell/HWS state) + every memory allocation (releasing its amdgpu_bo),
 * release the doorbell page, and unlink. Called on the last /dev/kfd close.
 */
void
kfd_process_destroy(struct kfd_process *p)
{
	struct kfd_queue *q;
	struct kfd_mem *m;

	if (p == NULL)
		return;

	mutex_enter(&kfd_proc_lock);
	list_remove(&kfd_proc_list, p);
	mutex_exit(&kfd_proc_lock);

	/* free queues (kfd_queue_destroy pulls them off p->queues) */
	while ((q = list_head(&p->queues)) != NULL)
		(void) kfd_queue_destroy(p, q->queue_id);

	/* free memory allocations */
	while ((m = list_head(&p->mems)) != NULL)
		(void) kfd_mem_free(p, m->handle);

	if (p->doorbell_page_assigned)
		kfd_doorbell_free_page(p->dev, p->doorbell_page);

	idr_destroy(&p->queue_ids);
	idr_destroy(&p->mem_handles);
	list_destroy(&p->queues);
	list_destroy(&p->mems);
	mutex_destroy(&p->lock);

	cmn_err(CE_CONT, "?kfd: process destroy pid=%d\n", (int)p->pid);
	kmem_free(p, sizeof (*p));
}
