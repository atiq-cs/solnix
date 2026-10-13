/*
 * k3usb.c — SpacemiT K3 USB (DWC3 + xHCI) SCAFFOLD.
 *   usb2@c0a00000 / usb3@cad00000 / usb3@81400000.. "spacemit,k1-dwc3"
 *   phy@... "spacemit,k3-usb2-phy" / "spacemit,k3-usb3-phy".
 *
 * The core is a standard Synopsys DWC3 (snps,dwc3 lineage) under a SpacemiT
 * wrapper: GCTL/GUSB2PHYCFG/GUSB3PIPECTL + an xHCI register bank. USB is a
 * LARGE stack port (xHCI host + a USB device framework); per the overnight-
 * task rule, this is SCAFFOLD-ONLY — discover the DWC3 core(s) + the phys and
 * document the remaining work. No MMIO is issued (a DWC3 core init that is
 * only half-done can wedge the controller).
 *
 * Crib: FreeBSD sys/dev/usb/controller/xhci.c + dwc3/dwc3.c; the combphy init
 * (shared with PCIe) has no BSD crib (Linux vendor driver only). illumos KPI
 * target is USBA/xhci. Effort: weeks (the stack, not the DWC3 glue).
 */

#include "sbi.h"

extern void kputhex(unsigned long v);

typedef long fdt_node_t;
#define	FDT_NONE	(-1L)
extern fdt_node_t fdt_find_compatible(unsigned long dtb, const char *pfx);
extern int fdt_node_reg(unsigned long dtb, fdt_node_t n, int i,
    unsigned long *base, unsigned long *size);

int
k3usb_probe(unsigned long dtb, int live)
{
	fdt_node_t n = fdt_find_compatible(dtb, "spacemit,k1-dwc3");
	unsigned long base = 0, size = 0;

	(void) live;
	if (n == FDT_NONE || fdt_node_reg(dtb, n, 0, &base, &size) != 0) {
		sbi_console_puts("[k3usb] no spacemit,k1-dwc3 node in boot DTB\n");
		return (0);
	}
	sbi_console_puts("[k3usb] dwc3 core @");
	kputhex(base);
	sbi_console_puts(" (SCAFFOLD). phys: ");
	if (fdt_find_compatible(dtb, "spacemit,k3-usb2-phy") != FDT_NONE)
		sbi_console_puts("usb2-phy ");
	if (fdt_find_compatible(dtb, "spacemit,k3-usb3-phy") != FDT_NONE)
		sbi_console_puts("usb3-phy ");
	sbi_console_puts("\n[k3usb] REMAINING WORK (weeks): combphy init "
	    "(no BSD crib), DWC3 GCTL host-mode, xHCI ring/TRB (FreeBSD "
	    "xhci.c crib), USBA device framework.\n");
	return (1);
}
