/*
 * main.c — illumos riscv64 kernel C entry: mlsetup + main (R-P4).
 *
 * Reached from locore.S (_start) in S-mode under OpenSBI on qemu virt with:
 *   hartid = boot hart id (a0),  dtb = flattened devicetree phys addr (a1).
 *
 * R-P4 grows the R-P3 (trap/Sv39/one-shot-timer) bring-up toward genunix:
 *
 *   locore.S  _start
 *     -> mlsetup(hartid, dtb)      machine-dependent low-level setup:
 *          - install the real S-mode trap vector (stvec -> _trap_entry)
 *          - build the Sv39 boot page table, turn paging ON (hat_boot_init)
 *          - self-test the trap path (deliberate fault, decoded + resumed)
 *          - phys page allocator + high-VA KERNELBASE hat map (hat_highva_prove)
 *          - SMP: start secondary harts via SBI HSM (start_secondaries)
 *          - PLIC external-interrupt path self-test (plic_selftest)
 *          - periodic (cyclic) clock at HZ, prove ~10 ticks (clock_prove)
 *     -> main()                    the illumos-style banner + subsystem status
 *
 * Secondary harts enter locore's _secondary_start, load the shared kernel
 * satp, and call secondary_main() to report "hart N online".
 *
 * This mirrors uts/i86pc mlsetup() -> main() (and richlowe arm64-gate): locore
 * builds just enough to run C, mlsetup does MD bring-up, main is the MI entry.
 * Freestanding; console only via the SBI layer (sbi.c). No libc.
 */

#include "sbi.h"
#include "riscv_regs.h"
#include "k1.h"

/* SunOS release identity — matches the illumos convention (utsname). */
#define	SOLNIX_RELEASE	"5.11"
#define	SOLNIX_VERSION	"solnix-riscv64"

/* MD bring-up entry points (trap.c, hat_riscv.c, timer.c, plic.c). */
extern void set_trap_vector(void);
extern void trap_selftest(void);
extern unsigned long hat_boot_init(void);
extern void hat_phys_init(void);
extern void hat_phys_set_ram(unsigned long base, unsigned long size);
extern int fdt_get_memory(unsigned long dtb, unsigned long *base,
    unsigned long *size);
extern void hat_highva_prove(void);
extern void clock_prove(unsigned long nticks);
extern void clock_set_timebase(unsigned long hz);
extern unsigned long clock_timebase(void);
extern unsigned long fdt_get_timebase(unsigned long dtb);
extern unsigned long gethrtime(void);
extern void plic_selftest(void);
extern void plic_set_context(unsigned long boot_hartid);
/* R-P13 AIA (aia.c) + FDT intc detection (fdt.c) + SMP dispatch (proc.c). */
extern void aia_selftest(unsigned long hartidx);
extern int aia_is_active(void);
extern int fdt_intc_is_aia(unsigned long dtb);
extern void smp_secondary_dispatch(unsigned long hartid);
extern volatile unsigned long timer_ticks;

/* SMP: secondary-hart entry (locore.S) + its per-cpu stack pool. */
extern void _secondary_start(void);
extern char secondary_stacks[];

/*
 * Max harts we support (matches the secondary_stacks pool in locore.S -- keep
 * the two in step, the pool is MAXCPU-1 stacks).
 *
 * 16, because the SpacemiT K3 Pico ITX has 16 harts (cpu@0..cpu@15, measured;
 * see docs/k3-vendor-dtb-findings.md). This was 8, which was not merely "too
 * small": it deterministically reinstated the bug-#9 hart-slot aliasing on any
 * board with more than 8 harts. startup_boot_hartid clamped an out-of-range boot
 * hartid to 0, and start_secondaries only skips h == boot_hartid, so with
 * MAXCPU=8 and OpenSBI booting on hart 8..15 the boot hart would take slot 0
 * while the REAL hart 0 was released as a secondary into dispatch_init_cpu(0) --
 * two harts on one slot, exactly the failure in docs/riscv64-preboot-flake.md.
 * On the K3 that is HALF the harts, not a one-in-three lottery.
 */
#define	MAXCPU		16
#define	SECONDARY_STACK_SIZE	16384UL

/*
 * cpu_online[] — R-P4 per-hart online bitmap (seed of the cpu_t[] array /
 * CPU set). Index by hartid; set by each hart as it reports in. In BSS.
 */
static volatile int cpu_online[MAXCPU];
static volatile int ncpu_online = 0;	/* count of SECONDARY harts reported in */

/*
 * cpu_ncpu_online -- total online harts, for libc's pset_info(PSET_INFO) and
 * hence Rust's available_parallelism().
 *
 * ⚠️ ncpu_online counts SECONDARY harts only (each secondary increments it as it
 * reports in), so the total is that plus the boot hart. Returning ncpu_online
 * directly would under-report by exactly one and, on a single-hart boot, report
 * ZERO CPUs -- which callers would read as "unknown" rather than "one".
 */
int
cpu_ncpu_online(void)
{
	int n = ncpu_online + 1;	/* + the boot hart */

	if (n < 1)
		n = 1;
	if (n > MAXCPU)
		n = MAXCPU;
	return (n);
}

/*
 * console_lock — a minimal test-and-set spinlock so concurrent harts do not
 * interleave console output byte-for-byte. amoswap.w publishes/acquires; a
 * store releases. This is the seed of the real illumos console/mutex path;
 * R-P5 replaces it with a proper mutex/disp lock.
 */
static volatile int console_lock = 0;

static void
console_acquire(void)
{
	int old;
	do {
		__asm__ __volatile__("amoswap.w.aq %0, %2, (%1)"
		    : "=&r"(old) : "r"(&console_lock), "r"(1) : "memory");
	} while (old != 0);
}

static void
console_release(void)
{
	__asm__ __volatile__("amoswap.w.rl zero, zero, (%0)"
	    :: "r"(&console_lock) : "memory");
}

/*
 * boot_cpu — the seed cpu_t. R-P3 records just the boot hartid, the live satp,
 * and the online-subsystem flags; this grows into the real cpu_t (dispatch,
 * per-cpu areas) in R-P4. Kept minimal and honest.
 */
struct boot_cpu {
	unsigned long	bc_hartid;	/* boot hart id from a0 */
	unsigned long	bc_dtb;		/* devicetree phys addr from a1 */
	unsigned long	bc_satp;	/* live satp after paging on */
	int		bc_trap_online;
	int		bc_vm_online;
	int		bc_timer_online;
	int		bc_smp_online;	/* secondary harts brought up */
	int		bc_nsecondary;	/* count of secondaries online */
	int		bc_plic_online;	/* external-interrupt path proven */
	int		bc_highva_online; /* high-VA hat map proven */
	unsigned long	bc_hrtime;	/* gethrtime after the clock proof */
};
static struct boot_cpu boot_cpu;

static void
puthex64(unsigned long v)
{
	static const char hex[] = "0123456789abcdef";
	int i;

	sbi_console_puts("0x");
	for (i = 60; i >= 0; i -= 4)
		sbi_console_putchar(hex[(v >> i) & 0xf]);
}

static void
putdec(unsigned long v)
{
	char buf[20];
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

/* From startup.c: the MI startup()-analog + its cpu count input. */
extern void startup(unsigned long dtb);
extern int startup_ncpu;
extern int startup_boot_hartid;

/* From proc.c: drive the cooperative dispatcher (R-P8 keeps userland running). */
extern void thread_yield(void);

/* Forward decl: the MI entry, called at the end of mlsetup. */
static void main(void);

/*
 * secondary_main — C entry for a secondary hart (from _secondary_start in
 * locore.S, after it adopted its per-cpu stack + loaded the shared kernel
 * satp). Reports "hart N online" under the console lock, marks itself in the
 * online bitmap, then parks (the future per-cpu idle thread). This is the
 * receiving end of the SBI-HSM bring-up; R-P5 turns the park into the idle
 * loop + per-cpu dispatch.
 */
void
secondary_main(unsigned long hartid)
{
	console_acquire();
	sbi_console_puts("[smp] hart ");
	putdec(hartid);
	sbi_console_puts(" online (secondary, satp=shared kernel PT, "
	    "trap vector installed)\n");
	console_release();

	if (hartid < MAXCPU)
		cpu_online[hartid] = 1;
	__sync_fetch_and_add(&ncpu_online, 1);

	/*
	 * R-P13: instead of parking in wfi, enter the shared-runq dispatcher as
	 * this hart's idle thread. The boot hart enqueues a proof thread + IPIs
	 * us; we pull it off the runq and run it on THIS hart (hart N != 0),
	 * proving physical-hart SMP. smp_secondary_dispatch never returns.
	 */
	smp_secondary_dispatch(hartid);

	/* Never reached. */
	for (;;)
		__asm__ __volatile__("wfi");
}

/*
 * start_secondaries — boot-hart SMP driver. Probe which harts exist via SBI
 * HSM get_status (a valid hartid returns a state >= 0; out-of-range returns a
 * negative SBI error), then for every hart other than us that is STOPPED, hand
 * it a per-cpu stack top and release it into _secondary_start via
 * sbi_hart_start. Wait (bounded) for each to report in. Returns the number of
 * secondaries confirmed online.
 *
 * The kernel page table (kernel_satp) was already published by hat_boot_init,
 * so each secondary loads the shared address space before running C.
 */
static int
start_secondaries(unsigned long boot_hartid)
{
	unsigned long h;
	int started = 0;
	int stack_slot = 0;
	int spin;
	int online;

	/*
	 * No silent fold. This line used to read
	 *   cpu_online[boot_hartid < MAXCPU ? boot_hartid : 0] = 1;
	 * and that ternary WAS the bug-#9 aliasing mechanism: a boot hart at or
	 * above MAXCPU folds onto slot 0 while the real hart 0 comes up as a
	 * secondary and claims the same slot. main()'s MAXCPU panic cannot save us
	 * here because mlsetup() -> start_secondaries() runs BEFORE main(), so the
	 * alias is already installed by the time that check reports it.
	 */
	if (boot_hartid >= MAXCPU) {
		sbi_console_puts("\n[PANIC] boot hart ");
		putdec(boot_hartid);
		sbi_console_puts(" >= MAXCPU ");
		putdec(MAXCPU);
		sbi_console_puts(" in start_secondaries -- refusing to fold to"
		    " slot 0 (that is bug #9's aliasing).\n"
		    "        Raise MAXCPU in main.c AND proc.c, and the"
		    " secondary_stacks pool in locore.S.\n");
		for (;;)
			__asm__ __volatile__("wfi");
	}
	cpu_online[boot_hartid] = 1;

	console_acquire();
	sbi_console_puts("[smp] boot hart ");
	putdec(boot_hartid);
	sbi_console_puts(" starting secondaries via SBI HSM "
	    "(EID 0x48534D)\n");
	console_release();

	for (h = 0; h < MAXCPU; h++) {
		long st;
		unsigned long stacktop;

		if (h == boot_hartid)
			continue;

		st = sbi_hart_get_status(h);
		if (st < 0)
			continue;	/* hartid does not exist on this platform */

		if (st != SBI_HSM_STOPPED) {
			/* Already started or transitional; skip in R-P4. */
			continue;
		}

		/* Assign this secondary a per-cpu stack (top = base + size). */
		stacktop = (unsigned long)&secondary_stacks[
		    (stack_slot + 1) * SECONDARY_STACK_SIZE];
		stack_slot++;

		console_acquire();
		sbi_console_puts("[smp] hart_start hart ");
		putdec(h);
		sbi_console_puts(" -> _secondary_start (stacktop ");
		puthex64(stacktop);
		sbi_console_puts(")\n");
		console_release();

		/*
		 * a1 (opaque) delivers the stack top to _secondary_start.
		 * start_addr is the physical address of _secondary_start, which
		 * equals its VA (identity-mapped kernel gigapage), so it is valid
		 * whether the hart is still in Bare mode or has loaded satp.
		 */
		if (sbi_hart_start(h, (unsigned long)&_secondary_start,
		    stacktop) == 0) {
			started++;
		} else {
			console_acquire();
			sbi_console_puts("[smp] hart_start FAILED\n");
			console_release();
		}
	}

	/*
	 * Wait for every started secondary to report in. ncpu_online counts
	 * secondaries only (the boot hart is implicit +1), so the target is
	 * `started`. Poll with an acquire fence so this hart observes the
	 * secondaries' __sync updates. Bound is generous but not huge — each
	 * secondary only needs to route through SBI hart_start + satp load +
	 * the console lock.
	 */
	for (spin = 0; spin < 50000000; spin++) {
		__atomic_thread_fence(__ATOMIC_ACQUIRE);
		if (ncpu_online >= started)
			break;
		__asm__ __volatile__("nop");
	}
	__atomic_thread_fence(__ATOMIC_ACQUIRE);
	online = ncpu_online;

	console_acquire();
	sbi_console_puts("[smp] secondaries started=");
	putdec(started);
	sbi_console_puts(" online-reported=");
	putdec((unsigned long)online);
	sbi_console_puts("\n");
	console_release();

	return (online);
}

/*
 * mlsetup — machine-dependent low-level bring-up. Called from locore with the
 * boot regs. Establishes trap dispatch, virtual memory, and the timer, then
 * enters main(). Does not return (main() parks the hart).
 */
void
mlsetup(unsigned long hartid, unsigned long dtb)
{
	boot_cpu.bc_hartid = hartid;
	boot_cpu.bc_dtb = dtb;

	sbi_console_puts("\n[mlsetup] riscv64 machine-dependent bring-up "
	    "(R-P4)\n");

	/* 1. Trap vector: point stvec at the real _trap_entry, then prove it. */
	set_trap_vector();
	boot_cpu.bc_trap_online = 1;
	sbi_console_puts("[mlsetup] trap vector installed (stvec -> "
	    "_trap_entry, Direct mode)\n");

	/*
	 * 2. Virtual memory: build the Sv39 boot page table and switch satp
	 * from Bare to Sv39. Execution continues in paged mode (identity map
	 * keeps PC/sp/data at the same addresses). hat_boot_init prints the
	 * post-paging banner + alias-readback proof and returns the live satp.
	 */
	boot_cpu.bc_satp = hat_boot_init();
	boot_cpu.bc_vm_online = 1;

	/*
	 * 3. Trap self-test AFTER paging is on: a deliberate load from an
	 * unmapped canonical VA takes a real Sv39 load-page-fault, which the
	 * trap dispatcher decodes, reports, and resumes from. Proves the
	 * synchronous-trap path end to end.
	 */
	trap_selftest();

	/*
	 * 4. R-P4 milestone: physical page allocator + high-VA kernel HAT.
	 * Init the bump allocator, then map a fresh physical page at the
	 * canonical high KERNELBASE and prove the translation by writing and
	 * reading it back through both the high VA and the page's identity VA.
	 */
	/*
	 * Adopt the firmware's /memory extent BEFORE hat_phys_init, so the boot
	 * bump allocator draws from real DRAM. A compiled-in 0x80000000 base is
	 * wrong on the SpaceMiT K1, whose DRAM is 0x0..0x80000000 with SoC MMIO
	 * above it -- bump-allocating there would hand out MMIO as page tables.
	 */
	{
		unsigned long rb = 0, rs = 0;
		if (fdt_get_memory(dtb, &rb, &rs))
			hat_phys_set_ram(rb, rs);
	}
	hat_phys_init();
	hat_highva_prove();
	boot_cpu.bc_highva_online = 1;

	/*
	 * 5. R-P4 milestone: SMP secondary-hart bringup via SBI HSM. Release
	 * each stopped secondary into _secondary_start (shared kernel satp,
	 * per-cpu stack) and wait for it to report "hart N online". Done before
	 * enabling interrupts so console output stays clean.
	 */
	boot_cpu.bc_nsecondary = start_secondaries(hartid);
	boot_cpu.bc_smp_online = (boot_cpu.bc_nsecondary > 0);

	/*
	 * 6. R-P13 milestone: external-interrupt controller. Pick AIA vs PLIC
	 * from the DTB (K1/K3 = AIA APLIC+IMSIC; qemu-virt default = PLIC). If
	 * the firmware advertises an APLIC/IMSIC, route external IRQs through
	 * IMSIC MSIs (stopei claim); otherwise use the legacy PLIC path.
	 */
	if (fdt_intc_is_aia(dtb)) {
		struct k1_devs d;

		sbi_console_puts("[mlsetup] DTB: interrupt controller is AIA "
		    "(APLIC+IMSIC) -> MSI IRQ model\n");
		/*
		 * DTB-driven AIA bases (R-P17). fdt_k1_summary parses the boot
		 * DTB's IMSIC/APLIC/UART bases + the UART's APLIC source number;
		 * aia_configure adopts them so aia_selftest targets the REAL
		 * controllers — K3's IMSIC 0xe0400000 / APLIC 0xe0804000 / UART
		 * 0xd4017000 (shift=2, 32-bit) IRQ 42, or qemu-virt's bases when
		 * the DTB names those. Any base the DTB omits keeps aia.c's
		 * compiled-in qemu-virt fallback, so this never regresses qemu.
		 */
		(void) fdt_k1_summary(dtb, &d);
		aia_configure(d.imsic_base, d.aplic_base, d.uart_base,
		    d.uart_irq, d.uart_shift, d.uart_io32);
		sbi_console_puts("[mlsetup] AIA bases from DTB: IMSIC@");
		puthex64(d.imsic_base);
		sbi_console_puts(" APLIC@");
		puthex64(d.aplic_base);
		sbi_console_puts(" UART@");
		puthex64(d.uart_base);
		sbi_console_puts(" IRQ ");
		putdec(d.uart_irq);
		sbi_console_puts("\n");
		aia_selftest(hartid);
		boot_cpu.bc_plic_online = aia_is_active();
	} else {
		sbi_console_puts("[mlsetup] DTB: interrupt controller is PLIC "
		    "-> wired IRQ model\n");
		plic_set_context(hartid);
		plic_selftest();
		boot_cpu.bc_plic_online = 1;
	}

	/*
	 * 7. R-P4 milestone: periodic (cyclic) clock. Start the clock at HZ and
	 * run ~10 ticks to prove a self-rearming periodic heartbeat + gethrtime
	 * (the illumos clock/cyclic foundation). Note: SEIE is left enabled from
	 * the PLIC step, so during the clock run the UART self-test source is
	 * already quiesced; only timer interrupts fire here.
	 *
	 * Adopt the platform's `time` CSR rate from the DTB FIRST. timer.c's
	 * default is qemu virt's 10 MHz, which is 2.4x wrong on the SpacemiT K3's
	 * 24 MHz -- every interval too short, silently. clock_set_timebase
	 * ignores an absent/unusable value, so a DTB without the property leaves
	 * the default in place and clock_start says so on the console.
	 */
	{
		unsigned long tb = fdt_get_timebase(dtb);

		if (tb != 0) {
			clock_set_timebase(tb);
			sbi_console_puts("[mlsetup] DTB: timebase-frequency ");
			putdec(tb);
			sbi_console_puts(" Hz\n");
		} else {
			sbi_console_puts("[mlsetup] DTB: no timebase-frequency;"
			    " keeping the built-in default\n");
		}
	}

	clock_prove(10);
	boot_cpu.bc_timer_online = (timer_ticks > 0);
	boot_cpu.bc_hrtime = gethrtime();

	/* Enter the MI kernel entry. */
	main();
}

/*
 * main — the illumos machine-independent entry (R-P3 seed). Prints the SunOS
 * banner and the subsystem-online status proving R-P3. Does not return; parks
 * the boot hart (the future idle thread).
 */
static void
main(void)
{
	sbi_console_puts("\n");
	sbi_console_puts("SunOS Release " SOLNIX_RELEASE " Version "
	    SOLNIX_VERSION " (first illumos on RISC-V)\n");
	sbi_console_puts("Copyright (c) solnix -- the first illumos RISC-V "
	    "port (R-P5 genunix bring-up)\n");
	sbi_console_puts("\n");

	sbi_console_puts("riscv64 kernel: mlsetup complete, entering main:\n");

	sbi_console_puts("  boot hart id      : ");
	putdec(boot_cpu.bc_hartid);
	sbi_console_puts("\n");

	sbi_console_puts("  devicetree        : ");
	puthex64(boot_cpu.bc_dtb);
	sbi_console_puts("\n");

	sbi_console_puts("  console path      : ");
	sbi_console_puts(sbi_console_kind());
	sbi_console_puts("\n");

	sbi_console_puts("  satp (Sv39)       : ");
	puthex64(boot_cpu.bc_satp);
	sbi_console_puts("\n");

	sbi_console_puts("  cpus online       : ");
	putdec((unsigned long)(ncpu_online + 1));
	sbi_console_puts(" (1 boot + ");
	putdec((unsigned long)boot_cpu.bc_nsecondary);
	sbi_console_puts(" secondary)\n");

	sbi_console_puts("  hrtime            : ");
	putdec(boot_cpu.bc_hrtime);
	sbi_console_puts(" ns\n");

	sbi_console_puts("\n");
	sbi_console_puts("[R-P4] subsystem status:\n");
	sbi_console_puts("       trap online   : ");
	sbi_console_puts(boot_cpu.bc_trap_online ? "yes\n" : "NO\n");
	sbi_console_puts("       VM online      : ");
	sbi_console_puts(boot_cpu.bc_vm_online ? "yes (Sv39 paging)\n" : "NO\n");
	sbi_console_puts("       high-VA hat    : ");
	sbi_console_puts(boot_cpu.bc_highva_online ?
	    "yes (KERNELBASE map + page alloc)\n" : "NO\n");
	sbi_console_puts("       SMP online     : ");
	if (boot_cpu.bc_smp_online) {
		sbi_console_puts("yes (");
		putdec((unsigned long)boot_cpu.bc_nsecondary);
		sbi_console_puts(" secondary harts via SBI HSM)\n");
	} else {
		sbi_console_puts("no secondaries (uniprocessor boot)\n");
	}
	sbi_console_puts("       PLIC ext IRQ   : ");
	sbi_console_puts(boot_cpu.bc_plic_online ?
	    "yes (claimed + completed)\n" : "NO\n");
	sbi_console_puts("       clock online   : ");
	if (boot_cpu.bc_timer_online) {
		sbi_console_puts("yes (periodic, ");
		putdec(timer_ticks);
		sbi_console_puts(" ticks)\n");
	} else {
		sbi_console_puts("NO\n");
	}

	sbi_console_puts("\n");
	sbi_console_puts("[R-P4] SMP + periodic clock + PLIC external IRQ + "
	    "high-VA hat online.\n");

	/*
	 * R-P5: cross the MD->MI seam. main() calls the startup()-analog, which
	 * brings genunix's foundation online (page_t/freelist over DTB RAM,
	 * kmem VA+slab, the callout wheel on the 100 Hz clock, and the
	 * dispatcher: the boot cpu becomes cpu0's idle thread and we prove
	 * scheduling with a 2-thread context-switch). This is the bridge from
	 * the machine-dependent kernel to the machine-independent kernel.
	 */
	startup_ncpu = ncpu_online + 1;
	/*
	 * The dispatcher indexes its per-cpu slots by hart id, so startup must
	 * know which hart WE are. OpenSBI's boot-hart lottery makes this a
	 * nonzero hart on roughly a third of qemu virt boots; assuming 0 aliased
	 * the boot hart onto the real hart 0's slot (docs/riscv64-preboot-flake.md).
	 *
	 * A boot hartid at or past MAXCPU has no slot to claim. Folding it to 0 is
	 * NOT a safe fallback -- slot 0 belongs to the real hart 0, which
	 * start_secondaries will release as a secondary, so the fold RECREATES the
	 * aliasing bug rather than containing it. Complain loudly instead: an
	 * explicit message about an unsupported hart id is recoverable (raise
	 * MAXCPU), a silent alias is a 178-line hang with no cause on screen.
	 */
	if (boot_cpu.bc_hartid >= MAXCPU) {
		sbi_console_puts("\n[PANIC] boot hart ");
		putdec(boot_cpu.bc_hartid);
		sbi_console_puts(" is >= MAXCPU ");
		putdec(MAXCPU);
		sbi_console_puts(" -- no dispatcher slot for it.\n");
		sbi_console_puts("        Raise MAXCPU in main.c AND proc.c,"
		    " and the secondary_stacks pool in locore.S.\n");
		sbi_console_puts("        Refusing to fold to slot 0: that"
		    " aliases two harts onto one slot\n");
		sbi_console_puts("        (docs/riscv64-preboot-flake.md).\n");
		for (;;)
			__asm__ __volatile__("wfi");
	}
	startup_boot_hartid = (int)boot_cpu.bc_hartid;
	startup(boot_cpu.bc_dtb);

	sbi_console_puts("\n");
	sbi_console_puts("[R-P5] genunix seam online: page_t + kmem + callout "
	    "wheel + dispatcher/idle threads.\n");
	sbi_console_puts("[R-P6] virtio-mmio + virtio-blk + root vfs + "
	    "single-user seam reached (see [R-P6] lines above).\n");
	sbi_console_puts("[R-P6] next: R-P7 real VFS + read root image off "
	    "vioblk + userland/init exec.\n");
	sbi_console_puts("[R-P8] boot cpu is cpu0 idle thread; entering the "
	    "dispatcher (yield loop) so userland runs.\n");

	/*
	 * R-P8: the boot cpu is cpu0's idle thread. Drive the cooperative
	 * dispatcher by yielding forever — this runs the single-user reaper
	 * thread, /sbin/init (U-mode), its forked children, and the interactive
	 * shell. (R-P7 ran the single user process inline; R-P8's multi-process
	 * model needs the scheduler kept alive here.) thread_yield wfi-idles when
	 * nothing is runnable, so this is not a busy spin when userland blocks on
	 * console input.
	 */
	for (;;)
		thread_yield();
}
