/*
 * clock_riscv.c -- R-P24 sub-task 2: riscv64 periodic clock via the SBI timer.
 *
 * The qemu-virt board has no free-running periodic timer of its own that S-mode
 * touches directly; S-mode arms a one-shot deadline through the SBI TIME
 * extension (sbi_set_timer) and takes a Supervisor Timer Interrupt (STIP,
 * scause = INTERRUPT | 5) when `time` reaches it.  Each interrupt we re-arm the
 * next deadline (rdtime + period) so it becomes a periodic tick.
 *
 * Enable path:
 *   clock_init(): read the timebase, compute the per-tick period, arm the first
 *     deadline, then unmask STIE in `sie` and set SIE in `sstatus` so the tick
 *     can be delivered.
 *   rv_timer_intr(): the C bottom half, called from rv_interrupt when scause
 *     says timer.  Count the tick, re-arm, and stop after CLOCK_TEST_TICKS so
 *     the boot proof terminates.
 *
 * CRIB PROVENANCE: the "arm SBI set_timer, take STIP, re-arm for a periodic
 * tick" cadence is the RISC-V SBI spec sbi_set_timer + the R-P6/R-P22.3 MD
 * clock bottom-half; the STIE/SIE unmask + scause==5 timer decode are the
 * RISC-V privileged spec; the illumos clock()-tick shape is uts clock.c.
 */

#include "sbi.h"
#include "clock_riscv.h"

/* qemu-virt CLINT/SBI timebase is 10 MHz. */
#define	TIMEBASE_HZ	10000000UL
#define	HZ		100UL			/* 100 ticks/sec (10 ms) */
#define	CLOCK_PERIOD	(TIMEBASE_HZ / HZ)

/* sstatus / sie bits (privileged spec). */
#define	SSTATUS_SIE	(1UL << 1)
#define	SIE_STIE	(1UL << 5)		/* supervisor timer int enable */
#define	SIE_SEIE	(1UL << 9)		/* supervisor external int enable */
#define	SIE_SSIE	(1UL << 1)		/* supervisor software int enable (IPI) */

volatile unsigned long clock_ticks;		/* ticks counted (boot proof) */
static volatile int clock_free_running;		/* R-P27: keep ticking forever */

static inline unsigned long
rd_time(void)
{
	unsigned long t;
	__asm__ __volatile__("rdtime %0" : "=r"(t));
	return (t);
}

static inline void
csr_set_sie_bit(unsigned long bit)
{
	__asm__ __volatile__("csrs sie, %0" :: "r"(bit) : "memory");
}

static inline void
csr_set_sstatus_sie(void)
{
	__asm__ __volatile__("csrsi sstatus, 0x2" ::: "memory"); /* SIE=bit1 */
}

/* arm the next one-shot deadline. */
static void
clock_rearm(void)
{
	(void) sbi_set_timer(rd_time() + CLOCK_PERIOD);
}

/*
 * clock_init -- start the periodic tick.  Arm the first deadline, unmask the
 * supervisor timer interrupt, and globally enable S-mode interrupts.
 */
void
clock_init(void)
{
	clock_ticks = 0;
	clock_rearm();
	csr_set_sie_bit(SIE_STIE);	/* let the timer interrupt through */
	csr_set_sstatus_sie();		/* global S-mode interrupt enable */
}

/* also unmask the supervisor external interrupt line (for the PLIC path). */
void
clock_enable_extintr(void)
{
	csr_set_sie_bit(SIE_SEIE);
}

/*
 * clock_enable_ssie -- R-P35.1: unmask the supervisor SOFTWARE interrupt
 * (SSIE, sie bit 1) so an SBI IPI posted to this hart is taken as an
 * interrupt -- and, critically, so a `wfi` in the per-CPU idle loop RESUMES
 * when a peer hart pokes us to re-dispatch a proc it just made runnable.  wfi
 * wakes on any interrupt ENABLED in `sie` regardless of the global sstatus.SIE
 * bit, but the source must be unmasked here first.
 */
void
clock_enable_ssie(void)
{
	csr_set_sie_bit(SIE_SSIE);
}

/*
 * clock_run_forever -- R-P27: switch the tick from the R-P24 finite boot-proof
 * cadence (stop after CLOCK_TEST_TICKS) into a free-running periodic tick, the
 * preemption heartbeat for the multiprocess phase.  Re-arm the deadline (the
 * R-P24 tick may already have stopped it) and let rv_timer_intr keep re-arming.
 */
void
clock_run_forever(void)
{
	clock_free_running = 1;
	csr_set_sie_bit(SIE_STIE);	/* R-P24 masked it after the last tick */
	clock_rearm();
}

/*
 * rv_timer_intr -- the timer bottom half (called from rv_interrupt on
 * scause==5).  Count the tick and re-arm.  In the R-P24 finite mode we stop
 * re-arming after CLOCK_TEST_TICKS so the boot proof prints a finite count;
 * once clock_run_forever() flips clock_free_running the tick keeps firing (the
 * R-P27 preemption heartbeat).
 */
int
rv_timer_intr(void)
{
	clock_ticks++;
	if (clock_free_running || clock_ticks < CLOCK_TEST_TICKS) {
		clock_rearm();
		return (1);		/* keep ticking */
	}
	/* stop the tick source: set the deadline to the far future. */
	(void) sbi_set_timer(~0UL);
	return (0);			/* done */
}
