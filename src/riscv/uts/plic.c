/*
 * plic.c — illumos riscv64 PLIC (Platform-Level Interrupt Controller) driver
 * and external-interrupt path (R-P4).
 *
 * The PLIC is the RISC-V standard controller for wired (external) device
 * interrupts — the path every real device driver (virtio, console, net) uses.
 * A device raises an interrupt line into the PLIC; the PLIC, per its
 * per-source priority and per-context enable/threshold, asserts the S-mode
 * external-interrupt pending bit (sip.SEIP) into the hart. The hart traps
 * (scause = IRQ_S_EXT, code 9), reads the CLAIM register to learn which
 * source fired (and to de-assert SEIP), services it, then writes the same
 * value back to COMPLETE to allow the next.
 *
 * Reference: the RISC-V PLIC Specification (the authority) + the qemu 'virt'
 * memory map, cross-checked against how Linux arch/riscv/../plic.c and NetBSD
 * sys/arch/riscv dev/plic wire the same registers. Reimplemented from the spec
 * in illumos idiom (no CDDL-incompatible source copied).
 *
 * ---------------------------------------------------------------------------
 * PLIC register map (base = PLIC_BASE = 0x0c000000 on qemu virt)
 * ---------------------------------------------------------------------------
 *   priority[src]              base + 0x000000 + src*4      (RW, 0=disabled)
 *   pending  (bitmap)          base + 0x001000 + (src/32)*4 (RO)
 *   enable[ctx][src bitmap]    base + 0x002000 + ctx*0x80 + (src/32)*4
 *   threshold[ctx]             base + 0x200000 + ctx*0x1000 (mask level)
 *   claim/complete[ctx]        base + 0x200004 + ctx*0x1000 (read=claim,
 *                                                            write=complete)
 *
 * "context" numbering on qemu virt: hart H has two contexts — M-mode = 2*H,
 * S-mode = 2*H + 1. We run in S-mode on the boot hart (hart 0), so our context
 * is 1. (Secondary harts' S-mode contexts are 3, 5, ... — wired in R-P5 when
 * device IRQs get steered/balanced across harts.)
 * ---------------------------------------------------------------------------
 */

#include "sbi.h"
#include "riscv_regs.h"

#define	PLIC_PRIORITY(src)	(PLIC_BASE + 0x000000UL + (src) * 4UL)
#define	PLIC_ENABLE(ctx, src)	\
	(PLIC_BASE + 0x002000UL + (ctx) * 0x80UL + ((src) / 32) * 4UL)
#define	PLIC_THRESHOLD(ctx)	(PLIC_BASE + 0x200000UL + (ctx) * 0x1000UL)
#define	PLIC_CLAIM(ctx)		(PLIC_BASE + 0x200004UL + (ctx) * 0x1000UL)

/* Our S-mode context on the boot hart (hart 0). */
#define	PLIC_S_CONTEXT		1UL

/* MMIO accessors (VA==PA via the R-P3 low-MMIO identity gigapage). */
static inline unsigned int
mmio_rd32(unsigned long a)
{
	return (*(volatile unsigned int *)a);
}
static inline void
mmio_wr32(unsigned long a, unsigned int v)
{
	*(volatile unsigned int *)a = v;
}

/*
 * ---------------------------------------------------------------------------
 * NS16550A UART (base = UART0_BASE = 0x10000000). We use it only as a concrete
 * interrupt source to prove the PLIC path: enabling the "transmit holding
 * register empty" (THRE) interrupt makes the idle UART raise its line into the
 * PLIC immediately and deterministically — no interactive keystroke needed
 * (interactive RX is fine too but unreliable in a timeboxed headless qemu).
 * ---------------------------------------------------------------------------
 */
#define	UART_IER	(UART0_BASE + 1)	/* interrupt enable */
#define	UART_IIR	(UART0_BASE + 2)	/* interrupt ident (read) */
#define	UART_LCR	(UART0_BASE + 3)	/* line control */
#define	UART_IER_RDA	0x01			/* received-data-available int */
#define	UART_IER_THRE	0x02			/* transmit-holding-empty int */

static inline unsigned char
uart_rd8(unsigned long a)
{
	return (*(volatile unsigned char *)a);
}
static inline void
uart_wr8(unsigned long a, unsigned char v)
{
	*(volatile unsigned char *)a = v;
}

static volatile int plic_claimed_count = 0;
static volatile unsigned long plic_last_irq = 0;

static void
puthex(unsigned long v)
{
	static const char hex[] = "0123456789abcdef";
	int i;
	sbi_console_puts("0x");
	for (i = 60; i >= 0; i -= 4)
		sbi_console_putchar(hex[(v >> i) & 0xf]);
}

/*
 * plic_init — bring the PLIC up for our S-mode context: set every source's
 * priority to 0 (disabled) as a clean baseline, then set threshold 0 (accept
 * any priority > 0). Individual sources are enabled with plic_enable().
 */
void
plic_init(void)
{
	int src;

	/* Disable all sources (priority 0). qemu virt has up to ~127 sources. */
	for (src = 1; src < 128; src++)
		mmio_wr32(PLIC_PRIORITY(src), 0);

	/* Accept any nonzero-priority interrupt on our context. */
	mmio_wr32(PLIC_THRESHOLD(PLIC_S_CONTEXT), 0);

	sbi_console_puts("[plic] init: base=");
	puthex(PLIC_BASE);
	sbi_console_puts(" S-context=1 threshold=0\n");
}

/*
 * plic_enable — enable interrupt source `src` at `prio` for our S-mode
 * context: set its priority (must be > threshold to fire) and set its enable
 * bit in the context's enable bitmap.
 */
void
plic_enable(unsigned long src, unsigned int prio)
{
	unsigned long ea = PLIC_ENABLE(PLIC_S_CONTEXT, src);
	unsigned int bit = 1U << (src % 32);

	mmio_wr32(PLIC_PRIORITY(src), prio);
	mmio_wr32(ea, mmio_rd32(ea) | bit);

	sbi_console_puts("[plic] enabled source ");
	puthex(src);
	sbi_console_puts(" prio ");
	puthex(prio);
	sbi_console_puts("\n");
}

/*
 * plic_claim — read the CLAIM register: returns the highest-priority pending
 * source id for our context (and de-asserts SEIP). 0 means "spurious / none".
 */
unsigned long
plic_claim(void)
{
	return (mmio_rd32(PLIC_CLAIM(PLIC_S_CONTEXT)));
}

/*
 * plic_complete — write the source id back to CLAIM/COMPLETE, signalling the
 * PLIC that servicing of that source is done so it may deliver the next.
 */
void
plic_complete(unsigned long src)
{
	mmio_wr32(PLIC_CLAIM(PLIC_S_CONTEXT), (unsigned int)src);
}

/*
 * plic_extintr — called from trap() on IRQ_S_EXT (scause code 9). Claim the
 * source, dispatch (here: quiet the UART so it stops re-asserting, then report
 * the claim), and complete. Loops in case several sources are pending. Returns
 * the number of sources serviced.
 */
int
plic_extintr(void)
{
	unsigned long src;
	int serviced = 0;

	while ((src = plic_claim()) != 0) {
		plic_last_irq = src;
		plic_claimed_count++;

		sbi_console_puts("[plic] IRQ ");
		puthex(src);
		sbi_console_puts(" claimed (S-mode external interrupt "
		    "delivered via PLIC)\n");

		/*
		 * Device dispatch. For our UART self-test source, quiet it by
		 * disabling its interrupts so it does not immediately re-raise
		 * the line (THRE stays asserted while the transmitter is idle).
		 * A real console driver would read RBR / drain the FIFO here.
		 */
		if (src == UART0_IRQ) {
			uart_wr8(UART_IER, 0);		/* mask UART ints */
			(void) uart_rd8(UART_IIR);	/* clear IIR */
		}

		plic_complete(src);
		serviced++;
	}
	return (serviced);
}

/*
 * plic_selftest — R-P4 milestone-3 proof of the external-interrupt path
 * end-to-end WITHOUT needing interactive input:
 *   1. plic_init + enable the UART source (UART0_IRQ = 10) at priority 1.
 *   2. Enable S-mode external interrupts (SIE.SEIE) and global sstatus.SIE.
 *   3. Poke the NS16550A: enable its THRE interrupt. The transmitter is idle,
 *      so the UART raises its line into the PLIC immediately.
 *   4. The PLIC asserts sip.SEIP -> the hart traps (IRQ_S_EXT) -> trap() ->
 *      plic_extintr() claims source 10, prints, completes.
 *   5. We wfi until the claim is observed, then report.
 *
 * This exercises exactly the path virtio/console/net drivers will use.
 */
void
plic_selftest(void)
{
	int spin;

	sbi_console_puts("[plic] self-test: prove external-interrupt "
	    "delivery via the UART source\n");

	plic_init();
	plic_enable(UART0_IRQ, 1);

	/* Enable S-mode external interrupts + global interrupt enable. */
	__asm__ __volatile__("csrs sie, %0" :: "r"(SIE_SEIE));
	__asm__ __volatile__("csrs sstatus, %0" :: "r"(SSTATUS_SIE));

	/*
	 * Trigger: enable the UART's transmit-holding-empty interrupt. The
	 * transmitter is idle at boot, so THRE is asserted and the UART raises
	 * its PLIC line right away. (LCR DLAB must be 0 to address IER; it is
	 * after OpenSBI's console setup, but force it to be safe.)
	 */
	uart_wr8(UART_LCR, uart_rd8(UART_LCR) & ~0x80);	/* DLAB = 0 */
	uart_wr8(UART_IER, UART_IER_THRE);

	/* Wait (bounded) for the external interrupt to be claimed. */
	for (spin = 0; spin < 1000000 && plic_claimed_count == 0; spin++)
		__asm__ __volatile__("wfi");

	if (plic_claimed_count > 0) {
		sbi_console_puts("[plic] self-test OK: external IRQ ");
		puthex(plic_last_irq);
		sbi_console_puts(" claimed + completed via PLIC.\n");
	} else {
		sbi_console_puts("[plic] self-test WARN: no external interrupt "
		    "observed (SEIP path)\n");
	}

	/* Leave SEIE enabled (real console/device IRQs continue via PLIC). */
}
