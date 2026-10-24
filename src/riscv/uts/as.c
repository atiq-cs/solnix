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
 * + page tables + root. as_anon_map adds the MAP_ANON arena. Still no segment
 * list / demand paging / munmap. Upgrade path: seg_vn/seg_kmem-style segments +
 * demand paging.
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
extern unsigned long hat_as_unmap(unsigned long root, unsigned long va);
extern int hat_user_range_ok(unsigned long va, unsigned long len);

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
/*
 * How many freed anon extents an address space remembers for reuse. 16 covers a
 * compositor's churn (buffer pools being resized, clients coming and going)
 * without needing a dynamic allocator underneath the allocator.
 */
#define	AS_NFREE	16

typedef struct as {
	unsigned long	a_root;		/* root page-table PA */
	unsigned long	a_satp;		/* Sv39 satp for this AS */
	unsigned long	a_npages;	/* user pages mapped */
	unsigned long	a_brk;		/* current program break (heap top VA) */
	unsigned long	a_mmap;		/* next free VA in the anon mmap arena */
	/*
	 * Freed anon extents, newest first, for reuse. A fixed array rather than
	 * a linked list because the nodes would otherwise need an allocator that
	 * itself wants mmap -- and a compositor's steady state is a handful of
	 * long-lived mappings plus churn, not thousands of distinct holes.
	 *
	 * When the array is full the oldest entry is DROPPED rather than
	 * coalesced, which leaks that VA range until process exit. That is a
	 * bounded, documented ceiling (see as_anon_unmap) and strictly better
	 * than the previous behaviour of leaking every single unmap.
	 */
	struct {
		unsigned long	f_va;
		unsigned long	f_len;
	}		a_free[AS_NFREE];
	unsigned int	a_nfree;
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
/*
 * ANON_MMAP_BASE -- the base of the anonymous-mmap arena, which grows UP.
 *
 * Placement inside Sv39 level-2 slot 3 (0xC0000000..0xFFFFFFFF), the one slot
 * with no kernel entry, alongside the other user regions:
 *   0xC0010000  userland text/data, heap (brk) growing up behind it
 *   0xC4000000  the /dev/fb device mapping (fb.c FB_MMAP_BASE, <= 8 MiB)
 *   0xD0000000  THIS arena, growing up
 *   0xfffff000  top of the user stack, growing down (64 KiB)
 * That leaves ~768 MiB of arena between the framebuffer and the stack, which is
 * more than the physical memory a boot has, so the arena cannot collide with
 * either neighbour before page_alloc fails first.
 */
#define	ANON_MMAP_BASE	0xD0000000UL

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
	as->a_mmap = ANON_MMAP_BASE;
	return (as);
}

/*
 * as_anon_map -- back [va, va+len) with fresh ZEROED private user pages and
 * return the VA. This is the MAP_ANON|MAP_PRIVATE primitive: every allocator
 * (including Rust std's) and every thread-stack allocation wants it, and until
 * now only /dev/fb was mappable.
 *
 * Allocation is a bump pointer up the arena; the pages are eagerly allocated and
 * mapped RW (no demand paging exists), and they are zeroed because page_alloc
 * zeroes -- which MAP_ANON requires, not merely permits.
 *
 * Returns the mapped VA, or 0 if the length is unusable or a page allocation
 * failed partway (the pages already installed stay mapped and are reclaimed with
 * the rest of the AS at exit; there is no partial-unmap primitive to undo them
 * with, which is the same reason munmap does not exist -- see the NOTE).
 *
 * NOTE (ceiling): a bump arena with NO reuse and NO munmap. Freed mappings are
 * reclaimed only at process exit, so a program that maps and unmaps in a loop
 * exhausts the arena. The upgrade is a real seg_vn segment list with a free list
 * and an unmap primitive in the hat; that is also what munmap(2) needs, so both
 * arrive together rather than shipping a munmap that silently leaks.
 */
unsigned long
as_anon_map(as_t *as, unsigned long len)
{
	unsigned long va, p, end;

	if (as == 0 || len == 0)
		return (0);
	len = (len + PAGESIZE - 1) & ~(PAGESIZE - 1);

	/*
	 * Reuse a freed extent if one fits, newest first. Exact-fit only: a
	 * best-fit split would leave remainder entries that need coalescing to
	 * stay useful, and an uncoalesced splinter list degrades into a slow leak.
	 * Exact fit is the common case here anyway -- allocators re-request the
	 * same rounded sizes.
	 */
	{
		unsigned int i;

		for (i = 0; i < as->a_nfree; i++) {
			if (as->a_free[i].f_len != len)
				continue;
			va = as->a_free[i].f_va;
			as->a_free[i] = as->a_free[as->a_nfree - 1];
			as->a_nfree--;
			/* Re-back it: the pages were freed at unmap time. */
			for (p = va; p < va + len; p += PAGESIZE) {
				unsigned long pa = page_alloc();

				if (pa == 0)
					return (0);
				hat_as_map(as->a_root, p, pa,
				    PTE_R | PTE_W);
				as->a_npages++;
			}
			return (va);
		}
	}

	va = as->a_mmap;
	end = va + len;
	if (end < va)
		return (0);		/* length overflowed the arena */
	/* rvsrv: with GiBs of RAM page_alloc no longer fails first; stay below
	 * the user stack (USTACK_TOP - 64 KiB in uproc.c) and inside slot 3. */
	if (end > 0xfffff000UL - 16 * PAGESIZE || !hat_user_range_ok(va, len))
		return (0);

	for (p = va; p < end; p += PAGESIZE) {
		unsigned long pa = page_alloc();	/* zeroed */

		if (pa == 0)
			return (0);
		hat_as_map(as->a_root, p, pa, PTE_R | PTE_W);
		as->a_npages++;
	}
	as->a_mmap = end;
	/*
	 * The arena VAs were unmapped a moment ago, and this AS may be the live
	 * satp (mmap is called from a syscall in the mapping process), so a
	 * negative TLB entry for a touched-and-faulted VA must not survive.
	 */
	__asm__ __volatile__("sfence.vma" ::: "memory");
	return (va);
}

/*
 * as_anon_unmap -- tear down [va, va+len) in the anon arena, free its pages, and
 * remember the VA range for reuse. Returns 0 on success, -1 if the range is not
 * in the arena.
 *
 * This plus hat_as_unmap is what munmap(2) needs, and what makes as_anon_map's
 * free-list reuse possible. Before it existed, every unmap leaked until process
 * exit, so a program that mapped and unmapped in a loop exhausted the arena --
 * which a long-running compositor resizing buffer pools would do.
 *
 * The pages ARE freed here (unlike hat_as_unmap, which only returns the PA):
 * anon pages are private by construction, so this address space is the sole
 * owner and page_free is safe. That would NOT hold for a COW-shared page, which
 * is exactly why the hat layer leaves the decision to its caller.
 */
int
as_anon_unmap(as_t *as, unsigned long va, unsigned long len)
{
	unsigned long p;

	if (as == 0 || len == 0)
		return (-1);
	if ((va & (PAGESIZE - 1)) != 0)
		return (-1);		/* must be page-aligned */
	len = (len + PAGESIZE - 1) & ~(PAGESIZE - 1);
	if (va < ANON_MMAP_BASE || va + len > as->a_mmap)
		return (-1);		/* not a range we handed out */

	for (p = va; p < va + len; p += PAGESIZE) {
		unsigned long pa = hat_as_unmap(as->a_root, p);

		if (pa != 0) {
			page_free(pa);
			if (as->a_npages > 0)
				as->a_npages--;
		}
	}

	/*
	 * Remember the hole. If the table is full the OLDEST entry is dropped:
	 * that range then leaks until exit. Bounded and deliberate -- the
	 * alternative is failing the unmap, which would be worse, and coalescing
	 * needs a sorted structure this layer does not have yet.
	 */
	if (as->a_nfree == AS_NFREE) {
		unsigned int i;

		for (i = 1; i < AS_NFREE; i++)
			as->a_free[i - 1] = as->a_free[i];
		as->a_nfree--;
	}
	as->a_free[as->a_nfree].f_va = va;
	as->a_free[as->a_nfree].f_len = len;
	as->a_nfree++;

	/*
	 * The caller must invalidate the TLB; as_anon_unmap cannot know whether
	 * this AS is loaded on the current hart.
	 */
	return (0);
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

	/* rvsrv: an ELF segment must lie in a user slot, not on a kernel leaf. */
	if (end < start || !hat_user_range_ok(start, end - start))
		return (0);
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
	c.dst->a_mmap = src->a_mmap;	/* the arena bump follows the AS */
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
	/*
	 * The arena bump must be INHERITED, not reset: the child's anon mappings
	 * are already present (COW-shared with the parent's), so restarting the
	 * bump at the base would hand out VAs that are already mapped and the
	 * second mmap would silently overwrite the first.
	 */
	dst->a_mmap = src->a_mmap;
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
	/* rvsrv: a brk past its user slot would map onto a kernel leaf. */
	if (!hat_user_range_ok(oldtop, newtop - oldtop))
		return (0);
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
/*
 * The /dev/fb device window. Kept in sync with fb.c's FB_MMAP_BASE and the
 * address-space map comment above.
 */
#define	FB_DEV_VA_BASE	0xC4000000UL
#define	FB_DEV_VA_END	(FB_DEV_VA_BASE + 0x800000UL)	/* <= 8 MiB */

static void
as_free_leaf(void *arg, unsigned long va, unsigned long pa, unsigned long perm)
{
	(void) arg;
	(void) perm;

	/*
	 * DO NOT free the framebuffer. Those pages are the scanout hardware
	 * window, not memory this address space owns: they are mapped into every
	 * process that opened /dev/fb, and page_free()ing them at one process's
	 * exit hands live display memory back to the page allocator, where it is
	 * promptly reused. The surviving mapper then store-faults on its own
	 * framebuffer.
	 *
	 * Found by the compositor-shaped integration test, and only findable
	 * there: it needs a process that maps /dev/fb, forks, has the child exit,
	 * and then keeps painting. No per-feature gate does all four, which is
	 * precisely the argument for having an integration test at all.
	 *
	 * (My first theory was COW-marking at fork. Wrong: the fault lands after
	 * the CHILD EXITS, which points at teardown rather than at fork.)
	 */
	if (va >= FB_DEV_VA_BASE && va < FB_DEV_VA_END)
		return;

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
