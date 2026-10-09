/*
 * OpenBSD <dev/pci/pcidevs.h> subset: the Intel device IDs iwm(4) claims.
 *
 * Values copied from OpenBSD sys/dev/pci/pcidevs (the generator input; the
 * same values the generated pcidevs.h carries). They are hardware facts, not
 * code. iwm/compat/ is searched before iwx/compat/, so this header replaces
 * the AX2xx-only subset when compiling iwm.
 *
 * The X1 Extreme Gen 1 ("dixi") wifi is WL_9560_2 = 8086:a370 (Cannon Lake
 * PCH CNVi, Jefferson Peak RF, subsystem 8086:0030). Its illumos alias is
 * "pci8086,a370".
 */
#ifndef _IWM_COMPAT_DEV_PCI_PCIDEVS_H
#define _IWM_COMPAT_DEV_PCI_PCIDEVS_H

#define PCI_VENDOR_INTEL		0x8086

#define PCI_PRODUCT_INTEL_WL_3160_1	0x08b3	/* AC 3160 */
#define PCI_PRODUCT_INTEL_WL_3160_2	0x08b4	/* AC 3160 */
#define PCI_PRODUCT_INTEL_WL_3165_1	0x3165	/* AC 3165 */
#define PCI_PRODUCT_INTEL_WL_3165_2	0x3166	/* AC 3165 */
#define PCI_PRODUCT_INTEL_WL_3168_1	0x24fb	/* AC 3168 */
#define PCI_PRODUCT_INTEL_WL_7260_1	0x08b1	/* AC 7260 */
#define PCI_PRODUCT_INTEL_WL_7260_2	0x08b2	/* AC 7260 */
#define PCI_PRODUCT_INTEL_WL_7265_1	0x095a	/* AC 7265 */
#define PCI_PRODUCT_INTEL_WL_7265_2	0x095b	/* AC 7265 */
#define PCI_PRODUCT_INTEL_WL_8260_1	0x24f3	/* AC 8260 */
#define PCI_PRODUCT_INTEL_WL_8260_2	0x24f4	/* AC 8260 */
#define PCI_PRODUCT_INTEL_WL_8265_1	0x24fd	/* AC 8265 */
#define PCI_PRODUCT_INTEL_WL_9260_1	0x2526	/* AC 9260 */
#define PCI_PRODUCT_INTEL_WL_9560_1	0x9df0	/* AC 9560 */
#define PCI_PRODUCT_INTEL_WL_9560_2	0xa370	/* AC 9560 (CNVi, Cannon Lake PCH) */
#define PCI_PRODUCT_INTEL_WL_9560_3	0x31dc	/* AC 9560 */

#endif /* _IWM_COMPAT_DEV_PCI_PCIDEVS_H */
