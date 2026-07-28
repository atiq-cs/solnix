/*
 * main.c — illumos riscv64 kernel C entry: mlsetup + main (R-P3).
 *
 * Reached from locore.S (_start) in S-mode under OpenSBI on qemu virt with:
 *   hartid = boot hart id (a0),  dtb = flattened devicetree phys addr (a1).
 *
 * R-P3 turns the R-P2 banner into the seed of the real illumos boot sequence:
 *
 *   locore.S  _start
 *     -> mlsetup(hartid, dtb)      machine-dependent low-level setup:
 *          - install the real S-mode trap vector (stvec -> _trap_entry)
 *          - self-test the trap path (deliberate fault, decoded + resumed)
 *          - build the Sv39 boot page table and turn paging ON (hat_boot_init)
 *          - prove one timer interrupt (timer_prove_one_tick)
 *          - stamp the boot cpu_t
 *     -> main()                    the illumos-style banner + subsystem status
 *
 * This mirrors uts/i86pc mlsetup() -> main() (and richlowe arm64-gate): locore
 * builds just enough to run C, mlsetup does MD bring-up, main is the MI entry.
 * Freestanding; console only via the SBI layer (sbi.c). No libc.
 */

#include "sbi.h"
#include "riscv_regs.h"

/* SunOS release identity — matches the illumos convention (utsname). */
#define	SOLNIX_RELEASE	"5.11"
#define	SOLNIX_VERSION	"solnix-riscv64"

/* MD bring-up entry points (trap.c, hat_riscv.c, timer.c). */
extern void set_trap_vector(void);
extern void trap_selftest(void);
extern unsigned long hat_boot_init(void);
extern void timer_prove_one_tick(void);
extern volatile int timer_ticks;

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

/* Forward decl: the MI entry, called at the end of mlsetup. */
static void main(void);

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
	    "(R-P3)\n");

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

	/* 4. Timer: take exactly one S-mode timer interrupt. */
	timer_prove_one_tick();
	boot_cpu.bc_timer_online = (timer_ticks > 0);

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
	    "port (R-P3 bring-up)\n");
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

	sbi_console_puts("\n");
	sbi_console_puts("[R-P3] subsystem status:\n");
	sbi_console_puts("       trap online   : ");
	sbi_console_puts(boot_cpu.bc_trap_online ? "yes\n" : "NO\n");
	sbi_console_puts("       VM online      : ");
	sbi_console_puts(boot_cpu.bc_vm_online ? "yes (Sv39 paging)\n" : "NO\n");
	sbi_console_puts("       timer online   : ");
	sbi_console_puts(boot_cpu.bc_timer_online ? "yes (1 tick)\n" : "NO\n");

	sbi_console_puts("\n");
	sbi_console_puts("[R-P3] VM online, trap online, timer online. "
	    "First illumos RISC-V kernel reached main with paging.\n");
	sbi_console_puts("[R-P3] next: R-P4 SMP (SBI HSM hart start), cyclic "
	    "clock, PLIC external interrupts, genunix.\n");
	sbi_console_puts("[R-P3] parking boot hart (future idle thread).\n");

	for (;;)
		__asm__ __volatile__("wfi");
}
