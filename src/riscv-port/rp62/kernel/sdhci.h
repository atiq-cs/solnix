/*
 * sdhci.h -- R-P62: the SDHCI-standard SD/eMMC driver seam (SpacemiT K1 root
 * medium).  Mirrors dwmmc.h: the driver sits behind bdev_strategy with the same
 * (blkno, buf, rw) block shape.  Under qemu-virt there is no SDHCI node, so
 * sdhci_set_base() is never given the K1 base, sdhci_present() stays 0, and
 * bdev_strategy keeps dispatching to virtio-blk (regression-safe).  On the K1
 * the FDT walker's fi_mmc_base (fi_mmc_kind == FDT_MMC_SDHCI) binds this driver.
 */
#ifndef	_RP62_SDHCI_H
#define	_RP62_SDHCI_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * sdhci_set_base -- bind the driver to the DTB-discovered SDHCI controller MMIO
 * base (fdt_info.fi_mmc_base when fi_mmc_kind == FDT_MMC_SDHCI, e.g. the K1
 * 0xd4280000).  A nonzero base makes sdhci_present() eligible.
 */
extern void sdhci_set_base(unsigned long base);

/*
 * sdhci_probe -- one-time card bring-up (CMD0/CMD8/ACMD41/CMD2/CMD3/CMD7/CMD16).
 * Returns 1 if a card was initialized and the driver is live, 0 otherwise (no
 * base bound, or no card -- always under qemu-virt).
 */
extern int sdhci_probe(void);

/* sdhci_present -- 1 once sdhci_probe() succeeded, else 0 (0 under qemu). */
extern int sdhci_present(void);

/*
 * sdhci_strategy -- transfer ONE 512-byte sector.  rw==0 reads sector `blkno`
 * into buf (CMD17), rw==1 writes buf to sector `blkno` (CMD24), PIO Buffer Data
 * Port.  The same (blkno, buf, rw) -> 0/-1 shape as dwmmc_strategy /
 * virtio_blk_strategy so bdev_strategy dispatches to it identically.
 */
extern int sdhci_strategy(unsigned long blkno, unsigned char *buf, int rw);

#ifdef __cplusplus
}
#endif

#endif	/* _RP62_SDHCI_H */
