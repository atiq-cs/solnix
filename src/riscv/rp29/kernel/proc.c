/*
 * proc.c -- R-P26: the riscv64 process/lwp table, fork(2)/exec(2)/wait(2), and
 * a minimal cooperative dispatcher (a runq + a real context switch between
 * process kernel stacks).  This grows the R-P25 single-user-context assumption
 * (one process, entered by a label_t longjmp) into a MULTIPROCESS kernel: a
 * parent forks a child, both run through the dispatcher and print distinct
 * output (their pid), the child exits, and the parent waits + reaps it.
 *
 * MODEL (reduced illumos proc_t/klwp_t + xv6-riscv proc/scheduler):
 *   - proc_t: pid, state, parent pid, the user address space (satp root), a
 *     per-process kernel stack, a saved scheduler context (rv_context for
 *     rv_swtch), a pointer to the process's trap frame on its kernel stack,
 *     and the exit status.  One lwp per proc (t_ctx == the proc context).
 *   - Each proc runs on its OWN kernel stack with its OWN user AS.  A proc
 *     enters the kernel via a U-mode ecall trap (rv_trap_dispatch builds a
 *     struct regs frame on the proc's kernel stack); a syscall handler may
 *     yield to the scheduler (sched()) which rv_swtch'es callee-saved+ra+sp+
 *     satp between the proc's kernel stack and the scheduler's.
 *   - The scheduler loop (rv_sched) runs on the boot/kernel context+AS: it
 *     picks a RUNNABLE proc and rv_swtch'es into it (loading its user satp so
 *     the trap epilogue sret's straight to U-mode); a proc yields back by
 *     rv_swtch'ing to the scheduler context.  Cooperative for now (procs
 *     yield at fork/wait/exit); the R-P24 timer tick is the later preemption
 *     hook.
 *
 * fork(2): allocate a child proc, COPY the parent's user AS (copy the 4 KiB
 * user leaf frames -- COW is a later optimization), copy the parent's trap
 * frame onto the child kernel stack with a0=0 (child returns 0; parent returns
 * the child pid), seed the child scheduler context so the first swtch into it
 * lands in the trap-return epilogue and sret's to U-mode at the instruction
 * after the child's fork ecall.
 *
 * exec(2): replace the calling proc's user AS with a freshly loaded ELF (reuse
 * the R-P25 exec_elf loader), rewrite the proc's trap frame (sepc=new entry,
 * sp=new user stack, a0..=argc-style) so the epilogue sret's into the new
 * program.  Embedded-ELF now (execee), fs-backed later.
 *
 * wait(2): the parent blocks (state WAITING, yields to the scheduler) until a
 * child reaches ZOMBIE; then it reaps the child (frees it, returns its pid +
 * exit status).
 *
 * CRIB PROVENANCE: proc_t/kthread_t/klwp_t (pid, p_stat, p_parent, p_as,
 * t_stk, exit status) reduced from illumos uts/common/sys/proc.h + this repo's
 * R-P5 proc.c; cfork/forklwp (copy the AS + duplicate the lwp so the child
 * returns 0) is illumos os/fork.c + BSD kern_fork; the "copy trapframe, set
 * a0=0, seed context.ra=forkret, swtch into it" mechanism is xv6-riscv
 * fork()/forkret/scheduler/swtch; exec replacing the AS + rewriting the return
 * frame is illumos gexec/elfexec + BSD kern_exec; waitid/exit rendezvous is
 * illumos os/exit.c/os/wait.c reduced to a parent/child ZOMBIE reap; the
 * runq + rv_swtch between kernel stacks is the R-P24 dispatcher on-ramp grown
 * to N contexts.
 */

#include "mmu_riscv.h"
#include "proc_riscv.h"
#include "sbi.h"

extern void *kmem_alloc(unsigned long);
extern void kmem_free(void *, unsigned long);
extern void *kmem_alloc_page(void);
extern unsigned long rv_get_satp(void);
extern void rv_set_satp(unsigned long);
extern void rv_tlb_flush_all(void);
extern void putdec_pub(unsigned long);
extern void puthex_pub(unsigned long);

/* the scheduler <-> proc context switch (mach_swtch.S). */
extern void rv_swtch(struct rv_context *old, struct rv_context *nw);
/* the asm shim a fresh proc context "returns" into: sp = trap frame, fall
   into the trap-return epilogue and sret to U-mode. */
extern void rv_user_frame_ret(void);

/*
 * R-P29: zero a fresh context's FP save area (fcsr + f0..f31) so the first
 * rv_swtch INTO it loads a clean FP state rather than whatever a reused proc
 * slot left behind.  A running proc's FP regs are saved on switch-OUT, so only
 * the initial seed needs this.
 */
static void
ctx_clear_fp(struct rv_context *c)
{
	int i;
	c->c_fcsr = 0;
	for (i = 0; i < 32; i++)
		c->c_f[i] = 0.0;
}

/* ---- the struct regs trap frame (mirrors mach_trap.S offsets) -------- */
struct regs {
	unsigned long r_x[31];	/* x1..x31; a0 = r_x[9], a7 = r_x[16] */
	unsigned long r_sepc;
	unsigned long r_sstatus;
	unsigned long r_scause;
	unsigned long r_stval;
};
#define	R_X_RA	0	/* x1  */
#define	R_X_SP	1	/* x2  */
#define	R_X_A0	9	/* x10 */
#define	R_X_A1	10
#define	R_X_A2	11
#define	R_X_A7	16	/* x17 */

/* ---- the process table ----------------------------------------------- */
#define	NPROC		16
#define	KSTACK_SIZE	(16UL * 1024)

/*
 * R-P28 dispatch priorities.  A reduced illumos disp priority scale: a small
 * band of numeric priorities where HIGHER runs sooner.  Real illumos has 170
 * global priorities across scheduling classes (TS/RT/SYS/interrupt); we keep a
 * handful of bands -- enough to prove priority-ordered dispatch.
 */
#define	NPRI		8		/* priorities 0..7 */
#define	PRI_MIN		0
#define	PRI_DEFAULT	3
#define	PRI_MAX		(NPRI - 1)

enum p_state { P_UNUSED = 0, P_RUNNABLE, P_RUNNING, P_WAITING, P_ZOMBIE };

typedef struct proc {
	int		p_pid;
	enum p_state	p_state;
	int		p_ppid;		/* parent pid (0 = none) */
	int		p_pri;		/* R-P28: dispatch priority (higher = sooner) */
	int		p_kthread;	/* R-P28: 1 = kernel thread (no U-mode) */
	unsigned long	*p_uroot;	/* user Sv39 root (== PA); MAKE_SATP()able */
	unsigned long	p_usatp;	/* satp value for this AS */
	unsigned char	*p_kstack;	/* kernel stack base (kmem) */
	unsigned long	p_kstack_top;	/* kernel stack top (== sscratch in U) */
	struct rv_context p_ctx;	/* saved scheduler context (rv_swtch) */
	struct regs	*p_tf;		/* the proc's trap frame on its kstack */
	int		p_xstat;	/* exit status (valid when ZOMBIE) */
	void		(*p_kentry)(void); /* R-P28: kernel-thread start function */
	unsigned long	p_brk;		/* R-P29: current program break (heap top) */
} proc_t;

static proc_t proc_tab[NPROC];
static int next_pid = 1;
static proc_t *curproc;			/* the running proc (0 in scheduler) */
static struct rv_context sched_ctx;	/* the scheduler's own context */
static int sched_last = -1;		/* R-P28: round-robin cursor within a band */
static unsigned long kernel_satp;
static volatile int want_resched;	/* R-P27: a timer tick asked to preempt */

/* exec_elf.c: load the ELF at img[0..) into a fresh user AS; fills up. */
extern int exec_image(struct uproc *up, const unsigned char *img);
/* R-P27: dynamic-exec (PT_INTERP -> load ld.so.1 + the app, enter ld.so.1). */
extern int exec_dynamic(struct uproc *up, const unsigned char *img);
extern const char *elf_has_interp(const unsigned char *img);
extern const unsigned char user_elf_start[];	/* forker image */
extern const unsigned char execee_elf_start[];	/* exec target image */

proc_t *
proc_alloc(void)
{
	int i;
	for (i = 0; i < NPROC; i++) {
		if (proc_tab[i].p_state == P_UNUSED) {
			proc_t *p = &proc_tab[i];
			p->p_pid = next_pid++;
			p->p_state = P_RUNNABLE;
			p->p_ppid = 0;
			p->p_pri = PRI_DEFAULT;	/* R-P28: default disp priority */
			p->p_kthread = 0;
			p->p_xstat = 0;
			p->p_kstack = kmem_alloc(KSTACK_SIZE);
			if (p->p_kstack == 0) {
				p->p_state = P_UNUSED;
				return (0);
			}
			p->p_kstack_top =
			    ((unsigned long)p->p_kstack + KSTACK_SIZE) & ~15UL;
			return (p);
		}
	}
	return (0);
}

/*
 * proc_first -- build the FIRST user process from an embedded ELF image: exec
 * the image into a fresh user AS, then seed a trap frame at the top of its
 * kernel stack + a scheduler context so the first rv_swtch into it drops to
 * U-mode at the program entry.  Returns the proc, RUNNABLE.
 */
proc_t *
proc_first(const unsigned char *img)
{
	proc_t *p = proc_alloc();
	struct uproc up;
	struct regs *tf;

	if (p == 0)
		return (0);
	if (exec_image(&up, img) != 0) {
		p->p_state = P_UNUSED;
		return (0);
	}
	p->p_uroot = (unsigned long *)up.u_root;
	p->p_usatp = up.u_satp;

	/* seed the trap frame at the top of the kernel stack. */
	tf = (struct regs *)(p->p_kstack_top - sizeof (struct regs));
	{
		unsigned int i;
		for (i = 0; i < 31; i++)
			tf->r_x[i] = 0;
	}
	tf->r_x[R_X_SP] = up.u_sp;		/* user sp */
	tf->r_sepc = up.u_entry;		/* first user instruction */
	/* sstatus: SPP=0 (return to U), SPIE=1, SUM=1 (kernel may touch U),
	   FS=Initial (bit 13): enable the U-mode FP unit so soft-float libgcc
	   routines (e.g. __multf3, which reads the frm CSR) do not trap as
	   illegal instructions -- the RISC-V privileged-spec FS state field.
	   R-P29: rv_swtch now saves/restores the FP register file (fcsr +
	   f0..f31) per context, so two FP-using procs that preempt each other
	   keep independent FP state (the FP-context-switch proof, fptest). */
	tf->r_sstatus = (1UL << 5) | (1UL << 18) | (1UL << 13);
	tf->r_scause = 0;
	tf->r_stval = 0;
	p->p_tf = tf;

	/*
	 * Scheduler context: when the scheduler rv_swtch'es into p, it loads
	 * c_satp = the USER satp (so the trap epilogue sret's straight into the
	 * user AS), sp = the trap frame, ra = rv_user_frame_ret (falls into the
	 * trap-return epilogue).  The kernel stack + frame live in identity-
	 * mapped low DRAM which the user AS also maps (shared kernel high half),
	 * so the epilogue runs correctly under the user satp.
	 */
	{
		int i;
		p->p_ctx.c_ra = (unsigned long)rv_user_frame_ret;
		p->p_ctx.c_sp = (unsigned long)tf;
		for (i = 0; i < 12; i++)
			p->p_ctx.c_s[i] = 0;
		p->p_ctx.c_satp = up.u_satp;
		ctx_clear_fp(&p->p_ctx);
	}
	return (p);
}

/* copy the parent user AS: walk the parent's L2 idx 0 subtree and duplicate
   every 4 KiB user leaf frame into the child (copy, not COW). */
extern int hat_user_copy(unsigned long *dst_root, unsigned long *src_root);
extern unsigned long *hat_user_new(void);

/*
 * do_fork -- allocate a child, copy the parent AS, copy the parent trap frame
 * (child a0=0), seed the child scheduler context so its first swtch sret's to
 * U-mode after the fork ecall.  Returns the child pid, or -1.
 */
static int
do_fork(proc_t *parent)
{
	proc_t *child = proc_alloc();
	struct regs *ctf;
	unsigned long *croot;
	int i;

	if (child == 0)
		return (-1);
	croot = hat_user_new();
	if (croot == 0) {
		child->p_state = P_UNUSED;
		return (-1);
	}
	if (hat_user_copy(croot, parent->p_uroot) != 0) {
		child->p_state = P_UNUSED;
		return (-1);
	}
	child->p_uroot = croot;
	child->p_usatp = MAKE_SATP((unsigned long)croot);
	child->p_ppid = parent->p_pid;

	/* copy the parent's trap frame to the top of the child kstack. */
	ctf = (struct regs *)(child->p_kstack_top - sizeof (struct regs));
	*ctf = *parent->p_tf;
	ctf->r_x[R_X_A0] = 0;			/* child returns 0 from fork */
	child->p_tf = ctf;

	/* seed the child scheduler context (same shape as proc_first). */
	child->p_ctx.c_ra = (unsigned long)rv_user_frame_ret;
	child->p_ctx.c_sp = (unsigned long)ctf;
	for (i = 0; i < 12; i++)
		child->p_ctx.c_s[i] = 0;
	child->p_ctx.c_satp = child->p_usatp;
	ctx_clear_fp(&child->p_ctx);

	return (child->p_pid);
}

/*
 * do_exec -- replace curproc's user AS with a freshly loaded embedded ELF and
 * rewrite its trap frame so the epilogue sret's into the new program.  Reduced
 * (embedded image, no fs/open, no argv passthrough).
 */
static int
do_exec(proc_t *p, const unsigned char *img)
{
	struct uproc up;
	struct regs *tf = p->p_tf;
	unsigned int i;

	/* R-P27: a DYNAMIC image (PT_INTERP) is loaded together with its
	   interpreter (ld.so.1); we enter the interpreter, not the app. */
	if (elf_has_interp(img) != 0) {
		if (exec_dynamic(&up, img) != 0)
			return (-1);
	} else if (exec_image(&up, img) != 0) {
		return (-1);
	}
	/* leak the old AS frames (reduced: no as_free yet). */
	p->p_uroot = (unsigned long *)up.u_root;
	p->p_usatp = up.u_satp;

	for (i = 0; i < 31; i++)
		tf->r_x[i] = 0;
	tf->r_x[R_X_SP] = up.u_sp;
	tf->r_sepc = up.u_entry;
	tf->r_sstatus = (1UL << 5) | (1UL << 18) | (1UL << 13); /* SPIE|SUM|FS=Initial, SPP=0 */
	/* the scheduler context c_satp must follow the new AS too. */
	p->p_ctx.c_satp = up.u_satp;
	/*
	 * Switch the LIVE satp now: we are mid-syscall in this proc's context
	 * with the OLD user AS installed, and the trap-return epilogue does not
	 * reload satp -- it sret's under whatever satp is current.  Install the
	 * new AS so the epilogue returns into the new program.  The kernel
	 * stack + trap frame live in identity-mapped low DRAM that the new user
	 * AS also maps (shared kernel high half), so this is safe mid-kernel.
	 */
	rv_set_satp(up.u_satp);
	return (0);
}

/* ---- the cooperative scheduler --------------------------------------- */

/*
 * sched -- yield the CPU from curproc back to the scheduler.  Saves the proc
 * context (rv_swtch into sched_ctx); the proc resumes here when the scheduler
 * next runs it.
 */
static void
sched(void)
{
	proc_t *p = curproc;
	rv_swtch(&p->p_ctx, &sched_ctx);
}

/*
 * proc_preempt_tick -- R-P27: called from the timer interrupt (rv_interrupt)
 * on every clock tick.  If a user proc is currently running (curproc != 0 and
 * we took the tick from its kernel trap context), raise want_resched so the
 * trap path yields to the scheduler on the way out.  We do NOT rv_swtch here
 * directly: we are on the proc's kernel stack inside the interrupt frame, so we
 * defer the context switch to the syscall/interrupt-return path (proc_yield),
 * exactly like illumos setting cpu_runrun / xv6 setting p->yield-on-tick.
 */
void
proc_preempt_tick(void)
{
	if (curproc != 0)
		want_resched = 1;
}

/*
 * proc_preempt_pending -- R-P27: the trap-return path asks whether a tick
 * requested a reschedule while this proc was running.  Consumes the flag.
 */
int
proc_preempt_pending(void)
{
	int w = want_resched;
	want_resched = 0;
	return (w && curproc != 0);
}

/*
 * proc_yield -- R-P27: PREEMPT the running proc.  Put it back on the runq
 * (RUNNABLE) and yield to the scheduler; when the scheduler next picks it the
 * rv_swtch returns here, sched() returns, and the interrupted trap epilogue
 * resumes the proc exactly where the tick hit it.  This turns the R-P26
 * cooperative dispatcher preemptive: a CPU-bound proc that never yields is
 * forced off the CPU by the timer.
 *
 * CRIB PROVENANCE: the "tick sets a resched flag, the trap-return path calls
 * yield() which sets the thread RUNNABLE + swtch()es to the scheduler" split is
 * illumos clock()/preempt()/cpu_runrun + xv6-riscv usertrap yield-on-tick;
 * resuming the interrupted frame after the swtch-back is the same mechanism as
 * a cooperative sched() (the proc's whole kernel call stack is preserved).
 */
void
proc_yield(void)
{
	proc_t *p = curproc;
	if (p == 0)
		return;
	p->p_state = P_RUNNABLE;	/* back on the runq */
	rv_swtch(&p->p_ctx, &sched_ctx);
}

/*
 * rv_sched -- the priority dispatcher loop.  Runs on the boot/kernel context+AS.
 * On each pass it picks the HIGHEST-PRIORITY RUNNABLE proc (illumos disp(): the
 * highest occupied dispatch band; FIFO within a band by proc-table order),
 * marks it RUNNING, and rv_swtch'es into it (loading its satp -- the user satp
 * for a user proc, or the kernel satp for a kernel thread).  When it yields
 * back, loops.  Returns when NO proc is left RUNNABLE/RUNNING/WAITING.
 *
 * CRIB PROVENANCE: "scan the dispatch queues from highest priority down, run
 * the first runnable thread, re-dispatch on yield" is illumos uts/common/disp/
 * disp.c disp() + the DISP_MAXRUNPRI/dq band walk, reduced from 170 global
 * priorities + per-CPU disp_t queues to a small NPRI band scan over the proc
 * table; the round-robin-within-a-band is the illumos TS quantum behavior.
 */
void
rv_sched(void)
{
	kernel_satp = rv_get_satp();
	sched_ctx.c_satp = kernel_satp;

	for (;;) {
		int i, any_alive = 0;
		int best = -1, top_pri = -1;

		/* pass 1: reap parentless zombies + find the top occupied band. */
		for (i = 0; i < NPROC; i++) {
			proc_t *p = &proc_tab[i];
			if (p->p_state == P_ZOMBIE && p->p_ppid == 0) {
				if (p->p_kstack != 0)
					kmem_free(p->p_kstack, KSTACK_SIZE);
				p->p_state = P_UNUSED;
				p->p_kstack = 0;
				continue;
			}
			if (p->p_state == P_RUNNABLE && p->p_pri > top_pri)
				top_pri = p->p_pri;
			if (p->p_state == P_RUNNABLE ||
			    p->p_state == P_RUNNING ||
			    p->p_state == P_WAITING)
				any_alive = 1;
		}
		/*
		 * pass 2: ROUND-ROBIN within the top band -- scan from the slot
		 * after the last one we ran, so equal-priority procs take turns
		 * (FIFO within a disp band).  This keeps preemption fair: two
		 * equal-priority CPU-bound procs interleave instead of the
		 * lowest-slot one monopolizing.
		 */
		if (top_pri >= 0) {
			for (i = 0; i < NPROC; i++) {
				int j = (sched_last + 1 + i) % NPROC;
				proc_t *p = &proc_tab[j];
				if (p->p_state == P_RUNNABLE &&
				    p->p_pri == top_pri) {
					best = j;
					break;
				}
			}
		}
		if (best >= 0) {
			proc_t *p = &proc_tab[best];
			sched_last = best;
			p->p_state = P_RUNNING;
			curproc = p;
			rv_swtch(&sched_ctx, &p->p_ctx);
			curproc = 0;
			continue;	/* re-dispatch: re-pick the top band */
		}
		if (!any_alive)
			return;
	}
}

/* ---- the syscall bodies (called from rv_syscall in main.c) ----------- */

int proc_getpid(void) { return (curproc ? curproc->p_pid : 0); }

/*
 * proc_brk -- SYS_brk body.  A minimal program break: the heap grows upward
 * from HEAP_BASE, one 4 KiB page mapped on demand into the proc's user AS.
 * brk(0) queries the current break; brk(addr) grows (mapping fresh zeroed
 * frames) or shrinks the break and returns the NEW break, or -1 on failure.
 * The heap lives in the level-2 index-0 user subtree (below the 0x40000000
 * user stack), same private region fork deep-copies.
 *
 * CRIB PROVENANCE: brk/sbrk growing an anonymous heap segment by mapping fresh
 * pages is illumos os/grow.c brk()/brk_internal + as_map of the heap seg,
 * reduced to on-demand 4 KiB leaf maps (no seg_vn, no lazy fault-in).
 */
#define	HEAP_BASE	0x20000000UL
extern int hat_user_map(unsigned long *root, unsigned long va,
    unsigned long pa, unsigned long perms);

long
proc_brk(unsigned long newbrk)
{
	proc_t *p = curproc;
	unsigned long cur, va;

	if (p == 0)
		return (-1);
	if (p->p_brk == 0)
		p->p_brk = HEAP_BASE;	/* first call: seed the heap base */
	cur = p->p_brk;
	if (newbrk == 0)
		return ((long)cur);	/* query */
	if (newbrk < HEAP_BASE)
		return (-1);
	/* grow: map fresh zeroed pages from the page-up of cur to newbrk. */
	for (va = (cur + PAGEOFFSET) & PAGEMASK;
	    va < ((newbrk + PAGEOFFSET) & PAGEMASK); va += PAGESIZE) {
		unsigned char *frame = kmem_alloc_page();
		unsigned int b;
		if (frame == 0)
			return (-1);
		for (b = 0; b < PAGESIZE; b++)
			frame[b] = 0;
		if (hat_user_map(p->p_uroot, va, (unsigned long)frame,
		    PTE_R | PTE_W | PTE_U) != 0)
			return (-1);
	}
	rv_tlb_flush_all();		/* the mapping changed under the live satp */
	p->p_brk = newbrk;
	return ((long)newbrk);
}

/* R-P28: the current proc's user Sv39 root (for SYS_mapso mapping into it). */
unsigned long *
proc_curroot(void)
{
	return (curproc ? curproc->p_uroot : 0);
}

/* ---- R-P28: kernel threads + priority-dispatch proof ---------------- */

/*
 * kthread_exit -- a kernel thread's return path.  Marks the running (kernel)
 * proc ZOMBIE so the scheduler stops dispatching it, and yields to the
 * scheduler forever.  A kernel thread runs a plain C function in the kernel AS;
 * when that function returns (via the trampoline) or calls this, it is done.
 */
void
kthread_exit(void)
{
	proc_t *p = curproc;
	if (p != 0)
		p->p_state = P_ZOMBIE;
	rv_swtch(&p->p_ctx, &sched_ctx);	/* never returns */
	for (;;)
		;
}

/*
 * kthread_trampoline -- the shim a fresh kernel thread "returns" into: run the
 * thread's start function (curproc->p_kentry), then kthread_exit().  Reading
 * the entry from curproc (set at first dispatch by rv_sched) is register-
 * clobber-safe and gives each thread its own entry -- the illumos t_pc idiom.
 */
static void
kthread_trampoline(void)
{
	void (*entry)(void) = curproc ? curproc->p_kentry : 0;
	if (entry != 0)
		entry();
	kthread_exit();
}

/*
 * kthread_create -- create a kernel thread that runs entry() at dispatch
 * priority `pri` on a fresh kernel stack in the kernel AS.  The scheduler picks
 * it by priority like any other proc.  Returns the pid, or -1.
 *
 * CRIB PROVENANCE: thread_create() building a kthread_t on a fresh stack with a
 * seeded start context (t_pc/t_sp) + a dispatch priority t_pri is illumos
 * uts/common/disp/thread.c thread_create() + the R-P24 startup.c thread_init/
 * swtch seam, reduced to the proc_t + rv_context of this kernel.
 */
int
kthread_create(void (*entry)(void), int pri)
{
	proc_t *p = proc_alloc();
	int i;

	if (p == 0)
		return (-1);
	p->p_kthread = 1;
	p->p_ppid = 0;
	if (pri < PRI_MIN) pri = PRI_MIN;
	if (pri > PRI_MAX) pri = PRI_MAX;
	p->p_pri = pri;
	p->p_uroot = 0;
	p->p_usatp = rv_get_satp();		/* kernel AS */
	p->p_tf = 0;
	p->p_kentry = entry;			/* the illumos t_pc: read at dispatch */

	p->p_ctx.c_ra = (unsigned long)kthread_trampoline;
	p->p_ctx.c_sp = p->p_kstack_top;
	for (i = 0; i < 12; i++)
		p->p_ctx.c_s[i] = 0;
	p->p_ctx.c_satp = rv_get_satp();	/* run in the kernel AS */
	ctx_clear_fp(&p->p_ctx);
	return (p->p_pid);
}

/*
 * proc_fork -- SYS_fork body.  Fork off a child; the PARENT (curproc) returns
 * the child pid here; the CHILD is a fresh RUNNABLE proc that the scheduler
 * will run and which "returns" 0 (its trap frame a0=0).  Returns child pid to
 * the parent, -1 on failure.
 */
long
proc_fork(void)
{
	return (do_fork(curproc));
}

/* proc_exec -- SYS_execve body.  R-P27: resolve `path` in the initramfs
 * (fs-backed exec) and exec those ELF bytes.  Falls back to the embedded
 * execee image if the path is not in the ramfs (R-P26 back-compat).  On
 * success does NOT return to the caller's old image; the trap frame now points
 * at the new program, so returning from the syscall sret's into it.  Returns
 * 0, or -1 on failure. */
extern int ramfs_lookup(const char *path, const unsigned char **out,
    unsigned long *outlen);

long
proc_exec(const char *path)
{
	const unsigned char *img;
	unsigned long len;

	if (path != 0 && ramfs_lookup(path, &img, &len) == 0)
		return (do_exec(curproc, img));
	/* not in the ramfs: fall back to the embedded execee (R-P26). */
	return (do_exec(curproc, execee_elf_start));
}

/*
 * proc_exit -- SYS_exit body.  Record the status, mark ZOMBIE, wake a WAITING
 * parent, and yield to the scheduler FOREVER (a ZOMBIE never runs again).
 */
void
proc_exit(int status)
{
	proc_t *p = curproc;
	int i;

	p->p_xstat = status;
	p->p_state = P_ZOMBIE;
	/* wake a parent blocked in wait(). */
	for (i = 0; i < NPROC; i++) {
		if (proc_tab[i].p_state == P_WAITING &&
		    proc_tab[i].p_pid == p->p_ppid)
			proc_tab[i].p_state = P_RUNNABLE;
	}
	sched();		/* never returns (ZOMBIE is not RUNNABLE) */
	/* not reached */
	for (;;)
		;
}

/*
 * proc_wait -- SYS_wait body.  Block until a child of curproc is ZOMBIE, reap
 * it (free its kstack, mark UNUSED), store its exit status through *statusp
 * (a user VA reachable under the current user satp), and return its pid.
 * Returns -1 if the caller has no children.
 */
long
proc_wait(long *statusp)
{
	proc_t *p = curproc;

	for (;;) {
		int i, have_child = 0;
		for (i = 0; i < NPROC; i++) {
			proc_t *c = &proc_tab[i];
			if (c->p_ppid != p->p_pid ||
			    c->p_state == P_UNUSED)
				continue;
			have_child = 1;
			if (c->p_state == P_ZOMBIE) {
				int pid = c->p_pid;
				int xs = c->p_xstat;
				/* reap: free the kstack, clear the slot. */
				kmem_free(c->p_kstack, KSTACK_SIZE);
				c->p_state = P_UNUSED;
				c->p_ppid = 0;
				if (statusp != 0)
					*statusp = xs;
				return (pid);
			}
		}
		if (!have_child)
			return (-1);
		/* no zombie child yet: block + yield. */
		p->p_state = P_WAITING;
		sched();
		/* woken (a child exited): re-scan. */
	}
}
