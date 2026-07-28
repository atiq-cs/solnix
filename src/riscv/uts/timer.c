/*
 * timer.c — illumos riscv64 S-mode periodic (cyclic) clock (R-P4).
 *
 * R-P3 took exactly ONE S-mode timer interrupt (one-shot, then disarm). R-P4
 * turns that into a running PERIODIC clock: each tick rearms the timer one
 * period ahead, so the hart ticks at a fixed HZ. This is the foundation the
 * illumos cyclic subsystem and clock() sit on — the heartbeat that drives
 * timeouts, the scheduler tick, and time-of-day advancement.
 *
 * Mechanism (RISC-V Priv Spec + SBI TIME extension):
 *   - The `time` CSR is the platform monotonic counter. On qemu virt the CLINT
 *     runs at TIMEBASE_HZ = 10 MHz, so 1 tick of `time` = 100 ns.
 *   - We tick at HZ (100 Hz => a 10 ms period => TIMER_PERIOD `time`-ticks).
 *   - Each timer interrupt: bump the tick counter, advance the deadline by one
 *     period, and re-arm via SBI set_timer(next_deadline). set_timer clears the
 *     current STIP as a side effect, so rearming is also the acknowledgement.
 *   - gethrtime() reads the `time` CSR and scales to nanoseconds: the illumos
 *     high-resolution monotonic clock, wired to real hardware time here.
 *
 * R-P4 scope: single boot hart, no per-cpu cyclic wheel, no callout dispatch —
 * just the periodic heartbeat + hrtime + a tick counter, proven by running ~10
 * ticks and reporting count + hrtime. The cyclic wheel/callouts are R-P5.
 */

#include "sbi.h"
#include "riscv_regs.h"

/* qemu virt CLINT timebase: 10 MHz => 100 ns per `time` tick. */
#define	TIMEBASE_HZ	10000000UL
#define	NANOSEC		1000000000UL

/* Clock rate. illumos default hz is 100; a 100 Hz tick = 10 ms period. */
#define	HZ		100UL
#define	TIMER_PERIOD	(TIMEBASE_HZ / HZ)	/* `time` ticks per clock tick */

volatile unsigned long timer_ticks = 0;		/* total periodic ticks */
static volatile unsigned long timer_deadline = 0;	/* next fire (`time`) */
static volatile int timer_periodic = 0;		/* 1 = rearm each tick */

static void
putdec(unsigned long v)
{
	char buf[24];
	int n = 0;

	if (v == 0) {
		sbi_console_putchar('0');
		return;
	}
	while (v != 0 && n < (int)sizeof (buf)) {
		buf[n++] = (char)('0' + (v % 10));
		v /= 10;
	}
	while (n-- > 0)
		sbi_console_putchar(buf[n]);
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
 * gethrtime — illumos high-resolution monotonic clock, in nanoseconds. Scales
 * the `time` CSR by the timebase. Split the multiply to avoid overflow on a
 * 64-bit counter: seconds part * 1e9 + fractional-ticks * ns-per-tick.
 * (100 ns/tick here, exact for a 10 MHz timebase.)
 */
unsigned long
gethrtime(void)
{
	unsigned long t = rd_time();
	unsigned long sec = t / TIMEBASE_HZ;
	unsigned long rem = t % TIMEBASE_HZ;

	return (sec * NANOSEC + (rem * NANOSEC) / TIMEBASE_HZ);
}

/*
 * timer_intr — called from trap() on IRQ_S_TIMER. Bump the tick counter and,
 * if periodic, rearm one period ahead (which also clears the pending STIP).
 * This is the periodic clock's per-tick work; a full clock() would also
 * advance lbolt/time-of-day and run the cyclic wheel.
 */
void
timer_intr(void)
{
	timer_ticks++;

	if (timer_periodic) {
		/*
		 * Advance the deadline by a fixed period from the LAST deadline
		 * (not from `now`) so ticks don't drift with interrupt latency.
		 * If we've fallen behind, catch the deadline up to the future.
		 */
		unsigned long now = rd_time();
		timer_deadline += TIMER_PERIOD;
		if (timer_deadline <= now)
			timer_deadline = now + TIMER_PERIOD;
		(void) sbi_set_timer(timer_deadline);
	} else {
		/* One-shot legacy path: disarm. */
		(void) sbi_set_timer(~0UL);
		__asm__ __volatile__("csrc sie, %0" :: "r"(SIE_STIE));
	}
}

/*
 * clock_start — start the periodic clock at HZ. Arm the first deadline one
 * period ahead, mark periodic, enable STIE + global SIE. After this the hart
 * ticks continuously (each tick rearms in timer_intr).
 */
void
clock_start(void)
{
	unsigned long now = rd_time();

	timer_periodic = 1;
	timer_deadline = now + TIMER_PERIOD;

	sbi_console_puts("[clock] starting periodic clock: hz=");
	putdec(HZ);
	sbi_console_puts(" period=");
	putdec(TIMER_PERIOD);
	sbi_console_puts(" time-ticks (");
	putdec(NANOSEC / HZ);
	sbi_console_puts(" ns), timebase=");
	putdec(TIMEBASE_HZ);
	sbi_console_puts(" Hz\n");

	(void) sbi_set_timer(timer_deadline);
	__asm__ __volatile__("csrs sie, %0" :: "r"(SIE_STIE));
	__asm__ __volatile__("csrs sstatus, %0" :: "r"(SSTATUS_SIE));
}

/*
 * clock_prove — R-P4 milestone-2 proof. Start the periodic clock and wfi until
 * it has ticked N times, then report the tick count + gethrtime. A running,
 * self-rearming count (not one-shot) proves the periodic clock heartbeat.
 */
void
clock_prove(unsigned long nticks)
{
	unsigned long hr0, hr1;

	hr0 = gethrtime();
	clock_start();

	while (timer_ticks < nticks)
		__asm__ __volatile__("wfi");

	hr1 = gethrtime();

	sbi_console_puts("[clock] ");
	putdec(timer_ticks);
	sbi_console_puts(" ticks, hrtime=");
	putdec(hr1);
	sbi_console_puts(" ns (elapsed ");
	putdec(hr1 - hr0);
	sbi_console_puts(" ns) -> periodic clock running.\n");
}
