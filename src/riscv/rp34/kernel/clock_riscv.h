/*
 * clock_riscv.h -- R-P24 riscv64 clock interface.
 */
#ifndef	_RP24_CLOCK_RISCV_H
#define	_RP24_CLOCK_RISCV_H

#ifdef __cplusplus
extern "C" {
#endif

#define	CLOCK_TEST_TICKS	10	/* boot proof: count this many then stop */

extern volatile unsigned long clock_ticks;

extern void clock_init(void);
extern void clock_enable_extintr(void);
extern void clock_run_forever(void);
extern int rv_timer_intr(void);

#ifdef __cplusplus
}
#endif

#endif	/* _RP24_CLOCK_RISCV_H */
