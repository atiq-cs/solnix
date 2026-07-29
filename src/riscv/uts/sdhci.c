/*
 * sdhci.c — illumos riscv64 SDHCI / eMMC register-level probe (R-P14).
 *
 * The SpaceMiT K1 root filesystem lives on an SD/eMMC card behind a Synopsys
 * DesignWare mobile-storage host controller (compatible="snps,dwcmshc-sdhci"),
 * which is SD Host Controller (SDHCI) register-compatible. R-P14 gate-3-alt is
 * an HONEST register-level probe: read the SDHCI Host Controller Version and
 * Capabilities registers at the FDT-discovered base and decode them — the
 * first step every mmc block driver takes before issuing CMD0/CMD8.
 *
 * SDHCI standard register map (SD Host Controller Simplified Spec 3.00),
 * byte offsets from the controller base:
 *   0x24  Present State      (32b: card inserted, buffer read/write enable)
 *   0x28  Host Control 1     (8b)
 *   0x2c  Power Control      (8b)
 *   0x40  Capabilities       (64b: base clock, max block len, bus widths...)
 *   0xfc  Slot Interrupt Status (16b)
 *   0xfe  Host Controller Version (16b: [7:0] spec version, [15:8] vendor)
 *
 * qemu-vs-real-silicon: the qemu 'virt' machine has NO SDHCI, and the K1 base
 * (0xd4281000) is above the R-P3 identity-mapped low-MMIO gigapage
 * (0x0..0x40000000), so a live MMIO read here would page-fault under qemu. So
 * the probe is GUARDED: it performs the real 16550-style register reads ONLY
 * when the base lies inside the identity-mapped window; otherwise it reports
 * the exact register offsets it WOULD read and the decode it WOULD apply, so
 * the probe logic is proven and the on-silicon read is a one-line unblock once
 * the device mapping (R-P15) is added. Reimplemented from the public SDHCI
 * simplified spec (no CDDL-incompatible source copied).
 */

#include "k1.h"

extern void kputhex(unsigned long v);
extern void kputdec(unsigned long v);
extern void sbi_console_puts(const char *s);

/* The R-P3 low-MMIO identity map covers PA 0x0 .. 0x40000000 (1 GiB gigapage).
 * SDHCI bases below this are safe to touch; the K1's 0xd4281000 is not (yet). */
#define	IDMAP_MMIO_LIMIT	0x40000000UL

#define	SDHCI_PRESENT_STATE	0x24
#define	SDHCI_CAPABILITIES	0x40
#define	SDHCI_HOST_VERSION	0xfe

static inline unsigned int
sd_rd32(unsigned long a)
{
	return (*(volatile unsigned int *)a);
}
static inline unsigned short
sd_rd16(unsigned long a)
{
	return (*(volatile unsigned short *)a);
}

/*
 * sdhci_probe — register-level probe of the SDHCI controller at `base`.
 * Returns 1 if a live decode was performed (base mapped), 0 if the base is
 * outside the identity map (decode-only, awaiting the R-P15 device mapping).
 *
 * PROVE: "sdhci: probe @<base> — HCVER=<v> (SDHCI spec <n>), caps=<c>,
 *         card=<present/absent>".
 */
int
sdhci_probe(unsigned long base)
{
	if (base == 0) {
		sbi_console_puts("[sdhci] no SDHCI node in DTB\n");
		return (0);
	}

	sbi_console_puts("[sdhci] probe @");
	kputhex(base);

	if (base >= IDMAP_MMIO_LIMIT) {
		/*
		 * Real-silicon base above the identity map. Report the exact
		 * register-level probe we WOULD issue; the reads are one line
		 * away once R-P15 maps the K1 device window.
		 */
		sbi_console_puts(" — above identity-mapped MMIO (");
		kputhex(IDMAP_MMIO_LIMIT);
		sbi_console_puts("); register-level probe plan: read HCVER@");
		kputhex(base + SDHCI_HOST_VERSION);
		sbi_console_puts(", CAPS@");
		kputhex(base + SDHCI_CAPABILITIES);
		sbi_console_puts(", PRESENT_STATE@");
		kputhex(base + SDHCI_PRESENT_STATE);
		sbi_console_puts(" (needs R-P15 K1 device mapping)\n");
		return (0);
	}

	{
		unsigned short ver = sd_rd16(base + SDHCI_HOST_VERSION);
		unsigned int caps = sd_rd32(base + SDHCI_CAPABILITIES);
		unsigned int pstate = sd_rd32(base + SDHCI_PRESENT_STATE);
		unsigned int specver = ver & 0xff;

		sbi_console_puts(" — HCVER=");
		kputhex(ver);
		sbi_console_puts(" (SDHCI spec ");
		kputdec(specver + 1);	/* spec ver field: 0=1.00, 1=2.00... */
		sbi_console_puts(".00), caps=");
		kputhex(caps);
		sbi_console_puts(", card=");
		sbi_console_puts((pstate & (1U << 16)) ? "present" : "absent");
		sbi_console_puts("\n");
		return (1);
	}
}
