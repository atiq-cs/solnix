/*
 * sbi.h -- illumos riscv64 SBI console interface, R-P23 skeleton (trimmed from
 * this repo's uts/riscv64 sbi.h to the console + timer + reset surface the
 * R-P23 banner path needs).
 */

#ifndef	_RP23_SBI_H
#define	_RP23_SBI_H

#ifdef __cplusplus
extern "C" {
#endif

extern void sbi_console_putchar(int ch);
extern void sbi_console_puts(const char *s);
extern const char *sbi_console_kind(void);
extern long sbi_set_timer(unsigned long deadline);
extern void sbi_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif	/* _RP23_SBI_H */
