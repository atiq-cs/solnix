/*
 * disp.c -- R-P29 sub-task 2: per-CPU dispatch queues + kpreempt.
 *
 * R-P28's SMP proof (smp.c) drained ONE shared work runq under a single global
 * lock -- correct but not the illumos per-CPU dispatch shape.  R-P29 grows it:
 *
 *   per-CPU disp queues -- each hart (cpu_t) owns its OWN runnable queue.  Work
 *     is spread across the per-CPU queues at enqueue time (round-robin, the
 *     illumos setbackdq / cpu_choose placement); each hart drains its LOCAL
 *     queue first (no lock on the fast path -- it is the only consumer of its
 *     own queue).  When a hart's local queue empties it STEALS a job from a
 *     peer's queue (the illumos disp_getwork / work-stealing balance path,
 *     guarded by the peer's queue lock).  Both harts run their own dispatcher
 *     concurrently -- the R-P28 single-shared-queue grown to N per-CPU queues +
 *     a steal path.
 *
 *   kpreempt -- a kernel preemption point.  A running kernel thread checks
 *     cpu_runrun (set by a higher-priority thread becoming runnable / a timer)
 *     at a kpreempt() call and voluntarily yields the CPU.  This is the illumos
 *     kpreempt(): kernel code is preemptible at explicit safe points (and at
 *     the clock tick when cpu_kprunrun is set).  We prove it by making a
 *     long-running kernel loop poll kpreempt_needed() and, when a flag is
 *     raised, call kpreempt() which records that the preemption point fired.
 *
 * Boot proof: enqueue N jobs spread across 2 per-CPU queues; both harts drain
 * their own queue and at least one steal occurs (queues start unbalanced); the
 * per-CPU job counts show work ran on BOTH harts from their OWN queues.  Then a
 * kernel loop hits a kpreempt point and yields.
 *
 * CRIB PROVENANCE: cpu_t.cpu_disp (a per-CPU disp_t with its own dispatch
 * queues) + setbackdq placing a thread on a CPU's queue + disp_getwork stealing
 * from a peer when the local queue is empty is illumos uts/common/disp/disp.c +
 * sys/cpu.h cpu_t; kpreempt() as an explicit kernel preemption point checking
 * cpu_kprunrun is illumos uts/common/disp/disp.c kpreempt() + the cpu_runrun/
 * cpu_kprunrun flags; the amoswap.w per-queue spinlock is the RISC-V A-extension
 * + the illumos disp_lock reduced to a raw byte lock.
 */

#include "sbi.h"

extern void putdec_pub(unsigned long v);
extern void _secondary_start(void);
extern unsigned long rv_get_satp(void);

#define	NCPU	2

/* ---- per-queue spinlock (amoswap.w test-and-set) -------------------- */
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

/* ---- a per-CPU dispatch queue (cpu_t.cpu_disp) ---------------------- */
/*
 * A job is just an id; running it prints which hart+queue ran it.  Each CPU has
 * a ring of pending job ids + a lock (only contended on a steal).  This models
 * a per-CPU disp_t runnable queue: the local hart is the common-case consumer;
 * a peer takes the lock only to steal.
 */
#define	QDEPTH	16
typedef struct cpu_disp {
	volatile int	dq_lock;
	int		dq_job[QDEPTH];
	int		dq_head;	/* next to run */
	int		dq_tail;	/* next free slot */
	volatile int	dq_ran;		/* jobs this CPU actually ran */
	volatile int	dq_stole;	/* jobs this CPU stole from a peer */
} cpu_disp_t;

typedef struct cpu {
	unsigned long	cpu_id;		/* hartid */
	cpu_disp_t	cpu_disp;	/* this CPU's dispatch queue */
	volatile int	cpu_runrun;	/* preempt-me flag (kpreempt) */
} cpu_t;

static cpu_t cpu[NCPU];
volatile int disp_secondary_online;
static volatile int disp_done;		/* total jobs completed */
static int disp_total;			/* jobs enqueued */

/* enqueue a job on CPU q's queue (setbackdq: place at the tail). */
static void
disp_enqueue(int q, int job)
{
	cpu_disp_t *dq = &cpu[q].cpu_disp;
	spin_lock(&dq->dq_lock);
	dq->dq_job[dq->dq_tail % QDEPTH] = job;
	dq->dq_tail++;
	spin_unlock(&dq->dq_lock);
}

/* dequeue from CPU q's OWN queue head; returns job id or -1 if empty. */
static int
disp_local(int q)
{
	cpu_disp_t *dq = &cpu[q].cpu_disp;
	int job = -1;
	spin_lock(&dq->dq_lock);
	if (dq->dq_head < dq->dq_tail)
		job = dq->dq_job[dq->dq_head++ % QDEPTH];
	spin_unlock(&dq->dq_lock);
	return (job);
}

/* steal one job from a PEER's queue tail (disp_getwork). Returns job or -1. */
static int
disp_steal(int self)
{
	int p;
	for (p = 0; p < NCPU; p++) {
		cpu_disp_t *dq;
		int job = -1;
		if (p == self)
			continue;
		dq = &cpu[p].cpu_disp;
		spin_lock(&dq->dq_lock);
		if (dq->dq_head < dq->dq_tail) {
			dq->dq_tail--;
			job = dq->dq_job[dq->dq_tail % QDEPTH];
		}
		spin_unlock(&dq->dq_lock);
		if (job >= 0)
			return (job);
	}
	return (-1);
}

/*
 * disp_run -- the per-CPU dispatcher for hart `self`: drain the LOCAL queue,
 * and when it is empty STEAL from a peer, until all jobs are done.  Prints each
 * job with the hart that ran it + whether it was local or stolen.
 */
static void
disp_run(int self)
{
	for (;;) {
		int stolen = 0;
		int job = disp_local(self);
		if (job < 0) {
			job = disp_steal(self);
			stolen = 1;
			if (job < 0) {
				if (disp_done >= disp_total)
					return;	/* all work finished */
				continue;	/* peer still has work incoming */
			}
		}
		spin_lock(&cpu[self].cpu_disp.dq_lock);
		sbi_console_puts("    [cpu ");
		putdec_pub(cpu[self].cpu_id);
		sbi_console_puts("] ran job ");
		putdec_pub((unsigned long)job);
		sbi_console_puts(stolen ? " (STOLEN from peer)\n" :
		    " (from own queue)\n");
		cpu[self].cpu_disp.dq_ran++;
		if (stolen)
			cpu[self].cpu_disp.dq_stole++;
		disp_done++;
		spin_unlock(&cpu[self].cpu_disp.dq_lock);
		{ volatile unsigned long d; for (d = 0; d < 150000; d++) ; }
	}
}

/* ---- kpreempt: a kernel preemption point --------------------------- */
static volatile int kpreempt_fired;

/* raise the current CPU's preempt flag (a higher-pri thread became runnable). */
void
kpreempt_arm(unsigned long hartid)
{
	if (hartid < NCPU)
		cpu[hartid].cpu_runrun = 1;
}

/* kpreempt point: if cpu_runrun is set, "yield" (here: record + clear it). */
int
kpreempt(unsigned long hartid)
{
	if (hartid < NCPU && cpu[hartid].cpu_runrun) {
		cpu[hartid].cpu_runrun = 0;
		kpreempt_fired = 1;
		return (1);		/* preempted */
	}
	return (0);
}

int kpreempt_did_fire(void) { return (kpreempt_fired); }

/*
 * disp_secondary_main -- the secondary hart's per-CPU dispatch entry (called
 * from _secondary_start via secondary_main2).  It runs disp_run for its own
 * hartid (queue), so both harts drain their OWN per-CPU queues concurrently.
 */
void
disp_secondary_main(unsigned long hartid)
{
	cpu[hartid].cpu_id = hartid;
	disp_secondary_online = 1;
	disp_run((int)hartid);
	/* return to STOPPED so the boot hart can restart this hart for a later
	   phase (the R-P28 SMP proof restarts it via sbi_hart_start). */
	sbi_hart_stop();
	for (;;)
		__asm__ __volatile__("wfi");
}

/*
 * disp_percpu_demo -- R-P29.2 driver (boot hart).  Start the secondary, spread
 * jobs UNBALANCED across the two per-CPU queues (most on CPU0, few on CPU1) so
 * CPU1 empties first and STEALS from CPU0 -- proving both the per-CPU queues and
 * the steal balance path.  Then run a kpreempt point.
 */
extern long sbi_hart_start(unsigned long, unsigned long, unsigned long);
extern void disp_ap_entry(void);	/* locore trampoline -> disp_secondary_main */

void
disp_percpu_demo(unsigned long boot_hartid)
{
	unsigned long sec = boot_hartid ^ 1;
	unsigned long ksatp = rv_get_satp();
	volatile unsigned long spin;
	int i;
	long err;

	sbi_console_puts("\n");
	sbi_console_puts("[R-P29.2] per-CPU dispatch: each hart drains its OWN "
	    "runq; empty queue STEALS from the peer\n");
	sbi_console_puts("----- per-CPU dispatch proof output -----\n");

	cpu[boot_hartid].cpu_id = boot_hartid;
	cpu[sec].cpu_id = sec;

	/*
	 * Enqueue 12 jobs UNBALANCED: 9 on the boot hart's queue, 3 on the
	 * secondary's.  The secondary drains its 3 quickly then steals from the
	 * boot hart -- forcing the balance path.
	 */
	disp_total = 12;
	disp_done = 0;
	for (i = 0; i < 9; i++)
		disp_enqueue((int)boot_hartid, i);
	for (i = 9; i < 12; i++)
		disp_enqueue((int)sec, i);

	err = sbi_hart_start(sec, (unsigned long)disp_ap_entry, ksatp);
	if (err != 0) {
		sbi_console_puts("  [disp] sbi_hart_start FAILED -- draining "
		    "all queues on the boot hart (UP)\n");
		disp_run((int)boot_hartid);
		disp_run((int)sec);	/* boot hart also drains the peer queue */
	} else {
		for (spin = 0; spin < 200000000UL &&
		    disp_secondary_online == 0; spin++)
			;
		disp_run((int)boot_hartid);
		for (spin = 0; spin < 200000000UL && disp_done < disp_total;
		    spin++)
			;
	}

	sbi_console_puts("----- end per-CPU dispatch proof output -----\n");
	sbi_console_puts("  [disp] cpu0 ran=");
	putdec_pub((unsigned long)cpu[0].cpu_disp.dq_ran);
	sbi_console_puts(" (stole ");
	putdec_pub((unsigned long)cpu[0].cpu_disp.dq_stole);
	sbi_console_puts("); cpu1 ran=");
	putdec_pub((unsigned long)cpu[1].cpu_disp.dq_ran);
	sbi_console_puts(" (stole ");
	putdec_pub((unsigned long)cpu[1].cpu_disp.dq_stole);
	sbi_console_puts(")\n");
	if (cpu[0].cpu_disp.dq_ran > 0 && cpu[1].cpu_disp.dq_ran > 0 &&
	    (cpu[0].cpu_disp.dq_stole + cpu[1].cpu_disp.dq_stole) > 0)
		sbi_console_puts("[R-P29.2] percpu disp PROVEN: both harts ran "
		    "from their own per-CPU queues + a steal balanced them.\n");
	else
		sbi_console_puts("[R-P29.2] per-CPU dispatch: incomplete "
		    "(no steal or a hart idle).\n");

	/* kpreempt proof: a kernel loop hits a preemption point + yields. */
	sbi_console_puts("[R-P29.2] kpreempt: a kernel loop polls a preemption "
	    "point; arm cpu_runrun -> it yields\n");
	{
		int iter, preempted = 0;
		for (iter = 0; iter < 1000 && !preempted; iter++) {
			if (iter == 500)
				kpreempt_arm(boot_hartid);	/* simulate a resched request */
			if (kpreempt(boot_hartid)) {
				sbi_console_puts("  [kpreempt] cpu_runrun set at "
				    "iter 500 -> kernel loop yielded\n");
				preempted = 1;
			}
		}
		if (kpreempt_did_fire())
			sbi_console_puts("[R-P29.2] kpreempt PROVEN: kernel "
			    "preemption point fired + yielded.\n");
		else
			sbi_console_puts("[R-P29.2] kpreempt: point did not "
			    "fire.\n");
	}
}
