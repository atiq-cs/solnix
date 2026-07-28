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
 * ponytail: LIFO free list + one global lock — fine for bring-up; illumos uses
 * per-cpu magazines + NUMA freelists. Upgrade when contention shows.
 */

#include "sbi.h"
#include "riscv_regs.h"

/* From hat_riscv.c: the physical bump watermark bounds (post kernel + PTs). */
extern unsigned long hat_phys_watermark(void);

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
 * page_init — build the page_t array + free list over [rambase,ramend) that
 * lies above the boot bump watermark. Called from startup() with the DTB-
 * reported RAM extent. The page_t array is self-hosted at the front of the
 * managed region; the rest is freed onto the list.
 */
void
page_init(unsigned long rambase, unsigned long ramsize)
{
	unsigned long ramend = rambase + ramsize;
	unsigned long mstart = hat_phys_watermark();	/* first free PA */
	unsigned long mpages, arraybytes, arraypages, i;

	/* Managed region: [mstart, ramend), page-aligned. */
	mstart = (mstart + PAGESIZE - 1) & ~(PAGESIZE - 1);
	ramend &= ~(PAGESIZE - 1);
	if (mstart >= ramend) {
		sbi_console_puts("[page] PANIC: no RAM above watermark\n");
		for (;;)
			__asm__ __volatile__("wfi");
	}

	mpages = (ramend - mstart) >> PAGESHIFT;

	/* Reserve the front pages of the region for the page_t array itself. */
	arraybytes = mpages * sizeof (page_t);
	arraypages = (arraybytes + PAGESIZE - 1) >> PAGESHIFT;

	/* pages[] lives at mstart (identity-mapped VA==PA), covers all mpages. */
	pages = (page_t *)mstart;
	npages = mpages;
	page_base_pfn = mstart >> PAGESHIFT;

	/* Initialize every descriptor; array pages start allocated (reserved). */
	for (i = 0; i < npages; i++) {
		pages[i].p_pfn = page_base_pfn + i;
		pages[i].p_next = 0;
		pages[i].p_state = PAGE_ALLOC;
	}

	/* Free every page after the reserved array region onto the list. */
	page_freelist = 0;
	nfree = 0;
	for (i = arraypages; i < npages; i++) {
		pages[i].p_state = PAGE_FREE;
		pages[i].p_next = page_freelist;
		page_freelist = &pages[i];
		nfree++;
	}

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
	sbi_console_puts("[page] free list: ");
	kputdec(nfree);
	sbi_console_puts(" pages available\n");
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
 * page_free — return a page (by physical address) to the free list. Validates
 * the pfn is in the managed range and not double-freed.
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
	pp->p_state = PAGE_FREE;
	pp->p_next = page_freelist;
	page_freelist = pp;
	nfree++;
	page_lock_exit();
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
