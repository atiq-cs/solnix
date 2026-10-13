/*
 * k3misc.c — SpacemiT K3 miscellaneous peripheral discovery (scaffold).
 * Reports presence of the remaining DT peripherals so the driver table is
 * grounded in the live DTB rather than a guess, without implementing each:
 *   "spacemit,k1-flexcan"   CAN (5x)       — Bosch FlexCAN (Linux flexcan.c)
 *   "spacemit,k3-ri2s" / "spacemit,k1-i2s" audio I2S + simple-audio-card
 *   "spacemit,k3-mailbox"   coprocessor mailbox (7x)
 *   "spacemit,k3-rproc"     remote-processor (RCPU)
 *   "spacemit,k3-tsensor"   thermal sensor
 *   "spacemit,dpu-saturn"   display (large, deferred per plan)
 * Each is a one-line presence report; no MMIO. Implementing any is future work.
 *
 * NOTE: "spacemit,k3-ufshcd" (the UFS host = THE root device) used to be
 * reported here; it now has a REAL driver (k3ufs.c, probed first in k3dev.c),
 * so it is no longer a presence-only line.
 */

#include "sbi.h"

typedef long fdt_node_t;
#define	FDT_NONE	(-1L)
extern fdt_node_t fdt_find_compatible(unsigned long dtb, const char *pfx);

static int
present(unsigned long dtb, const char *compat, const char *note)
{
	if (fdt_find_compatible(dtb, compat) == FDT_NONE)
		return (0);
	sbi_console_puts("[k3misc] present: ");
	sbi_console_puts(compat);
	sbi_console_puts(" — ");
	sbi_console_puts(note);
	sbi_console_puts("\n");
	return (1);
}

int
k3misc_probe(unsigned long dtb, int live)
{
	int found = 0;

	(void) live;
	found += present(dtb, "spacemit,k1-flexcan", "CAN (crib flexcan.c)");
	found += present(dtb, "spacemit,k3-ri2s", "audio I2S (ri2s)");
	found += present(dtb, "spacemit,k1-i2s", "audio I2S (i2s)");
	found += present(dtb, "spacemit,k3-mailbox", "coprocessor mailbox");
	found += present(dtb, "spacemit,k3-rproc", "remote-processor (RCPU)");
	found += present(dtb, "spacemit,k3-tsensor", "thermal sensor");
	found += present(dtb, "spacemit,dpu-saturn",
	    "display DPU (large, deferred — llvmpipe + scanout plan)");
	return (found);
}
