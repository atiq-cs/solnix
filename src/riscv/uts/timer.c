/*
 * timer.c — illumos riscv64 S-mode timer bring-up (R-P3).
 *
 * Proves interrupt delivery + the timer by taking exactly ONE S-mode timer
 * interrupt and printing "tick". Full clock/cyclics is R-P4; this is the seed.
 *
 * Mechanism (RISC-V Priv Spec + SBI TIME extension):
 *   - The `time` CSR is the platform's monotonic counter (mtime shadow).
 *   - We arm a one-shot by calling SBI set_timer(EID 0x54494D45, FID 0) with
 *     an absolute deadline = now + TIMER_DELTA. SBI programs mtimecmp in
 *     M-mode and pends the S-mode timer interrupt (STIP in sip) when time
 *     reaches it. (This works even without the sstc extension; if sstc is
 *     present the kernel could write stimecmp directly, an R-P4 optimization.)
 *   - Enable STIE (sie) + SIE (sstatus). When time >= deadline the hart traps
 *     to _trap_entry -> trap() -> timer_intr().
 *   - timer_intr() prints "tick" and disarms by calling set_timer with a
 *     max deadline (so STIP clears and no further ticks fire) and masking STIE.
 *
 * SBI set_timer clears the pending timer interrupt as a side effect (per the
 * SBI spec), so re-arming to "infinity" is the clean way to take exactly one.
 */

#include "sbi.h"
#include "riscv_regs.h"

/* One-shot delay in `time` CSR ticks. qemu virt CLINT runs at 10 MHz, so
 * ~100000 ticks = ~10 ms — long enough to arm, short enough to fire fast. */
#define	TIMER_DELTA	100000UL
#define	TIMER_NEVER	(~0UL)		/* disarm: deadline in the far future */

volatile int timer_ticks = 0;

static void
puthex(unsigned long v)
{
	static const char hex[] = "0123456789abcdef";
	int i;
	sbi_console_puts("0x");
	for (i = 60; i >= 0; i -= 4)
		sbi_console_putchar(hex[(v >> i) & 0xf]);
}

/* Read the S-mode `time` CSR (the monotonic counter). */
static unsigned long
rd_time(void)
{
	unsigned long t;
	__asm__ __volatile__("csrr %0, time" : "=r"(t));
	return (t);
}

/*
 * timer_intr — called from trap() on IRQ_S_TIMER. Print one tick and disarm.
 */
void
timer_intr(void)
{
	timer_ticks++;
	sbi_console_puts("[timer] tick #");
	/* small decimal, ticks is tiny */
	sbi_console_putchar((char)('0' + (timer_ticks % 10)));
	sbi_console_puts(" at time=");
	puthex(rd_time());
	sbi_console_puts("  (S-mode timer interrupt delivered)\n");

	/* Disarm: push the deadline to infinity (clears STIP) and mask STIE so
	 * no further timer interrupts occur in R-P3. */
	(void) sbi_set_timer(TIMER_NEVER);
	__asm__ __volatile__("csrc sie, %0" :: "r"(SIE_STIE));
}

/*
 * timer_prove_one_tick — arm a one-shot, enable timer interrupts, and spin
 * (wfi) until timer_intr has fired once. Returns after the single tick.
 */
void
timer_prove_one_tick(void)
{
	unsigned long now = rd_time();

	sbi_console_puts("[timer] arming one-shot: time=");
	puthex(now);
	sbi_console_puts(" deadline=");
	puthex(now + TIMER_DELTA);
	sbi_console_puts("\n");

	/* Program the deadline via SBI, then enable S-mode timer + global. */
	(void) sbi_set_timer(now + TIMER_DELTA);
	__asm__ __volatile__("csrs sie, %0" :: "r"(SIE_STIE));
	__asm__ __volatile__("csrs sstatus, %0" :: "r"(SSTATUS_SIE));

	/* Wait for the one tick. wfi resumes on any pending interrupt; the
	 * trap handler increments timer_ticks. */
	while (timer_ticks == 0)
		__asm__ __volatile__("wfi");

	sbi_console_puts("[timer] one tick observed -> timer + interrupt path OK.\n");
}
