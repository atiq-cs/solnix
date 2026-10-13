/*
 * k3efuse.c — SpacemiT K3 eFuse scaffold (compatible "spacemit,efuse",
 * fuse@f0702800 banks). Read-only OTP (chip ID, MAC, calibration). Crib:
 * Linux drivers/nvmem/spacemit-efuse.c. Compile+bind deliverable: discover the
 * fuse bank reg; a live OTP read is the on-silicon TODO (needs aes_core clk).
 */

#include "sbi.h"

extern void kputhex(unsigned long v);

typedef long fdt_node_t;
#define	FDT_NONE	(-1L)
extern fdt_node_t fdt_find_compatible(unsigned long dtb, const char *pfx);
extern int fdt_node_reg(unsigned long dtb, fdt_node_t n, int i,
    unsigned long *base, unsigned long *size);

int
k3efuse_probe(unsigned long dtb, int live)
{
	fdt_node_t n = fdt_find_compatible(dtb, "spacemit,efuse");
	unsigned long base = 0, size = 0;

	(void) live;
	if (n == FDT_NONE) {
		sbi_console_puts("[k3efuse] no spacemit,efuse node in boot "
		    "DTB\n");
		return (0);
	}
	/* reg here is an offset within the simple-mfd ranges, not an MMIO VA. */
	(void) fdt_node_reg(dtb, n, 0, &base, &size);
	sbi_console_puts("[k3efuse] efuse bank bound (reg-offset ");
	kputhex(base);
	sbi_console_puts("). ON-SILICON TODO: aes_core clk, OTP read.\n");
	return (1);
}
