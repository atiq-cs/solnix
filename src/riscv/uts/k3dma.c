/*
 * k3dma.c — solnix riscv64 driver for the SpacemiT K3 DMA engines:
 *   "spacemit,k1-pdma"    peripheral DMA (d4000000, 16 channels) — the main
 *                         DMA used by SPI/UART/I2S peripherals.
 *   "spacemit,k3-adma"    audio DMA (c0883000.. 4 instances, 2 ch each).
 *   "spacemit-ai-dmac"    AI-subsystem DMA (8 instances).
 *
 * The PDMA is the Marvell/MMP MDMA/PDMA controller (Linux
 * drivers/dma/mmp_pdma.c): per-channel descriptor chains (DDADR/DSADR/DTADR/
 * DCMD), a global DALGN/DINT. The ADMA/ai-dmac are SpacemiT audio/AI variants
 * with a small per-channel register block.
 *
 * illumos has ddi_dma for host-side DMA, but these are PERIPHERAL DMA engines
 * that a device driver programs to move bytes between a device FIFO and RAM;
 * the seam here is a channel-descriptor API the SPI/I2S drivers would call.
 *
 * Compile+bind deliverable: discover each engine's reg base, IRQ and channel
 * count, and report. Programming a descriptor chain + a live memory-to-memory
 * copy is the on-silicon TODO. Reimplemented from the mmp_pdma register spec;
 * no CDDL-incompatible source copied.
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

static int
report(unsigned long dtb, const char *compat, const char *label)
{
	fdt_node_t n = fdt_find_compatible(dtb, compat);
	unsigned long base = 0, size = 0;
	int nch;

	if (n == FDT_NONE)
		return (0);
	if (fdt_node_reg(dtb, n, 0, &base, &size) != 0)
		return (0);
	nch = fdt_node_prop_u32(dtb, n, "#dma-channels", -1);

	sbi_console_puts("[k3dma] ");
	sbi_console_puts(label);
	sbi_console_puts(" @");
	kputhex(base);
	sbi_console_puts(" channels ");
	if (nch < 0)
		sbi_console_puts("(unspecified)");
	else
		kputdec((unsigned long)nch);
	sbi_console_puts("\n");
	return (1);
}

int
k3dma_probe(unsigned long dtb, int live)
{
	int found = 0;

	found += report(dtb, "spacemit,k1-pdma", "pdma");
	found += report(dtb, "spacemit,k3-adma", "adma");
	found += report(dtb, "spacemit-ai-dmac", "ai-dmac");
	(void) live;

	if (found == 0) {
		sbi_console_puts("[k3dma] no DMA-engine node in boot DTB\n");
		return (0);
	}
	sbi_console_puts("[k3dma] bound. ON-SILICON TODO: clk+reset, "
	    "per-channel descriptor chain (DDADR/DSADR/DTADR/DCMD), live "
	    "mem->mem copy, then wire SPI/I2S tx/rx channels.\n");
	return (found);
}
