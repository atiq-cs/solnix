/*
 * as.c — illumos riscv64 per-process address space (R-P7).
 *
 * The R-P7 address-space (as_t) analog: each userland process gets its own
 * Sv39 root page table (via hat_as_newroot, which copies the kernel gigapages
 * in so the kernel stays reachable after a trap from U-mode) plus a set of
 * user-page mappings installed with PTE_U. This is the seed of uts/common/vm
 * as.c / seg drivers, pared to what exec + a first process need:
 *
 *   - as_alloc():        fresh address space (new Sv39 root).
 *   - as_map():          map [va,va+len) to freshly allocated zeroed user
 *                        pages with the given perm, copying `copylen` bytes of
 *                        `data` into them (the ELF PT_LOAD memsz/filesz split).
 *   - as_map_stack():    map a user stack region.
 *   - as_switch():       load this address space's satp on the current hart.
 *
 * NOTE (R-P9): copy-on-write fork IS implemented (as_cow_copy shares pages
 * read-only + splits them on the store fault); as_free reclaims all user leaves
 * + page tables + root. Still no segment list / demand paging / mmap. Upgrade
 * path: seg_vn/seg_kmem-style segments + demand paging.
 */

#include "sbi.h"
#include "riscv_regs.h"

/* hat_riscv.c: per-AS page-table primitives. */
extern unsigned long hat_as_newroot(void);
extern void hat_as_map(unsigned long root, unsigned long va, unsigned long pa,
    unsigned long perm);
extern unsigned long hat_as_satp(unsigned long root);
extern void hat_as_switch(unsigned long satp);
extern void hat_as_walk_leaves(unsigned long root,
    void (*cb)(void *arg, unsigned long va, unsigned long pa,
    unsigned long perm), void *arg);
extern void hat_as_freeuser(unsigned long root);
extern unsigned long hat_as_va2pa(unsigned long root, unsigned long va);

/* vm_page.c */
extern void page_free(unsigned long pa);

/* vm_page.c: real page allocator (returns a zeroed identity-mapped phys page). */
extern unsigned long page_alloc(void);

extern void kputhex(unsigned long v);
extern void kputdec(unsigned long v);

/*
 * as_t — a user address space: its root table PA, precomputed satp, and a
 * small tally of mapped user pages (diagnostics). Kept in kmem by the caller.
 */
typedef struct as {
	unsigned long	a_root;		/* root page-table PA */
	unsigned long	a_satp;		/* Sv39 satp for this AS */
	unsigned long	a_npages;	/* user pages mapped */
	unsigned long	a_brk;		/* current program break (heap top VA) */
} as_t;

/* From kmem.c. */
extern void *kmem_alloc(unsigned long size);
extern void kmem_free(void *buf, unsigned long size);

/* forward (as_copy references as_free before its definition). */
void as_free(as_t *as);

/*
 * as_alloc — build a fresh user address space (new Sv39 root with the kernel
 * gigapages copied in). Returns the as_t (kmem) or NULL.
 */
as_t *
as_alloc(void)
{
	as_t *as = kmem_alloc(sizeof (as_t));

	if (as == 0)
		return (0);
	as->a_root = hat_as_newroot();
	as->a_satp = hat_as_satp(as->a_root);
	as->a_npages = 0;
	as->a_brk = 0;
	return (as);
}

/*
 * as_map — map the user region [va, va+len) into `as` with permission `perm`
 * (PTE_R/W/X bits; PTE_U is added by the hat). Fresh zeroed pages are
 * allocated per 4 KiB; the first `copylen` bytes of the region are filled from
 * `data` (which may be NULL for a pure-BSS region). va/len need not be page
 * aligned — we round the region out to page boundaries and copy into the
 * correct offsets. This is the exec PT_LOAD primitive: filesz bytes copied,
 * the rest (memsz-filesz) left zero.
 *
 * Returns 1 on success, 0 on allocation failure.
 */
int
as_map(as_t *as, unsigned long va, unsigned long len, const void *data,
    unsigned long copylen, unsigned long perm)
{
	unsigned long start = va & ~(PAGESIZE - 1);
	unsigned long end = (va + len + PAGESIZE - 1) & ~(PAGESIZE - 1);
	unsigned long p;

	for (p = start; p < end; p += PAGESIZE) {
		unsigned long pa = page_alloc();	/* zeroed */
		unsigned long off, n;

		if (pa == 0)
			return (0);

		/*
		 * Copy the slice of `data` that falls in this page. The source
		 * range is [va, va+copylen); intersect it with [p, p+PAGESIZE).
		 */
		if (data != 0 && p + PAGESIZE > va && p < va + copylen) {
			unsigned long seg_start = (p > va) ? p : va;
			unsigned long seg_end = (p + PAGESIZE < va + copylen) ?
			    (p + PAGESIZE) : (va + copylen);
			const unsigned char *src =
			    (const unsigned char *)data + (seg_start - va);
			unsigned char *dst =
			    (unsigned char *)(pa + (seg_start - p));

			off = 0;
			n = seg_end - seg_start;
			while (off < n) {
				dst[off] = src[off];
				off++;
			}
		}

		hat_as_map(as->a_root, p, pa, perm);
		as->a_npages++;
	}
	return (1);
}

/* as_switch — load this address space's satp on the current hart. */
void
as_switch(as_t *as)
{
	hat_as_switch(as->a_satp);
}

/*
 * as_copy — duplicate `src` into a brand-new address space (fork). Every user
 * leaf of the parent is copied to a freshly allocated page in the child with
 * the same VA + protection (a full eager copy — no copy-on-write in R-P8). The
 * program break is inherited. Returns the child as_t or NULL on failure.
 *
 * NOTE: full eager copy (as_copy). R-P9 adds as_cow_copy (copy-on-write): the
 * default fork path now shares pages read-only and splits on write. as_copy is
 * retained for callers that want an eager duplicate.
 */
struct as_copy_ctx {
	as_t	*dst;
	int	ok;
};

static void
as_copy_leaf(void *arg, unsigned long va, unsigned long pa, unsigned long perm)
{
	struct as_copy_ctx *c = (struct as_copy_ctx *)arg;
	unsigned long npa;
	unsigned long i;
	const unsigned char *src;
	unsigned char *dst;

	if (!c->ok)
		return;
	npa = page_alloc();		/* zeroed */
	if (npa == 0) {
		c->ok = 0;
		return;
	}
	/* Pages are identity-mapped (VA==PA) in the kernel, so copy directly. */
	src = (const unsigned char *)pa;
	dst = (unsigned char *)npa;
	for (i = 0; i < PAGESIZE; i++)
		dst[i] = src[i];
	hat_as_map(c->dst->a_root, va, npa, perm);
	c->dst->a_npages++;
}

as_t *
as_copy(as_t *src)
{
	struct as_copy_ctx c;

	c.dst = as_alloc();
	if (c.dst == 0)
		return (0);
	c.ok = 1;
	hat_as_walk_leaves(src->a_root, as_copy_leaf, &c);
	if (!c.ok) {
		as_free(c.dst);
		return (0);
	}
	c.dst->a_brk = src->a_brk;
	return (c.dst);
}

/* hat_riscv.c: COW share (fork) + COW store-fault split (R-P9). */
extern unsigned long hat_as_cow_share(unsigned long dstroot,
    unsigned long srcroot);
extern int hat_as_cow_fault(unsigned long root, unsigned long va);

/* R-P9 COW fork stats (for the gate banner): pages shared read-only at fork,
 * and pages actually copied on a later write fault. */
unsigned long as_cow_shared_total;
unsigned long as_cow_copied_total;

/*
 * as_cow_copy — copy-on-write fork of `src`. Instead of eagerly copying every
 * leaf (as_copy), share the parent's pages read-only into the child and mark
 * both COW; the first write in either process store-faults and splits the page
 * private (as_cow_fault). Returns the child as_t or NULL on failure. This is
 * the R-P9 replacement for the R-P8 full-AS-copy fork.
 */
as_t *
as_cow_copy(as_t *src)
{
	as_t *dst = as_alloc();
	unsigned long shared;

	if (dst == 0)
		return (0);
	shared = hat_as_cow_share(dst->a_root, src->a_root);
	dst->a_npages = shared;
	dst->a_brk = src->a_brk;
	as_cow_shared_total += shared;

	/* Both AS TLBs must be flushed: the parent's writable leaves became
	 * read-only. sfence.vma (all) on the current hart covers the active
	 * (parent) satp; the child has not run yet so its TLB is cold. */
	__asm__ __volatile__("sfence.vma" ::: "memory");
	return (dst);
}

/*
 * as_cow_fault — handle a store page fault at user VA `va` in address space
 * `as`. Returns 1 if it was a COW page that was successfully split (the store
 * can be retried), 0 if `va` is not a COW leaf (a genuine fault). Called from
 * the trap dispatcher's store-page-fault path.
 */
int
as_cow_fault(as_t *as, unsigned long va)
{
	int r;

	if (as == 0)
		return (0);
	r = hat_as_cow_fault(as->a_root, va);
	if (r)
		as_cow_copied_total++;
	return (r);
}

/*
 * as_setbrk / as_grow — the heap (brk/sbrk) primitive. exec sets the initial
 * break just past the loaded image (via as_setbrk). as_grow moves the break to
 * `newbrk`, eagerly mapping fresh RW user pages for any newly covered page. A
 * shrink just lowers the recorded break (pages are not reclaimed until exit).
 * Returns the new break, or 0 on allocation failure.
 */
void
as_setbrk(as_t *as, unsigned long brk)
{
	as->a_brk = (brk + PAGESIZE - 1) & ~(PAGESIZE - 1);
}

unsigned long
as_getbrk(as_t *as)
{
	return (as->a_brk);
}

unsigned long
as_grow(as_t *as, unsigned long newbrk)
{
	unsigned long oldtop = (as->a_brk + PAGESIZE - 1) & ~(PAGESIZE - 1);
	unsigned long newtop = (newbrk + PAGESIZE - 1) & ~(PAGESIZE - 1);
	unsigned long p;

	if (newbrk <= as->a_brk) {
		as->a_brk = newbrk;		/* shrink: keep pages, lower brk */
		return (as->a_brk);
	}
	for (p = oldtop; p < newtop; p += PAGESIZE) {
		unsigned long pa = page_alloc();	/* zeroed */

		if (pa == 0)
			return (0);
		hat_as_map(as->a_root, p, pa, PTE_R | PTE_W);
		as->a_npages++;
	}
	as->a_brk = newbrk;
	return (as->a_brk);
}

/*
 * as_free — reclaim every user page (leaf data + intermediate page tables +
 * root) of `as` and free the as_t. Called on proc_exit teardown. Must not run
 * while `as` is the active satp (switch to the kernel AS first).
 */
static void
as_free_leaf(void *arg, unsigned long va, unsigned long pa, unsigned long perm)
{
	(void) arg;
	(void) va;
	(void) perm;
	page_free(pa);
}

void
as_free(as_t *as)
{
	if (as == 0)
		return;
	hat_as_walk_leaves(as->a_root, as_free_leaf, 0);
	hat_as_freeuser(as->a_root);
	kmem_free(as, sizeof (as_t));
}

/* Accessors for the exec/proc path. */
unsigned long as_satp(as_t *as)   { return (as->a_satp); }
unsigned long as_root(as_t *as)   { return (as->a_root); }
unsigned long as_npages(as_t *as) { return (as->a_npages); }

/*
 * as_copyto — copy `n` bytes from a kernel buffer into user VA `va` of `as`,
 * WITHOUT switching satp. Walks the AS page table per page to find the backing
 * physical page (identity-mapped VA==PA in the kernel) and writes into it. Used
 * by the exec path to plant the argv/env/auxv image on the fresh user stack
 * before the process's satp is ever loaded. Returns 1 on success, 0 if any page
 * of the range is unmapped in `as`.
 */
int
as_copyto(as_t *as, unsigned long va, const void *src, unsigned long n)
{
	const unsigned char *s = (const unsigned char *)src;
	unsigned long done = 0;

	while (done < n) {
		unsigned long uva = va + done;
		unsigned long pa = hat_as_va2pa(as->a_root, uva & ~(PAGESIZE - 1));
		unsigned long off = uva & (PAGESIZE - 1);
		unsigned long chunk = PAGESIZE - off;
		unsigned char *dst;
		unsigned long i;

		if (pa == 0)
			return (0);		/* unmapped user page */
		if (chunk > n - done)
			chunk = n - done;
		dst = (unsigned char *)(pa + off);
		for (i = 0; i < chunk; i++)
			dst[i] = s[done + i];
		done += chunk;
	}
	return (1);
}
