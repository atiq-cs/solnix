/*
 * sbi.h — illumos riscv64 SBI console interface (R-P2).
 *
 * Minimal public surface of the SBI layer for the R-P2 banner. Grows into a
 * full SBI header (timer/IPI/HSM/reset) in R-P3/R-P4.
 */

#ifndef	_SBI_H
#define	_SBI_H

#ifdef __cplusplus
extern "C" {
#endif

extern void sbi_console_putchar(int ch);
extern void sbi_console_putchar_u(int ch);	/* userland output: never quieted */
extern volatile int kcons_quiet;
extern void sbi_console_puts(const char *s);
extern const char *sbi_console_kind(void);
extern long sbi_set_timer(unsigned long deadline);

/*
 * SBI HSM (Hart State Management) extension, EID 0x48534D ("HSM") — R-P4 SMP.
 *   sbi_hart_start(hartid, start_addr, opaque): release a stopped hart; it
 *     begins executing in S-mode at start_addr with a0=hartid, a1=opaque.
 *   sbi_hart_get_status(hartid): returns the HSM state (>=0) or a negative
 *     SBI error. State 0=STARTED, 1=STOPPED, others are transitional.
 */
#define	SBI_HSM_STARTED		0L
#define	SBI_HSM_STOPPED		1L
#define	SBI_HSM_START_PENDING	2L
#define	SBI_HSM_STOP_PENDING	3L

extern long sbi_hart_start(unsigned long hartid, unsigned long start_addr,
    unsigned long opaque);
extern long sbi_hart_get_status(unsigned long hartid);

/*
 * SBI IPI (Inter-Processor Interrupt) extension, EID 0x735049 ("sPI") — R-P13
 * SMP. sbi_send_ipi(hart_mask, hart_mask_base) pends a S-mode software
 * interrupt (sip.SSIP) on the selected harts, waking them from wfi to re-run
 * their dispatcher. Returns the SBI error (0 == success).
 */
extern long sbi_send_ipi(unsigned long hart_mask, unsigned long hart_mask_base);

#ifdef __cplusplus
}
#endif

#endif	/* _SBI_H */
