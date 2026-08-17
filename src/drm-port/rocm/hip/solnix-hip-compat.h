/*
 * solnix-hip-compat.h -- force-included shim for building HIP core
 * (libamdhip64) + ROCclr on illumos x86_64 (the AOT dispatch path).
 *
 * HIP/ROCclr assume a handful of glibc/Linux spellings illumos names
 * differently. Everything here is a portability spelling or a documented
 * degradation (thread-name/affinity no-ops), not a compute-path change: the
 * AOT dispatch (code-object load -> hsa AQL) is untouched.
 */
#ifndef SOLNIX_HIP_COMPAT_H
#define SOLNIX_HIP_COMPAT_H
#ifdef __sun

#include <alloca.h>          /* illumos puts alloca(3) here, not <stdlib.h> */
#include <time.h>
#include <pthread.h>
#include <string.h>
#include <libgen.h>          /* basename(3) */
#include <sys/regset.h>      /* REG_RIP / gregs[] indices */
#include <ucontext.h>
#include <unistd.h>

/* illumos declares environ in <unistd.h> but not always in scope for C++ TUs;
   ROCclr flags.cpp walks it to read AMD_* env vars. */
extern "C" char **environ;

/* CLOCK_MONOTONIC_RAW is Linux-only; CLOCK_HIGHRES is the illumos monotonic
   high-res clock (gethrtime backend) -- same map ROCr used. */
#ifndef CLOCK_MONOTONIC_RAW
#ifdef CLOCK_HIGHRES
#define CLOCK_MONOTONIC_RAW CLOCK_HIGHRES
#else
#define CLOCK_MONOTONIC_RAW CLOCK_MONOTONIC
#endif
#endif

/* Linux CPU-affinity API (cpu_set_t / CPU_* / pthread_*_setaffinity_np) has no
   illumos equivalent. ROCclr uses it only to pin worker threads across all
   CPUs -- a locality hint, not a compute path. Degrade to a no-op: the mask is
   a dummy bitmap and the affinity setters return success without binding
   (illumos schedules across all CPUs by default, which is what "all CPUs set"
   means). Same doctrine as libhsakmt's libnuma no-op. */
#ifndef CPU_SETSIZE
#define CPU_SETSIZE 1024
typedef unsigned long __cpu_mask;
typedef struct { __cpu_mask __bits[CPU_SETSIZE / (8 * sizeof(__cpu_mask))]; } cpu_set_t;
#define CPU_ZERO(s)     memset((s), 0, sizeof(cpu_set_t))
#define CPU_SET(c, s)   ((void)(c), (void)(s))
#define CPU_CLR(c, s)   ((void)(c), (void)(s))
#define CPU_ISSET(c, s) (0)
static inline int pthread_attr_setaffinity_np(pthread_attr_t *a, size_t sz, const cpu_set_t *m)
{ (void)a; (void)sz; (void)m; return 0; }
static inline int pthread_setaffinity_np(pthread_t t, size_t sz, const cpu_set_t *m)
{ (void)t; (void)sz; (void)m; return 0; }
#endif

/* pthread_getattr_np is a glibc extension (fetch a running thread's stack
   base/size, used only to guess the stack extent for a div-by-zero signal
   frame walk -- diagnostic, not compute). illumos exposes the same fact via
   thr_stksegment(); fill just the stack fields the caller reads back with
   pthread_attr_getstack. */
#ifndef HAVE_PTHREAD_GETATTR_NP
#include <thread.h>
static inline int pthread_getattr_np(pthread_t t, pthread_attr_t *a) {
  (void)t;
  stack_t ss;
  pthread_attr_init(a);
  if (thr_stksegment(&ss) == 0) {
    /* thr_stksegment gives the high end (ss_sp) + size; getstack wants the
       low end. */
    void *low = (char *)ss.ss_sp - ss.ss_size;
    pthread_attr_setstack(a, low, ss.ss_size);
  }
  return 0;
}
#endif

#endif /* __sun */
#endif
