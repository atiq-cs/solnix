/*
 * startup.c — illumos riscv64 machine-independent startup()-analog (R-P5).
 *
 * The bridge from the MD kernel (locore/mlsetup) to the MI kernel (genunix).
 * This is the riscv64 analog of uts/common/os/startup.c: after mlsetup has
 * done the MD bring-up (trap/paging/SMP/clock/PLIC in R-P4), main() calls
 * startup() which brings the MI subsystems online in the illumos order:
 *
 *   startup()
 *     startup_memlist()  -> page_init()   real page_t/freelist over DTB RAM
 *     startup_vm()       -> kmem_init()   kernel VA arena + kmem slab
 *     startup_cyclic()   -> (clock already periodic) + callout wheel proof
 *     startup_dispatch() -> dispatch_init_cpu(0): boot cpu becomes cpu0's idle
 *                           thread; the dispatcher + swtch come online
 *
 * Each stage runs its R-P5 gate self-test so the console proves the subsystem
 * works. This file also hosts the shared decimal/hex console helpers used by
 * the R-P5 subsystems (kputdec/kputhex), so each .c does not duplicate them.
 *
 * ponytail: startup here is a linear "bring up + prove" sequence, not the full
 * illumos multi-phase startup (kvseg/segkmem/mod_setup/vfs). It is the honest
 * MD->MI seam for R-P5; R-P6 grows it toward mounting root + module load.
 */

#include "sbi.h"
#include "riscv_regs.h"

/* R-P5 subsystem entry points. */
extern void page_init(unsigned long rambase, unsigned long ramsize);
extern void page_selftest(void);
extern unsigned long page_freecount(void);
extern unsigned long physmem;			/* total managed pages */
extern void hat_page_layer_online(void);	/* hat.c: route PT allocs to page_alloc */

extern void kmem_init(void);
extern void kmem_selftest(void);
extern unsigned long kmem_heap_pages(void);

extern void callout_selftest(void);

extern void dispatch_init_cpu(int cpu);
extern void thread_ab_selftest(void);

/* FDT /memory parse (fdt.c). */
extern int fdt_get_memory(unsigned long dtb, unsigned long *base,
    unsigned long *size);

/* gethrtime for the completion banner (timer.c). */
extern unsigned long gethrtime(void);

/*
 * Shared console number formatters. Kept here (one definition) and extern'd by
 * vm_page.c / kmem.c / proc.c so those files don't each re-roll putdec/puthex.
 */
void
kputdec(unsigned long v)
{
	char buf[24];
	int n = 0;

	if (v == 0) {
		sbi_console_putchar('0');
		return;
	}
	while (v != 0 && n < (int)sizeof (buf)) {
		buf[n++] = (char)('0' + (v % 10));
		v /= 10;
	}
	while (n-- > 0)
		sbi_console_putchar(buf[n]);
}

void
kputhex(unsigned long v)
{
	static const char hex[] = "0123456789abcdef";
	int i;

	sbi_console_puts("0x");
	for (i = 60; i >= 0; i -= 4)
		sbi_console_putchar(hex[(v >> i) & 0xf]);
}

/* Recorded for the startup banner. */
static unsigned long startup_rambase;
static unsigned long startup_ramsize;
int startup_ncpu;			/* set by main() from the SMP count */

/* Fallbacks if the DTB parse fails (qemu virt default). */
#define	PHYS_RAM_BASE_FALLBACK	0x80000000UL
#define	PHYS_RAM_SIZE_FALLBACK	0x08000000UL	/* 128 MiB */

/*
 * startup_memlist — the physical memory stage. Parse the DTB /memory node for
 * the real RAM extent (R-P4 hardcoded 128 MiB), build the page_t array +
 * freelist over the RAM above the boot watermark, and self-test alloc/free.
 * After this the hat routes new page-table allocations through page_alloc.
 */
static void
startup_memlist(unsigned long dtb)
{
	unsigned long base = PHYS_RAM_BASE_FALLBACK;
	unsigned long size = PHYS_RAM_SIZE_FALLBACK;

	sbi_console_puts("\n[startup] startup_memlist: physical memory\n");

	if (fdt_get_memory(dtb, &base, &size)) {
		sbi_console_puts("[startup] FDT /memory: base ");
		kputhex(base);
		sbi_console_puts(" size ");
		kputhex(size);
		sbi_console_puts(" (");
		kputdec(size >> 20);
		sbi_console_puts(" MiB) [from DTB]\n");
	} else {
		sbi_console_puts("[startup] FDT /memory parse FAILED, using "
		    "fallback 128 MiB\n");
	}
	startup_rambase = base;
	startup_ramsize = size;

	page_init(base, size);
	sbi_console_puts("[startup] physmem: ");
	kputdec(physmem);
	sbi_console_puts(" pages (");
	kputdec((physmem << PAGESHIFT) >> 20);
	sbi_console_puts(" MB) managed\n");

	/* From now on the hat draws page-table pages from the page allocator. */
	hat_page_layer_online();

	page_selftest();
}

/*
 * startup_vm — the kernel virtual-memory stage: bring up the kmem heap VA arena
 * over the KERNELBASE high range + the slab allocator, and self-test it.
 */
static void
startup_vm(void)
{
	sbi_console_puts("\n[startup] startup_vm: kernel VA + kmem\n");
	kmem_init();
	kmem_selftest();
}

/*
 * startup_cyclic — the timing stage. The periodic clock is already running
 * (mlsetup ran clock_prove); here we prove the callout wheel driven by it.
 */
static void
startup_cyclic(void)
{
	sbi_console_puts("\n[startup] startup_cyclic: callout wheel on the "
	    "100 Hz clock\n");
	callout_selftest();
}

/*
 * startup_dispatch — the dispatcher stage. Make the boot cpu's execution
 * context cpu0's idle thread (so there is always a curthread), then prove
 * scheduling with the A/B two-thread context-switch test.
 */
static void
startup_dispatch(void)
{
	sbi_console_puts("\n[startup] startup_dispatch: threads + swtch\n");
	dispatch_init_cpu(0);
	sbi_console_puts("[startup] boot cpu is now cpu0 idle thread; "
	    "dispatcher online\n");
	thread_ab_selftest();
}

/*
 * startup — the MI startup()-analog. Called from main() after mlsetup. Brings
 * the MI subsystems online in illumos order and prints the completion banner.
 */
void
startup(unsigned long dtb)
{
	sbi_console_puts("\n========================================\n");
	sbi_console_puts("[startup] MI kernel bring-up (genunix seam, R-P5)\n");
	sbi_console_puts("========================================\n");

	startup_memlist(dtb);
	startup_vm();
	startup_cyclic();
	startup_dispatch();

	sbi_console_puts("\n[startup] startup complete: ");
	kputdec((unsigned long)startup_ncpu);
	sbi_console_puts(" cpus, physmem ");
	kputdec(physmem);
	sbi_console_puts(" pages (");
	kputdec((physmem << PAGESHIFT) >> 20);
	sbi_console_puts(" MB), kmem online (");
	kputdec(kmem_heap_pages());
	sbi_console_puts(" heap pages), cyclic online, dispatch online.\n");
	sbi_console_puts("[startup] freelist: ");
	kputdec(page_freecount());
	sbi_console_puts(" pages free; hrtime ");
	kputdec(gethrtime());
	sbi_console_puts(" ns\n");
}
