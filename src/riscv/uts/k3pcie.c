/*
 * k3pcie.c — SpacemiT K3 PCIe root complex SCAFFOLD.
 *   pcie@80000000 "spacemit,k1-pcie" (DesignWare DWC PCIe RC)
 *   phy-pcie@81d00000.. "spacemit,k3-pcie-phy".
 *
 * The RC core is a Synopsys DesignWare PCIe (dbi/dbi2/atu/config/link reg
 * banks named in reg-names), max-link-speed 3 (Gen3), num-lanes up to 8. This
 * is a LARGE port (DWC core + an illumos PCI/PCIe host-bridge nexus + the
 * combphy bring-up + MSI-to-IMSIC); per the overnight rule it is SCAFFOLD-ONLY
 * — discover the RC + phys and document remaining work. No MMIO issued.
 *
 * Crib: FreeBSD sys/dev/pci/pci_dw.c (DWC base) + pci_dw_mv.c (platform glue)
 * + pci_host_generic.c; illumos KPI is the PCI/PCIe nexus + pci_config_*. The
 * combphy init is the K3-specific hard part (Linux vendor driver only).
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
k3pcie_probe(unsigned long dtb, int live)
{
	fdt_node_t n = fdt_find_compatible(dtb, "spacemit,k1-pcie");
	unsigned long base = 0, size = 0;

	(void) live;
	if (n == FDT_NONE || fdt_node_reg(dtb, n, 0, &base, &size) != 0) {
		sbi_console_puts("[k3pcie] no spacemit,k1-pcie node in boot "
		    "DTB\n");
		return (0);
	}
	sbi_console_puts("[k3pcie] dwc-pcie RC dbi@");
	kputhex(base);
	sbi_console_puts(" link-speed Gen");
	kputdec((unsigned long)fdt_node_prop_u32(dtb, n, "max-link-speed", 0));
	sbi_console_puts(" lanes ");
	kputdec((unsigned long)fdt_node_prop_u32(dtb, n, "num-lanes", 0));
	sbi_console_puts(" (SCAFFOLD)\n");
	if (fdt_find_compatible(dtb, "spacemit,k3-pcie-phy") != FDT_NONE)
		sbi_console_puts("[k3pcie] k3-pcie-phy present\n");
	sbi_console_puts("[k3pcie] REMAINING WORK (weeks): combphy init (no "
	    "BSD crib), DWC link-up poll, iATU windows, illumos host-bridge "
	    "nexus, MSI->IMSIC. Gates NVMe.\n");
	return (1);
}
