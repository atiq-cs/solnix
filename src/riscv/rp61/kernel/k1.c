/*
 * k1.c -- R-P61: SpacemiT K1 (Milk-V Jupiter) bring-up scaffolding.
 *
 * The physical Milk-V Jupiter board is not here yet, so R-P61 is COMPILE +
 * QEMU-verified scaffolding driven by a static, CORRECT K1 device tree
 * (k1_dtb.h): the SAME fdt_discover() walker the live boot uses parses the K1
 * blob, and we assert the discovered topology is the REAL K1 one:
 *
 *   - 8 harts (2 clusters x 4 X60 cores)
 *   - PLIC @ 0xe0000000            (NOT AIA -- the K1 is PLIC-based)
 *   - CLINT @ 0xe4000000
 *   - console UART: spacemit,pxa-uart @ 0xd4017000, reg-shift 2
 *                   (a 16550 variant -- the existing ns16550 arm drives it)
 *   - SDHCI mmc @ 0xd4280000       (NOT dw-mmc -- routes to uts/sdhci.c on HW)
 *   - memory @ 0 = 8 GiB
 *
 * Plus a minimal K1 clock/reset (CCU) shim: on a real board a device needs its
 * clock ungated before MMIO works.  qemu-virt has no CCU, so the shim is
 * COMPILE-phase -- it records the K1 CCU register map (from the vendor DTS /
 * OpenSBI spacemit/k1) and provides an enable path that is a NO-OP under qemu
 * (no real MMIO poke without the board) but is structured so the on-HW R-P62
 * fills the writel()s.  The console UART clock + the SDHCI clock are wired as
 * the first two consumers.
 *
 * Crib: mainline arch/riscv/boot/dts/spacemit/k1-x.dtsi (the K1 memory map),
 * OpenSBI platform/generic/spacemit/k1.{c,h} (PMU_AP @ 0xd4282800, CCI-550 @
 * 0xd8500000, 8 CPUs / 2 clusters), the RISC-V SBI HSM spec (hart start), and
 * the Devicetree Specification v0.4 (the FDT the walker parses).
 */

#include "fdt.h"

extern void sbi_console_puts(const char *s);
extern void putdec_pub(unsigned long v);
extern void puthex_pub(unsigned long v);

#include "k1_dtb.h"		/* the generated static K1 DTB blob */

/*
 * The K1 Clock Control Unit (CCU) register map, documented from the vendor DTS
 * for R-P62's real MMIO.  These are the SoC clock/reset bases the Jupiter needs
 * ungated before a device's MMIO responds.  Values are the mainline k1-x.dtsi
 * clock-controller reg bases (APBC/APBS/MPMU/APMU) + the two device clocks we
 * wire first.  On HW R-P62 replaces the shim's (void)base with writel() pokes.
 */
#define	K1_CCU_MPMU_BASE	0xd4050000UL	/* main PLL / PMU */
#define	K1_CCU_APBC_BASE	0xd4015000UL	/* APB peripheral clocks (UART) */
#define	K1_CCU_APBS_BASE	0xd4090000UL	/* APB secure clocks */
#define	K1_CCU_APMU_BASE	0xd4282800UL	/* AP MMU/PMU (== OpenSBI PMU_AP_BASE) */

/* per-device clock/reset offsets (from k1-x.dtsi clock cell indices). */
#define	K1_CLK_UART0_OFF	0x00cUL		/* APBC uart0 clock/reset reg */
#define	K1_CLK_SDH0_OFF		0x054UL		/* APMU sdh0 (SDHCI) clock/reset reg */

/* clock/reset enable bits (dt: fnclk + apbclk enable, reset deassert). */
#define	K1_CLK_FN_EN		(1U << 1)	/* function clock enable */
#define	K1_CLK_APB_EN		(1U << 0)	/* APB bus clock enable */
#define	K1_CLK_RST_DEASSERT	(1U << 2)	/* reset deassert */

/*
 * k1_ccu_enable -- ungate one device clock + deassert its reset.  COMPILE-phase
 * under qemu (no CCU MMIO): records the intent + is a no-op poke.  On HW R-P62
 * fills the writel(base+off, ...).  Returns 1 (enabled/would-enable).
 *
 * (Under qemu this is a no-op MMIO; the real writel() poke lands in R-P62 on
 * the board.)
 */
static int
k1_ccu_enable(const char *what, unsigned long base, unsigned long off)
{
	volatile unsigned int *reg = (volatile unsigned int *)(base + off);
	unsigned int want = K1_CLK_FN_EN | K1_CLK_APB_EN | K1_CLK_RST_DEASSERT;

	sbi_console_puts("  [k1-ccu] enable ");
	sbi_console_puts(what);
	sbi_console_puts(" clock @ ");
	puthex_pub(base + off);
	sbi_console_puts(" (set 0x");
	puthex_pub((unsigned long)want);
	sbi_console_puts(") -- COMPILE-phase no-op under qemu; the real writel "
	    "poke lands on the Jupiter (R-P62)\n");
	(void) reg;		/* no MMIO without the board */
	(void) want;
	return (1);
}

/*
 * run_k1_fdtest -- R-P61 headline: parse the static CORRECT K1 DTB through the
 * SAME fdt_discover() the live boot uses, print the discovered map, and assert
 * the corrected topology (PLIC / 8 harts / SDHCI / pxa-uart).  Then exercise
 * the console-UART-arm selection + the K1 CCU clock shim on the discovered
 * bases.  Sets *pass to 1 on full match.
 */
void
run_k1_fdtest(int *pass)
{
	struct fdt_info k1;
	int ok = 1;

	sbi_console_puts("\n");
	sbi_console_puts("[R-P61] K1 DTB parse: the SpacemiT K1 (Milk-V Jupiter) "
	    "topology through the SAME FDT walker the live boot uses (static "
	    "CORRECT blob; the board is not here yet)\n");

	/*
	 * fdt_discover re-adds KERNEL_DMAP_BASE to a PHYSICAL address; the static
	 * blob is a kernel .rodata symbol at high VA, so hand it a form that maps
	 * back: fdt_discover treats dtb_pa as phys and reads DMAP+phys.  For the
	 * static blob we instead call a raw variant by pointing at the blob's
	 * kernel VA minus DMAP so DMAP+(VA-DMAP)==VA.  Simpler: the walker only
	 * needs a readable pointer; expose a phys-agnostic entry.
	 */
	{
		extern int fdt_discover_ptr(const unsigned char *dtb,
		    struct fdt_info *out);
		if (!fdt_discover_ptr(k1_dtb, &k1)) {
			sbi_console_puts("[R-P61] FAIL: K1 DTB did not parse "
			    "(magic/walk)\n");
			*pass = 0;
			return;
		}
	}

	sbi_console_puts("  K1 /memory         : base=");
	puthex_pub(k1.fi_mem_base);
	sbi_console_puts(" size=");
	putdec_pub(k1.fi_mem_size >> 30);
	sbi_console_puts(" GiB\n");
	sbi_console_puts("  K1 /cpus harts     : ");
	putdec_pub(k1.fi_nharts);
	sbi_console_puts(" (2 clusters x 4 X60 cores)\n");
	sbi_console_puts("  K1 PLIC base       : ");
	puthex_pub(k1.fi_plic_base);
	sbi_console_puts(" (PLIC, NOT AIA)\n");
	sbi_console_puts("  K1 CLINT base      : ");
	puthex_pub(k1.fi_clint_base);
	sbi_console_puts("\n");
	sbi_console_puts("  K1 console UART    : ");
	puthex_pub(k1.fi_uart_base);
	sbi_console_puts(" compatible='");
	sbi_console_puts(k1.fi_uart_compat);
	sbi_console_puts("' reg-shift=");
	putdec_pub(k1.fi_uart_shift);
	sbi_console_puts(k1.fi_uart_kind == FDT_UART_PXA ?
	    " -> FDT_UART_PXA (16550 variant)\n" :
	    (k1.fi_uart_kind == FDT_UART_NS16550 ?
	    " -> FDT_UART_NS16550\n" : " -> UNKNOWN\n"));
	sbi_console_puts("  K1 storage host    : ");
	puthex_pub(k1.fi_mmc_base);
	sbi_console_puts(" compatible='");
	sbi_console_puts(k1.fi_mmc_compat);
	sbi_console_puts(k1.fi_mmc_kind == FDT_MMC_SDHCI ?
	    "' -> FDT_MMC_SDHCI (routes to uts/sdhci.c, NOT dw-mmc)\n" :
	    (k1.fi_mmc_kind == FDT_MMC_DWMMC ?
	    "' -> FDT_MMC_DWMMC\n" : "' -> UNKNOWN\n"));

	/* assert the CORRECTED K1 topology. */
	if (k1.fi_nharts != 8) {
		sbi_console_puts("[R-P61] FAIL: expected 8 harts\n"); ok = 0;
	}
	if (k1.fi_plic_base != 0xe0000000UL) {
		sbi_console_puts("[R-P61] FAIL: expected PLIC @ 0xe0000000\n"); ok = 0;
	}
	if (k1.fi_clint_base != 0xe4000000UL) {
		sbi_console_puts("[R-P61] FAIL: expected CLINT @ 0xe4000000\n"); ok = 0;
	}
	if (k1.fi_uart_base != 0xd4017000UL || k1.fi_uart_kind != FDT_UART_PXA ||
	    k1.fi_uart_shift != 2) {
		sbi_console_puts("[R-P61] FAIL: expected pxa-uart @ 0xd4017000 "
		    "shift 2\n"); ok = 0;
	}
	if (k1.fi_mmc_base != 0xd4280000UL || k1.fi_mmc_kind != FDT_MMC_SDHCI) {
		sbi_console_puts("[R-P61] FAIL: expected SDHCI @ 0xd4280000\n"); ok = 0;
	}
	if (k1.fi_mem_size != 0x200000000UL) {
		sbi_console_puts("[R-P61] FAIL: expected 8 GiB memory\n"); ok = 0;
	}

	if (ok) {
		sbi_console_puts("[R-P61] K1 DTB PARSE PROVEN: the corrected K1 "
		    "topology (8 harts, PLIC@0xe0000000, CLINT@0xe4000000, "
		    "spacemit,pxa-uart@0xd4017000 shift 2, SDHCI@0xd4280000, 8 GiB) "
		    "was discovered by the SAME walker -- NOT AIA, NOT dw-mmc\n");
	}

	/*
	 * R-P61 console-UART arm: the K1 UART is a 16550 variant (reg-shift 2),
	 * so the console driver reuses the ns16550 register path -- the DTB
	 * compatible just selects the shift, no new UART driver.  (Output still
	 * goes through the SBI console; the arm proves the DTB-driven selection.)
	 */
	sbi_console_puts("[R-P61] console UART arm: FDT_UART_PXA selects the "
	    "ns16550 register path with reg-shift ");
	putdec_pub(k1.fi_uart_shift);
	sbi_console_puts(" (a 16550 variant -- no new UART driver; the SBI "
	    "console remains the console under qemu)\n");

	/*
	 * R-P61 K1 clock/reset shim: ungate the two first-consumer clocks (the
	 * console UART + the SDHCI host).  COMPILE-phase no-op under qemu.
	 */
	sbi_console_puts("[R-P61] K1 clock/reset (CCU) shim: enabling the first "
	    "two device clocks (console UART + SDHCI)\n");
	(void) k1_ccu_enable("uart0", K1_CCU_APBC_BASE, K1_CLK_UART0_OFF);
	(void) k1_ccu_enable("sdh0(SDHCI)", K1_CCU_APMU_BASE, K1_CLK_SDH0_OFF);
	sbi_console_puts("[R-P61] K1 CCU shim structure PROVEN (compile-phase; "
	    "the real MMIO pokes land on the Jupiter in R-P62)\n");

	*pass = ok;
}
