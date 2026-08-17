/*
 * numa.h - illumos stub for libhsakmt's libnuma dependency.
 *
 * libhsakmt uses libnuma only in bind_mem_to_numa() (fmm.c) to pin a host
 * allocation to the NUMA node nearest a GPU -- a locality optimization, not a
 * correctness requirement. illumos has no libnuma/mbind userspace API, so this
 * stub makes numa_available() report "no NUMA" (-1); bind_mem_to_numa() then
 * returns early without binding, which is the correct degradation (the memory
 * is still allocated + mapped to the GPU, just not NUMA-pinned).
 *
 * The upstream lgroup(3LGRP) API is the illumos analogue if NUMA-locality
 * tuning is ever wanted, but that is a host-side perf knob, not part of the
 * KFD compute ABI.
 */
#ifndef _SOLNIX_NUMA_STUB_H_
#define _SOLNIX_NUMA_STUB_H_

#include <stdint.h>
#include <stddef.h>

struct bitmask {
	unsigned long size;
	unsigned long *maskp;
};

static inline int numa_available(void) { return -1; }
static inline int numa_max_node(void) { return 0; }
static inline struct bitmask *numa_bitmask_alloc(unsigned int n) { (void)n; return NULL; }
static inline void numa_bitmask_free(struct bitmask *b) { (void)b; }
static inline struct bitmask *numa_bitmask_setbit(struct bitmask *b, unsigned int i)
{ (void)i; return b; }

#endif /* _SOLNIX_NUMA_STUB_H_ */
