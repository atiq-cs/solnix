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

/* The asm context switch + new-thread trampoline (swtch.S). */
struct rv_context {
	unsigned long c_ra;
	unsigned long c_sp;
	unsigned long c_tp;
	unsigned long c_s[12];		/* s0..s11 */
};
extern void rv_swtch(struct rv_context *old, struct rv_context *new);
extern void rv_thread_start(void);

#define	THREAD_STACK_SIZE	8192UL

typedef enum {
	TS_RUN,		/* on the run queue, runnable */
	TS_ONPROC,	/* currently executing */
	TS_IDLE,	/* idle thread (only runs when runq empty) */
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
	struct kthread	*t_link;	/* run-queue link */
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

/* Current hartid via tp is not set up in R-P5; boot-cpu dispatch uses cpu 0. */
static int
this_cpu(void)
{
	return (0);
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
	kthread_t *self = curthread[this_cpu()];

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
	t->t_link = 0;

	/* Stack grows down: top = base + size, 16-byte aligned. */
	sp = ((unsigned long)t->t_stack + THREAD_STACK_SIZE) & ~15UL;

	for (i = 0; i < 12; i++)
		t->t_ctx.c_s[i] = 0;
	/* rv_thread_start reads s0=entry, s1=arg (rv_swtch restores them). */
	t->t_ctx.c_s[0] = (unsigned long)entry;		/* s0 */
	t->t_ctx.c_s[1] = (unsigned long)arg;		/* s1 */
	t->t_ctx.c_ra = (unsigned long)rv_thread_start;	/* first "return" */
	t->t_ctx.c_sp = sp;
	t->t_ctx.c_tp = (unsigned long)t;		/* tp = curthread hook */

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
	int cpu = this_cpu();
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
	rv_swtch(&old->t_ctx, &new->t_ctx);
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
 */
void
thread_yield(void)
{
	int cpu = this_cpu();
	kthread_t *self = curthread[cpu];

	if (self->t_state != TS_IDLE)
		runq_enqueue(self);		/* back of the line */
	swtch();
}

/*
 * thread_exit — terminate the current thread and switch away for good. Called
 * from rv_thread_start if a thread's entry returns.
 */
void
thread_exit(void)
{
	int cpu = this_cpu();
	kthread_t *self = curthread[cpu];

	self->t_state = TS_DEAD;
	/* Do not re-enqueue; just switch to the next runnable/idle thread. */
	swtch();
	/* Never reached. */
	for (;;)
		__asm__ __volatile__("wfi");
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
	kthread_t *idle = kmem_alloc(sizeof (kthread_t));

	idle->t_stack = 0;		/* runs on the existing boot/hart stack */
	idle->t_stacksize = 0;
	idle->t_entry = idle_body;
	idle->t_arg = 0;
	idle->t_id = -cpu - 1;		/* idle threads: negative ids */
	idle->t_state = TS_ONPROC;
	idle->t_link = 0;

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
