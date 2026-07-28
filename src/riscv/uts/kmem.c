/*
 * kmem.c — illumos riscv64 kernel VA allocator + kmem slab (R-P5).
 *
 * The seed of the illumos VMEM + kmem_cache/kmem_alloc layer
 * (uts/common/os/vmem.c, kmem.c). Two pieces:
 *
 *   1. A kernel VIRTUAL-ADDRESS allocator (heap_vmem, a minimal vmem arena)
 *      over a reserved sub-range of the KERNELBASE high canonical VA space.
 *      It hands out page-aligned VA runs; each page it hands out is backed by
 *      a fresh physical frame from page_alloc() and mapped R/W into the shared
 *      kernel page table via hat_kmap_page(). This is the analog of the illumos
 *      `heap_arena` fed by page-backed segkmem.
 *
 *   2. kmem_alloc()/kmem_free(): power-of-two size-class allocation. Each size
 *      class keeps a free list of objects; when empty, it grabs a fresh page
 *      (a "slab") of VA from heap_vmem and carves it into objects. Frees push
 *      the object back on its class free list. This is a deliberately minimal
 *      slab (one page per slab, embedded free list, no magazines/depot) — the
 *      real kmem_cache with per-cpu magazines is a later phase.
 *
 * KERNELBASE region layout (R-P5):
 *   KERNELBASE + 0                         : the R-P4 high-VA proof page (1 pg)
 *   KERNELBASE + HEAP_VA_OFFSET .. +SIZE    : the kmem heap VA arena (this file)
 * The proof page and the heap do not overlap.
 *
 * ponytail: power-of-two classes + single-page slabs + one global lock. The
 * real kmem_cache (arbitrary object sizes, per-cpu magazines, slab coloring)
 * is R-P6+. Upgrade when allocation pressure or fragmentation shows.
 */

#include "sbi.h"
#include "riscv_regs.h"

/* From hat_riscv.c. */
extern unsigned long page_alloc(void);
extern void hat_kmap_page(unsigned long va, unsigned long pa, unsigned long perm);

/* Shared console helpers (startup.c). */
extern void kputdec(unsigned long v);
extern void kputhex(unsigned long v);

/*
 * The kmem heap VA arena. Start it 16 MiB above KERNELBASE to stay clear of the
 * R-P4 proof page at KERNELBASE+0, and give it a generous VA window (the VA is
 * free; only touched pages consume physical frames + PTEs).
 */
#define	HEAP_VA_OFFSET	(16UL * 1024 * 1024)		/* +16 MiB */
#define	HEAP_VA_BASE	(KERNELBASE + HEAP_VA_OFFSET)
#define	HEAP_VA_SIZE	(64UL * 1024 * 1024)		/* 64 MiB VA window */

static unsigned long heap_va_next;	/* next unallocated VA (bump) */
static unsigned long heap_va_end;	/* one past the window */
static unsigned long heap_pages_used;	/* physical pages backing the heap */

/* One global lock guarding both the VA arena and the size-class free lists. */
static volatile int kmem_lock;

static void
kmem_lock_enter(void)
{
	int old;
	do {
		__asm__ __volatile__("amoswap.w.aq %0, %2, (%1)"
		    : "=&r"(old) : "r"(&kmem_lock), "r"(1) : "memory");
	} while (old != 0);
}

static void
kmem_lock_exit(void)
{
	__asm__ __volatile__("amoswap.w.rl zero, zero, (%0)"
	    :: "r"(&kmem_lock) : "memory");
}

/*
 * vmem_alloc_page — hand out one page of kernel VA, backed by a fresh physical
 * frame mapped R/W. Returns the VA (page-aligned) or 0 on exhaustion. Caller
 * holds kmem_lock.
 */
static unsigned long
vmem_alloc_page(void)
{
	unsigned long va, pa;

	if (heap_va_next + PAGESIZE > heap_va_end)
		return (0);

	pa = page_alloc();
	if (pa == 0)
		return (0);

	va = heap_va_next;
	heap_va_next += PAGESIZE;
	heap_pages_used++;

	hat_kmap_page(va, pa, PTE_R | PTE_W);
	return (va);
}

/*
 * Size classes: powers of two from 16 to 2048 bytes. Larger requests get whole
 * page-multiple VA runs (page-granular, tracked by the slab-free path below).
 */
#define	KMEM_MIN_SHIFT	4			/* 16 bytes */
#define	KMEM_MAX_SHIFT	11			/* 2048 bytes */
#define	KMEM_NCLASS	(KMEM_MAX_SHIFT - KMEM_MIN_SHIFT + 1)

/* Embedded free-list node: an unused object's first word links to the next. */
struct kmem_bufctl {
	struct kmem_bufctl *bc_next;
};

static struct kmem_bufctl *kmem_freelist[KMEM_NCLASS];

/* Round size up to a class index (0..KMEM_NCLASS-1), or -1 if too big. */
static int
size_to_class(unsigned long size)
{
	int shift = KMEM_MIN_SHIFT;

	while ((1UL << shift) < size)
		shift++;
	if (shift < KMEM_MIN_SHIFT)
		shift = KMEM_MIN_SHIFT;
	if (shift > KMEM_MAX_SHIFT)
		return (-1);
	return (shift - KMEM_MIN_SHIFT);
}

/*
 * kmem_slab_grow — carve a fresh page into objects of the given class and push
 * them all onto the class free list. Caller holds kmem_lock.
 */
static int
kmem_slab_grow(int cls)
{
	unsigned long objsize = 1UL << (cls + KMEM_MIN_SHIFT);
	unsigned long page = vmem_alloc_page();
	unsigned long off;

	if (page == 0)
		return (0);

	for (off = 0; off + objsize <= PAGESIZE; off += objsize) {
		struct kmem_bufctl *bc =
		    (struct kmem_bufctl *)(page + off);
		bc->bc_next = kmem_freelist[cls];
		kmem_freelist[cls] = bc;
	}
	return (1);
}

/*
 * kmem_init — set up the heap VA arena. Called from startup() after page_init.
 */
void
kmem_init(void)
{
	int i;

	heap_va_next = HEAP_VA_BASE;
	heap_va_end = HEAP_VA_BASE + HEAP_VA_SIZE;
	heap_pages_used = 0;
	for (i = 0; i < KMEM_NCLASS; i++)
		kmem_freelist[i] = 0;

	sbi_console_puts("[kmem] heap VA arena ");
	kputhex(HEAP_VA_BASE);
	sbi_console_puts(" .. ");
	kputhex(heap_va_end);
	sbi_console_puts(" (");
	kputdec(HEAP_VA_SIZE >> 20);
	sbi_console_puts(" MiB VA, page-backed on demand); ");
	kputdec(KMEM_NCLASS);
	sbi_console_puts(" size classes (16..2048 B)\n");
}

/*
 * kmem_alloc — allocate an object of at least `size` bytes. Requests up to
 * 2048 B come from a size-class free list (page-slab backed). Larger requests
 * get a page-multiple VA run directly (rounded up).
 */
void *
kmem_alloc(unsigned long size)
{
	int cls;
	struct kmem_bufctl *bc;

	if (size == 0)
		return (0);

	cls = size_to_class(size);
	kmem_lock_enter();

	if (cls < 0) {
		/* Large: page-multiple VA run. */
		unsigned long need = (size + PAGESIZE - 1) & ~(PAGESIZE - 1);
		unsigned long first = 0, prev = 0, va;
		unsigned long got = 0;

		while (got < need) {
			va = vmem_alloc_page();
			if (va == 0) {
				kmem_lock_exit();
				return (0);
			}
			if (first == 0)
				first = va;
			(void) prev;
			prev = va;
			got += PAGESIZE;
		}
		kmem_lock_exit();
		return ((void *)first);
	}

	if (kmem_freelist[cls] == 0) {
		if (!kmem_slab_grow(cls)) {
			kmem_lock_exit();
			return (0);
		}
	}
	bc = kmem_freelist[cls];
	kmem_freelist[cls] = bc->bc_next;
	kmem_lock_exit();
	return ((void *)bc);
}

/*
 * kmem_free — return an object to its size-class free list. `size` must match
 * the alloc (illumos kmem_free takes the size too). Large (>2048) allocations
 * are page runs; R-P5 leaks their VA back (no vmem free list yet) — documented.
 */
void
kmem_free(void *buf, unsigned long size)
{
	int cls;
	struct kmem_bufctl *bc;

	if (buf == 0 || size == 0)
		return;

	cls = size_to_class(size);
	if (cls < 0) {
		/* ponytail: large page-run frees leak VA in R-P5 (no vmem free
		 * list yet). Add a vmem span free list when large allocs churn. */
		return;
	}

	bc = (struct kmem_bufctl *)buf;
	kmem_lock_enter();
	bc->bc_next = kmem_freelist[cls];
	kmem_freelist[cls] = bc;
	kmem_lock_exit();
}

unsigned long
kmem_heap_pages(void)
{
	return (heap_pages_used);
}

/*
 * kmem_selftest — R-P5 gate 2 proof. Alloc a few sizes, write + read them back
 * (proving the VA is mapped + distinct), free them, and re-alloc to confirm the
 * freed object is recycled from the class free list.
 */
void
kmem_selftest(void)
{
	unsigned long sizes[4] = { 16, 64, 256, 1500 };
	void *p[4];
	int i, ok = 1;

	for (i = 0; i < 4; i++) {
		p[i] = kmem_alloc(sizes[i]);
		if (p[i] == 0) {
			ok = 0;
			continue;
		}
		/* Write a pattern across the object, read it back. */
		{
			volatile unsigned char *b = p[i];
			unsigned long j;
			for (j = 0; j < sizes[i]; j++)
				b[j] = (unsigned char)(0x30 + (int)(j & 0x3f));
			for (j = 0; j < sizes[i]; j++)
				if (b[j] != (unsigned char)(0x30 + (int)(j & 0x3f)))
					ok = 0;
		}
	}

	/* Free the 64 B object, re-alloc same class, expect the same address. */
	{
		void *reuse;
		kmem_free(p[1], 64);
		reuse = kmem_alloc(64);
		if (reuse != p[1])
			ok = 0;
		kmem_free(reuse, 64);
	}

	kmem_free(p[0], 16);
	kmem_free(p[2], 256);
	kmem_free(p[3], 1500);

	sbi_console_puts("[kmem] alloc/free self-test ");
	if (ok) {
		sbi_console_puts("OK (16/64/256/1500 B alloc'd, "
		    "written+verified, freed; 64 B recycled)\n");
	} else {
		sbi_console_puts("FAILED\n");
	}
}
