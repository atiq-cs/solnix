/*
 * numaif.h - illumos stub for libhsakmt's libnuma mbind() dependency.
 *
 * See numa.h. mbind() is never reached at runtime because numa_available()
 * reports -1; the declaration + MPOL_* constants exist only so fmm.c compiles.
 */
#ifndef _SOLNIX_NUMAIF_STUB_H_
#define _SOLNIX_NUMAIF_STUB_H_

#include <stddef.h>

#define MPOL_DEFAULT		0
#define MPOL_PREFERRED		1
#define MPOL_BIND		2
#define MPOL_INTERLEAVE		3
#define MPOL_F_STATIC_NODES	(1 << 15)

static inline long mbind(void *addr, unsigned long len, int mode,
			 const unsigned long *nodemask, unsigned long maxnode,
			 unsigned int flags)
{
	(void)addr; (void)len; (void)mode; (void)nodemask;
	(void)maxnode; (void)flags;
	return 0;
}

#endif /* _SOLNIX_NUMAIF_STUB_H_ */
