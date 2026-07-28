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
} as_t;

/* From kmem.c. */
extern void *kmem_alloc(unsigned long size);

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

/* Accessors for the exec/proc path. */
unsigned long as_satp(as_t *as)   { return (as->a_satp); }
unsigned long as_root(as_t *as)   { return (as->a_root); }
unsigned long as_npages(as_t *as) { return (as->a_npages); }
