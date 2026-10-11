/*
 * OpenBSD <dev/pci/pcireg.h> subset: the config-space offsets and bits iwx uses.
 *
 * Values are architectural PCI/PCIe constants, identical on every OS. REAL.
 */
#ifndef _IWX_COMPAT_DEV_PCI_PCIREG_H
#define _IWX_COMPAT_DEV_PCI_PCIREG_H

#define PCI_COMMAND_STATUS_REG		0x04
#define PCI_COMMAND_INTERRUPT_DISABLE	0x00000400
#define PCI_SUBSYS_ID_REG		0x2c
#define PCI_MAPREG_START		0x10
#define PCI_MAPREG_TYPE_MEM		0x00000000
#define PCI_MAPREG_TYPE_IO		0x00000001

#define PCI_CAP_PCIEXPRESS		0x10

/* PCIe capability-relative offsets. */
#define PCI_PCIE_LCSR			0x10
#define PCI_PCIE_LCSR_ASPM_L0S		0x00000001
#define PCI_PCIE_LCSR_ASPM_L1		0x00000002
#define PCI_PCIE_DCSR2			0x28
#define PCI_PCIE_DCSR2_LTREN		0x00000400

#endif /* _IWX_COMPAT_DEV_PCI_PCIREG_H */
