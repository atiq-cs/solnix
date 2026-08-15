/*
 * plic.c -- R-P24 sub-task 3: qemu-virt PLIC (Platform-Level Interrupt
 * Controller) bring-up + a claim/complete of one external interrupt.
 *
 * The PLIC routes device (wired) interrupts to a hart "context" as a
 * Supervisor External Interrupt (scause = INTERRUPT | 9).  On qemu-virt:
 *   base    = 0x0C000000
 *   sources : UART0 (ns16550a) = IRQ 10, VIRTIO = 1..8, RTC = 11, ...
 *   contexts: even = hart N M-mode, odd = hart N S-mode.  Hart 0 S-mode = ctx 1.
 *
 * Register map (per the PLIC spec, qemu layout):
 *   +0x000000 + 4*src        source priority (0 disables, >0 enables level)
 *   +0x001000 + ...          pending bits (read-only)
 *   +0x002000 + 0x80*ctx     enable bitmap for context (1 bit / source)
 *   +0x200000 + 0x1000*ctx   [0]=priority threshold, [4]=claim/complete
 *
 * bring-up:  plic_init() sets UART0 priority > 0, enables it for our context,
 *   drops the threshold to 0.  plic_claim() reads the claim register (returns
 *   the highest-priority pending source id, 0 if none); plic_complete(id)
 *   writes it back to signal EOI.  The boot proof provokes a UART RX interrupt
 *   (or, if none is pending, a synthetic pending) and claims it.
 *
 * Once paging is on we reach the PLIC through the high direct-map; pre-check we
 * touch the identity-mapped IO range.  We take the direct-map VA so the driver
 * is paging-correct.
 *
 * CRIB PROVENANCE: the PLIC register offsets (priority/enable/threshold/claim)
 * + the "set priority, enable for context, drop threshold, claim, complete"
 * sequence are the RISC-V PLIC spec + the R-P plic.c slice; the qemu-virt base
 * 0x0C000000 + UART0=IRQ10 + S-mode-context numbering are the qemu virt board +
 * its devicetree.
 */

#include "sbi.h"
#include "plic.h"
#include "mmu_riscv.h"

#define	PLIC_PHYS	0x0C000000UL
#define	UART0_IRQ	10U		/* qemu-virt ns16550a */

/* context for hart 0 S-mode on qemu-virt. */
#define	PLIC_CTX		1U

#define	PLIC_PRIORITY(src)	(0x000000UL + 4UL * (src))
#define	PLIC_PENDING(src)	(0x001000UL + 4UL * ((src) / 32))
#define	PLIC_ENABLE(ctx)	(0x002000UL + 0x80UL * (ctx))
#define	PLIC_THRESHOLD(ctx)	(0x200000UL + 0x1000UL * (ctx))
#define	PLIC_CLAIM(ctx)		(0x200004UL + 0x1000UL * (ctx))

/*
 * PLIC MMIO base as a virtual address.  Post-paging we use the high direct-map
 * (KERNEL_DMAP_BASE + PA); the identity map also covers it so either works.
 */
static volatile unsigned int *
plic_reg(unsigned long off)
{
	return ((volatile unsigned int *)(KERNEL_DMAP_BASE + PLIC_PHYS + off));
}

void
plic_init(void)
{
	/* enable UART0 as a source: nonzero priority + set its context bit. */
	*plic_reg(PLIC_PRIORITY(UART0_IRQ)) = 1;
	*plic_reg(PLIC_ENABLE(PLIC_CTX) + 4UL * (UART0_IRQ / 32)) |=
	    (1U << (UART0_IRQ % 32));
	/* threshold 0 => accept any priority > 0. */
	*plic_reg(PLIC_THRESHOLD(PLIC_CTX)) = 0;
}

/* claim: returns the pending source id (0 == none). */
unsigned int
plic_claim(void)
{
	return (*plic_reg(PLIC_CLAIM(PLIC_CTX)));
}

/* complete: signal EOI for a claimed source. */
void
plic_complete(unsigned int src)
{
	*plic_reg(PLIC_CLAIM(PLIC_CTX)) = src;
}

/*
 * Force a UART0 interrupt so the PLIC has something to claim under qemu: the
 * ns16550a raises IRQ 10 when the "enable received-data-available interrupt"
 * bit (IER bit0) is set and the RX FIFO is non-empty, OR simply when THR-empty
 * (IER bit1) since the transmitter is always ready.  We enable THRE interrupt;
 * qemu asserts IRQ 10 to the PLIC immediately.
 */
#define	UART0_PHYS	0x10000000UL
#define	UART_IER	1U		/* interrupt enable register */
#define	IER_THRE	0x02U		/* transmitter-holding-empty int */

void
plic_provoke_uart(void)
{
	volatile unsigned char *uart =
	    (volatile unsigned char *)(KERNEL_DMAP_BASE + UART0_PHYS);
	uart[UART_IER] = IER_THRE;	/* raises IRQ 10 (TX always ready) */
}

void
plic_quiesce_uart(void)
{
	volatile unsigned char *uart =
	    (volatile unsigned char *)(KERNEL_DMAP_BASE + UART0_PHYS);
	uart[UART_IER] = 0;		/* stop asserting */
}
