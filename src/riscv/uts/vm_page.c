/*
 * vm_page.c — illumos riscv64 physical page management (R-P5).
 *
 * The seed of the real illumos VM page layer (uts/common/vm/page.h,
 * vm/vm_page.c): a page_t array describing every managed physical page and a
 * free list threaded through it. R-P4 handed out physical pages from a one-way
 * bump allocator with a hardcoded 128 MiB cap and no free; R-P5 replaces that
 * with a genuine page_t[] + freelist built over the RAM the DTB reports, with
 * page_alloc() / page_free().
 *
 * Design (illumos idiom, minimized to the essentials):
 *   - page_t: per-page frame descriptor. illumos page_t is large (vnode/offset,
 *     hash links, io/lock state); here we keep the fields the allocator needs:
 *     the pfn (physical frame number), a free-list link, and a state flag.
 *   - The page_t array itself is carved from managed RAM (self-hosting): we
 *     reserve the first N pages of the managed region to hold the array, then
 *     the remaining pages go on the free list. This mirrors how illumos places
 *     the page_t array in boot-reserved memory.
 *   - Free list: a singly-linked LIFO through page_t.p_next. page_alloc pops,
 *     page_free pushes. O(1) both. A global spinlock guards it (SMP-safe).
 *
 * The managed region starts at the current physical bump watermark (above the
 * kernel image + boot page tables that hat_riscv.c already consumed) and runs
 * to the DTB-reported RAM end. So page management and the boot allocator do not
 * overlap: boot pages (page tables) came from below the watermark; every page
 * page_alloc hands out is above it and tracked by a page_t.
 *
 * NOTE: LIFO free list + one global lock — fine for bring-up; illumos uses
 * per-cpu magazines + NUMA freelists. Upgrade when contention shows.
 */

#include "sbi.h"
#include "riscv_regs.h"

/* From hat_riscv.c: the physical bump watermark bounds (post kernel + PTs). */
extern unsigned long hat_phys_watermark(void);
extern int hat_phys_identity(unsigned long pa);
extern unsigned long hat_peek_highva(unsigned long pa, unsigned long off);

/* From startup.c helpers: decimal/hex console (shared, avoid duplicating). */
extern void kputdec(unsigned long v);
extern void kputhex(unsigned long v);

/*
 * page_t — physical frame descriptor. Minimal but real: pfn + free link +
 * state. p_next threads the free list (and, when allocated, is NULL).
 */
typedef struct page {
	unsigned long	p_pfn;		/* physical frame number (PA >> PAGESHIFT) */
	struct page	*p_next;	/* free-list link (NULL when allocated) */
	unsigned int	p_state;	/* PAGE_FREE | PAGE_ALLOC */
	unsigned int	p_ref;		/* COW share count (R-P9): 1 = sole owner */
} page_t;

#define	PAGE_FREE	0
#define	PAGE_ALLOC	1

static page_t		*pages;		/* the page_t array (base) */
static unsigned long	npages;		/* total managed pages */
static unsigned long	page_base_pfn;	/* pfn of pages[0]'s frame */
static page_t		*page_freelist;	/* free-list head */
static unsigned long	nfree;		/* current free count */

/* physmem exported for the startup banner (total managed pages). */
unsigned long physmem;

/* One global lock (amoswap test-and-set) guarding the free list. */
static volatile int page_lock;

static void
page_lock_enter(void)
{
	int old;
	do {
		__asm__ __volatile__("amoswap.w.aq %0, %2, (%1)"
		    : "=&r"(old) : "r"(&page_lock), "r"(1) : "memory");
	} while (old != 0);
}

static void
page_lock_exit(void)
{
	__asm__ __volatile__("amoswap.w.rl zero, zero, (%0)"
	    :: "r"(&page_lock) : "memory");
}

/*
 * page_init — build the page_t array + free list over [rambase, rambase +
 * ramsize) above the boot bump watermark: all of DRAM the DTB reports (rvsrv;
 * it used to stop at the end of the kernel's boot gigapage). The page_t array
 * is self-hosted at the front of the managed region. A page is freed only if
 * it is identity-mapped in every address space (hat_phys_identity: not in a
 * user slot) and not inside one of the `nrsv` firmware-reserved ranges
 * (rsvbase/rsvsize: the DTB, its reservation block, /reserved-memory).
 *
 * The free count is then checked two ways, independently: arithmetic (DTB
 * size minus every class of page not freed, each printed) and a walk of the
 * free list. Both must equal nfree exactly; the bound is 0 pages.
 */
void
page_init(unsigned long rambase, unsigned long ramsize,
    const unsigned long *rsvbase, const unsigned long *rsvsize, int nrsv)
{
	unsigned long ramend = rambase + ramsize;
	unsigned long mstart = hat_phys_watermark();	/* first free PA */
	unsigned long mpages, arraybytes, arraypages, i, run;
	unsigned long nhole = 0, nrsvd = 0, nwalk = 0, below, beyond, expect;
	page_t *pp;
	int r;

	/* Managed region: [mstart, ramend), page-aligned. */
	mstart = (mstart + PAGESIZE - 1) & ~(PAGESIZE - 1);
	ramend &= ~(PAGESIZE - 1);
	if (mstart >= ramend) {
		sbi_console_puts("[page] PANIC: no RAM above watermark\n");
		for (;;)
			__asm__ __volatile__("wfi");
	}

	mpages = (ramend - mstart) >> PAGESHIFT;

	/*
	 * The array is written through VA==PA, so it must fit in the identity
	 * run that starts at mstart (to the next hole). shortcut: on qemu virt
	 * that run is the kernel gigapage, ~1 GiB of page_t = ~170 GiB of RAM;
	 * past that the managed extent is cut, as printed. A sparse/per-range
	 * page_t (memseg) lifts it.
	 */
	for (run = mstart; run < ramend && hat_phys_identity(run);
	    run = (run | (GIGASIZE - 1)) + 1)
		;
	if (run > ramend)
		run = ramend;
	if (mpages * sizeof (page_t) > run - mstart) {
		mpages = (run - mstart) / (sizeof (page_t) + PAGESIZE) *
		    (PAGESIZE / sizeof (page_t));
		sbi_console_puts("[page] page_t array capped by the identity run"
		    " at the kernel: managing only ");
		kputdec(mpages);
		sbi_console_puts(" frames\n");
		ramend = mstart + (mpages << PAGESHIFT);
	}

	/* Reserve the front pages of the region for the page_t array itself. */
	arraybytes = mpages * sizeof (page_t);
	arraypages = (arraybytes + PAGESIZE - 1) >> PAGESHIFT;

	/* pages[] lives at mstart (identity-mapped VA==PA), covers all mpages. */
	pages = (page_t *)mstart;
	npages = mpages;
	page_base_pfn = mstart >> PAGESHIFT;

	/*
	 * Pass 1: every descriptor; a page after the array that is identity in
	 * every AS is a free candidate, any other is a hole (stays allocated).
	 */
	for (i = 0; i < npages; i++) {
		pages[i].p_pfn = page_base_pfn + i;
		pages[i].p_next = 0;
		pages[i].p_ref = 0;
		if (i >= arraypages &&
		    hat_phys_identity((page_base_pfn + i) << PAGESHIFT)) {
			pages[i].p_state = PAGE_FREE;
		} else {
			pages[i].p_state = PAGE_ALLOC;
			if (i >= arraypages)
				nhole++;
		}
	}

	/* Pass 2: firmware-reserved ranges inside the managed region. */
	for (r = 0; r < nrsv; r++) {
		unsigned long b = rsvbase[r] & ~(PAGESIZE - 1);
		unsigned long e = (rsvbase[r] + rsvsize[r] + PAGESIZE - 1) &
		    ~(PAGESIZE - 1);
		unsigned long pa;

		if (e <= mstart || b >= ramend)
			continue;
		if (b < mstart)
			b = mstart;
		if (e > ramend)
			e = ramend;
		for (pa = b; pa < e; pa += PAGESIZE) {
			pp = &pages[(pa >> PAGESHIFT) - page_base_pfn];
			if (pp->p_state == PAGE_FREE) {
				pp->p_state = PAGE_ALLOC;
				nrsvd++;
			}
		}
	}

	/* Pass 3: thread the free list (LIFO: the highest page is popped first). */
	page_freelist = 0;
	nfree = 0;
	for (i = arraypages; i < npages; i++) {
		if (pages[i].p_state != PAGE_FREE)
			continue;
		pages[i].p_next = page_freelist;
		page_freelist = &pages[i];
		nfree++;
	}
	for (pp = page_freelist; pp != 0; pp = pp->p_next)
		nwalk++;

	physmem = npages;

	sbi_console_puts("[page] page_t array at PA ");
	kputhex(mstart);
	sbi_console_puts(" (");
	kputdec(arraypages);
	sbi_console_puts(" pages reserved), managing ");
	kputdec(npages);
	sbi_console_puts(" frames [");
	kputhex(mstart);
	sbi_console_puts("..");
	kputhex(ramend);
	sbi_console_puts(")\n");

	below = (mstart - rambase) >> PAGESHIFT;
	beyond = ((rambase + ramsize) & ~(PAGESIZE - 1)) - ramend;
	beyond >>= PAGESHIFT;
	expect = (ramsize >> PAGESHIFT) - below - arraypages - nhole - nrsvd -
	    beyond;
	sbi_console_puts("[page] DTB RAM ");
	kputdec(ramsize >> PAGESHIFT);
	sbi_console_puts(" pages = free ");
	kputdec(expect);
	sbi_console_puts(" + firmware/kernel/boot-PT below the watermark ");
	kputdec(below);
	sbi_console_puts(" + page_t ");
	kputdec(arraypages);
	sbi_console_puts(" + user-slot hole ");
	kputdec(nhole);
	sbi_console_puts(" + fw-reserved ");
	kputdec(nrsvd);
	sbi_console_puts(" + unmanaged ");
	kputdec(beyond);
	sbi_console_puts("\n");
	sbi_console_puts("[page] free list: ");
	kputdec(nfree);
	sbi_console_puts(" pages available (list walk ");
	kputdec(nwalk);
	sbi_console_puts(", expected ");
	kputdec(expect);
	sbi_console_puts(nfree == expect && nwalk == nfree ?
	    "; EXACT, bound 0 pages)\n" : "; MISMATCH)\n");
}

/*
 * page_highram_selftest — rvsrv: prove RAM above 4 GiB is real, distinct
 * memory. One free page per GiB above 4 GiB (at an offset that varies by GiB),
 * 512 words each of a PA-unique pattern, written through the identity map;
 * then every word read back through the identity map, and two words per page
 * through a fresh KERNELBASE mapping of that PA (an independent page-table
 * walk). Runs single-hart, before anything allocates (the secondaries are
 * parked on smp_dispatch_ready), so borrowing free pages is safe; page_alloc
 * zeroes them on hand-out. Negative control: -DRVSRV_SABOTAGE_ALIAS maps every
 * high GiB onto one PA, which this must report as FAIL.
 */
#define	HIGHRAM_SIG	0x4849474852414d00UL	/* "HIGHRAM\0" */

void
page_highram_selftest(void)
{
	unsigned long lim = (page_base_pfn + npages) << PAGESHIFT;
	unsigned long g, pa, i, tested = 0, bad = 0, first = 0, last = 0;
	int pass;

	for (pass = 0; pass < 2; pass++) {
		for (g = 4; (g << GIGASHIFT) < lim; g++) {
			unsigned long pfn, *w;

			pa = (g << GIGASHIFT) + ((g * 37) % 0x3fff + 1) * PAGESIZE;
			pfn = pa >> PAGESHIFT;
			if (pfn < page_base_pfn || pfn >= page_base_pfn + npages ||
			    pages[pfn - page_base_pfn].p_state != PAGE_FREE)
				continue;
			w = (unsigned long *)pa;
			if (pass == 0) {
				for (i = 0; i < PAGESIZE / sizeof (long); i++)
					w[i] = pa ^ (i * 0x9e3779b97f4a7c15UL) ^
					    HIGHRAM_SIG;
				tested++;
				if (first == 0)
					first = pa;
				last = pa;
				continue;
			}
			for (i = 0; i < PAGESIZE / sizeof (long); i++)
				if (w[i] != (pa ^ (i * 0x9e3779b97f4a7c15UL) ^
				    HIGHRAM_SIG))
					break;
			if (i != PAGESIZE / sizeof (long) ||
			    hat_peek_highva(pa, 0) != (pa ^ HIGHRAM_SIG) ||
			    hat_peek_highva(pa, PAGESIZE - 8) != (pa ^
			    (511 * 0x9e3779b97f4a7c15UL) ^ HIGHRAM_SIG)) {
				if (bad == 0) {
					sbi_console_puts("[page] high-RAM: "
					    "readback MISMATCH at PA ");
					kputhex(pa);
					sbi_console_puts("\n");
				}
				bad++;
			}
		}
	}
	if (tested == 0) {
		sbi_console_puts("[page] high-RAM self-test: skipped "
		    "(no managed RAM above 4 GiB)\n");
		return;
	}
	sbi_console_puts("[page] high-RAM self-test: ");
	kputdec(tested);
	sbi_console_puts(" pages above 4 GiB (one per GiB, PA ");
	kputhex(first);
	sbi_console_puts(" .. ");
	kputhex(last);
	sbi_console_puts("), 4 KiB each written via identity, read back via "
	    "identity + KERNELBASE kmap: ");
	if (bad == 0) {
		sbi_console_puts("OK\n");
	} else {
		sbi_console_puts("FAIL (");
		kputdec(bad);
		sbi_console_puts(" bad)\n");
	}
}

/*
 * page_alloc — pop one free page. Returns its physical address (== identity VA),
 * zeroed, or 0 if the free list is empty.
 */
unsigned long
page_alloc(void)
{
	page_t *pp;
	unsigned long pa, i;
	unsigned long *z;

	page_lock_enter();
	pp = page_freelist;
	if (pp == 0) {
		page_lock_exit();
		return (0);
	}
	page_freelist = pp->p_next;
	pp->p_next = 0;
	pp->p_state = PAGE_ALLOC;
	pp->p_ref = 1;			/* sole owner (R-P9 COW) */
	nfree--;
	page_lock_exit();

	pa = pp->p_pfn << PAGESHIFT;

	/* Zero the page (identity map VA==PA). */
	z = (unsigned long *)pa;
	for (i = 0; i < PAGESIZE / sizeof (unsigned long); i++)
		z[i] = 0;
	return (pa);
}

/*
 * page_free — release a reference to a page (by physical address). With COW
 * sharing (R-P9) a page may be mapped in several address spaces; the page is
 * only returned to the free list when the LAST reference drops. Validates the
 * pfn is in the managed range and not already free.
 */
void
page_free(unsigned long pa)
{
	unsigned long pfn = pa >> PAGESHIFT;
	unsigned long idx;
	page_t *pp;

	if (pfn < page_base_pfn || pfn >= page_base_pfn + npages) {
		sbi_console_puts("[page] page_free: pfn out of range\n");
		return;
	}
	idx = pfn - page_base_pfn;
	pp = &pages[idx];

	page_lock_enter();
	if (pp->p_state == PAGE_FREE) {
		page_lock_exit();
		sbi_console_puts("[page] page_free: double free\n");
		return;
	}
	if (pp->p_ref > 1) {
		pp->p_ref--;		/* still shared: keep the frame mapped */
		page_lock_exit();
		return;
	}
	pp->p_ref = 0;
	pp->p_state = PAGE_FREE;
	pp->p_next = page_freelist;
	page_freelist = pp;
	nfree++;
	page_lock_exit();
}

/*
 * page_incref / page_decref / page_refcount — COW share-count API (R-P9). fork
 * marks a shared leaf read-only in both AS and page_increfs it; the store-fault
 * COW handler page_decrefs (dropping its share) after copying to a private
 * page, or, if it was the sole owner, just re-maps it writable in place.
 */
void
page_incref(unsigned long pa)
{
	unsigned long pfn = pa >> PAGESHIFT;
	unsigned long idx;

	if (pfn < page_base_pfn || pfn >= page_base_pfn + npages)
		return;
	idx = pfn - page_base_pfn;
	page_lock_enter();
	if (pages[idx].p_state == PAGE_ALLOC)
		pages[idx].p_ref++;
	page_lock_exit();
}

unsigned int
page_refcount(unsigned long pa)
{
	unsigned long pfn = pa >> PAGESHIFT;
	unsigned long idx;
	unsigned int r;

	if (pfn < page_base_pfn || pfn >= page_base_pfn + npages)
		return (0);
	idx = pfn - page_base_pfn;
	page_lock_enter();
	r = pages[idx].p_ref;
	page_lock_exit();
	return (r);
}

unsigned long
page_freecount(void)
{
	return (nfree);
}

/*
 * page_selftest — R-P5 gate 1 proof. Alloc a handful of pages, verify they are
 * distinct + zeroed + writable, free them, and confirm the free count returns.
 */
void
page_selftest(void)
{
	unsigned long p[4];
	unsigned long before = nfree;
	int i, ok = 1;

	for (i = 0; i < 4; i++) {
		p[i] = page_alloc();
		if (p[i] == 0) {
			ok = 0;
			break;
		}
		/* Zeroed check + write signature. */
		if (*(volatile unsigned long *)p[i] != 0)
			ok = 0;
		*(volatile unsigned long *)p[i] = 0xA5A5A5A5A5A5A5A5UL;
	}
	/* Distinctness check. */
	if (ok && (p[0] == p[1] || p[1] == p[2] || p[2] == p[3]))
		ok = 0;

	for (i = 0; i < 4; i++)
		if (p[i] != 0)
			page_free(p[i]);

	sbi_console_puts("[page] page_alloc/free self-test ");
	if (ok && nfree == before) {
		sbi_console_puts("OK (4 pages alloc'd, zeroed, written, freed; "
		    "freecount restored)\n");
	} else {
		sbi_console_puts("FAILED\n");
	}
}
