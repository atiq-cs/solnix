/*
 * obsd_prelude.h -- forced-include prelude for compiling OpenBSD's drm core
 * and inteldrm (i915) sources, unmodified, against the illumos kernel
 * headers. Used as:
 *
 *   gcc -D_KERNEL -ffreestanding -nostdinc -include obsd_prelude.h \
 *       -I<obsd-compat> -I<obsd>/include -I<obsd>/include/uapi -I<obsd> \
 *       -I<obsd>/i915 -I<illumos proto>/usr/include ...
 *
 * OpenBSD's linux-KPI shim (include/linux, include/asm) keeps its own
 * PD/ISC notices and is used unmodified. It is written on top of the OpenBSD kernel API
 * (mtx_enter, tsleep_nsec, bus_space_read_4, pci_conf_read, km_alloc, ...).
 * This directory supplies THAT API on illumos (route (a) in
 * docs/x1-gpu-route.md section 5).
 *
 * Order matters:
 *  1. Every illumos header the compat layer maps onto is parsed first, under
 *     its own names, so the illumos declarations are complete.
 *  2. Then the tag/name collisions are renamed for the rest of the
 *     translation unit (below). Because the illumos headers are already
 *     parsed and include-guarded, the renames only reach OpenBSD code.
 *  3. Then the OpenBSD kernel API itself (obsd_kern.h, obsd_vm.h,
 *     obsd_bus.h).
 *
 * The OpenBSD host headers (<sys/malloc.h>, <machine/bus.h>, <uvm/...>,
 * <dev/pci/pcivar.h>, ...) exist in this directory as one-line files: every
 * declaration they would carry is already here, so their only job is to stop
 * the include from failing. Where illumos has a header of the same name that
 * OpenBSD code includes (<sys/mutex.h>, <sys/proc.h>, ...), the illumos one is
 * used and the OpenBSD additions come from this prelude.
 *
 * STATUS of each mapping is tagged in the per-area headers: REAL (illumos
 * equivalent, same semantics), MAP (illumos equivalent with a documented
 * semantic difference), DECL (declared here, implemented in obsd_kern.c),
 * PLANNED (declared, no implementation yet: an unresolved symbol at link
 * time, never a silent success).
 */
#ifndef _OBSD_PRELUDE_H
#define _OBSD_PRELUDE_H

/* OpenBSD's own sources select their glue with __OpenBSD__. Their drm/i915
 * code is only ever built with it defined, so it is defined here: the
 * alternative (neither __linux__ nor __OpenBSD__) is a configuration no
 * upstream has compiled. */
#ifndef __OpenBSD__
#define __OpenBSD__	1
#endif
/* OpenBSD amd64 GENERIC has "option I915" next to "inteldrm* at pci?"
 * (sys/arch/amd64/conf/GENERIC), which config(8) turns into -DI915. Without
 * it the legacy-platform display headers (intel_tv.h, vlv_dsi.h, ...)
 * declare static inline stubs that collide with the .c definitions. */
#ifndef I915
#define I915	1
#endif

/* ---- 1. illumos headers, under their own names. ---- */
#include <sys/types.h>
#include <sys/param.h>
#include <sys/stdbool.h>
#include <sys/stddef.h>
#include <sys/int_limits.h>
#include <sys/errno.h>
#include <sys/systm.h>
#include <sys/cmn_err.h>
#include <sys/debug.h>
#include <sys/sysmacros.h>
#include <sys/kmem.h>
#include <sys/ksynch.h>
#include <sys/mutex.h>
#include <sys/condvar.h>
#include <sys/rwlock.h>
#include <sys/atomic.h>
#include <sys/time.h>
#include <sys/byteorder.h>
#include <sys/list.h>
#include <sys/proc.h>
#include <sys/thread.h>
#include <sys/cpuvar.h>
#include <sys/disp.h>
#include <sys/file.h>
#include <sys/vnode.h>
#include <sys/cred.h>
#include <sys/mman.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/taskq.h>
#include <sys/taskq_impl.h>	/* taskq_ent_t */
#include <sys/poll.h>		/* struct pollhead */
#include <sys/random.h>
#include <sys/archsystm.h>
#include <sys/queue.h>
#include <sys/varargs.h>
#include <sys/bitmap.h>
#include <sys/ioccom.h>
#include <sys/fcntl.h>
#include <sys/stat.h>
#include <sys/limits.h>
#include <sys/uio.h>

/* ---- 2. collisions, renamed for the OpenBSD code that follows. ---- */
/*
 * struct proc: illumos proc_t is needed by the illumos headers above;
 * OpenBSD's struct proc (p_p->ps_pid, p_p->ps_comm, p_fd, ...) is a
 * different object. OpenBSD code gets its own tag.
 */
#define proc			obsd_proc
#undef curproc
/* struct task: illumos's is the project/task accounting object (pulled in by
 * sys/sunddi.h -> sys/ddi_implfuncs.h); OpenBSD's is a taskq work item.
 * struct pool: illumos's is a resource pool (sys/pool.h); OpenBSD's is
 * pool(9), a fixed-size allocator. Every use of these tokens below is
 * OpenBSD's, so renaming the token keeps the translation unit consistent. */
#define task			obsd_task
#define pool			obsd_pool
/* struct file: illumos file_t vs OpenBSD struct file (f_data, f_ops, f_type,
 * f_mtx). See obsd_kern.h; only drm_linux.c's dma-buf/sync_file code reads
 * OpenBSD's fields. */
#define file			obsd_file
/*
 * list_move_tail: illumos sys/list.h exports list_move_tail(list_t *, list_t *);
 * OpenBSD linux/list.h defines a static inline of the Linux shape. The 42
 * collision sites measured by the E2 union run are all this one name.
 */
#define list_move_tail		linux_list_move_tail
/*
 * Kernel-exported illumos names with a different OpenBSD signature. krtld
 * binds a module's reference to a name the kernel defines to the kernel's
 * definition (src/wifi-port/net80211-openbsd/compat/sys/n80211_symrename.h),
 * so these must never reach the object file under their OpenBSD spelling.
 */
#define taskq_create		obsd_taskq_create
#define suser			obsd_suser
/* pool(9): illumos genunix exports pool_init/pool_destroy (resource pools,
 * different signatures). Measured by i915/link-gap.sh: the two names a
 * linked module would define AND the kernel already defines. */
#define pool_init		obsd_pool_init
#define pool_destroy		obsd_pool_destroy
/* malloc(9): the loaded ufs module exports a global free() (its block
 * free, ufs_alloc.c), measured by i915/build-module.sh's /dev/ksyms gate on
 * dixi; krtld would bind the module's free() calls to it. The token
 * rename keeps drm's ->free member names consistent (tags and members are
 * renamed alike). malloc/mallocarray follow for symmetry: no kernel
 * defines them today, a later module might. */
#define malloc			obsd_malloc
#define mallocarray		obsd_mallocarray
#define free			obsd_free
/* rw_*: illumos rw_enter(krwlock_t *, krw_t) returns void; OpenBSD's takes a
 * struct rwlock and flags and returns an error. Function-like, so the
 * already-parsed illumos prototypes are untouched. */
#define rw_init(l, n)		obsd_rw_init_flags((l), (n), 0)
#define rw_enter(l, f)		obsd_rw_enter((l), (f))
#define rw_exit(l)		obsd_rw_exit(l)
#define rw_destroy(l)		((void)(l))
/* delay(): OpenBSD's is a microsecond busy-wait; illumos delay(9F) sleeps
 * for clock TICKS. Left unmapped, delay(tick) would sleep ~100 s. */
#define delay(us)		drv_usecwait(us)
/* DELAY: illumos sys/param.h already defines it as drv_usecwait. */
/* resume: illumos sys/disp.h declares resume(kthread_t *); i915
 * gt/intel_reset.c has a static resume(struct intel_gt *). */
#define resume			obsd_resume

/* ---- 3. the OpenBSD kernel API. ---- */
#include <sys/tree.h>		/* vendored OpenBSD SPLAY/RB/RBT macros */
#include <obsd_kern.h>
#include <obsd_vm.h>
#include <obsd_bus.h>

#endif /* _OBSD_PRELUDE_H */
