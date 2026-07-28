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
 * NOTE: no segment list / page-fault-driven demand paging / copy-on-write /
 * mmap / munmap / teardown-and-free. Every page is eagerly allocated and
 * mapped at exec time; there is exactly one live user address space at a time
 * (the first process). Upgrade path (R-P8): seg_vn/seg_kmem-style segments,
 * demand paging off the store-page-fault handler, and as_free reclaiming pages.
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
 * NOTE: full copy, not COW. Simple + correct for R-P8's small processes; COW
 * off the store-page-fault handler is the R-P9 upgrade (fork of a big AS is
 * O(pages) copies today).
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
