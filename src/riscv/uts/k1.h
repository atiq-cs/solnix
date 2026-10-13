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
	int uart_is_dw;			/* 16550-family console UART present */
	int uart_io32;			/* reg-io-width == 4 (32-bit MMIO) */
	unsigned long uart_irq;		/* first `interrupts' cell (APLIC source) */
	unsigned long sdhci_base;	int sdhci_present;
	unsigned long aplic_base;	int aplic_present;
	unsigned long imsic_base;	int imsic_present;
};

/* fdt.c: walk a K1 DTB, fill *out, print the gate-1 proof line. Returns 1 iff
 * the four K1 signature devices (dw-apb-uart, sdhci, aplic, imsic) are present. */
extern int fdt_k1_summary(unsigned long dtb, struct k1_devs *out);

/*
 * aia.c: bind the AIA driver's IMSIC/APLIC/UART MMIO bases + UART IRQ to the
 * values the boot DTB reported, instead of the compiled-in qemu-virt constants.
 * `uart_shift`/`uart_io32` carry the UART's reg-shift and reg-io-width so the
 * self-test pokes the right register offsets (K3 UART is shift=2, 32-bit).
 * Any base/irq given as 0 keeps that device's qemu-virt fallback (so a DTB that
 * omits a node still boots on qemu-virt). Call once, before aia_selftest().
 */
extern void aia_configure(unsigned long imsic_base, unsigned long aplic_base,
    unsigned long uart_base, unsigned long uart_irq,
    unsigned int uart_shift, int uart_io32);

/* uart.c: bind the console to base/reg-shift/io-width, and the gate-2 proof.
 * `live` nonzero => the base came from the firmware's own DTB and MMIO is safe;
 * 0 => report the binding but issue NO MMIO (a TX to a non-UART spins forever
 * on LSR.THRE rather than failing). */
extern void uart_config(unsigned long base, unsigned int shift, int io32);
extern void dw_apb_uart_selftest(unsigned long base, unsigned int shift,
    int io32, int live);

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

/*
 * uart.c: the base the console is CURRENTLY bound to. Exists so the boot log
 * can state the bound address rather than the address someone believed was
 * bound. Binding the console to a compiled-in constant instead of the live
 * boot DTB is a silent infinite spin on any board whose UART is elsewhere
 * (see the uart.c banner).
 */
extern unsigned long uart_current_base(void);

#endif	/* _K1_H */
