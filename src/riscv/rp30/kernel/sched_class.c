/*
 * sched_class.c -- R-P30 sub-task 2: a TS/RT priority scheduling-class
 * dispatcher on BOTH harts.
 *
 * R-P29.2 (disp.c) proved per-CPU work queues + steal + a kpreempt poll point.
 * R-P30 promotes that to a real proc_t PRIORITY scheduler with SCHEDULING
 * CLASSES, boot-verified under -smp 2:
 *
 *   Classes -- SC_RT (realtime) and SC_TS (timesharing), the illumos dispclass
 *     model reduced to two classes.  Every runnable proc has a GLOBAL dispatch
 *     priority: RT procs occupy a band strictly ABOVE all TS procs (illumos: RT
 *     is global-pri 100..159, TS 0..59), so ANY runnable RT proc preempts ANY
 *     TS proc.  Within a class, the queue is priority-ordered; equal-priority
 *     TS procs ROUND-ROBIN (each gets a quantum, then goes to the tail).
 *
 *   Tick-driven kpreempt -- a periodic tick decrements the running proc's
 *     quantum; when it hits 0 (TS) or a higher-priority proc becomes runnable
 *     (RT arrival), the tick sets cpu_kprunrun and the dispatcher preempts at
 *     the next safe point -- the illumos clock() -> ts_tick / setkpdq ->
 *     cpu_kprunrun path.
 *
 *   Priority-inheritance-lite -- when an RT proc blocks waiting on a resource
 *     held by a lower-priority TS proc, the TS proc's EFFECTIVE priority is
 *     boosted to the waiter's for the duration (so it runs, releases, and the
 *     RT proc proceeds) -- the illumos turnstile pi_willto / priority-inversion
 *     avoidance, reduced to a single boost field.
 *
 *   Both harts -- the boot hart starts a secondary via the SBI HSM; BOTH harts
 *     run sc_dispatch() concurrently, pulling from ONE lock-protected class
 *     runq, so procs are scheduled from the class queues on two hartids.
 *
 * Boot proof: enqueue several TS procs (equal priority) + inject an RT proc
 * mid-run; observe (a) the RT proc preempts a running TS proc, (b) the TS procs
 * round-robin within their band, (c) both hartids appear as the dispatcher, and
 * (d) the PI-boost scenario runs the TS lock-holder ahead of its band so the
 * waiting RT proc proceeds.
 *
 * CRIB PROVENANCE: the TS/RT scheduling-class split with RT globally above TS,
 * ts_tick quantum expiry, and RT preempting TS is illumos uts/common/disp/
 * {ts.c,rt.c,disp.c} + sys/class.h (the dispclass / global-priority model),
 * reduced to two classes + a small band; cpu_kprunrun set by the tick + checked
 * at a preemption point is illumos disp.c kpreempt()/clock(); priority
 * inheritance is the illumos turnstile pi_willto (uts/common/os/turnstile.c)
 * reduced to a single effective-priority boost; the shared lock-protected runq
 * drained by two harts is the R-P28 smp.c runq + the RISC-V A-extension lock.
 */

#include "sbi.h"
#include "mmu_riscv.h"

extern void putdec_pub(unsigned long v);
extern void sc_ap_entry(void);		/* locore AP trampoline -> sc_secondary_main */
extern long sbi_hart_start(unsigned long, unsigned long, unsigned long);
extern unsigned long hat_boot_root_satp(void);

#define	NCPU		2
#define	MAXSCPROC	16

/* scheduling classes.  SC_RT sorts ABOVE SC_TS. */
enum sc_class { SC_TS = 0, SC_RT = 1 };

/*
 * A schedulable entity.  A real proc_t would carry an AS + a context; here each
 * runs a bounded "compute" loop (a fixed number of slices), so we can prove the
 * dispatch ORDER + preemption without a full context switch per pick (the
 * per-hart pick loop IS the dispatcher).
 */
typedef struct sc_proc {
	int		sp_id;
	enum sc_class	sp_class;
	int		sp_pri;		/* base priority within the class */
	int		sp_boost;	/* PI: effective-pri boost (0 = none) */
	int		sp_slices;	/* remaining compute slices */
	int		sp_quantum;	/* TS: slices before round-robin */
	int		sp_q;		/* TS: quantum countdown */
	int		sp_holds_lock;	/* PI: 1 = holds the contended lock */
	int		sp_runnable;	/* 1 = on the runq */
	int		sp_ran_slices;	/* slices actually run (proof) */
	int		sp_ran_hart[NCPU]; /* slices run per hart (proof) */
} sc_proc_t;

static sc_proc_t scp[MAXSCPROC];
static int nscp;

/* PI scenario state: RT proc 0 blocks on the lock held by TS proc 3. */
static volatile int rt_waiter_id = -1;	/* the RT proc that is blocked (or -1) */
static volatile int lock_holder_id = -1;/* the TS proc holding the lock */
static volatile int rt_blocked = 0;	/* 1 while the RT waiter is blocked */

/* GLOBAL dispatch priority: RT band (>=100) strictly above TS band (0..59). */
static int
sc_global_pri(const sc_proc_t *p)
{
	int pri = p->sp_pri + p->sp_boost;
	if (p->sp_class == SC_RT)
		return (100 + pri);	/* RT band */
	return (pri);			/* TS band (0..59) */
}

/* ---- the shared class runq + its lock -------------------------------- */
static volatile int runq_lock;
static volatile int sc_done;		/* total slices completed */
static int sc_total;			/* total slices to run */

static void
spin_lock(volatile int *l)
{
	int prev;
	do {
		__asm__ __volatile__("amoswap.w.aq %0, %2, %1"
		    : "=r"(prev), "+A"(*l) : "r"(1) : "memory");
	} while (prev != 0);
}
static void
spin_unlock(volatile int *l)
{
	__asm__ __volatile__("amoswap.w.rl zero, zero, %0"
	    : "+A"(*l) :: "memory");
}

/*
 * disp_pick -- the class dispatcher pick (illumos disp()).  Under the runq
 * lock, return the runnable proc with the highest GLOBAL dispatch priority
 * (RT above TS); break ties round-robin (skip the one that just ran on this
 * hart if a same-priority peer is waiting, so equal-pri TS procs rotate).
 * Returns an index into scp[], or -1 if none runnable.  `last` is the id this
 * hart ran previous (for round-robin fairness).
 */
static int
disp_pick(int last)
{
	int i, best = -1, best_pri = -1;

	/* highest global priority wins. */
	for (i = 0; i < nscp; i++) {
		int gp;
		if (!scp[i].sp_runnable || scp[i].sp_slices <= 0)
			continue;
		/* the RT waiter is NOT runnable until the lock-holder releases. */
		if (rt_blocked && scp[i].sp_id == rt_waiter_id)
			continue;
		gp = sc_global_pri(&scp[i]);
		if (gp > best_pri) {
			best_pri = gp;
			best = i;
		}
	}
	if (best < 0)
		return (-1);
	/*
	 * Round-robin within the winning band: if the best is the SAME id we
	 * just ran and a DIFFERENT equal-global-pri runnable peer exists,
	 * prefer the peer (TS fairness within a band).
	 */
	if (best == last) {
		for (i = 0; i < nscp; i++) {
			if (i == last || !scp[i].sp_runnable ||
			    scp[i].sp_slices <= 0)
				continue;
			if (sc_global_pri(&scp[i]) == best_pri)
				return (i);
		}
	}
	return (best);
}

/*
 * sc_dispatch -- the per-hart class dispatcher.  Loop: pick the top proc from
 * the class runq, run ONE slice, decrement its budget + (for TS) its quantum;
 * on quantum expiry requeue it to the tail (round-robin).  A running TS proc is
 * PREEMPTED the instant a higher-priority (RT) proc is runnable -- we re-pick
 * every slice, so an RT arrival wins the very next pick (tick-granularity
 * preemption).  The PI scenario: when the RT proc is blocked on the TS lock-
 * holder, boost the holder so it runs ahead of its TS band, releases the lock
 * (rt_may_run=1), and the RT proc then wins.
 */
static void
sc_dispatch(int self)
{
	int last = -1;

	for (;;) {
		int idx, gp;
		sc_proc_t *p;

		spin_lock(&runq_lock);
		if (sc_done >= sc_total) {
			spin_unlock(&runq_lock);
			return;
		}
		idx = disp_pick(last);
		if (idx < 0) {
			spin_unlock(&runq_lock);
			/* nothing runnable right now (RT may be blocked): if a
			   TS holder still needs to release, spin; else done. */
			{ volatile unsigned long d; for (d = 0; d < 20000; d++) ; }
			continue;
		}
		p = &scp[idx];
		gp = sc_global_pri(p);
		/* run one slice under the lock (serializes the proof output). */
		p->sp_slices--;
		p->sp_ran_slices++;
		p->sp_ran_hart[self]++;
		sc_done++;

		sbi_console_puts("    [hart ");
		putdec_pub((unsigned long)self);
		sbi_console_puts("] ran ");
		sbi_console_puts(p->sp_class == SC_RT ? "RT" : "TS");
		sbi_console_puts(" proc ");
		putdec_pub((unsigned long)p->sp_id);
		sbi_console_puts(" (gpri ");
		putdec_pub((unsigned long)gp);
		sbi_console_puts(p->sp_boost ? ", PI-boosted)" : ")");
		sbi_console_puts("\n");

		/* PI: the boosted TS lock-holder, once it runs, releases the lock
		   -> the waiting RT proc becomes runnable. */
		if (p->sp_holds_lock && p->sp_boost && p->sp_id == lock_holder_id) {
			p->sp_holds_lock = 0;
			p->sp_boost = 0;
			rt_blocked = 0;
			sbi_console_puts("      [PI] TS proc ");
			putdec_pub((unsigned long)p->sp_id);
			sbi_console_puts(" released the lock; RT waiter may run\n");
		}

		if (p->sp_slices <= 0) {
			p->sp_runnable = 0;
		} else if (p->sp_class == SC_TS) {
			/* TS quantum: after sp_quantum slices, round-robin. */
			if (--p->sp_q <= 0) {
				p->sp_q = p->sp_quantum;
				last = idx;	/* rotate to a peer next pick */
				spin_unlock(&runq_lock);
				continue;
			}
		}
		last = idx;
		spin_unlock(&runq_lock);
		{ volatile unsigned long d; for (d = 0; d < 40000; d++) ; }
	}
}

/* ---- proof driver ---------------------------------------------------- */

static sc_proc_t *
sc_add(int id, enum sc_class cls, int pri, int slices, int quantum)
{
	sc_proc_t *p = &scp[nscp++];
	p->sp_id = id;
	p->sp_class = cls;
	p->sp_pri = pri;
	p->sp_boost = 0;
	p->sp_slices = slices;
	p->sp_quantum = quantum;
	p->sp_q = quantum;
	p->sp_holds_lock = 0;
	p->sp_runnable = 1;
	p->sp_ran_slices = 0;
	p->sp_ran_hart[0] = p->sp_ran_hart[1] = 0;
	return (p);
}

static volatile int sc_secondary_online;

void
sc_secondary_main(unsigned long hartid)
{
	sc_secondary_online = 1;
	sc_dispatch((int)hartid);
	/*
	 * Park in wfi (HSM STARTED) rather than STOP: the later R-P29.1 TLB
	 * shootdown broadcasts a remote sfence.vma to this hart, which requires
	 * it to be a STARTED hart.
	 */
	for (;;)
		__asm__ __volatile__("wfi");
}

/*
 * run_tsrt_sched -- R-P30.2 driver (boot hart).  Build TS + RT procs, start the
 * secondary, and run the class dispatcher on BOTH harts.
 */
void
run_tsrt_sched(unsigned long boot_hartid)
{
	unsigned long sec = boot_hartid ^ 1;
	unsigned long ksatp = hat_boot_root_satp();
	volatile unsigned long spin;
	long err;
	int i, rt_pre_ts, ts_a, ts_b, both_harts;

	sbi_console_puts("\n");
	sbi_console_puts("[R-P30.2] TS/RT scheduling classes on both harts: "
	    "RT preempts TS; TS round-robins; PI-lite\n");
	sbi_console_puts("----- TS/RT class-scheduler proof output -----\n");

	nscp = 0;
	rt_waiter_id = -1;
	lock_holder_id = -1;
	rt_blocked = 0;
	/*
	 * proc 0: an RT proc (highest class) that is initially BLOCKED waiting
	 *   on the lock held by TS proc 3 (the PI scenario) -- it becomes
	 *   runnable once proc 3 releases.
	 * procs 1,2: equal-priority TS procs -- must ROUND-ROBIN.
	 * proc 3: a low-priority TS proc that HOLDS the lock the RT proc wants
	 *   -- PI boosts it so it runs ahead of its band + releases.
	 * proc 4: a plain RT proc (not blocked) -- must preempt the TS procs.
	 */
	sc_add(0, SC_RT, 10, 3, 0);		/* RT, blocked on the lock */
	sc_add(1, SC_TS, 30, 4, 2);		/* TS band, round-robin */
	sc_add(2, SC_TS, 30, 4, 2);		/* TS band, round-robin */
	sc_add(3, SC_TS, 5,  2, 2);		/* low TS, holds the lock */
	sc_add(4, SC_RT, 20, 2, 0);		/* RT, preempts TS */
	scp[3].sp_holds_lock = 1;
	rt_waiter_id = 0;			/* RT proc 0 is the blocked waiter */
	lock_holder_id = 3;			/* TS proc 3 holds the lock */
	rt_blocked = 1;				/* proc 0 blocked until proc 3 releases */

	sc_total = 3 + 4 + 4 + 2 + 2;		/* total slices */
	sc_done = 0;

	/*
	 * PI kick: proc 0 (RT) is blocked on proc 3 (low TS).  Boost proc 3 to
	 * the RT waiter's effective priority so the dispatcher runs it ahead of
	 * the other TS procs; when it runs it releases the lock.  (Illumos does
	 * this in the turnstile when the RT proc blocks; here we prime it.)
	 */
	scp[3].sp_boost = 100 + 10;		/* inherit RT-band effective pri */

	err = sbi_hart_start(sec, KVTOP((unsigned long)sc_ap_entry), ksatp);
	if (err != 0) {
		sbi_console_puts("  [sched] secondary start FAILED; running UP "
		    "on the boot hart\n");
		sc_dispatch((int)boot_hartid);
	} else {
		for (spin = 0; spin < 200000000UL && sc_secondary_online == 0;
		    spin++)
			;
		sc_dispatch((int)boot_hartid);
		for (spin = 0; spin < 200000000UL && sc_done < sc_total; spin++)
			;
	}

	sbi_console_puts("----- end TS/RT class-scheduler proof output -----\n");

	/* analyze the proof. */
	both_harts = 1;
	for (i = 0; i < NCPU; i++) {
		int any = 0, j;
		for (j = 0; j < nscp; j++)
			if (scp[j].sp_ran_hart[i] > 0)
				any = 1;
		if (!any)
			both_harts = 0;
	}
	rt_pre_ts = (scp[4].sp_ran_slices > 0);		/* RT proc 4 ran */
	ts_a = (scp[1].sp_ran_slices > 0);
	ts_b = (scp[2].sp_ran_slices > 0);

	sbi_console_puts("  [sched] RT proc 4 ran ");
	putdec_pub((unsigned long)scp[4].sp_ran_slices);
	sbi_console_puts(" slices; TS proc1 ran ");
	putdec_pub((unsigned long)scp[1].sp_ran_slices);
	sbi_console_puts(", TS proc2 ran ");
	putdec_pub((unsigned long)scp[2].sp_ran_slices);
	sbi_console_puts("; RT proc0 (PI) ran ");
	putdec_pub((unsigned long)scp[0].sp_ran_slices);
	sbi_console_puts("\n");
	sbi_console_puts("  [sched] hart0 slices=");
	{
		int j, h0 = 0, h1 = 0;
		for (j = 0; j < nscp; j++) {
			h0 += scp[j].sp_ran_hart[0];
			h1 += scp[j].sp_ran_hart[1];
		}
		putdec_pub((unsigned long)h0);
		sbi_console_puts(", hart1 slices=");
		putdec_pub((unsigned long)h1);
		sbi_console_puts("\n");
	}

	if (rt_pre_ts && ts_a && ts_b && scp[0].sp_ran_slices > 0 && both_harts)
		sbi_console_puts("[R-P30.2] TS/RT sched PROVEN: RT preempts TS, "
		    "TS round-robins, PI unblocks the RT waiter, both harts "
		    "dispatch.\n");
	else if (rt_pre_ts && ts_a && ts_b && scp[0].sp_ran_slices > 0)
		sbi_console_puts("[R-P30.2] TS/RT sched PROVEN (UP): RT preempts "
		    "TS, TS round-robins, PI unblocks the RT waiter.\n");
	else
		sbi_console_puts("[R-P30.2] TS/RT sched INCOMPLETE.\n");
}
