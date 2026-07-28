/*
 * uart.c — illumos riscv64 NS16550A polled console RX/TX (R-P7).
 *
 * The qemu virt machine puts an 8250/16550-compatible UART at physical
 * 0x10000000 (identity-mapped by the R-P3 low-MMIO gigapage, and copied into
 * every process root by hat_as_newroot). R-P7 needs userland to READ from the
 * console (the read(0) syscall) and the kernel to be able to poll for input;
 * SBI's console path is TX-only in practice (legacy getchar is deprecated and
 * often unimplemented). So we drive the 16550 registers directly, polled.
 *
 * This is the seed of the illumos asy(7D)/NS16550 console driver, pared to
 * polled getc/putc. IRQ-driven RX through the PLIC (source 10) is the R-P8
 * upgrade; the PLIC path is already proven (R-P4).
 *
 * Register map (byte offsets from UART0_BASE), 16550 with DLAB:
 *   0 RBR (read) / THR (write) / DLL (DLAB=1)
 *   1 IER / DLM (DLAB=1)
 *   2 IIR (read) / FCR (write)
 *   3 LCR
 *   5 LSR   bit0 DR (data ready), bit5 THRE (TX holding empty)
 */

#include "riscv_regs.h"

#define	UART_RBR	0
#define	UART_THR	0
#define	UART_LSR	5
#define	LSR_DR		0x01	/* data ready (RX byte available) */
#define	LSR_THRE	0x20	/* TX holding register empty */

static volatile unsigned char *
uart_reg(int off)
{
	return ((volatile unsigned char *)(UART0_BASE + off));
}

/* uart_rx_ready — nonzero if an input byte is waiting. */
int
uart_rx_ready(void)
{
	return ((*uart_reg(UART_LSR) & LSR_DR) != 0);
}

/*
 * uart_getc — poll for one input byte, blocking (wfi between polls) until one
 * arrives. Returns the byte (0..255). Used by the read(0) syscall so userland
 * can read from the interactive console.
 */
int
uart_getc(void)
{
	while ((*uart_reg(UART_LSR) & LSR_DR) == 0)
		__asm__ __volatile__("nop");
	return ((int)*uart_reg(UART_RBR));
}

/* uart_getc_nonblock — return the byte if ready, else -1. */
int
uart_getc_nonblock(void)
{
	if ((*uart_reg(UART_LSR) & LSR_DR) == 0)
		return (-1);
	return ((int)*uart_reg(UART_RBR));
}

/*
 * uart_putc — write one byte, polling THRE. The kernel banners use the SBI
 * console; this is here so the write(1) syscall path can go straight to the
 * UART if desired. We keep write(1) on the SBI path (proven) and expose this
 * for symmetry / future console-driver use.
 */
void
uart_putc(int ch)
{
	while ((*uart_reg(UART_LSR) & LSR_THRE) == 0)
		__asm__ __volatile__("nop");
	*uart_reg(UART_THR) = (unsigned char)ch;
}
