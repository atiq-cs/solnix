/*
 * dwmmc.h -- R-P58: a Synopsys DesignWare MMC (dw-mmc / "snps,dw-mshc") SD/eMMC
 * host driver behind the bdev_strategy block seam -- the real-hardware root
 * medium on the StarFive VisionFive 2 (JH7110) and most RISC-V SoCs.
 *
 * qemu-virt has NO dw-mmc controller (its block device is virtio-blk), so this
 * driver CANNOT run under qemu -- it is a COMPILE + link + structured skeleton
 * for a real board: the register layout, the CMD/DATA FSM, a single-sector PIO
 * read, selected at runtime by the DTB-discovered mmc controller base.  Under
 * qemu dwmmc_present() returns 0 and bdev_strategy stays on virtio-blk
 * (regression-safe); on a board the FDT walker's fi_mmc_base binds this driver.
 */
#ifndef	_RP58_DWMMC_H
#define	_RP58_DWMMC_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * dwmmc_set_base -- bind the driver to the DTB-discovered controller MMIO base
 * (fdt_info.fi_mmc_base).  A nonzero base makes dwmmc_present() eligible; the
 * card-init probe still has to succeed for it to report present.
 */
extern void dwmmc_set_base(unsigned long base);

/*
 * dwmmc_probe -- one-time card bring-up (CMD0/CMD8/ACMD41/CMD2/CMD3/CMD9/CMD7/
 * CMD16).  Returns 1 if an SD card was initialized and the driver is live, 0
 * otherwise (no base bound, or no card -- e.g. always under qemu-virt).
 */
extern int dwmmc_probe(void);

/* dwmmc_present -- 1 once dwmmc_probe() succeeded, else 0 (0 under qemu). */
extern int dwmmc_present(void);

/*
 * dwmmc_strategy -- transfer ONE 512-byte sector.  rw==0 reads sector `blkno`
 * into buf (CMD17), rw==1 writes buf to sector `blkno` (CMD24), PIO FIFO.  The
 * same (blkno, buf, rw) -> 0/err shape as virtio_blk_strategy so bdev_strategy
 * dispatches to it identically.  Returns 0 on success, -1 on error.
 */
extern int dwmmc_strategy(unsigned long blkno, unsigned char *buf, int rw);

#ifdef __cplusplus
}
#endif

#endif	/* _RP58_DWMMC_H */
