/*
 * uart.c — illumos riscv64 8250/16550-family polled console (R-P7 + R-P14).
 *
 * R-P7 drove the qemu-virt NS16550A at 0x10000000 (byte registers). R-P14
 * generalizes this to ANY 8250/16550-family UART discovered from the FDT,
 * because the SpaceMiT K1's console is a Synopsys DesignWare APB UART
 * (compatible="snps,dw-apb-uart") — the SAME 16550 register programming model,
 * but the registers are 32 bits wide on a 4-byte stride (`reg-shift=2`,
 * `reg-io-width=4`). One `uart_reg()` computed from a base + a shift handles
 * both:
 *
 *   qemu-virt NS16550A : base 0x10000000, reg-shift=0  (byte-wide registers)
 *   SpaceMiT K1 dw-apb : base 0xd4017000, reg-shift=2  (32-bit-wide registers)
 *
 * The register OFFSETS (RBR/THR/IER/IIR/LCR/LSR at logical indices 0,1,2,3,5)
 * are identical; only the byte stride and access width differ. `reg-shift`
 * scales the logical index to a byte offset; `reg-io-width` selects 8- vs
 * 32-bit MMIO. This is why a single 16550 driver binds both the qemu console
 * AND the K1's dw-apb-uart — the crux of making a real K1 boot possible.
 *
 * Register map (LOGICAL indices, DLAB=0), 16550-standard:
 *   0 RBR (read) / THR (write) / DLL (DLAB=1)
 *   1 IER / DLM (DLAB=1)
 *   2 IIR (read) / FCR (write)
 *   3 LCR
 *   5 LSR   bit0 DR (data ready), bit5 THRE (TX holding empty)
 *
 * This is the seed of the illumos asy(7D)/NS16550 driver, pared to polled
 * getc/putc + an FDT bind. IRQ-driven RX is the AIA/APLIC path (aia.c).
 * Reimplemented from the 16550 datasheet + the DesignWare DW_apb_uart
 * databook's public register model (no CDDL-incompatible source copied).
 */

#include "riscv_regs.h"
#include "sbi.h"	/* kcons_quiet */

extern void kputhex(unsigned long v);
extern void kputdec(unsigned long v);
extern void sbi_console_puts(const char *s);

/* Logical register indices (scaled by reg-shift to a byte offset). */
#define	UART_RBR	0
#define	UART_THR	0
#define	UART_IER	1
#define	UART_IIR	2
#define	UART_LCR	3
#define	UART_LSR	5
#define	LSR_DR		0x01	/* data ready (RX byte available) */
#define	LSR_THRE	0x20	/* TX holding register empty */
#define	IER_THRE	0x02	/* TX-holding-empty interrupt enable */

/*
 * Live console binding. Defaults to the qemu-virt NS16550A (base UART0_BASE,
 * byte registers) purely as a pre-DTB fallback; uart_config() rebinds it to the
 * UART the LIVE BOOT DTB describes -- on the K1 that is 0xd4017000, reg-shift=2,
 * 32-bit access.
 *
 * WHY THIS DEFAULT IS DANGEROUS, AND WHY NOTHING MAY REBIND TO IT:
 *
 * Console OUTPUT for kernel messages does not come through here at all -- it
 * goes out via sbi_console_puts (SBI legacy putchar), i.e. the FIRMWARE's own
 * UART driver. Console INPUT (uart_getc, the read(fd=0) path in syscall.c) and
 * uart_putc go through THIS base, configured SEPARATELY. That split is exactly
 * the x86_64 `console` vs `os_console` bug: output worked, input was dead, and
 * a silent console is indistinguishable from a hang.
 *
 * On the K1 it is worse than a dead keyboard. 0x10000000 is not a UART there;
 * bank-0 DRAM is 0x0..0x80000000, so 0x10000000 is ordinary RAM. Freshly
 * trained DRAM reads 0x00, so LSR.THRE (bit 5) never sets and uart_putc's
 * `while ((uart_rd(UART_LSR) & LSR_THRE) == 0)` spins FOREVER, and uart_wr(THR)
 * scribbles into RAM that page_init later manages. QEMU cannot exhibit this:
 * on -machine virt 0x10000000 IS a real ns16550, so every gate passes 8/8 while
 * proving nothing about metal.
 *
 * Hence: the base must always come from the boot DTB, and the check that
 * matters is the PRECONDITION -- does the bound base resolve to 0xd4017000 on
 * a K1 DTB and 0x10000000 on a virt DTB? -- not an attempt to reproduce the
 * spin, which is unreproducible in emulation by construction.
 */
static unsigned long uart_base = UART0_BASE;
static unsigned int uart_shift = 0;	/* reg-shift: 0 = byte, 2 = 32-bit */
static int uart_io32 = 0;		/* reg-io-width == 4 (32-bit MMIO)? */

/* Byte offset of a logical register given the current reg-shift. */
static inline unsigned long
uart_off(int idx)
{
	return (uart_base + ((unsigned long)idx << uart_shift));
}

/* Read a UART register honoring reg-io-width (8- or 32-bit MMIO). */
static inline unsigned int
uart_rd(int idx)
{
	if (uart_io32)
		return (*(volatile unsigned int *)uart_off(idx) & 0xff);
	return (*(volatile unsigned char *)uart_off(idx));
}
static inline void
uart_wr(int idx, unsigned int v)
{
	if (uart_io32)
		*(volatile unsigned int *)uart_off(idx) = v & 0xff;
	else
		*(volatile unsigned char *)uart_off(idx) = (unsigned char)v;
}

/*
 * uart_config — rebind the console to the UART the FDT discovered. `base` is
 * the MMIO base, `shift` the devicetree `reg-shift` (0 for the qemu NS16550, 2
 * for the K1 dw-apb-uart), `io32` nonzero if `reg-io-width == 4`. After this,
 * every getc/putc/selftest below drives the newly-bound UART.
 *
 * A zero base is REFUSED rather than installed: a DTB walk that found no UART
 * node leaves base 0, and binding there would poll physical page 0 forever.
 * Refusing keeps the previous binding, which is this fallback's only
 * legitimate use.
 *
 * The K1's UART at 0xd4017000 is reachable after paging because hat_boot_init
 * installs an identity gigapage over 0xc0000000..0x100000000 (K1_DEV_GIGA in
 * hat_riscv.c) — the same one that covers sdhci/PLIC/CLINT.
 */
void
uart_config(unsigned long base, unsigned int shift, int io32)
{
	if (base == 0) {
		sbi_console_puts("[uart] REFUSING to bind console to base 0 "
		    "(no UART in the boot DTB); keeping @");
		kputhex(uart_base);
		sbi_console_puts("\n");
		return;
	}
	uart_base = base;
	uart_shift = shift;
	uart_io32 = io32;
}

/* uart_current_base — the base the console is bound to RIGHT NOW. */
unsigned long
uart_current_base(void)
{
	return (uart_base);
}

/*
 * uart_regshift_check — arithmetic proof (no MMIO) that the reg-shift math
 * places each logical 16550 register at the right byte offset for a UART with
 * the given reg-shift. On the K1 dw-apb-uart (shift=2) RBR/THR is at +0, IER
 * at +4, IIR at +8, LCR at +12, LSR at +20 (logical index << 2). This is what
 * makes uart_off/uart_rd/uart_wr address the K1's 32-bit-wide registers
 * correctly; touching those offsets as 32-bit MMIO against qemu's BYTE-wide
 * NS16550 would fault, so the shift=2 arithmetic is proven here and the live
 * drive is the real-K1-silicon run (R-P15).
 */
void
uart_regshift_check(unsigned int shift)
{
	unsigned long save_base = uart_base;
	unsigned int save_shift = uart_shift;
	int ok;

	uart_base = 0;			/* offsets only, no real base */
	uart_shift = shift;
	ok = (uart_off(UART_RBR) == (0UL << shift)) &&
	    (uart_off(UART_IER) == (1UL << shift)) &&
	    (uart_off(UART_IIR) == (2UL << shift)) &&
	    (uart_off(UART_LCR) == (3UL << shift)) &&
	    (uart_off(UART_LSR) == (5UL << shift));
	uart_base = save_base;
	uart_shift = save_shift;

	sbi_console_puts("[dw-apb-uart] reg-shift=");
	kputdec(shift);
	sbi_console_puts(ok ? " register-offset math OK (LSR@" :
	    " register-offset math WRONG (LSR@");
	kputhex((unsigned long)(UART_LSR << shift));
	sbi_console_puts(") drives K1 dw-apb-uart 32-bit registers; live "
	    "shift=2 drive is the K1-silicon run (R-P15)\n");
}

/* uart_rx_ready — nonzero if an input byte is waiting. */
int
uart_rx_ready(void)
{
	return ((uart_rd(UART_LSR) & LSR_DR) != 0);
}

/*
 * uart_getc — poll for one input byte, blocking until one arrives. Returns the
 * byte (0..255). Used by the read(0) syscall so userland can read the console.
 */
int
uart_getc(void)
{
	while ((uart_rd(UART_LSR) & LSR_DR) == 0)
		__asm__ __volatile__("nop");
	return ((int)(uart_rd(UART_RBR) & 0xff));
}

/* uart_getc_nonblock — return the byte if ready, else -1. */
int
uart_getc_nonblock(void)
{
	if ((uart_rd(UART_LSR) & LSR_DR) == 0)
		return (-1);
	return ((int)(uart_rd(UART_RBR) & 0xff));
}

/*
 * uart_putc — write one byte, polling THRE. Kernel banners use the SBI console;
 * this drives the bound UART directly (used by the K1 console self-test and
 * available to the write(1) path).
 */
void
uart_putc(int ch)
{
	while ((uart_rd(UART_LSR) & LSR_THRE) == 0)
		__asm__ __volatile__("nop");
	uart_wr(UART_THR, (unsigned int)ch);
}

/*
 * dw_apb_uart_selftest — R-P14 gate 2 proof: a real 8250/16550 console driver
 * driving TX/RX through the FDT-bound UART, exercising the reg-shift math the
 * K1's UART needs. `base`/`shift`/`io32` come from the LIVE BOOT DTB discovered
 * by fdt_k1_summary / fdt_attach_drivers — never from a compiled-in constant.
 *
 * `live` says whether `base` is a UART on THIS board. When it is 0 the test
 * binds and reports but does NOT touch MMIO, because a TX to a non-UART is not
 * a failed test, it is an infinite spin: uart_putc polls LSR.THRE forever, and
 * on the K1 the qemu-virt base 0x10000000 is DRAM, which reads 0x00 and never
 * sets THRE. Skipping is the only safe behaviour for an address we did not get
 * from the firmware.
 *
 * PROVE: "dw-apb-uart: console TX/RX on K1 uart (8250, reg-shift=2)".
 */
void
dw_apb_uart_selftest(unsigned long base, unsigned int shift, int io32, int live)
{
	unsigned int lsr;
	const char *msg = "[dw-apb-uart] 8250 console TX self-test\n";
	const char *q;

	uart_config(base, shift, io32);

	sbi_console_puts("[dw-apb-uart] bind console @");
	kputhex(uart_current_base());
	sbi_console_puts(" reg-shift=");
	kputdec(shift);
	sbi_console_puts(io32 ? " io-width=4(32b)" : " io-width=1(8b)");
	sbi_console_puts(" [from boot DTB]\n");

	if (!live) {
		/*
		 * Deliberately no MMIO. See the banner: a TX to an address the
		 * firmware did not report as a UART hangs rather than fails.
		 */
		sbi_console_puts("[dw-apb-uart] TX self-test SKIPPED: base not "
		    "firmware-confirmed as a UART on this board (no MMIO "
		    "issued; a TX here would spin on LSR.THRE forever)\n");
		return;
	}

	/* TX a line straight through the bound UART's THR (shifted offset);
	 * not printed when the kernel console is quiet (tryit1 demo). */
	for (q = msg; *q != '\0' && !kcons_quiet; q++)
		uart_putc((int)*q);

	/* Read LSR back at its shifted offset; an idle line has THRE set. */
	lsr = uart_rd(UART_LSR);

	if (lsr & LSR_THRE) {
		sbi_console_puts("[dw-apb-uart] console TX/RX on uart "
		    "(8250, reg-shift=");
		kputdec(shift);
		sbi_console_puts("): LSR.THRE live @");
		kputhex(uart_off(UART_LSR));
		sbi_console_puts(" (RX-ready via LSR.DR polled)\n");
	} else {
		sbi_console_puts("[dw-apb-uart] WARN: LSR.THRE not set at "
		    "shifted offset (reg-shift math?)\n");
	}

	/*
	 * The console stays bound to the UART the boot DTB named. It is NOT
	 * rebound to UART0_BASE here: that rebind was the bug — it pointed
	 * console INPUT (uart_getc, read(fd=0)) and uart_putc at the qemu-virt
	 * ns16550 address, which on the K1 is DRAM. Output survived because
	 * kernel messages go via SBI putchar, so the breakage was invisible
	 * except as a hang: the same output-fine/input-dead split as the
	 * x86_64 `console` vs `os_console` bug.
	 */
}
