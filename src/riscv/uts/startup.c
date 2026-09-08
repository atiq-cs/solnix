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
 *     startup_dispatch() -> dispatch_init_cpu(boot hartid): boot cpu becomes
 *          its own hart's idle
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
/* cmo.c: pick the cache-maintenance backend for this boot from the DT. */
extern int cmo_init(unsigned long dtb);
extern int cmo_selftest(void);
/*
 * R-P64 scanout seam: the virtio-gpu display device (virtio_gpu.c) and the
 * /dev/fb node over it (fb.c) that a software compositor mmaps and flushes.
 */
extern int virtio_gpu_init(void);
extern int fb_init(void);
extern int fb_selftest(void);extern int snfs_init(void);
extern int fdt_summary(unsigned long dtb);
/* R-P13: FDT-driven driver attach + physical-hart SMP proof. */
extern int fdt_attach_drivers(unsigned long dtb);
extern void smp_selftest(void);
extern void smp_dispatch_open(void);

/* R-P14: SpaceMiT K1 board bring-up (DTB ingest + dw-apb-uart + sdhci). */
#include "k1.h"
#include "k1_dtb.h"		/* the embedded, dtc-compiled K1 board DTB */

/* R-P15: hat gate-1 proof — the K1 device gigapage is mapped + readable. */
extern void hat_k1_devmap_prove(void);

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
/*
 * The hart OpenSBI elected as the boot hart -- the boot hart's own dispatcher
 * cpu slot. Set by main() from a0 before it calls startup().
 *
 * This is NOT always 0. OpenSBI runs a boot-hart lottery, so on qemu virt the
 * S-mode payload is entered on hart 0 about 2/3 of the time and on hart 1/2/3
 * otherwise. It cannot be recovered from tp here: locore deliberately leaves tp
 * at 0 for the boot hart (see the this_cpu() comment in proc.c -- seeding tp
 * early destabilized the boot), so the id must be carried across the MD->MI seam
 * explicitly, exactly like startup_ncpu.
 */
int startup_boot_hartid;

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

	/*
	 * Choose the cache-maintenance backend FIRST, before any driver can touch
	 * a DMA path. Both candidate instruction sets (Zicbom, T-Head custom) trap
	 * as illegal instructions on a CPU that lacks them, so until this runs the
	 * only safe behavior is the plain ordering fence -- which is exactly what
	 * cmo_backend's default gives, but a wrong choice later is fatal, so make
	 * the choice as early as the DTB is available.
	 */
	(void) cmo_init(dtb);
	(void) cmo_selftest();

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
		struct k1_devs k1;		/* from the EMBEDDED K1 blob */
		struct k1_devs boot;		/* from the FIRMWARE boot DTB (a1) */
		int is_k1 = fdt_k1_summary((unsigned long)k1_dtb_blob, &k1);
		/*
		 * R-P16 RUNTIME BOARD-DETECT. The embedded blob ALWAYS parses as
		 * K1 (it is our own k1.dts) -- that only validates the blob, it is
		 * NOT a platform test. The real signal is the boot DTB the firmware
		 * handed us in a1: OpenSBI on qemu-virt describes the EMULATED virt
		 * hardware (ns16550 uart, virtio, PLIC -- no snps,dwcmshc-sdhci /
		 * snps,dw-apb-uart / aplic+imsic), so fdt_k1_summary(boot) returns
		 * 0; U-Boot on the physical K1 hands a DTB carrying all four K1
		 * signature devices, so it returns 1. ONE `unix` image thus detects
		 * its board at boot and drives live K1 MMIO on silicon vs the
		 * faithful model under qemu -- no -DK1_SILICON recompile (per the
		 * R-P15 next-step note).
		 */
		int on_k1_silicon = fdt_k1_summary(dtb, &boot);
		unsigned long sdhci_base;

		if (is_k1) {
			sbi_console_puts("[k1] embedded K1 DTB valid "
			    "(dw-apb-uart + sdhci + aplic + imsic present)\n");
		} else {
			sbi_console_puts("[k1] WARN: embedded K1 DTB missing a "
			    "signature device\n");
		}
		sbi_console_puts(on_k1_silicon ?
		    "[board] runtime detect: boot DTB IS SpaceMiT K1 -> live "
		    "MMIO (physical board)\n" :
		    "[board] runtime detect: boot DTB is NOT K1 (qemu-virt) -> "
		    "faithful in-kernel SDHCI+SD model\n");
		/* Tell the sdhci driver which backend to use, at runtime. */
		sdhci_set_platform(on_k1_silicon);
		/* On real K1, use the sdhci base the FIRMWARE DTB reported; under
		 * qemu-virt (model) use our embedded blob's K1 base 0xd4281000. */
		sdhci_base = on_k1_silicon ? boot.sdhci_base : k1.sdhci_base;
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
		/* Gate 1 (R-P15): prove the K1 device MMIO window is mapped. */
		hat_k1_devmap_prove();
		/* Gate 3: R-P15 mmc/sdhci BLOCK DRIVER + R-P16 runtime backend.
		 * sdhci_probe runs the full bring-up: SDHCI reset -> SD init
		 * (CMD0/8/ACMD41/2/3/7) -> CMD17 read of sector 0. The backend
		 * (live MMIO vs faithful model) was chosen at RUNTIME above from
		 * the boot DTB, so the SAME code path serves qemu-virt and K1. */
		sdhci_model_selftest();
		(void) sdhci_probe(sdhci_base);
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
	/*
	 * The boot hart must claim ITS OWN hart's dispatcher slot, not slot 0.
	 * This was a hardcoded dispatch_init_cpu(0), which aliased two harts onto
	 * one slot whenever OpenSBI's boot-hart lottery picked a hart other than
	 * 0: the boot hart took curthread[0]/idlethread[0] while
	 * start_secondaries -- which skips only the boot hartid -- released the
	 * REAL hart 0 into smp_secondary_dispatch(0), whose dispatch_init_cpu(0)
	 * claimed the same slot. Hart 0's "curthread[cpu] = self" at the end of
	 * each dispatch then overwrote the boot hart's curthread with idlethread,
	 * so the boot hart's next swtch() saw new == old, returned early, and
	 * thread_exit fell into its wfi dead-end -- taking startup with it.
	 * Observed as: console stops at exactly 178 lines inside the A/B
	 * dispatcher self-test, zero userland exec'd, all seven gates failing
	 * together, and every failing run having a nonzero OpenSBI Boot HART ID.
	 * See docs/riscv64-preboot-flake.md.
	 */
	dispatch_init_cpu(startup_boot_hartid);
	sbi_console_puts("[startup] boot cpu is now cpu");
	kputdec((unsigned long)startup_boot_hartid);
	sbi_console_puts(" idle thread; dispatcher online\n");
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

	/*
	 * The scanout seam (docs/riscv64-scanout-seam.md): bring up the display
	 * device, then promote it to the /dev/fb node a software compositor mmaps.
	 * Ordered here, after virtio_discover, because virtio_gpu_init does its own
	 * MMIO-slot probe and needs the transport window already known-good; and
	 * before single_user, because the userland the seam serves starts there.
	 *
	 * A boot with no display device is not a failure: virtio_gpu_init returns
	 * 0, fb_init reports the node was not created, and the kernel continues to
	 * a serial console exactly as before.
	 */
	if (virtio_gpu_init()) {
		sbi_console_puts("[R-P64] virtio-gpu scanout bring-up OK "
		    "(GET_DISPLAY_INFO -> CREATE_2D -> ATTACH_BACKING -> "
		    "SET_SCANOUT)\n");
		(void) fb_init();
		(void) fb_selftest();
	} else {
		sbi_console_puts("[R-P64] no virtio-gpu device; /dev/fb not "
		    "created (serial console only)\n");
	}

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
