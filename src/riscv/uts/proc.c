/*
 * proc.c — illumos riscv64 kernel threads + minimal dispatcher (R-P5).
 *
 * The marquee R-P5 deliverable: real kernel threads and a working context
 * switch. This is the seed of the illumos dispatcher (uts/common/disp/,
 * kthread_t/cpu_t/disp_t, swtch()). Scope for R-P5:
 *
 *   - kthread_t: a kernel thread — its saved callee-saved context (rv_context),
 *     its stack, an entry point, and run-queue links.
 *   - thread_create(): allocate a thread + kmem stack, seed the context so the
 *     first switch into it lands on rv_thread_start (swtch.S) -> entry(arg).
 *   - A single global round-robin run queue (FIFO) + swtch()/thread_yield():
 *     cooperative scheduling. swtch() picks the next runnable thread and calls
 *     rv_swtch (swtch.S) to switch callee-saved context + stacks.
 *   - Idle threads: each cpu's old wfi-park becomes a real idle thread that
 *     loops wfi and yields; the boot cpu's idle thread is thread 0.
 *
 * The A/B proof (thread_ab_selftest): two kernel threads that each print and
 * yield to the other several times through swtch — proving genuine scheduling
 * (stacks + PC + callee-saved state switch and resume correctly).
 *
 * NOTE: ONE global runq + one global lock, cooperative (yield-driven, not
 * preemptive), boot-cpu dispatch only. illumos has per-cpu dispatch queues,
 * priorities, preemption off the clock tick, and load balancing. Upgrade path:
 * per-cpu runq + clock-driven preempt + priority bands (R-P6).
 */

#include "sbi.h"
#include "riscv_regs.h"

/* kmem for thread + stack allocation (kmem.c). */
extern void *kmem_alloc(unsigned long size);
extern void kmem_free(void *buf, unsigned long size);

/* Shared console helpers (startup.c). */
extern void kputdec(unsigned long v);

/* hat: the shared kernel satp (kernel threads run on it). */
extern unsigned long hat_kernel_satp(void);

/* uproc.c: save/restore the global curproc so it follows the thread across a
 * context switch (R-P9 preemption safety). */
extern void *proc_get_current(void);
extern void proc_set_current(void *p);

/* The asm context switch + new-thread trampoline (swtch.S). */
struct rv_context {
	unsigned long c_ra;
	unsigned long c_sp;
	unsigned long c_tp;
	unsigned long c_s[12];		/* s0..s11 */
	unsigned long c_satp;		/* per-thread satp (R-P8 multi-AS) */
	unsigned long c_lofault;	/* per-thread copy_lofault (R-P10 preempt) */
};
extern void rv_swtch(struct rv_context *old, struct rv_context *new);
extern void rv_thread_start(void);

/* forward decls (thread_preempt uses thread_yield defined lower). */
void thread_yield(void);
void swtch(void);

#define	THREAD_STACK_SIZE	8192UL

typedef enum {
	TS_RUN,		/* on the run queue, runnable */
	TS_ONPROC,	/* currently executing */
	/*
	 * TS_IDLE is DECLARED BUT NEVER ASSIGNED: an idle thread is TS_ONPROC
	 * while it runs, like any other. Do not write `t_state == TS_IDLE` to
	 * detect the idle thread -- that test can never be true, and two guards
	 * written that way silently did nothing (see thread_yield). Compare
	 * against idlethread[cpu] instead.
	 */
	TS_IDLE,	/* unused: idle threads are TS_ONPROC. Kept for the enum ABI */
	TS_SLEEP,	/* blocked on a wait channel (R-P9 sleepq) */
	TS_DEAD		/* exited */
} tstate_t;

typedef struct kthread {
	struct rv_context t_ctx;	/* saved callee-saved context */
	void		*t_stack;	/* kmem stack base */
	unsigned long	t_stacksize;
	void		(*t_entry)(void *);
	void		*t_arg;
	tstate_t	t_state;
	int		t_id;
	int		t_cpu;		/* hart it last ran on (R-P13 SMP proof) */
	void		*t_wchan;	/* sleep channel (R-P9), NULL if runnable */
	void		*t_curproc;	/* this thread's user proc (R-P9 preempt) */
	struct kthread	*t_link;	/* run-queue / sleepq link */
} kthread_t;

/* Global run queue (FIFO) + lock. */
static kthread_t *runq_head;
static kthread_t *runq_tail;
static volatile int runq_lock;
static int next_tid = 0;

/* Per-cpu current thread + idle thread. Boot-cpu dispatch only in R-P5, but
 * indexed by hartid so the structure is already SMP-shaped. */
#define	MAXCPU		8
static kthread_t *curthread[MAXCPU];
static kthread_t *idlethread[MAXCPU];

static void
runq_lock_enter(void)
{
	int old;
	do {
		__asm__ __volatile__("amoswap.w.aq %0, %2, (%1)"
		    : "=&r"(old) : "r"(&runq_lock), "r"(1) : "memory");
	} while (old != 0);
}

static void
runq_lock_exit(void)
{
	__asm__ __volatile__("amoswap.w.rl zero, zero, (%0)"
	    :: "r"(&runq_lock) : "memory");
}

/*
 * Current hartid. R-P13 SMP: each hart runs the dispatcher, so this_cpu() must
 * return the REAL hart index. We keep it in tp -- but ONLY while in S-mode.
 *
 * THE tp SPLIT. RISC-V reserves tp (x4) for the userland thread pointer, and the
 * TLS ABI requires tp to point at the running thread's TLS block, so userland
 * must own tp in U-mode -- Rust/illumos TLS is unimplementable otherwise. The
 * kernel wants a per-hart id in a single register because this_cpu() is on the
 * hot path of every dispatch decision. Both hold if tp's meaning is split by
 * privilege: userland's thread pointer in U-mode, the kernel's per-hart id in
 * S-mode. trap.S is the seam that swaps them at the U/S boundary, parking the
 * kernel id in the trap frame (TF_CPUID) while U-mode runs. See asm_frame.h
 * TF_CPUID for why a frame slot and not a CSR.
 *
 * COST: this_cpu() is unchanged -- one register read, no memory traffic. The
 * split adds exactly one load on entry from U and one store on return to U, both
 * to the trap frame's own already-dirty cache line. Nothing on the S-mode trap
 * path (timer, PLIC, IPI) and nothing on the context-switch path changes.
 *
 * tp is seeded by dispatch_init_cpu (via set_this_cpu) as each hart enters the
 * dispatcher, and rv_swtch saves/restores it per thread so a thread pulled off
 * the shared runq by any hart carries the right id.
 *
 * DO NOT seed tp in locore.S instead. It looks strictly better (this_cpu() would
 * be valid from the first S-mode instruction rather than from dispatch_init_cpu),
 * and it measurably destabilizes the boot: 3/3 clean boots became 2/4 with that
 * one `mv tp, a0` added and nothing else changed. Some early-boot path -- before
 * the dispatcher exists -- depends on tp being 0, and setting it early breaks that
 * silently and intermittently. The window between S-mode entry and
 * dispatch_init_cpu runs on the boot/hart stack with no threads and no dispatch
 * decisions, so this_cpu() has nothing to be correct FOR there; the gap costs
 * nothing. Fixing that root cause is worth doing, but it is a separate change and
 * must be verified by boot rate, not by inspection.
 *
 * WHY A RANGE CHECK, not a mask. This used to be `id & (MAXCPU - 1)`, which
 * turns ANY value in tp into a valid-looking cpu index. That is only safe while
 * nothing but the kernel ever writes tp. Now that userland owns tp in U-mode, a
 * stale or foreign value can reach here -- and MAXCPU is 8 while a typical boot
 * is -smp 4, so masking folds it into the 4..7 range whose curthread[] slots
 * stay NULL for the whole boot, giving a NULL dereference far from the cause.
 * (Measured: a userland tp of 0x5a5a0000deadbeef masks to 7 and killed
 * thread_preempt inside the timer trap.) Returning -1 makes an untrustworthy tp
 * a condition callers can refuse to act on rather than a silent mis-index. Cost
 * is one compare-and-branch; still no memory traffic.
 */
static inline int
this_cpu(void)
{
	unsigned long id;
	__asm__ __volatile__("mv %0, tp" : "=r"(id));
	if (id >= MAXCPU)
		return (-1);		/* tp is not a hart id: say so, do not guess */
	return ((int)id);
}

/*
 * this_cpu_ok -- the cpu index for code that runs on a kernel thread, where tp
 * is a hart id by contract (every kernel-thread context carries c_tp, and the
 * trap entry reloads it on the way in from U-mode). Falls back to cpu 0 if that
 * contract is somehow broken, because these callers have no way to decline: they
 * are mid-yield/exit/sleep and must index SOMETHING. Cpu 0's slots are always
 * initialized, so the fallback degrades to "the wrong hart's bookkeeping" rather
 * than a NULL dereference.
 *
 * Callers that CAN decline (thread_preempt, reached from the timer trap where a
 * userland tp may still be live) use this_cpu() and check for -1 instead.
 */
static inline int
this_cpu_ok(void)
{
	int cpu = this_cpu();

	return (cpu < 0 ? 0 : cpu);
}

/* Set this hart's S-mode id into tp (locore seeds it; this re-stamps it). */
static inline void
set_this_cpu(unsigned long hartid)
{
	__asm__ __volatile__("mv tp, %0" :: "r"(hartid));
}

/*
 * thread_preempt — the clock-tick preemption entry (R-P9). Called from the
 * timer ISR when a thread has run long enough. If another thread is runnable
 * (the runq is non-empty), yield the cpu to it (round-robin); otherwise do
 * nothing (nothing else to run). Returns 1 if it preempted (switched), 0 if
 * not. Safe to call from the timer trap on the kernel stack: thread_yield's
 * swtch saves/restores this thread's kernel context + satp + curproc, and when
 * we are switched back the timer trap returns and sret's to the interrupted PC.
 */
int
thread_preempt(void)
{
	int cpu = this_cpu();
	kthread_t *self;

	/*
	 * Refuse to act on a cpu identity we do not trust. this_cpu() returns -1
	 * when tp does not hold a hart id, and curthread[] is NULL for any hart
	 * that never entered the dispatcher. Preemption is always optional -- not
	 * preempting is a correct outcome -- so bail instead of dereferencing.
	 * Without this, an untrustworthy tp turned a skipped time-slice into a
	 * fatal NULL dereference inside the timer trap.
	 */
	if (cpu < 0)
		return (0);
	self = curthread[cpu];
	if (self == 0)
		return (0);

	/*
	 * Never preempt the idle thread. Identify it by IDENTITY, not by state:
	 * t_state is TS_ONPROC while a thread runs (dispatch_init_cpu sets the idle
	 * thread ONPROC, and swtch sets every incoming thread ONPROC), so a
	 * `t_state == TS_IDLE` test never fires and this guard silently did
	 * nothing. TS_IDLE is a value nothing ever assigns.
	 */
	if (self == idlethread[cpu])
		return (0);		/* idle thread never preempts */
	if (runq_head == 0)
		return (0);		/* nothing else runnable */
	thread_yield();			/* round-robin to the next thread */
	return (1);
}

/*
 * curthread_kstacktop — the top (high address) of the CURRENT thread's kernel
 * stack, 16-byte aligned. The R-P7 userland-exec path installs this in
 * sscratch so a trap from U-mode lands on a valid kernel stack. Returns 0 for
 * the boot/idle thread (which runs on the hart boot stack, not a kmem stack) —
 * exec always runs from a real kmem-stacked thread, so a nonzero value.
 */
unsigned long
curthread_kstacktop(void)
{
	kthread_t *self = curthread[this_cpu_ok()];

	if (self == 0 || self->t_stack == 0)
		return (0);
	return (((unsigned long)self->t_stack + self->t_stacksize) & ~15UL);
}

/* Enqueue a runnable thread at the tail (FIFO round-robin). Caller may hold or
 * not hold runq_lock; this takes it. */
static void
runq_enqueue(kthread_t *t)
{
	runq_lock_enter();
	t->t_state = TS_RUN;
	t->t_link = 0;
	if (runq_tail != 0)
		runq_tail->t_link = t;
	else
		runq_head = t;
	runq_tail = t;
	runq_lock_exit();
}

/* Dequeue the head runnable thread, or NULL if the runq is empty. */
static kthread_t *
runq_dequeue(void)
{
	kthread_t *t;

	runq_lock_enter();
	t = runq_head;
	if (t != 0) {
		runq_head = t->t_link;
		if (runq_head == 0)
			runq_tail = 0;
		t->t_link = 0;
	}
	runq_lock_exit();
	return (t);
}

/*
 * thread_create — allocate a kthread + stack, seed its context so the first
 * switch into it starts at rv_thread_start -> entry(arg), and enqueue it.
 */
kthread_t *
thread_create(void (*entry)(void *), void *arg)
{
	kthread_t *t = kmem_alloc(sizeof (kthread_t));
	unsigned long sp;
	int i;

	if (t == 0)
		return (0);

	t->t_stack = kmem_alloc(THREAD_STACK_SIZE);
	if (t->t_stack == 0) {
		kmem_free(t, sizeof (kthread_t));
		return (0);
	}
	t->t_stacksize = THREAD_STACK_SIZE;
	t->t_entry = entry;
	t->t_arg = arg;
	t->t_id = ++next_tid;
	t->t_cpu = 0;
	t->t_link = 0;
	t->t_wchan = 0;
	t->t_curproc = 0;

	/* Stack grows down: top = base + size, 16-byte aligned. */
	sp = ((unsigned long)t->t_stack + THREAD_STACK_SIZE) & ~15UL;

	for (i = 0; i < 12; i++)
		t->t_ctx.c_s[i] = 0;
	/* rv_thread_start reads s0=entry, s1=arg (rv_swtch restores them). */
	t->t_ctx.c_s[0] = (unsigned long)entry;		/* s0 */
	t->t_ctx.c_s[1] = (unsigned long)arg;		/* s1 */
	t->t_ctx.c_ra = (unsigned long)rv_thread_start;	/* first "return" */
	t->t_ctx.c_sp = sp;
	/*
	 * c_tp carries the S-mode per-hart id (this_cpu reads tp). Seed it to the
	 * creating hart; swtch re-stamps it with the running hart on every dispatch,
	 * so a thread that migrates to another hart sees the correct this_cpu there.
	 * This is the KERNEL id only: a user thread's tp is its TLS pointer and
	 * lives in the process's saved user frame (p_uframe.r_tp), not here.
	 */
	t->t_ctx.c_tp = (unsigned long)this_cpu_ok();
	/*
	 * New threads start on the kernel address space (the creator's, which is
	 * the kernel satp). A user-process thread body switches to its own AS as
	 * its first act; the saved satp then follows it across future switches.
	 */
	t->t_ctx.c_satp = hat_kernel_satp();
	t->t_ctx.c_lofault = 0;		/* R-P10: no armed copy on a fresh thread */

	runq_enqueue(t);
	return (t);
}

/*
 * swtch — the dispatcher core. Pick the next runnable thread (round-robin from
 * the runq; the idle thread if the runq is empty) and rv_swtch to it. The
 * current thread must already be in its desired state (re-enqueued by the
 * caller if it wants to keep running, or left off the runq if blocked/idle).
 */
void
swtch(void)
{
	int cpu = this_cpu_ok();
	kthread_t *old = curthread[cpu];
	kthread_t *new;

	new = runq_dequeue();
	if (new == 0)
		new = idlethread[cpu];		/* nothing runnable -> idle */

	if (new == old) {
		/* Only ourselves runnable: keep going (no switch needed). */
		new->t_state = TS_ONPROC;
		return;
	}

	new->t_state = TS_ONPROC;
	curthread[cpu] = new;
	/*
	 * R-P13 SMP: stamp the incoming thread with the hart it is now running
	 * on, so this_cpu() (which reads tp) is correct after rv_swtch restores
	 * this thread's c_tp. A thread pulled off the shared runq by any hart
	 * thus runs with the right cpu identity.
	 */
	new->t_cpu = cpu;
	new->t_ctx.c_tp = (unsigned long)cpu;
	/*
	 * curproc follows the thread (R-P9 preempt safety): save the outgoing
	 * thread's user proc, restore the incoming thread's. Without this a
	 * clock-preempted user thread would resume with the preempter's curproc
	 * and corrupt the next syscall.
	 */
	old->t_curproc = proc_get_current();
	rv_swtch(&old->t_ctx, &new->t_ctx);
	proc_set_current(curthread[cpu]->t_curproc);
	/*
	 * When we are switched back to, execution resumes here. The barrier
	 * also prevents the compiler from tail-call-optimizing rv_swtch (which
	 * would save the wrong ra/sp/callee-saved context and silently wedge).
	 */
	__asm__ __volatile__("" ::: "memory");
}

/*
 * thread_yield — voluntarily give up the cpu: re-enqueue self at the runq tail
 * and switch to the next runnable thread. Cooperative round-robin.
 *
 * AN IDLE THREAD MUST NEVER GO ON THE RUNQ, and the test for that must be
 * IDENTITY, not state. The runq is shared by every hart, so an idle thread
 * enqueued on it gets dequeued and resumed by a DIFFERENT hart while its owning
 * hart is still executing on that same stack and kthread_t -- two harts running
 * one thread. It presents far from the cause: a wild sepc (0xfffffffffffffffc,
 * 0x0), "[disp] thread A/B context-switch FAILED", or a stall anywhere later in
 * the boot, intermittently.
 *
 * The state test that used to be here (`t_state != TS_IDLE`) could never fire:
 * every running thread is TS_ONPROC, because dispatch_init_cpu marks the idle
 * thread ONPROC and swtch marks each incoming thread ONPROC. TS_IDLE is a value
 * nothing in the dispatcher ever assigns, so the guard was dead code and every
 * idle_body yield published the idle thread to the other harts.
 *
 * Measured: 2/10 clean boots with the state test, 8/10 with this identity test
 * and nothing else changed.
 */
void
thread_yield(void)
{
	int cpu = this_cpu_ok();
	kthread_t *self = curthread[cpu];

	if (self != idlethread[cpu])
		runq_enqueue(self);		/* back of the line */
	swtch();
}

/*
 * ---------------------------------------------------------------------------
 * R-P9 sleep queue: a real block/wakeup channel replacing the R-P8 wait
 * spin-yield. A thread that must block (wait4 with a live-but-not-yet-exited
 * child) calls sleep_on(chan): it is taken OFF the run queue (state TS_SLEEP,
 * t_wchan=chan) and swtch()es away, consuming no cpu until woken. wakeup(chan)
 * moves every thread sleeping on chan back onto the run queue. This is the seed
 * of the illumos sleepq_t / turnstile + CV (cv_wait/cv_signal): a hashed sleep
 * queue keyed by a channel address. One global sleepq list here (cooperative,
 * boot-cpu dispatch); a hashed per-bucket sleepq is the SMP upgrade.
 * ---------------------------------------------------------------------------
 */
static kthread_t *sleepq_head;		/* singly-linked list of TS_SLEEP threads */

/*
 * sleep_on — block the current thread on wait channel `chan`. The caller must
 * have already arranged that a wakeup(chan) will come (e.g. the child will exit
 * and call wakeup). Removes self from the run queue (it is running, so it is not
 * on the runq) and switches away; returns when woken (re-enqueued by wakeup and
 * dispatched). Cooperative: safe because interrupts are not driving preemption.
 */
void
sleep_on(void *chan)
{
	int cpu = this_cpu_ok();
	kthread_t *self = curthread[cpu];

	self->t_state = TS_SLEEP;
	self->t_wchan = chan;
	/* Push onto the sleepq list. */
	runq_lock_enter();
	self->t_link = sleepq_head;
	sleepq_head = self;
	runq_lock_exit();

	swtch();			/* off-cpu until wakeup re-enqueues us */
	/* Woken: we are ONPROC again; t_wchan cleared by wakeup. */
}

/*
 * wakeup — make every thread sleeping on `chan` runnable again (move it from
 * the sleepq back onto the run queue). A no-op if none are sleeping on chan.
 * Called by proc_exit's parent-wakeup so a parent blocked in wait4 resumes.
 */
void
wakeup(void *chan)
{
	kthread_t *prev = 0, *t, *next;

	runq_lock_enter();
	t = sleepq_head;
	while (t != 0) {
		next = t->t_link;
		if (t->t_wchan == chan) {
			/* Unlink from sleepq. */
			if (prev == 0)
				sleepq_head = next;
			else
				prev->t_link = next;
			t->t_wchan = 0;
			/* Re-enqueue runnable (inline; we hold the lock). */
			t->t_state = TS_RUN;
			t->t_link = 0;
			if (runq_tail != 0)
				runq_tail->t_link = t;
			else
				runq_head = t;
			runq_tail = t;
			/* prev stays (we removed t). */
			t = next;
		} else {
			prev = t;
			t = next;
		}
	}
	runq_lock_exit();
}

/*
 * thread_exit — terminate the current thread and switch away for good. Called
 * from rv_thread_start if a thread's entry returns, and from proc_exit when a
 * user process exits. The DEAD thread's kthread_t + stack are NOT freed here
 * (we are still running on that stack); thread_reap frees them later, once the
 * thread is no longer current (a parent reaps its exited child in wait).
 */
void
thread_exit(void)
{
	int cpu = this_cpu_ok();
	kthread_t *self = curthread[cpu];

	self->t_state = TS_DEAD;
	/* Do not re-enqueue; just switch to the next runnable/idle thread. */
	swtch();
	/* Never reached. */
	for (;;)
		__asm__ __volatile__("wfi");
}

/*
 * curthread_id — the current thread's id (for proc bookkeeping / diagnostics).
 */
int
curthread_id(void)
{
	kthread_t *self = curthread[this_cpu_ok()];
	return (self != 0 ? self->t_id : 0);
}

/*
 * thread_reap — free a DEAD thread's kthread_t + kernel stack. Called by the
 * reaper (proc_waitpid) after the thread has exited (TS_DEAD) and is no longer
 * running on any cpu, so its stack is safe to reclaim. A no-op for a NULL or
 * not-yet-dead thread (defensive).
 */
void
thread_reap(kthread_t *t)
{
	if (t == 0)
		return;
	if (t->t_state != TS_DEAD)
		return;		/* still runnable/onproc: not safe to free */
	if (t->t_stack != 0)
		kmem_free(t->t_stack, t->t_stacksize);
	kmem_free(t, sizeof (kthread_t));
}

/*
 * idle_body — the idle thread loop. Runs only when nothing else is runnable;
 * wfi's until an interrupt, then yields so a freshly-runnable thread can run.
 * This replaces the R-P4 raw wfi park with a real dispatched idle thread.
 */
static void
idle_body(void *arg)
{
	(void) arg;
	for (;;) {
		__asm__ __volatile__("wfi");
		thread_yield();
	}
}

/*
 * dispatch_init_cpu — make the CURRENT execution context cpu N's idle thread,
 * so there is always a valid curthread to switch away from. Called once per cpu
 * during startup (R-P5: boot cpu only drives the A/B proof).
 */
void
dispatch_init_cpu(int cpu)
{
	kthread_t *idle;

	/* kmem_alloc is not itself SMP-safe; serialize concurrent secondary
	 * bring-up (and the boot hart's thread_create) under the runq lock. */
	runq_lock_enter();
	idle = kmem_alloc(sizeof (kthread_t));
	runq_lock_exit();

	idle->t_stack = 0;		/* runs on the existing boot/hart stack */
	idle->t_stacksize = 0;
	idle->t_entry = idle_body;
	idle->t_arg = 0;
	idle->t_id = -cpu - 1;		/* idle threads: negative ids */
	idle->t_cpu = cpu;
	idle->t_state = TS_ONPROC;
	idle->t_link = 0;
	idle->t_wchan = 0;
	idle->t_curproc = 0;
	idle->t_ctx.c_tp = (unsigned long)cpu;

	set_this_cpu((unsigned long)cpu);	/* tp = our S-mode hart id */
	idlethread[cpu] = idle;
	curthread[cpu] = idle;		/* we ARE the idle thread now */
}

/*
 * ---------------------------------------------------------------------------
 * A/B context-switch proof (R-P5 gate 4)
 * ---------------------------------------------------------------------------
 */
static volatile int ab_rounds_a = 0;
static volatile int ab_rounds_b = 0;
static volatile int ab_done = 0;
#define	AB_ROUNDS	3

static void
thread_a(void *arg)
{
	(void) arg;
	while (ab_rounds_a < AB_ROUNDS) {
		sbi_console_puts("thread A: round ");
		kputdec((unsigned long)(ab_rounds_a + 1));
		sbi_console_puts(" (ctx-switch to B)\n");
		ab_rounds_a++;
		thread_yield();
	}
	thread_exit();
}

static void
thread_b(void *arg)
{
	(void) arg;
	while (ab_rounds_b < AB_ROUNDS) {
		sbi_console_puts("thread B: round ");
		kputdec((unsigned long)(ab_rounds_b + 1));
		sbi_console_puts(" (ctx-switch to A)\n");
		ab_rounds_b++;
		thread_yield();
	}
	ab_done = 1;
	thread_exit();
}

/*
 * thread_ab_selftest — create threads A and B and let them ping-pong via swtch.
 * We (the idle thread on the boot cpu) drive the dispatcher by yielding into
 * the runq; A and B each print + yield AB_ROUNDS times. When both are done the
 * runq drains back to us. Proves real scheduling: stacks/PC/callee-saved state
 * switch and resume across rv_swtch.
 */
void
thread_ab_selftest(void)
{
	int guard = 0;

	sbi_console_puts("[disp] creating kernel threads A + B, "
	    "cooperative round-robin via swtch:\n");

	(void) thread_create(thread_a, 0);
	(void) thread_create(thread_b, 0);


	/*
	 * We are the boot-cpu idle thread. Yield repeatedly: each yield runs
	 * the next runq thread (A, then B, ...) until both finish. Bounded so
	 * we can never wedge.
	 */
	while (!ab_done && guard < 100) {
		thread_yield();
		guard++;
	}

	sbi_console_puts("[disp] thread A/B context-switch ");
	if (ab_rounds_a == AB_ROUNDS && ab_rounds_b == AB_ROUNDS && ab_done) {
		sbi_console_puts("OK (A ran ");
		kputdec((unsigned long)ab_rounds_a);
		sbi_console_puts("x, B ran ");
		kputdec((unsigned long)ab_rounds_b);
		sbi_console_puts("x, yielded to each other via swtch)\n");
	} else {
		sbi_console_puts("FAILED\n");
	}
}

/*
 * ---------------------------------------------------------------------------
 * R-P13 physical-hart SMP: secondaries run the dispatcher.
 *
 * R-P5..R-P12 dispatched only on the boot cpu; secondaries parked in wfi
 * (main.c secondary_main). R-P13 brings them into the ONE shared, locked runq:
 * each secondary makes itself its hart's idle thread (dispatch_init_cpu with
 * its real hartid), enables the S-soft IPI, and loops the dispatcher. A thread
 * enqueued on the shared runq can then be pulled and run by ANY idle hart —
 * genuine multi-hart execution under the runq_lock. An IPI (sbi_send_ipi)
 * wakes a wfi'd idle hart when work appears.
 *
 * NOTE: ONE global runq + one global spinlock (runq_lock). Correct but not
 * scalable; per-hart runqs + work-stealing + affinity are the illumos-shaped
 * upgrade. The lock makes concurrent enqueue/dequeue/swtch from multiple harts
 * safe today. (ceiling documented; no shortcut in the locking itself.)
 * ---------------------------------------------------------------------------
 */

#define	HARTBIT(h)	(1UL << (h))
extern long sbi_send_ipi(unsigned long hart_mask, unsigned long hart_mask_base);

/* Bitmap of harts currently in their idle wfi (candidates to IPI-wake). */
static volatile unsigned long idle_harts;
/* Proof: which hart ran the SMP test thread, and how many harts dispatched. */
volatile int smp_ran_on_hart = -1;
volatile int smp_harts_dispatching = 0;
/*
 * Gate: the boot hart sets this once kmem + the dispatcher are online (in
 * startup_dispatch). Secondaries were started back in mlsetup (before startup
 * ran), so they MUST wait for this before touching kmem_alloc / the runq —
 * otherwise they fault storing into an uninitialized allocator. Set with a
 * release store; secondaries load-acquire.
 */
volatile int smp_dispatch_ready = 0;

void
smp_dispatch_open(void)
{
	__atomic_store_n(&smp_dispatch_ready, 1, __ATOMIC_RELEASE);
}

/*
 * ipi_intr — S-soft interrupt handler (trap.c cleared sip.SSIP already). An
 * IPI means "work may be runnable"; if this hart is idle and the runq is
 * non-empty, yield so the idle loop re-dispatches. Cheap + safe from the trap.
 */
void
ipi_intr(void)
{
	/* The idle loop re-checks the runq after each wfi; nothing more needed
	 * here beyond having cleared the pending bit. Kept as the hook where a
	 * real cross-call (TLB shootdown, reschedule) would dispatch. */
}

/*
 * smp_wake_idle — if any hart is parked idle, send it an IPI so it re-checks
 * the runq. Called when a thread is made runnable so a sleeping hart picks it
 * up promptly instead of waiting for its next timer tick.
 */
void
smp_wake_idle(void)
{
	unsigned long mask;
	__atomic_load(&idle_harts, &mask, __ATOMIC_ACQUIRE);
	if (mask != 0)
		(void) sbi_send_ipi(mask, 0);
}

/*
 * smp_secondary_dispatch — entry for a secondary hart (called from
 * secondary_main instead of the old wfi park). Become this hart's idle thread
 * on the shared runq, enable the IPI, and dispatch forever. Runs real threads
 * pulled from the shared runq under runq_lock.
 */
void
smp_secondary_dispatch(unsigned long hartid)
{
	/* Wait until the boot hart has brought kmem + the dispatcher online
	 * (startup_dispatch). Secondaries were released in mlsetup, well before
	 * startup() ran, so entering the runq before this would fault. */
	while (__atomic_load_n(&smp_dispatch_ready, __ATOMIC_ACQUIRE) == 0)
		__asm__ __volatile__("nop");

	dispatch_init_cpu((int)hartid);		/* idle thread; re-stamps tp = hartid */
	__sync_fetch_and_add(&smp_harts_dispatching, 1);

	/* Enable the S-soft (IPI) source so sbi_send_ipi can wake us from wfi. */
	__asm__ __volatile__("csrs sie, %0" :: "r"(SIE_SSIE));
	__asm__ __volatile__("csrs sstatus, %0" :: "r"(SSTATUS_SIE));

	for (;;) {
		kthread_t *t = runq_dequeue();
		if (t != 0) {
			/* Run it: switch to it, it returns to the runq when it
			 * yields/exits, and we (idle) resume here. */
			int cpu = this_cpu_ok();
			kthread_t *self = curthread[cpu];
			t->t_state = TS_ONPROC;
			t->t_cpu = cpu;
			t->t_ctx.c_tp = (unsigned long)cpu;
			curthread[cpu] = t;
			self->t_curproc = proc_get_current();
			rv_swtch(&self->t_ctx, &t->t_ctx);
			proc_set_current(curthread[cpu]->t_curproc);
			curthread[cpu] = self;	/* idle is current again */
			set_this_cpu(hartid);	/* restore tp (idle ran with it) */
		} else {
			__sync_fetch_and_or(&idle_harts, HARTBIT(hartid));
			__asm__ __volatile__("wfi");
			__sync_fetch_and_and(&idle_harts, ~HARTBIT(hartid));
		}
	}
}

/*
 * smp_probe_body — the R-P13 SMP proof thread. Enqueued on the shared runq by
 * the boot hart; whichever idle secondary hart pulls it records its hartid.
 * Proves a thread genuinely executed on a hart != the boot hart.
 */
static void
smp_probe_body(void *arg)
{
	(void) arg;
	/* Record the hart we ran on; the boot hart prints the result (printing
	 * here too would interleave byte-for-byte with smp_selftest's line, as
	 * the console has no cross-hart lock yet — that lock is the next SMP
	 * item). Recording is a single word store, ordered by the release below. */
	__atomic_store_n(&smp_ran_on_hart, this_cpu_ok(), __ATOMIC_RELEASE);
	thread_exit();
}

/*
 * smp_selftest — R-P13 gate 3 proof. Enqueue a thread on the shared runq and
 * IPI-wake the idle secondary harts to pull + run it. Wait (bounded) for it to
 * report which hart it ran on; success requires hart != 0. Called from the
 * boot hart after secondaries have entered smp_secondary_dispatch.
 */
void
smp_selftest(void)
{
	int spin;

	sbi_console_puts("[smp] enqueue a thread on the shared runq; "
	    "IPI-wake secondaries to run it\n");
	smp_ran_on_hart = -1;
	(void) thread_create(smp_probe_body, 0);
	smp_wake_idle();

	for (spin = 0; spin < 50000000 &&
	    __atomic_load_n(&smp_ran_on_hart, __ATOMIC_ACQUIRE) < 0; spin++) {
		if ((spin & 0xffff) == 0)
			smp_wake_idle();
		__asm__ __volatile__("nop");
	}

	if (smp_ran_on_hart > 0) {
		sbi_console_puts("[smp] OK: thread ran on hart ");
		kputdec((unsigned long)smp_ran_on_hart);
		sbi_console_puts(" (!=0); ");
		kputdec((unsigned long)smp_harts_dispatching + 1);
		sbi_console_puts(" harts online in dispatcher (1 boot + ");
		kputdec((unsigned long)smp_harts_dispatching);
		sbi_console_puts(" secondary)\n");
	} else if (smp_ran_on_hart == 0) {
		sbi_console_puts("[smp] thread ran on boot hart 0 only "
		    "(no secondary pulled it this run)\n");
	} else {
		sbi_console_puts("[smp] WARN: SMP proof thread did not run\n");
	}
}
