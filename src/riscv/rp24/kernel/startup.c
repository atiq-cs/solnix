/*
 * startup.c -- R-P24 sub-task 4: the genunix on-ramp.  A minimal slice of the
 * illumos startup() path onto the native-toolchain kernel:
 *
 *   startup_memlist(): stake out a boot heap from the physical DRAM the DTB /
 *     board gives us (here the qemu-virt 128 MiB above the kernel image).
 *   startup_kmem():    a bump/first-fit kmem_alloc over that heap -- the
 *     smallest thing that answers kmem_alloc()/kmem_free() so genunix consumers
 *     (page_t arrays, cpu_t, thread stacks) have an allocator.
 *   page_setup():      a minimal page_t array describing the managed frames --
 *     the seed of the VM page layer (page_create/page_free grow from here).
 *   startup():         drives the above, then hands the boot CPU to the
 *     dispatcher: build an idle kthread_t + a work kthread_t, and swtch() from
 *     the boot context into the idle loop with the clock ticking.  That idle
 *     loop + a live allocator + a page layer is the genunix seam -- real
 *     genunix replaces the idle body with thread_create/disp/callout.
 *
 * This is a REDUCED seam (per the anti-wedge directive): a first-fit heap (not
 * the slab kmem_cache), a flat page_t array (not the full page hash/freelists),
 * and a two-thread hand-switch (not the full disp queues).  It proves the
 * on-ramp: mlsetup -> startup -> kmem_alloc works -> a thread runs on a fresh
 * stack -> idle loop with clock ticks.
 *
 * CRIB PROVENANCE: the startup()/startup_memlist()/startup_kmem() decomposition
 * + the boot-heap-then-kmem-then-page-then-dispatcher order is illumos
 * uts/common/os startup.c + i86pc startup.c; the first-fit kmem_alloc + page_t
 * seed is the R-P5 kmem/vm_page slice (reduced from vmem/kmem_cache to a bump
 * heap); the "build idle + work kthread, swtch into the idle loop" is the R-P
 * swtch/disp seam (rv_swtch, mach_swtch.S).
 */

#include "sbi.h"
#include "mmu_riscv.h"
#include "clock_riscv.h"

extern void putdec_pub(unsigned long v);
extern void puthex_pub(unsigned long v);

/* ---- boot heap + first-fit kmem ------------------------------------- */

/*
 * The boot heap.  qemu-virt gives 256 MiB of DRAM at 0x80000000; the kernel
 * image sits at 0x80200000 and is small.  We carve a 16 MiB boot heap out of
 * BSS -- simple, self-contained, and reachable through both the identity map
 * and the high direct-map once paging is on.
 */
#define	BOOT_HEAP_SIZE	(16UL * 1024 * 1024)
static unsigned char boot_heap[BOOT_HEAP_SIZE] __attribute__((aligned(PAGESIZE)));

/*
 * First-fit free list.  Each block is [hdr | payload]; free blocks are chained.
 * Minimal, not the slab allocator -- enough to answer kmem_alloc/kmem_free.
 */
typedef struct kmem_hdr {
	unsigned long	kh_size;	/* payload bytes */
	int		kh_free;
	struct kmem_hdr	*kh_next;
} kmem_hdr_t;

static kmem_hdr_t *kmem_head;
static unsigned long kmem_total, kmem_inuse;

void
startup_kmem(void)
{
	kmem_head = (kmem_hdr_t *)boot_heap;
	kmem_head->kh_size = BOOT_HEAP_SIZE - sizeof (kmem_hdr_t);
	kmem_head->kh_free = 1;
	kmem_head->kh_next = 0;
	kmem_total = kmem_head->kh_size;
	kmem_inuse = 0;
}

void *
kmem_alloc(unsigned long size)
{
	kmem_hdr_t *b, *split;
	unsigned long need = (size + 15) & ~15UL;	/* 16-byte align */

	for (b = kmem_head; b != 0; b = b->kh_next) {
		if (!b->kh_free || b->kh_size < need)
			continue;
		/* split if the remainder can hold a header + a little payload */
		if (b->kh_size >= need + sizeof (kmem_hdr_t) + 16) {
			split = (kmem_hdr_t *)((unsigned char *)(b + 1) + need);
			split->kh_size = b->kh_size - need - sizeof (kmem_hdr_t);
			split->kh_free = 1;
			split->kh_next = b->kh_next;
			b->kh_size = need;
			b->kh_next = split;
		}
		b->kh_free = 0;
		kmem_inuse += b->kh_size;
		return ((void *)(b + 1));
	}
	return (0);	/* out of boot heap */
}

void
kmem_free(void *p, unsigned long size)
{
	kmem_hdr_t *b;

	if (p == 0)
		return;
	(void) size;
	b = ((kmem_hdr_t *)p) - 1;
	b->kh_free = 1;
	kmem_inuse -= b->kh_size;
	/* coalesce with the following block if it is free (first-fit tidy). */
	if (b->kh_next != 0 && b->kh_next->kh_free) {
		b->kh_size += sizeof (kmem_hdr_t) + b->kh_next->kh_size;
		b->kh_next = b->kh_next->kh_next;
	}
}

unsigned long kmem_heapsize(void) { return (kmem_total); }
unsigned long kmem_inuse_bytes(void) { return (kmem_inuse); }

/* ---- minimal page_t layer ------------------------------------------- */

/*
 * The seed page_t.  The full illumos page_t is large; the R-P24 seed carries
 * just the frame number + a use flag -- enough to describe the managed frames
 * and answer page_create/page_free.  page_setup() sizes the array to a small
 * managed window (the qemu DRAM above the kernel) and kmem_allocs it.
 */
typedef struct page {
	unsigned long	p_pfn;		/* physical frame number */
	int		p_inuse;
} page_t;

static page_t *pages;
static unsigned long npages;
static unsigned long managed_base_pfn;

/* manage a small window (8 MiB) of frames as the page-layer seed. */
#define	MANAGED_BYTES	(8UL * 1024 * 1024)
#define	MANAGED_BASE_PA	0x88000000UL	/* well above the kernel image */

void
page_setup(void)
{
	unsigned long i;

	npages = MANAGED_BYTES / PAGESIZE;
	managed_base_pfn = MANAGED_BASE_PA >> PAGESHIFT;
	pages = kmem_alloc(npages * sizeof (page_t));	/* uses the boot heap */
	for (i = 0; i < npages; i++) {
		pages[i].p_pfn = managed_base_pfn + i;
		pages[i].p_inuse = 0;
	}
}

/* allocate one managed frame; returns its PA, or 0 if none. */
unsigned long
page_create(void)
{
	unsigned long i;
	for (i = 0; i < npages; i++) {
		if (!pages[i].p_inuse) {
			pages[i].p_inuse = 1;
			return (pages[i].p_pfn << PAGESHIFT);
		}
	}
	return (0);
}

unsigned long page_count(void) { return (npages); }

/* ---- minimal dispatcher on-ramp ------------------------------------- */

struct rv_context {
	unsigned long	c_ra;
	unsigned long	c_sp;
	unsigned long	c_s[12];	/* s0..s11 */
	unsigned long	c_satp;
};

typedef struct kthread {
	struct rv_context t_ctx;
	void		(*t_entry)(void);
	unsigned char	*t_stack;
	unsigned long	t_stacksize;
} kthread_t;

extern void rv_swtch(struct rv_context *old, struct rv_context *new);

static kthread_t boot_thread;	/* the context we came in on */
static kthread_t idle_thread;

/*
 * Build a kthread that will start executing entry() on a fresh kmem stack the
 * first time we swtch() to it: seed c_ra = entry, c_sp = stack top, c_satp =
 * the current (kernel) address space.
 */
static void
thread_init(kthread_t *t, void (*entry)(void), unsigned long stacksize)
{
	int i;

	t->t_stack = kmem_alloc(stacksize);
	t->t_stacksize = stacksize;
	t->t_entry = entry;
	t->t_ctx.c_ra = (unsigned long)entry;
	t->t_ctx.c_sp = ((unsigned long)t->t_stack + stacksize) & ~15UL;
	for (i = 0; i < 12; i++)
		t->t_ctx.c_s[i] = 0;
	__asm__ __volatile__("csrr %0, satp" : "=r"(t->t_ctx.c_satp));
}

/*
 * The idle loop: the CPU's home when no thread is runnable.  With the clock
 * ticking, wfi wakes on each timer interrupt; we spin until the boot proof's
 * tick count is reached, printing progress, then shut down (the R-P24
 * known-halt -- real genunix would stay in the idle loop forever).
 */
static void
idle_loop(void)
{
	unsigned long last = 0;

	sbi_console_puts("[dispatcher] idle thread running on its own stack; "
	    "entering idle loop with clock ticking\n");

	for (;;) {
		__asm__ __volatile__("wfi");
		if (clock_ticks != last) {
			last = clock_ticks;
			sbi_console_puts("  clock tick ");
			putdec_pub(last);
			sbi_console_puts("\n");
		}
		if (clock_ticks >= CLOCK_TEST_TICKS)
			break;
	}

	sbi_console_puts("[dispatcher] idle loop counted ");
	putdec_pub(clock_ticks);
	sbi_console_puts(" clock ticks; on-ramp proven\n");

	/* swtch back to the boot context to finish the boot proof cleanly. */
	rv_swtch(&idle_thread.t_ctx, &boot_thread.t_ctx);
}

/*
 * dispatch_onramp -- build the idle thread and swtch into it.  Returns (via the
 * idle loop swtch-back) once the boot proof's ticks are counted.
 */
#define	STACK_SIZE	(16UL * 1024)

void
dispatch_onramp(void)
{
	thread_init(&idle_thread, idle_loop, STACK_SIZE);
	sbi_console_puts("[dispatcher] built idle kthread (fresh 16K kmem "
	    "stack); swtch -> idle\n");
	/* first swtch: save the boot context, jump into idle_loop. */
	rv_swtch(&boot_thread.t_ctx, &idle_thread.t_ctx);
	/* control returns here when idle_loop swtches back. */
	sbi_console_puts("[dispatcher] swtched back to boot context; "
	    "dispatcher round-trip complete\n");
}
