/*
 * main.c — illumos riscv64 kernel C entry (R-P2 banner milestone).
 *
 * Reached from locore.S (_start) in S-mode under OpenSBI on qemu virt with:
 *   hartid = boot hart id (a0),  dtb = flattened devicetree phys addr (a1).
 *
 * For R-P2 this is the whole kernel: prove OpenSBI -> S-mode illumos entry ->
 * SBI console -> a real illumos-style banner. It is the seed of the future
 * mlsetup()/main() split; R-P3 turns this into the true startup sequence
 * (trap vector, Sv39 HAT, cyclic/clock) before reaching genunix main().
 *
 * This is the FIRST illumos RISC-V C code to execute. There is no libc: we are
 * freestanding, printing only via the SBI console layer (sbi.c).
 */

#include "sbi.h"

/* SunOS release identity — matches the illumos convention (utsname). */
#define	SOLNIX_RELEASE	"5.11"
#define	SOLNIX_VERSION	"solnix-riscv64"

/*
 * puthex64 — print a 64-bit value as 0x-prefixed, zero-padded hex via the SBI
 * console. Freestanding; no libc. Used for hartid/dtb in the banner.
 */
static void
puthex64(unsigned long v)
{
	static const char hex[] = "0123456789abcdef";
	int i;

	sbi_console_puts("0x");
	for (i = 60; i >= 0; i -= 4)
		sbi_console_putchar(hex[(v >> i) & 0xf]);
}

/*
 * putdec — print an unsigned value in decimal (for the hartid, which is small
 * and reads better in decimal alongside the hex dtb address).
 */
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

/*
 * main — the illumos riscv64 kernel entry. Prototype matches the locore call:
 *   void main(uint64_t hartid, uint64_t dtb);
 * Must not return (locore parks it in wfi if it does).
 */
void
main(unsigned long hartid, unsigned long dtb)
{
	/*
	 * The banner. First line is the canonical illumos SunOS banner shape
	 * (see uts/common/os/main.c cmn_err startup); the rest records the
	 * S-mode entry contract we just proved, for the boot log / history.
	 */
	sbi_console_puts("\n");
	sbi_console_puts("SunOS Release " SOLNIX_RELEASE " Version "
	    SOLNIX_VERSION " (first illumos on RISC-V)\n");
	sbi_console_puts("Copyright (c) solnix -- the first illumos RISC-V "
	    "port (R-P2 bring-up)\n");
	sbi_console_puts("\n");

	sbi_console_puts("riscv64 S-mode kernel entry reached under OpenSBI:\n");

	sbi_console_puts("  boot hart id (a0) : ");
	putdec(hartid);
	sbi_console_puts("\n");

	sbi_console_puts("  devicetree  (a1)  : ");
	puthex64(dtb);
	sbi_console_puts("\n");

	sbi_console_puts("  console path      : ");
	sbi_console_puts(sbi_console_kind());
	sbi_console_puts("\n");

	sbi_console_puts("\n");
	sbi_console_puts("[R-P2] first illumos RISC-V kernel instruction "
	    "executed. Parking boot hart.\n");
	sbi_console_puts("[R-P2] next: R-P3 trap vector (stvec) + Sv39 HAT + "
	    "timer -> mlsetup/main.\n");

	/*
	 * R-P2 ends here: no trap/MMU/scheduler yet. Return to locore, which
	 * parks the hart in wfi. (A future main() never returns; it becomes the
	 * idle thread.)
	 */
}
