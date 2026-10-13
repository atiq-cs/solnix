/*
 * k3spi.c — solnix riscv64 driver for the SpacemiT K3 SPI controllers
 * (compatible "spacemit,k3-spi"; d4040000/d4040800/f0613000/d401c000, plus a
 * "spacemit,k3-qspi" QSPI at d420c000 that drives the SPI-NOR boot chain).
 *
 * The K3 SPI reg window is small (0x30). The controller is the SpacemiT SSPA/
 * SPI master (vendor spi-k1x.c / Linux spi-pxa2xx-family lineage): TOP_CTRL,
 * FIFO_CTRL, STATUS, DATA registers, with optional DMA (dmas = <&pdma tx rx>).
 *
 * Crib: Linux drivers/spi/spi-k1x.c (SpacemiT) + the generic PXA2xx SSP model;
 * illumos has no MI SPI framework in this minimal kernel, so the seam is a
 * polled byte transfer like the I2C/UART ones. Reimplemented from the register
 * spec; no CDDL-incompatible source copied.
 *
 * Compile+bind deliverable: discover each controller's reg/irq/clocks and its
 * tx/rx DMA channel bindings. A live loopback byte is the on-silicon TODO.
 * The QSPI (d420c000) owns the jedec,spi-nor that holds the boot chain and is
 * reported separately — we must NOT write to it (it is the board's bootloader).
 */

#include "sbi.h"

extern void kputhex(unsigned long v);
extern void kputdec(unsigned long v);

typedef long fdt_node_t;
#define	FDT_NONE	(-1L)
extern fdt_node_t fdt_find_compatible(unsigned long dtb, const char *pfx);
extern int fdt_node_reg(unsigned long dtb, fdt_node_t n, int i,
    unsigned long *base, unsigned long *size);
extern int fdt_node_prop_u32(unsigned long dtb, fdt_node_t n, const char *name,
    int def);

int
k3spi_probe(unsigned long dtb, int live)
{
	fdt_node_t n;
	unsigned long base = 0, size = 0;
	int found = 0;

	n = fdt_find_compatible(dtb, "spacemit,k3-spi");
	if (n != FDT_NONE && fdt_node_reg(dtb, n, 0, &base, &size) == 0) {
		sbi_console_puts("[k3spi] k3-spi @");
		kputhex(base);
		sbi_console_puts(" irq ");
		kputdec((unsigned long)fdt_node_prop_u32(dtb, n, "interrupts",
		    -1));
		sbi_console_puts(" max-freq ");
		kputdec((unsigned long)fdt_node_prop_u32(dtb, n,
		    "spi-max-frequency", 0));
		sbi_console_puts(" Hz\n");
		found++;
		(void) live;
	} else {
		sbi_console_puts("[k3spi] no spacemit,k3-spi node in boot DTB\n");
	}

	/* QSPI (SPI-NOR boot chain) — report, never write. */
	n = fdt_find_compatible(dtb, "spacemit,k3-qspi");
	if (n != FDT_NONE && fdt_node_reg(dtb, n, 0, &base, &size) == 0) {
		sbi_console_puts("[k3spi] k3-qspi @");
		kputhex(base);
		sbi_console_puts(" (SPI-NOR boot chain — READ-ONLY, "
		    "never written)\n");
		found++;
	}

	if (found)
		sbi_console_puts("[k3spi] bound. ON-SILICON TODO: clk+reset, "
		    "polled byte xfer + FIFO, DMA (tx/rx via pdma).\n");
	return (found);
}
