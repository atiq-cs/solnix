/*
 * solnix-compat.h - illumos build shims for libhsakmt (the HSA/KFD thunk).
 *
 * Force-included ahead of every translation unit. It supplies the handful of
 * glibc/Linux affordances the thunk assumes that illumos spells differently:
 *   - alloca() lives in <alloca.h> on illumos, not <stdlib.h>.
 *   - MADV_DONTFORK / MADV_DONTDUMP are Linux-only madvise hints (fork-COW /
 *     coredump exclusion); illumos madvise has no equivalent, so map them to 0
 *     (a no-op advice value). This is a fork/coredump-behavior corner, not a
 *     compute-correctness one -- the queue/memory still map to the GPU.
 *   - sched_getcpu(): Linux affinity helper; not on the core KFD path.
 *
 * The Linux _IOC ioctl encoding + the __u32 types come from
 * hsakmt/linux/solnix-ioctl-compat.h (patched into kfd_ioctl.h), the same
 * shim RADV/ANV/the C1 drm.h use.
 */
#ifndef _SOLNIX_HSAKMT_COMPAT_H_
#define _SOLNIX_HSAKMT_COMPAT_H_

#include <alloca.h>
#include <sys/mman.h>

#ifndef MADV_DONTFORK
#define MADV_DONTFORK	0
#endif
#ifndef MADV_DONTDUMP
#define MADV_DONTDUMP	0
#endif
#ifndef MADV_DOFORK
#define MADV_DOFORK	0
#endif
#ifndef MADV_HUGEPAGE
#define MADV_HUGEPAGE	0
#endif
#ifndef MADV_NOHUGEPAGE
#define MADV_NOHUGEPAGE	0
#endif

#endif /* _SOLNIX_HSAKMT_COMPAT_H_ */
