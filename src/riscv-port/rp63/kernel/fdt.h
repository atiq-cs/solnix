/*
 * fdt.h -- R-P57: a minimal flattened-device-tree (FDT/DTB) parser interface.
 *
 * OpenSBI hands the S-mode kernel a pointer to the flattened device tree in a1
 * (a0 = boot hartid) per the RISC-V SBI boot convention; on qemu-virt the DTB
 * lands in DRAM (rp56 observed dtb=0x82200000).  fdt_discover() walks that blob
 * to learn the machine's REAL memory size, hart count, and the device MMIO base
 * addresses (virtio-mmio, PLIC, CLINT) -- the values that are HARDCODED for
 * qemu-virt today and DIFFER on real boards.  This is the real-hardware enabler:
 * a real RISC-V board (SiFive Unmatched, VisionFive 2, ...) always supplies a
 * DTB; discovering the layout from it is how the same kernel boots on hardware
 * whose MMIO map is not qemu-virt's.
 *
 * Crib: the Devicetree Specification v0.4 (the flattened DTB binary format --
 * fdt_header, the FDT_BEGIN_NODE/END_NODE/PROP/NOP/END struct tokens, the
 * strings block) + libfdt's fdt.h / fdt_ro.c walk idiom, reduced to a single
 * forward scan (no libfdt dependency).
 */
#ifndef	_RP57_FDT_H
#define	_RP57_FDT_H

#ifdef __cplusplus
extern "C" {
#endif

struct fdt_info {
	int		fi_valid;	/* 1 if magic matched + walk succeeded */
	unsigned long	fi_dtb_pa;	/* the physical DTB address we parsed */
	unsigned long	fi_totalsize;	/* fdt_header.totalsize */
	unsigned long	fi_mem_base;	/* /memory reg base (phys) */
	unsigned long	fi_mem_size;	/* /memory reg size (bytes) */
	unsigned int	fi_nharts;	/* count of enabled /cpus/cpu@N nodes */
	unsigned long	fi_virtio_base;	/* first /soc/virtio_mmio@ reg base, or 0 */
	unsigned int	fi_nvirtio;	/* count of virtio_mmio nodes seen */
	unsigned long	fi_plic_base;	/* /soc/plic@ reg base, or 0 */
	unsigned long	fi_clint_base;	/* /soc/clint@ (or /cpus timer) base, or 0 */
	unsigned long	fi_uart_base;	/* first ns16550/DW-APB serial@ reg base, 0 */
	unsigned long	fi_mmc_base;	/* dw-mmc / cadence-sdhci mmc@ reg base, 0 */
	unsigned long	fi_net_base;	/* first ethernet@ MAC reg base, or 0 */
	unsigned int	fi_net_irq;	/* net MAC PLIC interrupt number, or 0 */
	unsigned int	fi_uart_shift;	/* reg-shift for the console UART (0 or 2) */
	int		fi_uart_kind;	/* FDT_UART_* console UART type from compatible */
	int		fi_mmc_kind;	/* FDT_MMC_* storage host type from compatible */
	int		fi_net_kind;	/* FDT_NET_* NIC type from compatible */
	char		fi_uart_compat[48];	/* raw UART compatible[0] string */
	char		fi_mmc_compat[48];	/* raw mmc compatible[0] string */
	char		fi_net_compat[48];	/* raw ethernet compatible[0] string */
};

/* console UART kinds selected from the DTB compatible string. */
#define	FDT_UART_UNKNOWN	0
#define	FDT_UART_NS16550	1	/* ns16550a / snps,dw-apb-uart (shift 0) */
#define	FDT_UART_PXA		2	/* spacemit,pxa-uart: 16550 variant, shift 2 */

/* storage host kinds selected from the DTB compatible string. */
#define	FDT_MMC_UNKNOWN	0
#define	FDT_MMC_DWMMC	1	/* snps,dw-mshc dw-mmc (VF2/Unmatched) */
#define	FDT_MMC_SDHCI	2	/* SDHCI (SpacemiT K1 -> uts/sdhci.c) */

/* NIC kinds selected from the DTB compatible string. */
#define	FDT_NET_UNKNOWN		0
#define	FDT_NET_K1X_EMAC	1	/* spacemit,k1x-emac 1GbE (Milk-V Jupiter) */

/*
 * fdt_discover -- parse the DTB at physical address dtb_pa (reached through the
 * kernel high direct-map, KERNEL_DMAP_BASE + dtb_pa).  Fills *out.  Returns 1 on
 * a valid FDT (magic 0xd00dfeed matched), 0 otherwise.
 */
extern int fdt_discover(unsigned long dtb_pa, struct fdt_info *out);
extern int fdt_discover_ptr(const unsigned char *dtb, struct fdt_info *out);

#ifdef __cplusplus
}
#endif

#endif	/* _RP57_FDT_H */
