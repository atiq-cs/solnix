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
extern void putdec_pub(unsigned long);
extern void puthex_pub(unsigned long);

/* the scheduler <-> proc context switch (mach_swtch.S). */
extern void rv_swtch(struct rv_context *old, struct rv_context *nw);
/* the asm shim a fresh proc context "returns" into: sp = trap frame, fall
   into the trap-return epilogue and sret to U-mode. */
extern void rv_user_frame_ret(void);

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
#define	NPROC		8
#define	KSTACK_SIZE	(16UL * 1024)

enum p_state { P_UNUSED = 0, P_RUNNABLE, P_RUNNING, P_WAITING, P_ZOMBIE };

typedef struct proc {
	int		p_pid;
	enum p_state	p_state;
	int		p_ppid;		/* parent pid (0 = none) */
	unsigned long	*p_uroot;	/* user Sv39 root (== PA); MAKE_SATP()able */
	unsigned long	p_usatp;	/* satp value for this AS */
	unsigned char	*p_kstack;	/* kernel stack base (kmem) */
	unsigned long	p_kstack_top;	/* kernel stack top (== sscratch in U) */
	struct rv_context p_ctx;	/* saved scheduler context (rv_swtch) */
	struct regs	*p_tf;		/* the proc's trap frame on its kstack */
	int		p_xstat;	/* exit status (valid when ZOMBIE) */
} proc_t;

static proc_t proc_tab[NPROC];
static int next_pid = 1;
static proc_t *curproc;			/* the running proc (0 in scheduler) */
static struct rv_context sched_ctx;	/* the scheduler's own context */
static unsigned long kernel_satp;

/* exec_elf.c: load the ELF at img[0..) into a fresh user AS; fills up. */
extern int exec_image(struct uproc *up, const unsigned char *img);
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
	/* sstatus: SPP=0 (return to U), SPIE=1, SUM=1 (kernel may touch U). */
	tf->r_sstatus = (1UL << 5) | (1UL << 18);
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

	if (exec_image(&up, img) != 0)
		return (-1);
	/* leak the old AS frames (reduced: no as_free yet). */
	p->p_uroot = (unsigned long *)up.u_root;
	p->p_usatp = up.u_satp;

	for (i = 0; i < 31; i++)
		tf->r_x[i] = 0;
	tf->r_x[R_X_SP] = up.u_sp;
	tf->r_sepc = up.u_entry;
	tf->r_sstatus = (1UL << 5) | (1UL << 18);	/* SPIE | SUM, SPP=0 */
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
 * rv_sched -- the scheduler loop.  Runs on the boot/kernel context+AS.  Picks
 * a RUNNABLE proc, marks it RUNNING, swtches into it (loading its user satp);
 * when it yields back, loops.  Returns when NO proc is left RUNNABLE/RUNNING/
 * WAITING (all UNUSED/ZOMBIE-and-reaped) -- the boot proof's known end.
 */
void
rv_sched(void)
{
	kernel_satp = rv_get_satp();
	sched_ctx.c_satp = kernel_satp;

	for (;;) {
		int i, any_alive = 0, ran = 0;

		for (i = 0; i < NPROC; i++) {
			proc_t *p = &proc_tab[i];
			if (p->p_state == P_RUNNABLE) {
				p->p_state = P_RUNNING;
				curproc = p;
				rv_swtch(&sched_ctx, &p->p_ctx);
				curproc = 0;
				ran = 1;
			}
			if (p->p_state == P_RUNNABLE ||
			    p->p_state == P_RUNNING ||
			    p->p_state == P_WAITING)
				any_alive = 1;
		}
		if (!any_alive)
			return;
		(void) ran;
	}
}

/* ---- the syscall bodies (called from rv_syscall in main.c) ----------- */

int proc_getpid(void) { return (curproc ? curproc->p_pid : 0); }

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

/* proc_exec -- SYS_execve body.  path is ignored (reduced); we exec the
   embedded execee image.  On success does NOT return to the caller's old
   image; the trap frame now points at the new program, so returning from the
   syscall sret's into it.  Returns 0. */
long
proc_exec(const char *path)
{
	(void) path;
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
