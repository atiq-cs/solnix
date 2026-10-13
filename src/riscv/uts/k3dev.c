/*
 * k3dev.c — SpacemiT K3 Pico ITX peripheral bring-up dispatcher.
 *
 * One entry point, k3_bringup(dtb, live), called once from startup.c after the
 * SDHCI/UART bring-up while the low-MMIO gigapage is still identity-mapped
 * (VA==PA) and before page_init. It walks the per-driver DTB-driven probes for
 * the K3's Tier-2/Tier-3 peripherals (GMAC, I2C, SPI, DMA, PWM, USB/dwc3,
 * PCIe, eFuse, RTC, mailbox/rproc, audio). Each driver finds its own node(s)
 * by compatible string via fdt.c's of_utils accessors and reports the reg/
 * irq/clock wiring it discovered; drivers that need live DMA/PHY/link bring-up
 * print an explicit ON-SILICON TODO rather than half-initialising hardware.
 *
 * `live` != 0 means the boot DTB (a1) is the real K3 board, so a driver may
 * issue read-only identity-register MMIO; `live` == 0 (qemu-virt / embedded
 * blob) means bind-and-report only, no MMIO to addresses that are RAM on the
 * emulator. This mirrors uart_config()/gmac_probe()'s `live` discipline so the
 * SAME kernel is safe on qemu-virt and on silicon with no recompile.
 */

#include "sbi.h"

extern void kputdec(unsigned long v);

/* Per-driver DTB-driven probes (each in its own src/riscv/uts/<name>.c). */
extern int gmac_probe(unsigned long dtb, int live);
extern int k3i2c_probe(unsigned long dtb, int live);
extern int k3spi_probe(unsigned long dtb, int live);
extern int k3dma_probe(unsigned long dtb, int live);
extern int k3pwm_probe(unsigned long dtb, int live);
extern int k3usb_probe(unsigned long dtb, int live);
extern int k3pcie_probe(unsigned long dtb, int live);
extern int k3efuse_probe(unsigned long dtb, int live);
extern int k3rtc_probe(unsigned long dtb, int live);
extern int k3misc_probe(unsigned long dtb, int live);
/* k3ufs.c: THE root storage device (UFS). set_platform picks live-vs-model,
 * model_selftest proves the UFSHCI state machine, probe does the real attach. */
extern void k3ufs_set_platform(int is_k3);
extern void k3ufs_model_selftest(void);
extern int k3ufs_probe(unsigned long dtb, int live);

void
k3_bringup(unsigned long dtb, int live)
{
	int n = 0;

	sbi_console_puts("\n[k3dev] K3 peripheral bring-up (");
	sbi_console_puts(live ? "LIVE board DTB, read-only MMIO" :
	    "bind-only, no MMIO");
	sbi_console_puts("):\n");

	/*
	 * Tier 1 — UFS: THE root storage device. All three SD/MMC controllers
	 * are disabled in the K3 DTB; the okay on-disk root lives on UFS
	 * (ufshc@0xc0e00000). Bring it up FIRST so the console shows the storage
	 * path before the Tier-2/3 peripherals. The backend (live MMIO vs the
	 * faithful UFSHCI model) is chosen at runtime from `live`, exactly like
	 * sdhci. The model selftest proves the driver's HCE/DME/UTRL/READ(10)
	 * state machine on every boot; k3ufs_probe does the real DTB-driven
	 * attach that rootfs.c then reads the filesystem from.
	 */
	k3ufs_set_platform(live);
	k3ufs_model_selftest();
	n += k3ufs_probe(dtb, live);

	/* Tier 2: a useful networked system. */
	n += gmac_probe(dtb, live);
	n += k3i2c_probe(dtb, live);
	n += k3spi_probe(dtb, live);
	n += k3dma_probe(dtb, live);

	/* Tier 3: fuller hardware (scaffolds). */
	n += k3pwm_probe(dtb, live);
	n += k3usb_probe(dtb, live);
	n += k3pcie_probe(dtb, live);
	n += k3efuse_probe(dtb, live);
	n += k3rtc_probe(dtb, live);
	n += k3misc_probe(dtb, live);

	sbi_console_puts("[k3dev] ");
	kputdec((unsigned long)n);
	sbi_console_puts(" K3 peripheral(s) discovered + bound by FDT "
	    "compatible\n");
}
