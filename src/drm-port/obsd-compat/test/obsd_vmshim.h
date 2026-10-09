/*
 * obsd_vmshim.h -- userland model of the illumos primitives obsd_vm.c's
 * physical registry and uao allocator use (kmem, avl, mutex, atomics,
 * hat_getpfnum), for test/test_vm.c. kmem_alloc of a page multiple returns
 * page-aligned memory (posix_memalign), as the kernel's does; "pfns" are
 * synthetic (va >> 12), which keeps PHYS_TO_VM_PAGE(VM_PAGE_TO_PHYS(pg))
 * a real round trip through the AVL registry.
 */
#ifndef _OBSD_VMSHIM_H
#define _OBSD_VMSHIM_H
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <stddef.h>
#include <errno.h>
#include <pthread.h>
#include <assert.h>
#include <sys/queue.h>
#include <sys/avl.h>		/* illumos libavl, same API as the kernel's */

typedef uint64_t paddr_t;
typedef uintptr_t vaddr_t;
typedef size_t vsize_t;
typedef uint64_t psize_t;
typedef int64_t voff_t;
typedef int vm_prot_t;
#ifndef __sun
typedef unsigned long pfn_t;
typedef unsigned long pgcnt_t;
typedef unsigned int uint_t;
typedef char *caddr_t;
#endif

#define PAGESIZE	4096UL
#define PAGESHIFT	12
#define PAGEOFFSET	(PAGESIZE - 1)
#define ptob(x)		((size_t)(x) << PAGESHIFT)
#define btop(x)		((size_t)(x) >> PAGESHIFT)
#define btopr(x)	(((size_t)(x) + PAGEOFFSET) >> PAGESHIFT)
#define KM_SLEEP	0
#define KM_NOSLEEP	1
#define MUTEX_DRIVER	0
#define ASSERT(x)	assert(x)
#define physmem		1048576L
#define freemem		524288L

typedef pthread_mutex_t kmutex_t;
#define mutex_init(m, a, b, c)	pthread_mutex_init((m), NULL)
#define mutex_enter(m)		pthread_mutex_lock(m)
#define mutex_exit(m)		pthread_mutex_unlock(m)

extern long ushim_kmem_outstanding;	/* bytes, for the leak check */
static inline void *
kmem_alloc(size_t n, int km)
{
	void *p = NULL;

	(void) km;
	if (n % PAGESIZE == 0 ? posix_memalign(&p, PAGESIZE, n) != 0 :
	    (p = malloc(n)) == NULL)
		return (NULL);
	__atomic_add_fetch(&ushim_kmem_outstanding, (long)n, __ATOMIC_SEQ_CST);
	return (p);
}
static inline void *
kmem_zalloc(size_t n, int km)
{
	void *p = kmem_alloc(n, km);

	if (p != NULL)
		memset(p, 0, n);
	return (p);
}
static inline void
kmem_free(void *p, size_t n)
{
	__atomic_sub_fetch(&ushim_kmem_outstanding, (long)n, __ATOMIC_SEQ_CST);
	free(p);
}
#define bzero(p, n)	memset((p), 0, (n))
static inline void
atomic_inc_uint(volatile uint_t *p)
{
	__atomic_add_fetch(p, 1, __ATOMIC_SEQ_CST);
}
static inline uint_t
atomic_dec_uint_nv(volatile uint_t *p)
{
	return (__atomic_sub_fetch(p, 1, __ATOMIC_SEQ_CST));
}
static inline pfn_t
obsd_ushim_va2pfn(caddr_t va)
{
	return ((pfn_t)((uintptr_t)va >> PAGESHIFT));
}

/* The OpenBSD types obsd_vm.c touches, the same shapes as obsd_vm.h. */
struct uvm_object;
struct obsd_pgchunk;
TAILQ_HEAD(pglist, vm_page);
struct vm_page {
	TAILQ_ENTRY(vm_page)	pageq;
	struct uvm_object	*uobject;
	voff_t			offset;
	uint32_t		pg_flags;
	uint32_t		wire_count;
	paddr_t			phys_addr;
	unsigned long		pg_pfn;
	struct obsd_pgchunk	*pg_chunk;
};
#define PG_CLEAN	0x00000008
#define PG_DEV		0x00000200
#define VM_PAGE_TO_PHYS(pg)	((pg)->phys_addr)
struct uvm_pagerops { int dummy; };
struct rwlock { int dummy; };
struct uvm_object {
	struct rwlock			*vmobjlock;
	const struct uvm_pagerops	*pgops;
	int				uo_npages;
	int				uo_refs;
	void				*uo_priv;
};
struct uvmexp { int pagesize, pagemask, pageshift, npages, free; };
#define UVM_PLA_NOWAIT	0x0002
#define UVM_PLA_ZERO	0x0004
void uao_detach(struct uvm_object *);
#endif
