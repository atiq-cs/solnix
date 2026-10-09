/*
 * obsd_vm.c -- the part of OpenBSD UVM/pmap that the drm core and i915 call,
 * on the illumos VM, for rung R1a (modeset + dumb buffers).
 *
 * vm_page (MAP): OpenBSD keeps one struct vm_page per physical page of RAM
 * and per uvm_page_physload'd device range, and PHYS_TO_VM_PAGE(pa) indexes
 * that array. Here a vm_page exists only for memory this layer handed out:
 *   - a "chunk": page-aligned kernel memory from kmem_alloc, with one
 *     vm_page per page, pfns from hat_getpfnum. uvm_pglistalloc and uao
 *     objects allocate chunks.
 *   - a "range": a uvm_page_physload'd device range (GMADR aperture, stolen
 *     memory) with an array of vm_pages, so i915->pgs[i] works as on OpenBSD.
 * Every chunk and range is registered by physical page in an AVL tree, so
 * PHYS_TO_VM_PAGE / uvm_atopg answer for exactly those pages and return NULL
 * for any other address (i915 only calls them on its own pages).
 * NOTE: chunk pages are physically discontiguous; uvm_pglistalloc honours
 * nsegs > 1 (i915 internal objects fall back to order 0 when a large
 * contiguous allocation fails), and for nsegs == 1 with more than one page
 * it uses contig_alloc (illumos ddi_dma_mem_alloc's own allocator).
 *
 * uao (anonymous objects, GEM shmem backing): a uao is an array of chunk
 * pages allocated at uao_create time (MAP: OpenBSD allocates lazily and can
 * swap; here the memory is wired from creation until the last uao_detach).
 * That is the behaviour drm's dumb buffers and i915's shmem objects need for
 * R1a; swap-backed GEM objects are R2.
 *
 * pmap (MAP): only the kernel pmap exists. pmap_kenter_pa/pmap_enter on it
 * are hat_devload on kas with the cache attribute from the PMAP_* bits in
 * the low bits of pa (OpenBSD amd64 encodes PMAP_WC / PMAP_NOCACHE there).
 * The direct map (pmap_map_direct) is hat_kpm_pfn2va (kpm_enable=1 on dixi,
 * measured). User pmaps (pmap_enter on a process map, uvm_map) are R2: they
 * return an error, they do not pretend.
 *
 * Built as kernel code, and with -DOBSD_USERTEST against test/obsd_vmshim.h
 * for test/test_vm.c (the registry and the uao allocator).
 */
#ifdef OBSD_USERTEST
#include "test/obsd_vmshim.h"
#else
#include <sys/types.h>
#include <sys/avl.h>
#include <vm/hat.h>
#include <vm/as.h>
#include <vm/seg_kmem.h>
#include <sys/cpuvar.h>
#include <obsd_prelude.h>
#undef rw_init
#undef rw_enter
#undef rw_exit
#undef rw_destroy
/* Kernel exports without a header in the installed proto (measured in the
 * running kernel's symbol table; prototypes from illumos-gate
 * uts/i86pc/sys/x_call.h, uts/intel/sys/x86_archext.h, vm/hat_i86.h). */
typedef uintptr_t xc_arg_t;
typedef int (*xc_func_t)(xc_arg_t, xc_arg_t, xc_arg_t);
extern void xc_call(xc_arg_t, xc_arg_t, xc_arg_t, ulong_t *, xc_func_t);
extern void invalidate_cache(void);
extern caddr_t hat_kpm_pfn2va(pfn_t);
#define HAT_PLAT_NOCACHE_OBSD	0x100000	/* i86pc HAT_PLAT_NOCACHE */
#endif

/* ------------------------------------------------- the physical registry */
struct obsd_pgchunk {
	avl_node_t	c_node;
	pfn_t		c_pfn0;		/* range: first pfn; chunk: 0 */
	pgcnt_t		c_npages;
	int		c_kind;		/* OBSD_CHUNK_RAM / _RANGE */
	caddr_t		c_va;		/* RAM: the kmem VA */
	size_t		c_bytes;
	int		c_contig;	/* RAM: from contig_alloc */
	struct vm_page	*c_pages;	/* c_npages descriptors */
	pgcnt_t		c_freed;	/* pages returned by uvm_pglistfree */
};
#define OBSD_CHUNK_RAM		1
#define OBSD_CHUNK_RANGE	2

/* One AVL node per physical page of a RAM chunk (pfns are scattered) and
 * one per device range (contiguous by definition). */
struct obsd_pfnent {
	avl_node_t		e_node;
	pfn_t			e_pfn;
	pgcnt_t			e_n;		/* pages covered from e_pfn */
	struct vm_page		*e_pages;	/* descriptor of e_pfn */
};

static avl_tree_t obsd_pfntree;
static kmutex_t obsd_pfnlock;
static int obsd_vm_inited;
struct uvmexp uvmexp;

static int
obsd_pfncmp(const void *a, const void *b)
{
	const struct obsd_pfnent *x = a, *y = b;

	/* overlapping intervals compare equal, so avl_find locates the
	 * entry that contains a pfn */
#ifdef OBSD_VM_SABOTAGE
	/* negative control (test/test_vm.c): exact-pfn compare only */
	return (x->e_pfn < y->e_pfn ? -1 : x->e_pfn > y->e_pfn);
#endif
	if (x->e_pfn + x->e_n <= y->e_pfn)
		return (-1);
	if (y->e_pfn + y->e_n <= x->e_pfn)
		return (1);
	return (0);
}

void
obsd_vm_init(void)
{
	if (obsd_vm_inited)
		return;
	mutex_init(&obsd_pfnlock, NULL, MUTEX_DRIVER, NULL);
	avl_create(&obsd_pfntree, obsd_pfncmp, sizeof (struct obsd_pfnent),
	    offsetof(struct obsd_pfnent, e_node));
	uvmexp.pagesize = PAGESIZE;
	uvmexp.pagemask = PAGEOFFSET;
	uvmexp.pageshift = PAGESHIFT;
	uvmexp.npages = (int)physmem;
	uvmexp.free = (int)freemem;
	obsd_vm_inited = 1;
}

static int
obsd_pfn_add(pfn_t pfn, pgcnt_t n, struct vm_page *pg, int km)
{
	struct obsd_pfnent *e = kmem_zalloc(sizeof (*e), km);
	avl_index_t where;

	if (e == NULL)
		return (ENOMEM);

	e->e_pfn = pfn;
	e->e_n = n;
	e->e_pages = pg;
	mutex_enter(&obsd_pfnlock);
	if (avl_find(&obsd_pfntree, e, &where) != NULL) {
		mutex_exit(&obsd_pfnlock);
		kmem_free(e, sizeof (*e));
		return (EEXIST);
	}
	avl_insert(&obsd_pfntree, e, where);
	mutex_exit(&obsd_pfnlock);
	return (0);
}

static void
obsd_pfn_del(pfn_t pfn)
{
	struct obsd_pfnent key, *e;

	key.e_pfn = pfn;
	key.e_n = 1;
	mutex_enter(&obsd_pfnlock);
	if ((e = avl_find(&obsd_pfntree, &key, NULL)) != NULL)
		avl_remove(&obsd_pfntree, e);
	mutex_exit(&obsd_pfnlock);
	if (e != NULL)
		kmem_free(e, sizeof (*e));
}

struct vm_page *
PHYS_TO_VM_PAGE(paddr_t pa)
{
	struct obsd_pfnent key, *e;
	struct vm_page *pg = NULL;

	key.e_pfn = (pfn_t)(pa >> PAGESHIFT);
	key.e_n = 1;
	mutex_enter(&obsd_pfnlock);
	if ((e = avl_find(&obsd_pfntree, &key, NULL)) != NULL)
		pg = &e->e_pages[key.e_pfn - e->e_pfn];
	mutex_exit(&obsd_pfnlock);
	return (pg);
}

/* ---------------------------------------------------------- RAM chunks */
static pfn_t
obsd_va2pfn(caddr_t va)
{
#ifdef OBSD_USERTEST
	return (obsd_ushim_va2pfn(va));
#else
	return (hat_getpfnum(kas.a_hat, va));
#endif
}

static void obsd_chunk_free(struct obsd_pgchunk *);

/*
 * npages of kernel memory with a vm_page each, registered by pfn. contig:
 * physically contiguous (contig_alloc), else kmem_alloc (pages may be
 * scattered). Returns NULL on failure (sleep: KM_SLEEP semantics).
 */
static struct obsd_pgchunk *
obsd_chunk_alloc(pgcnt_t npages, int contig, int zero, int sleep)
{
	struct obsd_pgchunk *c;
	pgcnt_t i;
	int km = sleep ? KM_SLEEP : KM_NOSLEEP;

	c = kmem_zalloc(sizeof (*c), km);
	if (c == NULL)
		return (NULL);
	c->c_kind = OBSD_CHUNK_RAM;
	c->c_npages = npages;
	c->c_bytes = ptob(npages);
	c->c_contig = contig && npages > 1;
#ifndef OBSD_USERTEST
	if (c->c_contig) {
		static ddi_dma_attr_t attr = {
			DMA_ATTR_V0, 0, 0xffffffffffffffffULL,
			0xffffffffffffffffULL, 4096 /* align: one x86 page */, 1, 1,
			0xffffffffffffffffULL, 0xffffffffffffffffULL, 1, 1, 0
		};
		extern void *contig_alloc(size_t, ddi_dma_attr_t *,
		    uintptr_t, int);
		c->c_va = contig_alloc(c->c_bytes, &attr, PAGESIZE, sleep);
	} else
#endif
		c->c_va = kmem_alloc(c->c_bytes, km);
	c->c_pages = kmem_zalloc(npages * sizeof (struct vm_page), km);
	/* kmem_alloc of a page multiple is page-aligned (the kmem_alloc_N
	 * caches for page-multiple N, and segkmem beyond them); a debug
	 * kmem_flags setting could break that, and then pfns would be wrong,
	 * so refuse rather than hand out a misdescribed page. */
	if (c->c_va == NULL || c->c_pages == NULL ||
	    ((uintptr_t)c->c_va & PAGEOFFSET) != 0) {
		obsd_chunk_free(c);
		return (NULL);
	}
	if (zero)
		bzero(c->c_va, c->c_bytes);
	for (i = 0; i < npages; i++) {
		struct vm_page *pg = &c->c_pages[i];

		pg->pg_pfn = obsd_va2pfn(c->c_va + ptob(i));
		pg->phys_addr = (paddr_t)pg->pg_pfn << PAGESHIFT;
		pg->pg_chunk = c;
		pg->pg_flags = PG_CLEAN;
		if (obsd_pfn_add(pg->pg_pfn, 1, pg, km) != 0) {
			c->c_npages = i;	/* unregister only these */
			obsd_chunk_free(c);
			return (NULL);
		}
	}
	return (c);
}

static void
obsd_chunk_free(struct obsd_pgchunk *c)
{
	pgcnt_t i;
	pgcnt_t all = btop(c->c_bytes);

	for (i = 0; c->c_pages != NULL && i < c->c_npages; i++)
		obsd_pfn_del(c->c_pages[i].pg_pfn);
	if (c->c_va != NULL) {
#ifndef OBSD_USERTEST
		if (c->c_contig) {
			extern void contig_free(void *, size_t);
			contig_free(c->c_va, c->c_bytes);
		} else
#endif
			kmem_free(c->c_va, c->c_bytes);
	}
	if (c->c_pages != NULL)
		kmem_free(c->c_pages, all * sizeof (struct vm_page));
	kmem_free(c, sizeof (*c));
}

/* Kernel VA of a chunk page (what kmap returns on OpenBSD's direct map). */
static caddr_t
obsd_page_kva(struct vm_page *pg)
{
	struct obsd_pgchunk *c = pg->pg_chunk;

	if (c == NULL || c->c_kind != OBSD_CHUNK_RAM)
		return (NULL);
	return (c->c_va + ptob(pg - c->c_pages));
}

/*
 * uvm_pglistalloc: size bytes of pages within [low, high], appended to
 * rlist. nsegs == 1: one physically contiguous run. MAP: low/high and the
 * boundary are not enforced beyond a check that the result fits (on dixi
 * all RAM is below 2^39, which every Gen9 PTE reaches); alignment beyond a
 * page is not supported (EINVAL).
 */
int
uvm_pglistalloc(psize_t size, paddr_t low, paddr_t high, paddr_t alignment,
    paddr_t boundary, struct pglist *rlist, int nsegs, int flags)
{
	struct obsd_pgchunk *c;
	pgcnt_t i, n = btopr(size);

	(void) boundary;
	if (n == 0 || (alignment > PAGESIZE && nsegs == 1 && n > 1 &&
	    (alignment & (alignment - 1))))
		return (EINVAL);
	c = obsd_chunk_alloc(n, nsegs == 1, (flags & UVM_PLA_ZERO) != 0,
	    (flags & UVM_PLA_NOWAIT) == 0);
	if (c == NULL)
		return (ENOMEM);
	for (i = 0; i < n; i++) {
		if (c->c_pages[i].phys_addr < low ||
		    c->c_pages[i].phys_addr + PAGESIZE - 1 > high) {
			obsd_chunk_free(c);
			return (ENOMEM);
		}
	}
	for (i = 0; i < n; i++)
		TAILQ_INSERT_TAIL(rlist, &c->c_pages[i], pageq);
	return (0);
}

/*
 * uvm_pglistfree: free every page on list. A chunk is freed when its last
 * page comes back (callers free whole allocations: __free_pages frees the
 * 1 << order pages alloc_pages returned).
 */
void
uvm_pglistfree(struct pglist *list)
{
	struct vm_page *pg;

	while ((pg = TAILQ_FIRST(list)) != NULL) {
		struct obsd_pgchunk *c = pg->pg_chunk;

		TAILQ_REMOVE(list, pg, pageq);
		ASSERT(c != NULL && c->c_kind == OBSD_CHUNK_RAM);
		if (++c->c_freed == c->c_npages)
			obsd_chunk_free(c);
	}
}

/* ----------------------------------------------------- device ranges */
/*
 * uvm_page_physload(start, end, ...) with page numbers: give a device range
 * (the GMADR aperture, stolen memory) an array of vm_pages so that
 * PHYS_TO_VM_PAGE(base) returns its first element, as i915 expects.
 */
void
uvm_page_physload(paddr_t start, paddr_t end, paddr_t avail_start,
    paddr_t avail_end, int flags)
{
	struct obsd_pgchunk *c;
	pgcnt_t i, n = end - start;

	(void) avail_start; (void) avail_end; (void) flags;
	if (n == 0 || PHYS_TO_VM_PAGE(ptob(start)) != NULL)
		return;			/* already loaded (re-attach) */
	c = kmem_zalloc(sizeof (*c), KM_SLEEP);
	c->c_kind = OBSD_CHUNK_RANGE;
	c->c_pfn0 = (pfn_t)start;
	c->c_npages = n;
	c->c_bytes = ptob(n);
	c->c_pages = kmem_zalloc(n * sizeof (struct vm_page), KM_SLEEP);
	for (i = 0; i < n; i++) {
		c->c_pages[i].pg_pfn = start + i;
		c->c_pages[i].phys_addr = ptob(start + i);
		c->c_pages[i].pg_flags = PG_DEV;
		c->c_pages[i].pg_chunk = c;
	}
	if (obsd_pfn_add(c->c_pfn0, n, c->c_pages, KM_SLEEP) != 0) {
		kmem_free(c->c_pages, n * sizeof (struct vm_page));
		kmem_free(c, sizeof (*c));
	}
}

/* ------------------------------------------------------- uao objects */
/*
 * A uao is a uvm_object whose uo_priv is a struct obsd_uao: size bytes of
 * wired chunk pages, allocated at creation. Reference counted through
 * uo_refs (uao_reference / uao_detach).
 */
struct obsd_uao {
	struct uvm_object	u_obj;
	struct rwlock		u_lock;
	size_t			u_size;
	pgcnt_t			u_npages;
	struct obsd_pgchunk	**u_chunks;	/* one chunk per page */
};

static const struct uvm_pagerops obsd_aobj_pager;	/* identity only */

struct uvm_object *
uao_create(vsize_t size, int flags)
{
	struct obsd_uao *u;
	pgcnt_t i;

	(void) flags;
	if (size == 0)
		return (NULL);
	u = kmem_zalloc(sizeof (*u), KM_SLEEP);
	u->u_size = size;
	u->u_npages = btopr(size);
	u->u_chunks = kmem_zalloc(u->u_npages * sizeof (void *), KM_SLEEP);
	/*
	 * Per-page chunks: a 4K frame buffer object is 8100 pages, and a
	 * single kmem_alloc of 33 MB needs that much contiguous VA but not
	 * contiguous RAM, which a per-page list does not need either.
	 * NOTE: one kmem_alloc per page; a slab per object is the upgrade if
	 * creation cost shows up.
	 */
	for (i = 0; i < u->u_npages; i++) {
		u->u_chunks[i] = obsd_chunk_alloc(1, 0, 1, 1);
		if (u->u_chunks[i] == NULL) {
			u->u_obj.uo_refs = 1;
			u->u_obj.uo_priv = u;
			uao_detach(&u->u_obj);
			return (NULL);
		}
	}
#ifdef OBSD_USERTEST
	u->u_obj.vmobjlock = (void *)&u->u_lock;
#else
	rw_init(&u->u_lock.rwl_lock, NULL, RW_DRIVER, NULL);
	u->u_obj.vmobjlock = &u->u_lock;
#endif
	u->u_obj.pgops = &obsd_aobj_pager;
	u->u_obj.uo_npages = (int)u->u_npages;
	u->u_obj.uo_refs = 1;
	u->u_obj.uo_priv = u;
	return (&u->u_obj);
}

void
uao_reference(struct uvm_object *uobj)
{
	atomic_inc_uint((volatile uint_t *)&uobj->uo_refs);
}

void
uao_detach(struct uvm_object *uobj)
{
	struct obsd_uao *u = uobj->uo_priv;
	pgcnt_t i;

	if (atomic_dec_uint_nv((volatile uint_t *)&uobj->uo_refs) != 0)
		return;
	for (i = 0; i < u->u_npages; i++)
		if (u->u_chunks[i] != NULL)
			obsd_chunk_free(u->u_chunks[i]);
	kmem_free(u->u_chunks, u->u_npages * sizeof (void *));
#ifndef OBSD_USERTEST
	if (u->u_obj.vmobjlock != NULL)
		rw_destroy(&u->u_lock.rwl_lock);
#endif
	kmem_free(u, sizeof (*u));
}

/*
 * uvm_obj_wire(uobj, start, end, list): the pages backing [start, end) of
 * a uao, appended to list in offset order. Already wired, so this only
 * hands them out; uvm_obj_unwire is a no-op. Non-uao objects: EINVAL.
 */
int
uvm_obj_wire(struct uvm_object *uobj, voff_t start, voff_t end,
    struct pglist *list)
{
	struct obsd_uao *u = uobj->uo_priv;
	pgcnt_t i;

	if (uobj->pgops != &obsd_aobj_pager || start < 0 || end < start ||
	    btopr(end) > u->u_npages)
		return (EINVAL);
	for (i = btop(start); i < btopr(end); i++) {
		struct vm_page *pg = &u->u_chunks[i]->c_pages[0];

		pg->uobject = uobj;
		pg->offset = ptob(i);
		pg->wire_count++;
		TAILQ_INSERT_TAIL(list, pg, pageq);
	}
	return (0);
}

void
uvm_obj_unwire(struct uvm_object *uobj, voff_t start, voff_t end)
{
	struct obsd_uao *u = uobj->uo_priv;
	pgcnt_t i;

	if (uobj->pgops != &obsd_aobj_pager)
		return;
	for (i = btop(start); i < btopr(end) && i < u->u_npages; i++)
		if (u->u_chunks[i]->c_pages[0].wire_count > 0)
			u->u_chunks[i]->c_pages[0].wire_count--;
}

/* uvm_obj_init / destroy for drm's own (non-uao) objects: OpenBSD
 * allocates the object lock here unless refs is UVM_OBJ_KERN. */
void
uvm_obj_init(struct uvm_object *uobj, const struct uvm_pagerops *pgops,
    int refs)
{
	uobj->pgops = pgops;
	uobj->uo_npages = 0;
	uobj->uo_refs = refs;
	uobj->vmobjlock = kmem_zalloc(sizeof (struct rwlock), KM_SLEEP);
#ifndef OBSD_USERTEST
	rw_init(&uobj->vmobjlock->rwl_lock, NULL, RW_DRIVER, NULL);
#endif
}

void
uvm_obj_destroy(struct uvm_object *uobj)
{
	if (uobj->vmobjlock == NULL)
		return;
#ifndef OBSD_USERTEST
	rw_destroy(&uobj->vmobjlock->rwl_lock);
#endif
	kmem_free(uobj->vmobjlock, sizeof (struct rwlock));
	uobj->vmobjlock = NULL;
}

#ifndef OBSD_USERTEST
/* ---------------------------------------------------------- pmap (kernel) */
static struct pmap { int pm_dummy; } obsd_kernel_pmap;
static struct vm_map obsd_kernel_map, obsd_phys_map;
struct vm_map *kernel_map = &obsd_kernel_map;
struct vm_map *phys_map = &obsd_phys_map;
struct uvm_constraint_range no_constraint = { 0x0, (paddr_t)-1 };
struct uvm_constraint_range dma_constraint = { 0x0, (paddr_t)0xffffffffUL };

struct pmap *
pmap_kernel(void)
{
	return (&obsd_kernel_pmap);
}

/* OpenBSD amd64 carries PMAP_NOCACHE (0x1) / PMAP_WC (0x2) in pa's low
 * bits (asm/pgtable.h pgprot_*). */
static uint_t
obsd_hat_attr(paddr_t pa, vm_prot_t prot)
{
	uint_t a = 0;

	if (prot & PROT_READ)
		a |= PROT_READ;
	if (prot & PROT_WRITE)
		a |= PROT_WRITE;
	if (pa & PMAP_WC)
		a |= HAT_MERGING_OK | HAT_PLAT_NOCACHE_OBSD;
	else if (pa & PMAP_NOCACHE)
		a |= HAT_STRICTORDER | HAT_PLAT_NOCACHE_OBSD;
	else
		a |= HAT_STORECACHING_OK;
	return (a);
}

void
pmap_kenter_pa(vaddr_t va, paddr_t pa, vm_prot_t prot)
{
	hat_devload(kas.a_hat, (caddr_t)va, PAGESIZE,
	    (pfn_t)(pa >> PAGESHIFT), obsd_hat_attr(pa, prot), HAT_LOAD_LOCK);
}

void
pmap_kremove(vaddr_t va, vsize_t len)
{
	hat_unload(kas.a_hat, (caddr_t)va, len, HAT_UNLOAD_UNLOCK);
}

/* Only the kernel pmap: a process pmap is the GEM user-mapping path (R2). */
int
pmap_enter(pmap_t pm, vaddr_t va, paddr_t pa, vm_prot_t prot, int flags)
{
	(void) flags;
	if (pm != &obsd_kernel_pmap)
		return (ENOTSUP);
	pmap_kenter_pa(va, pa, prot);
	return (0);
}

void
pmap_remove(pmap_t pm, vaddr_t sva, vaddr_t eva)
{
	if (pm == &obsd_kernel_pmap)
		pmap_kremove(sva, eva - sva);
}

int
pmap_extract(pmap_t pm, vaddr_t va, paddr_t *pap)
{
	pfn_t pfn;

	if (pm != &obsd_kernel_pmap)
		return (0);
	pfn = hat_getpfnum(kas.a_hat, (caddr_t)va);
	if (pfn == PFN_INVALID)
		return (0);
	*pap = ptob(pfn) | (va & PAGEOFFSET);
	return (1);
}

/* OpenBSD revokes user mappings of the page; there are none before R2. */
void
pmap_page_protect(struct vm_page *pg, vm_prot_t prot)
{
	(void) pg; (void) prot;
}

vaddr_t
pmap_map_direct(struct vm_page *pg)
{
	caddr_t va = obsd_page_kva(pg);

	return ((vaddr_t)(va != NULL ? va : hat_kpm_pfn2va(pg->pg_pfn)));
}

struct vm_page *
pmap_unmap_direct(vaddr_t va)
{
	return (uvm_atopg(va));
}

void
pmap_zero_page(struct vm_page *pg)
{
	bzero((void *)pmap_map_direct(pg), PAGESIZE);
}

void
uvm_pagecopy(struct vm_page *src, struct vm_page *dst)
{
	bcopy((void *)pmap_map_direct(src), (void *)pmap_map_direct(dst),
	    PAGESIZE);
}

/* virt_to_page for kernel memory (km_alloc, kmem). */
struct vm_page *
uvm_atopg(vaddr_t va)
{
	pfn_t pfn = hat_getpfnum(kas.a_hat, (caddr_t)va);

	return (pfn == PFN_INVALID ? NULL : PHYS_TO_VM_PAGE(ptob(pfn)));
}

/* wbinvd on every CPU: illumos invalidate_cache() via a cross call. */
static int
obsd_wbinvd_xc(xc_arg_t a1, xc_arg_t a2, xc_arg_t a3)
{
	(void) a1; (void) a2; (void) a3;
	invalidate_cache();
	return (0);
}

void
wbinvd_on_all_cpus(void)
{
	cpuset_t *set = cpuset_alloc(KM_SLEEP);

	cpuset_all(set);
	kpreempt_disable();
	/* a cpuset_t is its bit vector (CPUSET2BV) */
	xc_call(0, 0, 0, (ulong_t *)(void *)set, obsd_wbinvd_xc);
	kpreempt_enable();
	cpuset_free(set);
}

/* ------------------------------------------------------------- km_alloc */
/*
 * km_alloc modes drm uses: kernel VA + dirty/zeroed pages (kv_any/kv_page +
 * kp_dirty/kp_zero) = kmem_alloc of a page multiple; VA only (kp_none, the
 * caller enters pages with pmap_kenter_pa: kmap, vmap, kmap_atomic) =
 * vmem_alloc(heap_arena), as gfxp_map_kernel_space does.
 */
const struct kmem_va_mode kv_any = { 0 };
const struct kmem_va_mode kv_intrsafe = { 0 };
const struct kmem_va_mode kv_page = { .kv_singlepage = 1 };
const struct kmem_pa_mode kp_dirty = { 0 };
const struct kmem_pa_mode kp_zero = { .kp_zero = 1 };
const struct kmem_pa_mode kp_none = { .kp_nomem = 1 };
const struct kmem_dyn_mode kd_waitok = { .kd_waitok = 1 };
const struct kmem_dyn_mode kd_nowait = { 0 };
const struct kmem_dyn_mode kd_trylock = { .kd_trylock = 1 };

void *
km_alloc(size_t sz, const struct kmem_va_mode *kv,
    const struct kmem_pa_mode *kp, const struct kmem_dyn_mode *kd)
{
	int km = (kd->kd_waitok || kv->kv_wait) ? KM_SLEEP : KM_NOSLEEP;

	sz = P2ROUNDUP(sz, PAGESIZE);
	if (kp->kp_nomem)
		return (vmem_alloc(heap_arena, sz,
		    km == KM_SLEEP ? VM_SLEEP : VM_NOSLEEP));
	if (kp->kp_constraint != NULL)
		return (NULL);	/* DMA-constrained modes: R2 (bus_dma) */
	return (kp->kp_zero ? kmem_zalloc(sz, km) : kmem_alloc(sz, km));
}

void
km_free(void *va, size_t sz, const struct kmem_va_mode *kv,
    const struct kmem_pa_mode *kp)
{
	(void) kv;
	sz = P2ROUNDUP(sz, PAGESIZE);
	if (kp->kp_nomem)
		vmem_free(heap_arena, va, sz);
	else
		kmem_free(va, sz);
}

/* --------------------------------------------- user mappings (R2, ENOTSUP) */
int
uvm_map(vm_map_t map, vaddr_t *addr, vsize_t size, struct uvm_object *uobj,
    voff_t off, vsize_t align, unsigned int flags)
{
	(void) map; (void) addr; (void) size; (void) uobj; (void) off;
	(void) align; (void) flags;
	return (ENOTSUP);
}

void
uvmfault_unlockall(struct uvm_faultinfo *ufi, void *amap,
    struct uvm_object *uobj)
{
	(void) ufi; (void) amap; (void) uobj;
}

/* Wait for memory: OpenBSD sleeps until the pagedaemon frees some; here
 * a 10 ms nap before the caller retries. */
void
uvm_wait(const char *wmsg)
{
	(void) tsleep_nsec(&nowake, PWAIT, wmsg, MSEC_TO_NSEC(10));
}
#endif /* !OBSD_USERTEST */
