/*
 * k1.h — SpaceMiT K1 board bring-up interfaces (R-P14).
 *
 * The K1 device set discovered from the board DTB by fdt_k1_summary(), plus the
 * driver-bind + probe entry points the R-P14 gates call. Shared so startup.c
 * can hand the discovered bases to the dw-apb-uart console and the sdhci probe.
 */

#ifndef	_K1_H
#define	_K1_H

/* Devices fdt_k1_summary discovers from a real SpaceMiT K1 devicetree. */
struct k1_devs {
	unsigned long mem_base, mem_size;
	unsigned long uart_base;	unsigned int uart_shift;
	int uart_is_dw;			/* snps,dw-apb-uart present */
	unsigned long sdhci_base;	int sdhci_present;
	unsigned long aplic_base;	int aplic_present;
	unsigned long imsic_base;	int imsic_present;
};

/* fdt.c: walk a K1 DTB, fill *out, print the gate-1 proof line. Returns 1 iff
 * the four K1 signature devices (dw-apb-uart, sdhci, aplic, imsic) are present. */
extern int fdt_k1_summary(unsigned long dtb, struct k1_devs *out);

/* uart.c: bind the console to base/reg-shift/io-width, and the gate-2 proof. */
extern void uart_config(unsigned long base, unsigned int shift, int io32);
extern void dw_apb_uart_selftest(unsigned long base, unsigned int shift,
    int io32);

/* sdhci.c: gate-3-alt register-level SDHCI/eMMC probe. */
extern int sdhci_probe(unsigned long base);

/* sdhci.c: R-P16 runtime board-detect. is_k1 != 0 => live MMIO on real K1
 * silicon; 0 => qemu-virt, drive the faithful in-kernel SDHCI+SD model. Set
 * once from the boot DTB (see startup.c board detect). */
extern void sdhci_set_platform(int is_k1);

/* sdhci.c: R-P15 mmc block-driver self-test (CMD0/8/ACMD41/2/3/7 + CMD17). */
extern void sdhci_model_selftest(void);

/* uart.c: arithmetic proof of the reg-shift register-offset math (no MMIO). */
extern void uart_regshift_check(unsigned int shift);

#endif	/* _K1_H */
