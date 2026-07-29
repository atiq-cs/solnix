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
 * NOTE: startup here is a linear "bring up + prove" sequence, not the full
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

/* R-P6 device + root bring-up (virtio.c, vioblk.c, rootfs.c). */
extern int virtio_discover(void);
extern int vioblk_attach(void);
extern int vionet_attach(void);
extern int mountroot(void);
extern int single_user(const char *rootdev);
extern const char *rootdev_name(void);

/* R-P12: writable data disk + on-disk SNFS + FDT device summary. */
extern int vioblk_data_attach(void);
extern int snfs_init(void);
extern int fdt_summary(unsigned long dtb);
/* R-P13: FDT-driven driver attach + physical-hart SMP proof. */
extern int fdt_attach_drivers(unsigned long dtb);
extern void smp_selftest(void);
extern void smp_dispatch_open(void);

/* R-P14: SpaceMiT K1 board bring-up (DTB ingest + dw-apb-uart + sdhci). */
#include "k1.h"
#include "k1_dtb.h"		/* the embedded, dtc-compiled K1 board DTB */

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

	/* R-P12: full FDT device summary (mem + uart + virtio node count) while
	 * the DTB is still identity-mapped (before startup_vm remaps). */
	(void) fdt_summary(dtb);

	/* R-P13: turn the summary into real driver attach — walk compatible=
	 * strings and bind uart / virtio / intc drivers to their FDT nodes
	 * (not compiled-in addresses). Also while the DTB is identity-mapped. */
	{
		int n = fdt_attach_drivers(dtb);
		sbi_console_puts("[devtree] ");
		kputdec((unsigned long)n);
		sbi_console_puts(" device(s) attached by FDT compatible\n");
	}

	/*
	 * R-P14: SpaceMiT K1 board bring-up. Parse a REAL K1 board DTB through
	 * fdt.c and bind the K1 devices. We parse the EMBEDDED K1 blob (k1.dts ->
	 * dtc, in k1_dtb.h) rather than qemu's boot DTB, because qemu-virt's DTB
	 * describes the EMULATED virt hardware (RAM@0x80000000, uart@0x10000000),
	 * not K1 silicon (RAM@0x0, dw-apb-uart@0xd4017000) — handing a pure-K1
	 * DTB to qemu as its boot DTB hangs OpenSBI (wrong device addresses). On
	 * the physical board U-Boot passes THIS blob in a1 and the addresses
	 * match. So: prove K1-DTB ingestion + K1 device discovery on the real K1
	 * topology here (identity-mapped kernel VA), and prove the dw-apb-uart
	 * 8250 driver TX/RX live against the qemu console (same 16550 code the K1
	 * uses). The K1 uart/sdhci bases are above the R-P3 identity map, so their
	 * live MMIO is the K1-silicon run (R-P15) — reported honestly here. */
	{
		struct k1_devs k1;
		int is_k1 = fdt_k1_summary((unsigned long)k1_dtb_blob, &k1);

		if (is_k1) {
			sbi_console_puts("[k1] SpaceMiT K1 board DTB confirmed "
			    "(dw-apb-uart + sdhci + aplic + imsic present)\n");
		} else {
			sbi_console_puts("[k1] WARN: embedded K1 DTB missing a "
			    "signature device\n");
		}
		/* Gate 2: prove the dw-apb-uart 8250 console driver TX/RX live
		 * against the qemu 16550 (shift=0) — the SAME driver code binds
		 * the K1 uart; then prove the K1's reg-shift=2 register math. */
		dw_apb_uart_selftest(UART0_BASE, 0, 0);
		uart_regshift_check(k1.uart_shift);
		sbi_console_puts("[dw-apb-uart] K1 console is dw-apb-uart@");
		kputhex(k1.uart_base);
		sbi_console_puts(" reg-shift=");
		kputdec(k1.uart_shift);
		sbi_console_puts(" (bind + live drive on K1 silicon: R-P15)\n");
		/* Gate 3-alt: SDHCI/eMMC register-level probe at the K1 base. */
		(void) sdhci_probe(k1.sdhci_base);
	}

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
	/* Release the secondary harts (spinning in smp_secondary_dispatch) now
	 * that kmem + the dispatcher are up: they can safely alloc + run. */
	smp_dispatch_open();
	thread_ab_selftest();

	/* R-P13: physical-hart SMP — enqueue a thread on the shared runq and
	 * IPI-wake the secondary harts (already in smp_secondary_dispatch) to
	 * pull + run it on a hart != 0. */
	smp_selftest();
}

/*
 * startup_root — R-P6 device + root stage. Discover virtio-mmio devices,
 * attach virtio-blk (test-read sector 0 = the DMA/device-I/O crux), mount the
 * root vfs, then dispatch the single-user context. This is the seam where the
 * kernel becomes a running OS.
 */
static void
startup_root(void)
{
	sbi_console_puts("\n[startup] startup_root: virtio devices + mount "
	    "root + single-user\n");

	(void) virtio_discover();
	(void) vioblk_attach();
	(void) vionet_attach();
	(void) mountroot();
	/* R-P12: writable on-disk FS (FDT summary already printed at memlist). */
	(void) vioblk_data_attach();
	(void) snfs_init();
	(void) single_user(rootdev_name());
}

/*
 * startup — the MI startup()-analog. Called from main() after mlsetup. Brings
 * the MI subsystems online in illumos order and prints the completion banner.
 */
void
startup(unsigned long dtb)
{
	sbi_console_puts("\n========================================\n");
	sbi_console_puts("[startup] MI kernel bring-up (genunix seam, R-P5/R-P6)\n");
	sbi_console_puts("========================================\n");

	startup_memlist(dtb);
	startup_vm();
	startup_cyclic();
	startup_dispatch();
	startup_root();

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
