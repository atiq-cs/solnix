/*
 * OpenBSD <dev/pci/pcidevs.h> subset: the Intel AX2xx device IDs iwx claims.
 *
 * VENDORED VERBATIM (values only) from OpenBSD sys/dev/pci/pcidevs.h. These are
 * hardware facts, not code. Kept as a subset rather than the full 30k-line
 * generated file because iwx only matches these 18 plus the vendor id.
 *
 * These are also the IDs a driver_aliases entry needs, in the illumos
 * "pciVVVV,DDDD" spelling, so both spellings are given.
 */
#ifndef _IWX_COMPAT_DEV_PCI_PCIDEVS_H
#define _IWX_COMPAT_DEV_PCI_PCIDEVS_H

#define PCI_VENDOR_INTEL		0x8086

#define PCI_PRODUCT_INTEL_WL_22500_1	0x2723	/* Wi-Fi 6 AX200 */
#define PCI_PRODUCT_INTEL_WL_22500_2	0x02f0	/* Wi-Fi 6 AX201 */
#define PCI_PRODUCT_INTEL_WL_22500_3	0xa0f0	/* Wi-Fi 6 AX201 */
#define PCI_PRODUCT_INTEL_WL_22500_4	0x34f0	/* Wi-Fi 6 AX201 */
#define PCI_PRODUCT_INTEL_WL_22500_5	0x06f0	/* Wi-Fi 6 AX201 */
#define PCI_PRODUCT_INTEL_WL_22500_6	0x43f0	/* Wi-Fi 6 AX201 */
#define PCI_PRODUCT_INTEL_WL_22500_7	0x3df0	/* Wi-Fi 6 AX201 */
#define PCI_PRODUCT_INTEL_WL_22500_8	0x4df0	/* Wi-Fi 6 AX201 */
#define PCI_PRODUCT_INTEL_WL_22500_9	0x2725	/* Wi-Fi 6 AX210 */
#define PCI_PRODUCT_INTEL_WL_22500_10	0x2726	/* Wi-Fi 6 AX211 */
#define PCI_PRODUCT_INTEL_WL_22500_11	0x51f0	/* Wi-Fi 6 AX211 */
#define PCI_PRODUCT_INTEL_WL_22500_12	0x7a70	/* Wi-Fi 6 AX211 */
#define PCI_PRODUCT_INTEL_WL_22500_13	0x7af0	/* Wi-Fi 6 AX211 */
#define PCI_PRODUCT_INTEL_WL_22500_14	0x7e40	/* Wi-Fi 6 AX210 */
#define PCI_PRODUCT_INTEL_WL_22500_15	0x7f70	/* Wi-Fi 6 AX211 */
#define PCI_PRODUCT_INTEL_WL_22500_16	0x54f0	/* Wi-Fi 6 AX211 */
#define PCI_PRODUCT_INTEL_WL_22500_17	0x51f1	/* Wi-Fi 6 AX211 */
#define PCI_PRODUCT_INTEL_WL_22500_18	0x7740	/* Wi-Fi AX211 */

/*
 * The same 18 as illumos driver_aliases strings. The X1 Carbon Extreme's card
 * is an AX201, so one of 02f0/06f0/34f0/3df0/43f0/4df0/a0f0 -- which one is a
 * fact about the machine and must be read from prtconf, not assumed.
 */
#define IWX_PCI_ALIASES \
	"pci8086,2723", "pci8086,02f0", "pci8086,a0f0", "pci8086,34f0", \
	"pci8086,06f0", "pci8086,43f0", "pci8086,3df0", "pci8086,4df0", \
	"pci8086,2725", "pci8086,2726", "pci8086,51f0", "pci8086,7a70", \
	"pci8086,7af0", "pci8086,7e40", "pci8086,7f70", "pci8086,54f0", \
	"pci8086,51f1", "pci8086,7740"

#endif /* _IWX_COMPAT_DEV_PCI_PCIDEVS_H */
