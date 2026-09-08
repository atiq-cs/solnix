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

/*
 * ---------------------------------------------------------------------------
 * Callout wheel (R-P5) — the seed of the illumos cyclic/callout subsystem.
 * ---------------------------------------------------------------------------
 * A minimal timer-tick-driven callout facility: callout_schedule() registers a
 * function to fire after a delay; the periodic clock ISR (timer_intr) walks the
 * table each tick and fires any callout whose deadline (in ticks) has arrived.
 *
 * illumos has a per-cpu callout wheel hashed by expiry + the cyclic subsystem
 * under it. This is one flat table walked O(n) per tick — fine for a handful of
 * callouts at bring-up.
 *
 * NOTE: O(n) table scan per tick, fixed CALLOUT_MAX slots. Replace with the
 * hashed callout wheel when callout count grows.
 */
#define	CALLOUT_MAX	16

typedef void (*callout_fn_t)(void *);

struct callout {
	int		c_active;
	unsigned long	c_expire_tick;	/* fire when timer_ticks >= this */
	callout_fn_t	c_func;
	void		*c_arg;
};

static struct callout callouts[CALLOUT_MAX];
static volatile int callout_lock;

/*
 * callout_lock is taken BY THE TIMER INTERRUPT HANDLER itself (timer_intr walks
 * the wheel under it), so it must be an interrupt-SAFE lock. It was a plain
 * test-and-set spin that left sstatus.SIE untouched: any hart that took the lock
 * from thread context -- callout_schedule() does, after clock_start() has enabled
 * SIE -- could then take a timer interrupt while holding it, and timer_intr's own
 * acquire would spin forever on a lock held by the very stack it interrupted.
 * A SAME-HART SELF-DEADLOCK, observed as a 166-line boot stall with CPU#0 parked
 * on the amoswap in timer_intr+0x2e.
 *
 * Save-and-disable SIE around the critical section. The saved flag is returned to
 * the caller rather than kept in a global, because a global would itself be a
 * race between harts (this is one lock shared by all of them) and would restore
 * the wrong state on nesting.
 */
static unsigned long
callout_lock_enter(void)
{
	unsigned long prev;
	int old;

	/* Clear SIE first and remember whether it was set. */
	__asm__ __volatile__("csrrc %0, sstatus, %1"
	    : "=r"(prev) : "r"((unsigned long)SSTATUS_SIE) : "memory");

	do {
		__asm__ __volatile__("amoswap.w.aq %0, %2, (%1)"
		    : "=&r"(old) : "r"(&callout_lock), "r"(1) : "memory");
	} while (old != 0);

	return (prev & SSTATUS_SIE);
}

static void
callout_lock_exit(unsigned long sie)
{
	__asm__ __volatile__("amoswap.w.rl zero, zero, (%0)"
	    :: "r"(&callout_lock) : "memory");

	/* Only re-enable if it was enabled on entry -- never enable in a context
	 * that had interrupts off for its own reasons (e.g. early boot). */
	if (sie != 0)
		__asm__ __volatile__("csrs sstatus, %0"
		    :: "r"(sie) : "memory");
}

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
	unsigned long co_sie = 0;
	timer_ticks++;

	/*
	 * Run the callout wheel: fire any callout whose deadline (in ticks) has
	 * arrived. Deactivate it before calling so a callout can reschedule
	 * itself. Runs in the clock ISR context (interrupts off on this hart).
	 */
	{
		int i;
		co_sie = callout_lock_enter();
		for (i = 0; i < CALLOUT_MAX; i++) {
			if (callouts[i].c_active &&
			    timer_ticks >= callouts[i].c_expire_tick) {
				callout_fn_t f = callouts[i].c_func;
				void *a = callouts[i].c_arg;
				callouts[i].c_active = 0;
				callout_lock_exit(co_sie);
				f(a);
				co_sie = callout_lock_enter();
			}
		}
		callout_lock_exit(co_sie);
	}

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

/*
 * ---------------------------------------------------------------------------
 * Callout API (R-P5)
 * ---------------------------------------------------------------------------
 */

/*
 * callout_schedule — fire func(arg) after `ms` milliseconds (rounded up to the
 * clock tick, HZ=100 => 10 ms granularity). Returns 0 on success, -1 if the
 * callout table is full. Requires the periodic clock to be running.
 */
int
callout_schedule(unsigned long ms, callout_fn_t func, void *arg)
{
	unsigned long co_sie;
	unsigned long delay_ticks = (ms * HZ + 999) / 1000;
	int i;

	if (delay_ticks == 0)
		delay_ticks = 1;

	co_sie = callout_lock_enter();
	for (i = 0; i < CALLOUT_MAX; i++) {
		if (!callouts[i].c_active) {
			callouts[i].c_expire_tick = timer_ticks + delay_ticks;
			callouts[i].c_func = func;
			callouts[i].c_arg = arg;
			callouts[i].c_active = 1;
			callout_lock_exit(co_sie);
			return (0);
		}
	}
	callout_lock_exit(co_sie);
	return (-1);
}

/* Self-test state: set by the fired callout so callout_selftest can observe. */
static volatile int callout_fired = 0;
static volatile unsigned long callout_fire_tick = 0;

static void
callout_test_fn(void *arg)
{
	callout_fired = 1;
	callout_fire_tick = timer_ticks;
	(void) arg;
}

/*
 * callout_selftest — R-P5 gate 3 proof. Schedule a callout +50 ms out, then
 * spin (wfi) until the clock ISR fires it, and report the tick it fired at.
 * Assumes the periodic clock is already running (clock_prove ran).
 */
void
callout_selftest(void)
{
	unsigned long start_tick = timer_ticks;
	unsigned long spins = 0;

	callout_fired = 0;
	if (callout_schedule(50, callout_test_fn, 0) != 0) {
		sbi_console_puts("[callout] self-test FAILED: table full\n");
		return;
	}

	sbi_console_puts("[callout] scheduled callout for +50 ms (");
	putdec((50 * HZ + 999) / 1000);
	sbi_console_puts(" ticks) at tick ");
	putdec(start_tick);
	sbi_console_puts("\n");

	/* Wait for the ISR to fire it (bounded so we never wedge). */
	while (!callout_fired && spins < 100) {
		__asm__ __volatile__("wfi");
		spins++;
	}

	if (callout_fired) {
		unsigned long dms = (callout_fire_tick - start_tick) *
		    (1000 / HZ);
		sbi_console_puts("[callout] callout fired at +");
		putdec(dms);
		sbi_console_puts("ms (tick ");
		putdec(callout_fire_tick);
		sbi_console_puts(") -> callout wheel OK\n");
	} else {
		sbi_console_puts("[callout] self-test FAILED: never fired\n");
	}
}
