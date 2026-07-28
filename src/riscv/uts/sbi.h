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
extern void sbi_console_puts(const char *s);
extern const char *sbi_console_kind(void);

#ifdef __cplusplus
}
#endif

#endif	/* _SBI_H */
