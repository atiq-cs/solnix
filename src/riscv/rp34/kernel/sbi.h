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
/* R-P28 SMP: SBI HSM hart_start -- boot a secondary hart at (addr) with opaque
   in a1.  Returns the SBI error (0 = SUCCESS). */
extern long sbi_hart_start(unsigned long hartid, unsigned long addr,
    unsigned long opaque);
/* R-P29 TLB shootdown / cross-call: IPI + remote sfence.vma to a peer hart. */
extern long sbi_send_ipi_hart(unsigned long hartid);
extern long sbi_remote_sfence_vma(unsigned long hartid);
/* R-P29: the calling hart stops itself (HSM STOP) so it can be restarted. */
extern long sbi_hart_stop(void);

#ifdef __cplusplus
}
#endif

#endif	/* _RP23_SBI_H */
