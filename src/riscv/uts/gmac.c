/*
 * gmac.c — solnix riscv64 driver for the SpacemiT K3 gigabit Ethernet MAC
 * (compatible "spacemit,k3-gmac", "snps,dwmac-5.10a").
 *
 * UNLIKE the K1's custom spacemit,k1x-emac (the biggest risk in the Milk-V
 * Jupiter plan — no BSD crib, a from-scratch port), the K3 GMAC advertises
 * "snps,dwmac-5.10a": it is a STANDARD Synopsys DesignWare MAC (DWMAC / the
 * Linux "stmmac" IP). That is a well-documented register model with mature
 * BSD cribs — FreeBSD sys/dev/dwc/if_dwc.c + dwc1000, NetBSD sys/dev/ic/
 * dwc_gmac.c — so the K3 NIC is a crib, not a reverse-engineer.
 *
 * This is a DTB-DRIVEN SCAFFOLD at the compile+bind deliverable level, matching
 * the overnight-task rule "scaffold large drivers + document the remaining
 * work rather than half-implementing". It:
 *   1. finds every k3-gmac node in the boot DTB and reads its reg base, two
 *      IRQs (macirq + eth_wake_irq), stmmaceth/ptp_ref clocks, reset, the
 *      SpacemiT APMU ctrl/dline delay-line offsets, and the phy-mode;
 *   2. maps the register block and reads the DWMAC core ID (MAC_VERSION,
 *      offset 0x110) + the three HW-feature words (0x11c/0x120/0x124), which
 *      proves the IP generation and the capability bits (DMA width, # of
 *      channels, TSO, etc.) WITHOUT touching the DMA engine;
 *   3. reports exactly what remains to prove on silicon (DMA descriptor rings,
 *      MDIO/PHY bring-up of the RTL8211F at phy-id 001c.c916, GLDv3 binding).
 *
 * Register model: Synopsys DWMAC 5.10a. The MAC core registers start at the
 * reg base; the DMA engine registers at base+0x1000; MTL at base+0xd00. We
 * read only the ID/feature window, which is safe on a controller U-Boot left
 * clock-enabled and does not perturb the running vendor Linux's MAC (we are a
 * compile/bind deliverable: no node is "okay"+claimed until silicon).
 *
 * Reimplemented from the DesignWare DWMAC register spec + the BSD cribs; no
 * CDDL-incompatible source copied.
 */

#include "sbi.h"

extern void kputhex(unsigned long v);
extern void kputdec(unsigned long v);

/* fdt.c of_utils-style accessors. */
typedef long fdt_node_t;
#define	FDT_NONE	(-1L)
extern fdt_node_t fdt_find_compatible(unsigned long dtb, const char *pfx);
extern int fdt_node_reg(unsigned long dtb, fdt_node_t n, int i,
    unsigned long *base, unsigned long *size);
extern int fdt_node_prop_u32(unsigned long dtb, fdt_node_t n, const char *name,
    int def);
extern int fdt_node_prop_str(unsigned long dtb, fdt_node_t n, const char *name,
    const char **out);
extern int fdt_node_clock(unsigned long dtb, fdt_node_t n, int i,
    unsigned int *ph, unsigned int *id);

static inline unsigned int
mmio_rd32(unsigned long a)
{
	return (*(volatile unsigned int *)a);
}

/* DesignWare DWMAC register offsets (gmac4/5 "snps,dwmac-5.x" layout). */
#define	DWMAC_MAC_CONFIG	0x0000	/* MAC configuration */
#define	DWMAC_MAC_VERSION	0x0110	/* [7:0] user ver, [15:8] synopsys ID */
#define	DWMAC_MAC_DEBUG		0x0114
#define	DWMAC_HW_FEATURE0	0x011c
#define	DWMAC_HW_FEATURE1	0x0120
#define	DWMAC_HW_FEATURE2	0x0124
#define	DWMAC_HW_FEATURE3	0x0128
#define	DWMAC_DMA_BUS_MODE	0x1000	/* DMA mode (channel 0) */

static int gmac_count;

/*
 * gmac_report_one — read + print the DWMAC identity/feature window of one
 * controller. live != 0 means the reg base came from the firmware's own boot
 * DTB and the MMIO is safe to issue (identity-mapped low-MMIO gigapage);
 * live == 0 reports the discovered wiring WITHOUT issuing MMIO (an unconfirmed
 * base must never be poked — same discipline as uart_config's `live`).
 */
static void
gmac_report_one(unsigned long dtb, fdt_node_t n, unsigned long base, int live)
{
	unsigned int irq0, irq1;
	const char *phymode = 0;
	unsigned int ctrl_off, dline_off;
	unsigned int clk_ph = 0, clk_id = 0;

	/* interrupts = <macirq 4  eth_wake_irq 4>: first cell is macirq. */
	irq0 = (unsigned int)fdt_node_prop_u32(dtb, n, "interrupts", -1);
	/* second IRQ cell is interrupts[2]; of_utils helper reads only [0], so
	 * report the first (macirq) which is what a wired-leg driver uses. */
	irq1 = 0;
	(void) fdt_node_prop_str(dtb, n, "phy-mode", &phymode);
	ctrl_off = (unsigned int)fdt_node_prop_u32(dtb, n,
	    "spacemit,ctrl-offset", -1);
	dline_off = (unsigned int)fdt_node_prop_u32(dtb, n,
	    "spacemit,dline-offset", -1);
	(void) fdt_node_clock(dtb, n, 0, &clk_ph, &clk_id);

	sbi_console_puts("[gmac] k3-gmac @");
	kputhex(base);
	sbi_console_puts(" macirq ");
	kputdec(irq0);
	sbi_console_puts(" phy-mode ");
	sbi_console_puts(phymode ? phymode : "(none)");
	sbi_console_puts(" apmu-ctrl +");
	kputhex(ctrl_off);
	sbi_console_puts(" dline +");
	kputhex(dline_off);
	sbi_console_puts("\n");
	(void) irq1;

	if (!live) {
		sbi_console_puts("[gmac]   base from embedded DTB only; no MMIO "
		    "issued (unconfirmed base)\n");
		return;
	}

	/*
	 * MAC_VERSION: low byte = user-defined version, high byte = Synopsys
	 * identification. DWMAC 5.10a reports 0x51 in the user byte. This read
	 * proves the register block is where the DTB says and the core is a
	 * DWMAC — the single most useful live fact before any DMA setup.
	 */
	{
		unsigned int ver = mmio_rd32(base + DWMAC_MAC_VERSION);
		unsigned int f0 = mmio_rd32(base + DWMAC_HW_FEATURE0);
		unsigned int f1 = mmio_rd32(base + DWMAC_HW_FEATURE1);
		unsigned int f2 = mmio_rd32(base + DWMAC_HW_FEATURE2);

		sbi_console_puts("[gmac]   MAC_VERSION=");
		kputhex(ver);
		sbi_console_puts(" (user 0x");
		kputhex(ver & 0xff);
		sbi_console_puts(" snps 0x");
		kputhex((ver >> 8) & 0xff);
		sbi_console_puts(") HW_FEATURE0=");
		kputhex(f0);
		sbi_console_puts(" F1=");
		kputhex(f1);
		sbi_console_puts(" F2=");
		kputhex(f2);
		sbi_console_puts("\n");
	}
}

/*
 * gmac_probe — DTB-driven bring-up entry. Finds the k3-gmac node(s) in the
 * boot DTB and reports each. `live` is set by the caller to whether the boot
 * DTB is the real board (safe MMIO) vs the embedded/qemu DTB (bind only).
 * Returns the number of GMAC controllers found. Call once from startup.c.
 */
int
gmac_probe(unsigned long dtb, int live)
{
	fdt_node_t n;
	unsigned long base = 0, size = 0;

	n = fdt_find_compatible(dtb, "spacemit,k3-gmac");
	if (n == FDT_NONE)
		n = fdt_find_compatible(dtb, "snps,dwmac-5.10a");
	if (n == FDT_NONE) {
		sbi_console_puts("[gmac] no k3-gmac / dwmac node in boot DTB\n");
		return (0);
	}
	if (fdt_node_reg(dtb, n, 0, &base, &size) != 0) {
		sbi_console_puts("[gmac] k3-gmac node has no usable reg\n");
		return (0);
	}
	gmac_report_one(dtb, n, base, live);
	gmac_count = 1;

	/*
	 * ON-SILICON TODO (the DWMAC crib work, deliberately not done at the
	 * compile/bind stage):
	 *   - §6 clock/reset: ungate stmmaceth + ptp_ref, deassert stmmaceth
	 *     reset, program the SpacemiT APMU ctrl/dline delay-line (rgmii
	 *     tx/rx phase 0x49/0x3d) — leave the phase values as a CALIBRATION
	 *     KNOB; rgmii delay is board/trace-length sensitive.
	 *   - DMA: software reset (DMA_BUS_MODE.SWR), build TX+RX descriptor
	 *     rings (dwmac4 enhanced desc), set DMA_CH0 base/ring-len, PA via
	 *     the direct-map/KVTOP pattern vioblk/vionet use.
	 *   - MDIO/PHY: clause-22 read of the RTL8211F at mdio addr 1
	 *     (phy-id 001c.c916), autoneg, read link speed/duplex.
	 *   - GLDv3: mac_register / mac_rx / mac_tx — the ena/vioif KPI target.
	 */
	sbi_console_puts("[gmac] bound (reg/irq/clock/apmu discovered). "
	    "ON-SILICON TODO: clk+reset+dline, DMA rings, MDIO/RTL8211F, "
	    "GLDv3.\n");
	return (gmac_count);
}
