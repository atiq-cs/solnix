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
#define	NOFILE		16		/* R-P31.3: open files per proc */
#define	NSIG		32		/* R-P33.1: signal count */
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

enum p_state { P_UNUSED = 0, P_RUNNABLE, P_RUNNING, P_WAITING, P_ZOMBIE, P_REAPING };

typedef struct proc {
	int		p_pid;
	enum p_state	p_state;
	int		p_ppid;		/* parent pid (0 = none) */
	int		p_pri;		/* R-P28: dispatch priority (higher = sooner) */
	int		p_hart;		/* R-P32: the hart currently dispatching it */
	int		p_onproc;	/* R-P32: 1 while switching off-cpu (context not yet safely saved) -- other harts must not pick it */
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
	/*
	 * R-P32.3: a per-proc open-file table over the VNODE layer.  Each open
	 * fd holds a vnode pointer (ramfs or tmpfs) + a byte offset (file
	 * position); read/write/getattr dispatch through the vnode op vector
	 * (vfs.c).  fds 0/1/2 are the console (f_vnode==0); fds >=3 are files.
	 */
	struct {
		void		*f_vnode;	/* vnode_t * (0 = console/free) */
		unsigned long	f_off;		/* current file offset */
		int		f_used;		/* 1 = open */
		/* R-P33.2: a pipe end.  f_pipe != 0 marks this fd a pipe end;
		   f_pipe_w = 1 write end, 0 read end.  f_dir marks a directory
		   fd opened for getdents (a tmpfs dir vnode). */
		void		*f_pipe;	/* struct pipe * (0 = not a pipe) */
		int		f_pipe_w;	/* 1 = write end, 0 = read end */
		int		f_dir;		/* 1 = a directory fd (getdents) */
	}		p_fd[NOFILE];
	/*
	 * R-P33.1: per-proc signal state.  p_sigpend is the pending-signal
	 * bitmask (bit N set = signal N pending); p_sighand[N] is the
	 * disposition (0=SIG_DFL, 1=SIG_IGN, else a user handler VA);
	 * p_sigrestorer is the userland sa_restorer trampoline (ecall
	 * SYS_sigreturn) the handler `ret`s into.  Inherited across fork.
	 */
	volatile unsigned int p_sigpend;	/* pending signal bitmask */
	unsigned long	p_sighand[NSIG];	/* per-signal disposition */
	unsigned long	p_sigrestorer;		/* sa_restorer VA */
	/*
	 * R-P33.3: file-backed demand-exec.  When exec maps the text segment
	 * LAZY, it records the ELF file backing here so the page-fault handler
	 * copies each touched text page from the image on first fetch.
	 * p_dimg == 0 means no file-backed segment.
	 */
	const unsigned char *p_dimg;	/* ELF image base for demand text */
	unsigned long	p_dva;		/* text segment first VA (page-aligned) */
	unsigned long	p_doff;		/* file offset backing p_dva */
	unsigned long	p_dfilesz;	/* file-backed bytes from p_dva */
	unsigned long	p_dmemsz;	/* total segment span from p_dva */
} proc_t;

#define	NCPU		2

static proc_t proc_tab[NPROC];
static int next_pid = 1;
/*
 * R-P32: PROCS ON BOTH HARTS.  The dispatcher runs on BOTH harts concurrently,
 * pulling real proc_t contexts from ONE shared runq (proc_tab) under a spinlock.
 * So the running proc, the scheduler context, and the round-robin cursor are
 * PER-HART (indexed by cpuid() == the hartid, carried in tp).  A proc forked on
 * hart 0 sits RUNNABLE in the shared table and may be dispatched by hart 1.
 *
 * CRIB PROVENANCE: a shared dispatch queue drained by every CPU with a per-CPU
 * "current thread" (cpu_t.cpu_thread) + per-CPU idle/scheduler context is the
 * illumos disp() / cpu_t model (uts/common/disp/disp.c) + the R-P29 per-CPU
 * dispatch seam; the tp-holds-hartid convention is the RISC-V calling-convention
 * thread pointer repurposed as the per-CPU pointer (Linux riscv __my_cpu_offset /
 * xv6-riscv tp=hartid).
 */
static proc_t *cpu_cur[NCPU];		/* the running proc per hart (0 in sched) */
static struct rv_context cpu_sched_ctx[NCPU];	/* per-hart scheduler context */
static volatile int sched_lock;		/* guards proc_tab state + the cursor */
static int sched_last = -1;		/* R-P28: round-robin cursor within a band */
static unsigned long kernel_satp;
static volatile int want_resched[NCPU];	/* R-P27: a tick asked to preempt (per hart) */

/* R-P32.1: count of USER-proc dispatches per hart (the procs-on-both-harts
   proof watches this go >0 on both harts). */
volatile int proc_smp_ran_hart[NCPU];

/* cpuid() -- the current hart id, stashed in tp at kernel entry (locore). */
static inline int
cpuid(void)
{
	unsigned long id;
	__asm__ __volatile__("mv %0, tp" : "=r"(id));
	return ((int)(id & (NCPU - 1)));
}

/* curproc/sched_ctx are per-hart; refer to THIS hart's slot everywhere. */
#define	curproc		(cpu_cur[cpuid()])
#define	sched_ctx	(cpu_sched_ctx[cpuid()])

static void
sched_spin_lock(void)
{
	int prev;
	do {
		__asm__ __volatile__("amoswap.w.aq %0, %2, %1"
		    : "=r"(prev), "+A"(sched_lock) : "r"(1) : "memory");
	} while (prev != 0);
}
static void
sched_spin_unlock(void)
{
	__asm__ __volatile__("amoswap.w.rl zero, zero, %0"
	    : "+A"(sched_lock) :: "memory");
}

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
	sched_spin_lock();
	for (i = 0; i < NPROC; i++) {
		if (proc_tab[i].p_state == P_UNUSED) {
			proc_t *p = &proc_tab[i];
			p->p_pid = next_pid++;
			p->p_state = P_RUNNABLE;
			p->p_ppid = 0;
			p->p_pri = PRI_DEFAULT;	/* R-P28: default disp priority */
			p->p_kthread = 0;
			p->p_xstat = 0;
			/* R-P33.1: a fresh proc slot has no pending signals + all
			   dispositions default (SIG_DFL); fork overwrites the
			   disposition table + restorer from the parent afterward. */
			{
				int s;
				p->p_sigpend = 0;
				p->p_sigrestorer = 0;
				for (s = 0; s < NSIG; s++)
					p->p_sighand[s] = 0;	/* SIG_DFL */
			}
			/* R-P33.2: a recycled slot starts with a clean fd table
			   (no stale vnode/pipe pointers from a prior proc). */
			{
				int fd;
				for (fd = 0; fd < NOFILE; fd++) {
					p->p_fd[fd].f_used = 0;
					p->p_fd[fd].f_vnode = 0;
					p->p_fd[fd].f_pipe = 0;
					p->p_fd[fd].f_off = 0;
					p->p_fd[fd].f_pipe_w = 0;
					p->p_fd[fd].f_dir = 0;
				}
			}
			/* RUNNABLE but NOT pickable until the caller finishes seeding
			   its context (do_fork/proc_first/kthread_create clear
			   p_onproc); closes the fresh-proc SMP setup race. */
			p->p_onproc = 1;
			sched_spin_unlock();
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
	sched_spin_unlock();
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
	p->p_onproc = 0;		/* context seeded: pickable by any hart */
	return (p);
}

/*
 * proc_first_demand -- R-P33.3: build the first process with FILE-BACKED
 * DEMAND-EXEC.  Same as proc_first but loads the ELF via exec_image_demand
 * (the text segment is mapped LAZY + file-backed) and records the demand region
 * on the proc so proc_pagefault -> exec_demand_fault pages the text in from the
 * ELF image on the first fetch fault.
 */
extern int exec_image_demand(struct uproc *up, const unsigned char *img);

proc_t *
proc_first_demand(const unsigned char *img)
{
	proc_t *p = proc_alloc();
	struct uproc up;
	struct regs *tf;
	int i;

	if (p == 0)
		return (0);
	if (exec_image_demand(&up, img) != 0) {
		p->p_state = P_UNUSED;
		return (0);
	}
	p->p_uroot = (unsigned long *)up.u_root;
	p->p_usatp = up.u_satp;
	/* record the file-backed demand-exec region. */
	p->p_dimg = up.ud_img;
	p->p_dva = up.ud_va;
	p->p_doff = up.ud_off;
	p->p_dfilesz = up.ud_filesz;
	p->p_dmemsz = up.ud_memsz;

	tf = (struct regs *)(p->p_kstack_top - sizeof (struct regs));
	for (i = 0; i < 31; i++)
		tf->r_x[i] = 0;
	tf->r_x[R_X_SP] = up.u_sp;
	tf->r_sepc = up.u_entry;
	tf->r_sstatus = (1UL << 5) | (1UL << 18) | (1UL << 13);
	tf->r_scause = 0;
	tf->r_stval = 0;
	p->p_tf = tf;

	p->p_ctx.c_ra = (unsigned long)rv_user_frame_ret;
	p->p_ctx.c_sp = (unsigned long)tf;
	for (i = 0; i < 12; i++)
		p->p_ctx.c_s[i] = 0;
	p->p_ctx.c_satp = up.u_satp;
	ctx_clear_fp(&p->p_ctx);
	p->p_onproc = 0;
	return (p);
}

/* copy the parent user AS: walk the parent's L2 idx 0 subtree and duplicate
   every 4 KiB user leaf frame into the child (copy, not COW). */
extern int hat_user_copy(unsigned long *dst_root, unsigned long *src_root);
extern unsigned long *hat_user_new(void);
/* R-P32 COW: share the parent's leaves into the child read-only + PTE_COW, and
   the copy-on-write / demand-paging fault handlers. */
extern int hat_user_cow_share(unsigned long *dst_root, unsigned long *src_root);
extern int hat_cow_fault(unsigned long *root, unsigned long va);
extern int hat_demand_fault(unsigned long *root, unsigned long va);
extern int hat_user_lazy(unsigned long *root, unsigned long va,
    unsigned long perms);

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
	/*
	 * R-P32: COPY-ON-WRITE fork.  Share the parent's user leaves into the
	 * child read-only + PTE_COW (instead of R-P26's eager per-frame copy);
	 * a later write faults into hat_cow_fault, which copies just that page.
	 * This is the memory-efficiency step: fork no longer duplicates the
	 * whole AS up front, only the pages that are actually written.  The
	 * parent's own writable leaves are ALSO marked COW so the parent's next
	 * write to a shared page copies too (both sides fault-on-write).  The
	 * live parent satp must drop the stale (now-read-only) translations.
	 */
	if (hat_user_cow_share(croot, parent->p_uroot) != 0) {
		child->p_state = P_UNUSED;
		return (-1);
	}
	rv_tlb_flush_all();		/* parent leaves went RO under the live satp */
	child->p_uroot = croot;
	child->p_usatp = MAKE_SATP(KVTOP((unsigned long)croot));
	child->p_ppid = parent->p_pid;

	/*
	 * R-P33.1: fork inherits the parent's signal dispositions + the
	 * sa_restorer trampoline, but NOT the pending set (POSIX: the child
	 * starts with an empty pending mask).  proc_alloc already cleared
	 * p_sigpend; copy the handler table + restorer here.
	 */
	{
		int s;
		for (s = 0; s < NSIG; s++)
			child->p_sighand[s] = parent->p_sighand[s];
		child->p_sigrestorer = parent->p_sigrestorer;
	}

	/*
	 * R-P33.2: fork inherits the parent's open file descriptors (POSIX):
	 * the child shares the same vnodes / pipe ends / offsets.  Copy the fd
	 * table + bump the refcount on any inherited pipe end so a parent that
	 * writes + a child that reads talk over the SAME pipe.
	 */
	{
		int fd;
		for (fd = 0; fd < NOFILE; fd++) {
			child->p_fd[fd] = parent->p_fd[fd];
			if (parent->p_fd[fd].f_used &&
			    parent->p_fd[fd].f_pipe != 0) {
				extern void pipe_incref(void *pp, int is_write);
				pipe_incref(parent->p_fd[fd].f_pipe,
				    parent->p_fd[fd].f_pipe_w);
			}
		}
	}

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

	child->p_onproc = 0;		/* context seeded: now pickable by any hart */
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
	/* R-P30: free the OLD user AS (was leaked in R-P26/29's do_exec). */
	{
		extern void hat_as_free(unsigned long *root);
		unsigned long *old_root = p->p_uroot;
		p->p_uroot = (unsigned long *)up.u_root;
		p->p_usatp = up.u_satp;
		/*
		 * Switch to the NEW AS FIRST (the kernel stack + trap frame live
		 * in the direct-map, mapped by both ASes), THEN free the old
		 * user page tables + frames -- the old AS is no longer the live
		 * satp so tearing it down cannot pull the ground from under us.
		 */
		p->p_ctx.c_satp = up.u_satp;
		rv_set_satp(up.u_satp);
		hat_as_free(old_root);
	}

	for (i = 0; i < 31; i++)
		tf->r_x[i] = 0;
	tf->r_x[R_X_SP] = up.u_sp;
	tf->r_sepc = up.u_entry;
	tf->r_sstatus = (1UL << 5) | (1UL << 18) | (1UL << 13); /* SPIE|SUM|FS=Initial, SPP=0 */
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
	sched_spin_lock();
	p->p_onproc = 1;		/* switching off-cpu; not yet safely saved */
	sched_spin_unlock();
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
		want_resched[cpuid()] = 1;
}

/*
 * proc_preempt_pending -- R-P27: the trap-return path asks whether a tick
 * requested a reschedule while this proc was running.  Consumes the flag.
 */
int
proc_preempt_pending(void)
{
	int c = cpuid();
	int w = want_resched[c];
	want_resched[c] = 0;
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
	sched_spin_lock();
	p->p_state = P_RUNNABLE;	/* back on the runq */
	p->p_onproc = 1;	/* but not pickable until safely switched off-cpu */
	sched_spin_unlock();
	rv_swtch(&p->p_ctx, &sched_ctx);
}

/*
 * rv_sched_cpu -- R-P32: the SMP priority dispatcher loop, run on EACH hart
 * (cpu == the hartid).  BOTH harts run this concurrently against ONE shared
 * runq (proc_tab); a spinlock (sched_lock) serializes the scan + the state
 * transition so a proc is picked by exactly one hart.  It picks the highest-
 * priority RUNNABLE proc, marks it RUNNING, records the hart in p_hart, and
 * rv_swtch'es into it on THIS hart's scheduler context (loading the proc's
 * satp).  A proc forked on hart 0 sits RUNNABLE in the shared table and may be
 * dispatched by hart 1 -- procs migrate across harts through the shared runq.
 * Returns when NO proc is left alive.
 *
 * CRIB PROVENANCE: every CPU running disp() against a shared dispatch queue,
 * grabbing disp_lock to pick + transition a thread to onproc, recording
 * t_cpu/cpu_thread, then swtch'ing into it is illumos uts/common/disp/disp.c
 * disp() + the cpu_t per-CPU dispatch model; the spinlock-serialized shared
 * runq drained by two harts is the R-P28 smp.c runq + the RISC-V A-extension.
 */
extern void hat_as_free(unsigned long *root);

void
rv_sched_cpu(int cpu)
{
	struct rv_context *myctx = &cpu_sched_ctx[cpu];

	kernel_satp = rv_get_satp();
	myctx->c_satp = kernel_satp;

	for (;;) {
		int i, any_alive = 0;
		int best = -1, top_pri = -1;
		proc_t *reap = 0;

		sched_spin_lock();
		/* pass 1: find a parentless zombie to reap + the top band. */
		for (i = 0; i < NPROC; i++) {
			proc_t *p = &proc_tab[i];
			if (p->p_state == P_ZOMBIE && p->p_ppid == 0) {
				/* not reapable until it has switched off-cpu. */
				if (p->p_onproc) {
					any_alive = 1;
					continue;
				}
				/* claim it for reaping OUTSIDE the lock (kmem). */
				if (reap == 0) {
					p->p_state = P_REAPING;
					reap = p;
				}
				any_alive = 1;
				continue;
			}
			if (p->p_state == P_RUNNABLE && !p->p_onproc &&
			    p->p_pri > top_pri)
				top_pri = p->p_pri;
			if (p->p_state == P_RUNNABLE ||
			    p->p_state == P_RUNNING ||
			    p->p_state == P_REAPING ||
			    p->p_state == P_WAITING)
				any_alive = 1;
		}
		/*
		 * A claimed parentless zombie is freed FIRST (before dispatching)
		 * so it never lingers in P_REAPING -- outside the lock (kmem/
		 * hat_as_free), then marked UNUSED.
		 */
		if (reap != 0) {
			sched_spin_unlock();
			if (reap->p_kstack != 0)
				kmem_free(reap->p_kstack, KSTACK_SIZE);
			if (!reap->p_kthread && reap->p_uroot != 0)
				hat_as_free(reap->p_uroot);
			sched_spin_lock();
			reap->p_uroot = 0;
			reap->p_state = P_UNUSED;
			reap->p_kstack = 0;
			sched_spin_unlock();
			continue;
		}
		/* pass 2: round-robin within the top band (shared cursor). */
		if (top_pri >= 0) {
			for (i = 0; i < NPROC; i++) {
				int j = (sched_last + 1 + i) % NPROC;
				proc_t *p = &proc_tab[j];
				if (p->p_state == P_RUNNABLE && !p->p_onproc &&
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
			p->p_hart = cpu;	/* record the dispatching hart */
			cpu_cur[cpu] = p;
			if (!p->p_kthread)
				proc_smp_ran_hart[cpu]++;
			sched_spin_unlock();
			rv_swtch(myctx, &p->p_ctx);
			/*
			 * p switched back to us; its context is now fully SAVED, so
			 * clear p_onproc -- it is safe for any hart to re-dispatch
			 * (this closes the SMP save/load race: a proc is never picked
			 * by a peer hart while its context is mid-save).
			 */
			sched_spin_lock();
			p->p_onproc = 0;
			cpu_cur[cpu] = 0;
			sched_spin_unlock();
			continue;	/* re-dispatch */
		}
		sched_spin_unlock();
		if (!any_alive)
			return;
	}
}

/* rv_sched -- back-compat entry: the boot hart's dispatcher (hart 0). */
void
rv_sched(void)
{
	rv_sched_cpu(cpuid());
}

/*
 * proc_gethartid -- SYS_gethartid body: the hart the calling proc is running on
 * (its p_hart, set by rv_sched_cpu at dispatch).  A proc migrated to hart 1 by
 * the shared dispatcher reads 1 here.
 */
int
proc_gethartid(void)
{
	return (curproc ? curproc->p_hart : cpuid());
}

/* ---- R-P33.1: signal state accessors + kill(2) ----------------------- */
/*
 * signal.c owns the delivery/frame logic; proc.c owns proc_t, so these
 * accessors expose the running proc's signal state to signal.c without
 * publishing the whole proc_t.  proc_kill posts a signal to a pid (any proc,
 * possibly on the other hart) and wakes it if it is blocked in wait(2) so it
 * returns to U-mode and delivers.
 */
unsigned long *
proc_sighand(void)
{
	return (curproc ? curproc->p_sighand : 0);
}
volatile unsigned int *
proc_sigpend(void)
{
	return (curproc ? &curproc->p_sigpend : 0);
}
unsigned long
proc_sigrestorer(void)
{
	return (curproc ? curproc->p_sigrestorer : 0);
}
void
proc_set_sigrestorer(unsigned long va)
{
	if (curproc)
		curproc->p_sigrestorer = va;
}
int
proc_sigaction_cur(int sig, unsigned long handler)
{
	if (curproc == 0 || sig < 1 || sig >= NSIG)
		return (-1);
	curproc->p_sighand[sig] = handler;
	return (0);
}

/*
 * proc_kill -- SYS_kill body: post signal `sig` to process `pid`.  Sets the
 * pending bit in the target's p_sigpend (an atomic OR since the target may be
 * running on the other hart) and, if the target is blocked in wait(2) (WAITING),
 * makes it RUNNABLE so it wakes, returns to U-mode, and delivers.  Returns 0 on
 * success, -1 if no such live process.  sig 0 is the existence probe (no post).
 *
 * CRIB PROVENANCE: sigtoproc() setting p_sig / t_sig and unsleeping the target
 * (setrun) is illumos uts/common/os/sig.c sigtoproc + eat_signal; the atomic
 * OR into the pending mask across CPUs is the SMP-safe bit-set (RISC-V A ext).
 */
int
proc_kill(int pid, int sig)
{
	int i, rc = -1;

	if (sig < 0 || sig >= NSIG)
		return (-1);
	sched_spin_lock();
	for (i = 0; i < NPROC; i++) {
		proc_t *p = &proc_tab[i];
		if (p->p_pid != pid || p->p_state == P_UNUSED ||
		    p->p_state == P_ZOMBIE || p->p_state == P_REAPING)
			continue;
		if (sig != 0) {
			__sync_fetch_and_or(&p->p_sigpend, (1u << sig));
			if (p->p_state == P_WAITING)
				p->p_state = P_RUNNABLE;
		}
		rc = 0;
		break;
	}
	sched_spin_unlock();
	return (rc);
}

/* ---- R-P32.1: the REAL proc_t dispatcher on BOTH harts --------------- */

static volatile int proc_smp_secondary_online;
static volatile int proc_smp_go;

/*
 * proc_secondary_main -- the C entry the secondary hart reaches from
 * proc_ap_high (tp already = hartid).  Wait for the boot hart to seed the
 * procs (proc_smp_go), then run the SHARED proc dispatcher rv_sched_cpu(hartid):
 * it pulls real proc_t contexts off the same runq the boot hart drains, so a
 * process forked on hart 0 can be dispatched here on hart 1.  When the runq
 * drains, STOP (HSM) so a later SMP phase can restart this hart.
 */
void
proc_secondary_main(unsigned long hartid)
{
	volatile unsigned long spin;
	proc_smp_secondary_online = 1;
	for (spin = 0; spin < 200000000UL && proc_smp_go == 0; spin++)
		;
	rv_sched_cpu((int)hartid);
	sbi_hart_stop();
	for (;;)
		__asm__ __volatile__("wfi");
}

/*
 * run_procs_smp -- R-P32.1 driver (boot hart).  Build a first process from the
 * embedded smproc ELF (which forks N children, each printing its hartid), bring
 * up the secondary hart into proc_secondary_main, then BOTH harts run
 * rv_sched_cpu against the SHARED runq -- real proc_t processes are dispatched
 * across two hartids, scheduler-balanced.
 */
extern const unsigned char smproc_elf_start[];
extern long sbi_hart_start(unsigned long, unsigned long, unsigned long);
extern void proc_ap_entry(void);
extern unsigned long hat_boot_root_satp(void);

void
run_procs_smp(unsigned long boot_hartid)
{
	unsigned long sec = boot_hartid ^ 1;
	unsigned long ksatp = hat_boot_root_satp();
	volatile unsigned long spin;
	long err;
	proc_t *p0;
	int h0 = 0, h1 = 0, i;

	sbi_console_puts("\n");
	sbi_console_puts("[R-P32.1] procs on BOTH harts: the real proc_t "
	    "dispatcher runs on 2 harts; a forked proc can run on either\n");
	sbi_console_puts("----- procs-on-both-harts proof output -----\n");

	proc_smp_secondary_online = 0;
	proc_smp_go = 0;

	/* build the first process (it forks N children that print their hartid). */
	p0 = proc_first(smproc_elf_start);
	if (p0 == 0) {
		sbi_console_puts("[R-P32.1] proc_first(smproc) FAILED\n");
		return;
	}

	/* bring up the secondary into the shared proc dispatcher. */
	err = sbi_hart_start(sec, KVTOP((unsigned long)proc_ap_entry), ksatp);
	if (err != 0) {
		sbi_console_puts("  [smp] secondary start FAILED; running the "
		    "proc dispatcher UP on the boot hart\n");
		proc_smp_go = 1;
		rv_sched_cpu((int)boot_hartid);
	} else {
		for (spin = 0; spin < 200000000UL &&
		    proc_smp_secondary_online == 0; spin++)
			;
		sbi_console_puts("  [smp] secondary hart online in the proc "
		    "dispatcher; both harts now drain the shared runq\n");
		proc_smp_go = 1;		/* release the secondary */
		rv_sched_cpu((int)boot_hartid);	/* boot hart dispatches too */
		/* wait for the secondary to finish + STOP. */
		for (spin = 0; spin < 400000000UL; spin++)
			;
	}

	sbi_console_puts("----- end procs-on-both-harts proof output -----\n");
	/* tally how many procs each hart last dispatched. */
	for (i = 0; i < NPROC; i++) {
		(void) i;
	}
	h0 = proc_smp_ran_hart[0];
	h1 = proc_smp_ran_hart[1];
	sbi_console_puts("  [R-P32.1] procs dispatched: hart0=");
	putdec_pub((unsigned long)h0);
	sbi_console_puts(" hart1=");
	putdec_pub((unsigned long)h1);
	sbi_console_puts("\n");
	if (h0 > 0 && h1 > 0)
		sbi_console_puts("[R-P32.1] procs-on-both-harts PROVEN: real "
		    "proc_t processes ran on BOTH hartids via the shared TS "
		    "dispatcher (fork on one hart, dispatch on either).\n");
	else
		sbi_console_puts("[R-P32.1] procs-on-both-harts INCOMPLETE (only "
		    "one hart dispatched).\n");
}

/* ---- the syscall bodies (called from rv_syscall in main.c) ----------- */

int proc_getpid(void) { return (curproc ? curproc->p_pid : 0); }

/* R-P32: is a user proc currently running (so a user-VA fault should route to
   proc_pagefault)?  1 iff curproc is set with a user AS. */
int curproc_active(void) { return (curproc != 0 && curproc->p_uroot != 0); }

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

/*
 * proc_pagefault -- R-P32: the U-mode page-fault handler (called from rv_trap
 * on scause 12/13/15 from U-mode).  Try, in order:
 *   1. a COW copy   -- a store to a shared read-only PTE_COW page: copy the
 *      frame into a private writable one (hat_cow_fault).
 *   2. a demand-page -- an access to a reserved-but-unbacked PTE_LAZY page:
 *      back it with a fresh zeroed frame (hat_demand_fault).
 * Returns 1 if handled (the trap epilogue retries the faulting instruction), 0
 * if this is a genuine fault (the caller halts).  Reports the first COW event +
 * the first demand-page event to the console (the boot proof).
 */
volatile int cow_events;
volatile int demand_events;
volatile int exec_demand_events;	/* R-P33.3: file-backed exec page-ins */
extern void puthex_pub(unsigned long);

int
proc_pagefault(unsigned long stval, unsigned long scause)
{
	proc_t *p = curproc;
	unsigned long va = stval & PAGEMASK;

	if (p == 0 || p->p_uroot == 0)
		return (0);

	/*
	 * R-P33.3: FILE-BACKED DEMAND-EXEC.  If the fault lands in this proc's
	 * lazily-mapped text segment, page it in from the ELF image (copy the
	 * file bytes, zero-fill the tail) instead of a bare zeroed frame.
	 */
	if (p->p_dimg != 0 && va >= p->p_dva &&
	    va < p->p_dva + p->p_dmemsz) {
		extern int exec_demand_fault(unsigned long *root, unsigned long va,
		    const unsigned char *img, unsigned long seg_va,
		    unsigned long file_off, unsigned long filesz);
		if (exec_demand_fault(p->p_uroot, va, p->p_dimg, p->p_dva,
		    p->p_doff, p->p_dfilesz)) {
			rv_tlb_flush_all();
			__sync_fetch_and_add(&exec_demand_events, 1);
			sbi_console_puts("      [exec-demand] fault -> paged text "
			    "from file va=");
			puthex_pub(va);
			sbi_console_puts(" (pid ");
			putdec_pub((unsigned long)p->p_pid);
			sbi_console_puts(")\n");
			return (1);
		}
	}

	/* a store fault may be a COW page: copy it + make it writable. */
	if (scause == 15 && hat_cow_fault(p->p_uroot, va)) {
		rv_tlb_flush_all();
		__sync_fetch_and_add(&cow_events, 1);
		sbi_console_puts("      [COW] store fault -> copied page va=");
		puthex_pub(va);
		sbi_console_puts(" (pid ");
		putdec_pub((unsigned long)p->p_pid);
		sbi_console_puts(") -- private writable copy\n");
		return (1);
	}
	/* otherwise a demand-paged (lazy) page: fault in a zeroed frame. */
	if (hat_demand_fault(p->p_uroot, va)) {
		rv_tlb_flush_all();
		__sync_fetch_and_add(&demand_events, 1);
		sbi_console_puts("      [demand] fault -> mapped zeroed page va=");
		puthex_pub(va);
		sbi_console_puts(" (pid ");
		putdec_pub((unsigned long)p->p_pid);
		sbi_console_puts(")\n");
		return (1);
	}
	return (0);				/* genuine fault */
}

/* R-P32: a proc reserves a demand-paged page at `va` (mapped on first touch). */
long
proc_lazy_reserve(unsigned long va)
{
	proc_t *p = curproc;
	if (p == 0 || p->p_uroot == 0)
		return (-1);
	if (hat_user_lazy(p->p_uroot, va & PAGEMASK,
	    PTE_R | PTE_W | PTE_U) != 0)
		return (-1);
	rv_tlb_flush_all();
	return (0);
}

/* ---- R-P32.3: the file(2) syscalls over the VNODE layer -------------- */
/*
 * An open fd holds a vnode pointer (ramfs or tmpfs) + a byte offset.  open
 * resolves a path via vfs_lookup (the reduced VOP_LOOKUP), read/write dispatch
 * through fop_read/fop_write (the vnode op vector), lseek repositions,
 * fstat/stat report the size via fop_getattr, close frees the fd.  This is the
 * illumos os/fio.c fd table (falloc/getf) + fs/vnode.c fop_*() reduced to a
 * per-proc fd -> vnode + offset, no page cache, the file's bytes ARE the file.
 *
 * CRIB PROVENANCE: the per-proc open-file table (fd -> vnode + offset) is
 * illumos os/fio.c (falloc/getf/ufalloc); open -> VOP_LOOKUP then read/write
 * doing uiomove through VOP_READ/VOP_WRITE advancing f_offset is vn_openat +
 * fop_read/fop_write; lseek/fstat are os/lseek.c / VOP_GETATTR.
 */
struct vnode;
extern int vfs_lookup(const char *path, struct vnode **out, int create);
extern long fop_read(struct vnode *, char *ubuf, unsigned long off,
    unsigned long n);
extern long fop_write(struct vnode *, const char *ubuf, unsigned long off,
    unsigned long n);
extern long fop_getattr(struct vnode *, unsigned long *size);

#define	RERR_EBADF	(-9)
#define	RERR_ENOENT	(-2)
#define	RERR_EMFILE	(-24)
#define	RERR_EROFS	(-30)

#define	O_CREAT		0x100		/* create the file if absent (tmpfs) */

/*
 * proc_open -- resolve `path` via vfs_lookup to a vnode + allocate an fd (>=3)
 * with a 0 offset.  `flags` carries O_CREAT (create a tmpfs file) / O_TRUNC.
 * Returns the fd or a negative errno.
 */
int
proc_openf(const char *path, int flags)
{
	proc_t *p = curproc;
	struct vnode *vp;
	int fd, rc;

	if (p == 0)
		return (RERR_EBADF);
	rc = vfs_lookup(path, &vp, (flags & O_CREAT) ? 1 : 0);
	if (rc != 0)
		return (rc);
	for (fd = 3; fd < NOFILE; fd++) {
		if (!p->p_fd[fd].f_used) {
			extern int vfs_isdir(struct vnode *vp);
			p->p_fd[fd].f_vnode = vp;
			p->p_fd[fd].f_off = 0;
			p->p_fd[fd].f_used = 1;
			p->p_fd[fd].f_pipe = 0;
			p->p_fd[fd].f_dir = vfs_isdir(vp);
			return (fd);
		}
	}
	return (RERR_EMFILE);
}

/* back-compat: open read-only (R-P31 SYS_open). */
int
proc_open(const char *path)
{
	return (proc_openf(path, 0));
}

/*
 * proc_read -- read up to `n` bytes from fd's offset into the user buffer via
 * the vnode's VOP_READ.  Advances the offset.  Returns the count (0 EOF) or a
 * negative errno.
 */
long
proc_read(int fd, char *ubuf, unsigned long n)
{
	proc_t *p = curproc;
	long r;

	if (p == 0 || fd < 0 || fd >= NOFILE || !p->p_fd[fd].f_used)
		return (RERR_EBADF);
	if (p->p_fd[fd].f_pipe != 0) {		/* R-P33.2: a pipe read end */
		extern long pipe_read_pub(void *pp, char *ubuf, unsigned long n,
		    int is_write);
		return (pipe_read_pub(p->p_fd[fd].f_pipe, ubuf, n,
		    p->p_fd[fd].f_pipe_w));
	}
	r = fop_read((struct vnode *)p->p_fd[fd].f_vnode, ubuf,
	    p->p_fd[fd].f_off, n);
	if (r > 0)
		p->p_fd[fd].f_off += (unsigned long)r;
	return (r);
}

/*
 * proc_write -- R-P32.3: write `n` bytes from the user buffer to fd's offset via
 * the vnode's VOP_WRITE.  Advances the offset.  Returns the count or a negative
 * errno (EROFS on a read-only ramfs vnode).  fd 1/2 (stdout/stderr) route to
 * the console (the R-P25 behavior).
 */
long
proc_write(int fd, const char *ubuf, unsigned long n)
{
	proc_t *p = curproc;
	long r;

	if (fd == 1 || fd == 2) {
		unsigned long i;
		for (i = 0; i < n; i++)
			sbi_console_putchar((int)(unsigned char)ubuf[i]);
		return ((long)n);
	}
	if (p == 0 || fd < 0 || fd >= NOFILE || !p->p_fd[fd].f_used)
		return (RERR_EBADF);
	if (p->p_fd[fd].f_pipe != 0) {		/* R-P33.2: a pipe write end */
		extern long pipe_write_pub(void *pp, const char *ubuf,
		    unsigned long n, int is_write);
		return (pipe_write_pub(p->p_fd[fd].f_pipe, ubuf, n,
		    p->p_fd[fd].f_pipe_w));
	}
	r = fop_write((struct vnode *)p->p_fd[fd].f_vnode, ubuf,
	    p->p_fd[fd].f_off, n);
	if (r > 0)
		p->p_fd[fd].f_off += (unsigned long)r;
	return (r);
}

/*
 * proc_lseek -- reposition fd's offset.  whence: 0=SEEK_SET, 1=SEEK_CUR,
 * 2=SEEK_END (uses the vnode size via fop_getattr).  Returns the new offset.
 */
long
proc_lseek(int fd, long off, int whence)
{
	proc_t *p = curproc;
	long base;
	unsigned long sz = 0;

	if (p == 0 || fd < 0 || fd >= NOFILE || !p->p_fd[fd].f_used)
		return (RERR_EBADF);
	switch (whence) {
	case 0: base = 0; break;				/* SEEK_SET */
	case 1: base = (long)p->p_fd[fd].f_off; break;	/* SEEK_CUR */
	case 2:						/* SEEK_END */
		(void) fop_getattr((struct vnode *)p->p_fd[fd].f_vnode, &sz);
		base = (long)sz;
		break;
	default: return (-22);				/* EINVAL */
	}
	if (base + off < 0)
		return (-22);
	p->p_fd[fd].f_off = (unsigned long)(base + off);
	return ((long)p->p_fd[fd].f_off);
}

/*
 * proc_fstat / proc_stat -- report the file size via VOP_GETATTR.  The reduced
 * stat buffer the userland reads is { long st_size; } at offset 0.
 */
long
proc_fstat(int fd, unsigned long *ubuf)
{
	proc_t *p = curproc;
	unsigned long sz = 0;

	if (p == 0 || fd < 0 || fd >= NOFILE || !p->p_fd[fd].f_used)
		return (RERR_EBADF);
	(void) fop_getattr((struct vnode *)p->p_fd[fd].f_vnode, &sz);
	if (ubuf != 0)
		ubuf[0] = sz;			/* st_size */
	return (0);
}

long
proc_stat(const char *path, unsigned long *ubuf)
{
	struct vnode *vp;
	unsigned long sz = 0;

	if (vfs_lookup(path, &vp, 0) != 0)
		return (RERR_ENOENT);
	(void) fop_getattr(vp, &sz);
	if (ubuf != 0)
		ubuf[0] = sz;			/* st_size */
	return (0);
}

/*
 * proc_mkdir -- SYS_mkdir body: create a tmpfs directory named `path`.
 * proc_getdents -- SYS_getdents body: read the `fd->f_off`th entry name of a
 * directory fd into the user buffer via VOP_READDIR; advances f_off; returns
 * the name length (0 at end-of-dir, -errno on error).
 */
extern int vfs_mkdir(const char *path);
extern int vfs_readdir(struct vnode *dvp, unsigned long index, char *name,
    unsigned long nsz);

long
proc_mkdir(const char *path)
{
	if (curproc == 0)
		return (RERR_EBADF);
	return (vfs_mkdir(path));
}

long
proc_getdents(int fd, char *ubuf, unsigned long n)
{
	proc_t *p = curproc;
	int got;

	if (p == 0 || fd < 0 || fd >= NOFILE || !p->p_fd[fd].f_used)
		return (RERR_EBADF);
	if (!p->p_fd[fd].f_dir)
		return (RERR_EBADF);		/* not a directory fd */
	got = vfs_readdir((struct vnode *)p->p_fd[fd].f_vnode,
	    p->p_fd[fd].f_off, ubuf, n);
	if (got == 0)
		return (0);			/* end of directory */
	p->p_fd[fd].f_off++;
	{
		long k = 0;
		while (ubuf[k] != 0)
			k++;
		return (k);			/* name length */
	}
}

long
proc_close_file(int fd)
{
	proc_t *p = curproc;

	if (fd >= 0 && fd <= 2)
		return (0);			/* console fds: no-op */
	if (p == 0 || fd < 0 || fd >= NOFILE || !p->p_fd[fd].f_used)
		return (RERR_EBADF);
	if (p->p_fd[fd].f_pipe != 0) {
		extern void pipe_close(void *pp, int is_write);
		pipe_close(p->p_fd[fd].f_pipe, p->p_fd[fd].f_pipe_w);
		p->p_fd[fd].f_pipe = 0;
	}
	p->p_fd[fd].f_used = 0;
	p->p_fd[fd].f_vnode = 0;
	p->p_fd[fd].f_dir = 0;
	return (0);
}

/* ---- R-P33.2: pipe(2) -- a kernel ring buffer with two fds ------------ */
/*
 * A pipe is a fixed ring buffer with a read + a write position, a byte count,
 * and open-end refcounts.  pipe(2) allocates one and installs two fds in the
 * caller: fds[0] the read end, fds[1] the write end.  fork inherits both (the
 * refcounts are bumped) so a parent + child communicate.  read/write BLOCK on
 * an empty/full buffer by yielding to the scheduler (P_RUNNABLE + sched()) and
 * re-checking -- the R-P30 dispatcher runs the peer so the condition changes;
 * a read on a pipe with no write ends left returns 0 (EOF).
 *
 * CRIB PROVENANCE: the fifofs/pipe ring buffer with reader/writer counts + a
 * blocking read/write that sleeps on the buffer and wakes the peer is illumos
 * uts/common/fs/fifofs/fifovnops.c (fifo_read/fifo_write + fifo_wait) +
 * sys/pipe.h, and the xv6 pipe (pipewrite/piperead sleep/wakeup); reduced here
 * to a cooperative yield-and-recheck against the R-P30 scheduler.
 */
#define	PIPE_BUFSZ	512
typedef struct pipe {
	unsigned char	pb_buf[PIPE_BUFSZ];
	unsigned long	pb_rpos;	/* read position (bytes consumed) */
	unsigned long	pb_wpos;	/* write position (bytes produced) */
	int		pb_readers;	/* open read ends */
	int		pb_writers;	/* open write ends */
	int		pb_used;	/* slot in use */
} pipe_t;

#define	NPIPE	8
static pipe_t pipe_tab[NPIPE];

static pipe_t *
pipe_alloc(void)
{
	int i;
	sched_spin_lock();
	for (i = 0; i < NPIPE; i++) {
		if (!pipe_tab[i].pb_used) {
			pipe_t *pp = &pipe_tab[i];
			pp->pb_used = 1;
			pp->pb_rpos = pp->pb_wpos = 0;
			pp->pb_readers = pp->pb_writers = 1;
			sched_spin_unlock();
			return (pp);
		}
	}
	sched_spin_unlock();
	return (0);
}

/* pipe_close -- drop a read or write end; free the pipe when both hit 0. */
void
pipe_close(void *ptr, int is_write)
{
	pipe_t *pp = (pipe_t *)ptr;
	sched_spin_lock();
	if (is_write)
		pp->pb_writers--;
	else
		pp->pb_readers--;
	if (pp->pb_readers <= 0 && pp->pb_writers <= 0)
		pp->pb_used = 0;
	sched_spin_unlock();
}

/* pipe_incref -- fork bumps both ends' refcounts for the inherited fds. */
void
pipe_incref(void *ptr, int is_write)
{
	pipe_t *pp = (pipe_t *)ptr;
	sched_spin_lock();
	if (is_write)
		pp->pb_writers++;
	else
		pp->pb_readers++;
	sched_spin_unlock();
}

/* a cooperative block: mark RUNNABLE + yield so the scheduler runs the peer. */
static void
pipe_block(void)
{
	proc_t *p = curproc;
	sched_spin_lock();
	p->p_state = P_RUNNABLE;
	p->p_onproc = 1;
	sched_spin_unlock();
	rv_swtch(&p->p_ctx, &sched_ctx);
}

long
proc_pipe(int *ufds)
{
	proc_t *p = curproc;
	pipe_t *pp;
	int rfd = -1, wfd = -1, fd;

	if (p == 0 || ufds == 0)
		return (RERR_EBADF);
	pp = pipe_alloc();
	if (pp == 0)
		return (RERR_EMFILE);
	/* read end. */
	for (fd = 3; fd < NOFILE; fd++) {
		if (!p->p_fd[fd].f_used) {
			p->p_fd[fd].f_used = 1;
			p->p_fd[fd].f_vnode = 0;
			p->p_fd[fd].f_off = 0;
			p->p_fd[fd].f_pipe = pp;
			p->p_fd[fd].f_pipe_w = 0;
			p->p_fd[fd].f_dir = 0;
			rfd = fd;
			break;
		}
	}
	/* write end. */
	for (fd = 3; fd < NOFILE; fd++) {
		if (!p->p_fd[fd].f_used) {
			p->p_fd[fd].f_used = 1;
			p->p_fd[fd].f_vnode = 0;
			p->p_fd[fd].f_off = 0;
			p->p_fd[fd].f_pipe = pp;
			p->p_fd[fd].f_pipe_w = 1;
			p->p_fd[fd].f_dir = 0;
			wfd = fd;
			break;
		}
	}
	if (rfd < 0 || wfd < 0) {
		if (rfd >= 0) p->p_fd[rfd].f_used = 0;
		pp->pb_used = 0;
		return (RERR_EMFILE);
	}
	ufds[0] = rfd;			/* SUM set: kernel may write user pages */
	ufds[1] = wfd;
	return (0);
}

/* pipe read: block until data or all writers gone (EOF -> 0). */
static long
pipe_read(pipe_t *pp, char *ubuf, unsigned long n)
{
	unsigned long got = 0;

	for (;;) {
		unsigned long avail = pp->pb_wpos - pp->pb_rpos;
		if (avail > 0) {
			while (got < n && pp->pb_rpos < pp->pb_wpos) {
				ubuf[got++] =
				    (char)pp->pb_buf[pp->pb_rpos % PIPE_BUFSZ];
				pp->pb_rpos++;
			}
			return ((long)got);
		}
		if (pp->pb_writers <= 0)
			return (0);		/* EOF: no writers left */
		pipe_block();			/* empty: let the writer run */
	}
}

/* pipe write: block while the buffer is full; write what fits then loop. */
static long
pipe_write(pipe_t *pp, const char *ubuf, unsigned long n)
{
	unsigned long put = 0;

	while (put < n) {
		unsigned long space;
		if (pp->pb_readers <= 0)
			return (put > 0 ? (long)put : -1); /* reader gone (EPIPE) */
		space = PIPE_BUFSZ - (pp->pb_wpos - pp->pb_rpos);
		if (space == 0) {
			pipe_block();		/* full: let the reader drain */
			continue;
		}
		while (put < n && (pp->pb_wpos - pp->pb_rpos) < PIPE_BUFSZ) {
			pp->pb_buf[pp->pb_wpos % PIPE_BUFSZ] =
			    (unsigned char)ubuf[put++];
			pp->pb_wpos++;
		}
	}
	return ((long)put);
}

/* direction-checked entry points proc_read/proc_write route pipe fds through. */
long
pipe_read_pub(void *pp, char *ubuf, unsigned long n, int is_write)
{
	if (is_write)
		return (RERR_EBADF);	/* read end only */
	return (pipe_read((pipe_t *)pp, ubuf, n));
}
long
pipe_write_pub(void *pp, const char *ubuf, unsigned long n, int is_write)
{
	if (!is_write)
		return (RERR_EBADF);	/* write end only */
	return (pipe_write((pipe_t *)pp, ubuf, n));
}

/*
 * proc_mprotect -- SYS_mprotect body (R-P31.2).  Change the leaf perms of the
 * user pages in [addr, addr+len) of the current proc's AS.  prot is the PROT_*
 * bitmask (PROT_READ=1, PROT_WRITE=2, PROT_EXEC=4); we map it to Sv39 R/W/X
 * leaf bits.  ld.so.1 calls this to make the RELRO segment read-only after
 * relocation (prot = PROT_READ).  Returns 0 or -1.
 */
#define	PROT_READ	1
#define	PROT_WRITE	2
#define	PROT_EXEC	4
extern int hat_user_protect(unsigned long *root, unsigned long va,
    unsigned long len, unsigned long perms);

long
proc_mprotect(unsigned long addr, unsigned long len, unsigned long prot)
{
	proc_t *p = curproc;
	unsigned long perms = 0;

	if (p == 0 || p->p_uroot == 0)
		return (-1);
	if (prot & PROT_READ)
		perms |= PTE_R;
	if (prot & PROT_WRITE)
		perms |= PTE_W;
	if (prot & PROT_EXEC)
		perms |= PTE_X;
	if (hat_user_protect(p->p_uroot, addr, len, perms) != 0)
		return (-1);
	rv_tlb_flush_all();		/* perms changed under the live satp */
	return (0);
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
	p->p_onproc = 0;		/* context seeded: pickable by any hart */
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

	sched_spin_lock();
	p->p_xstat = status;
	p->p_state = P_ZOMBIE;
	p->p_onproc = 1;	/* not reapable until safely switched off-cpu */
	/* wake a parent blocked in wait(). */
	for (i = 0; i < NPROC; i++) {
		if (proc_tab[i].p_state == P_WAITING &&
		    proc_tab[i].p_pid == p->p_ppid)
			proc_tab[i].p_state = P_RUNNABLE;
	}
	sched_spin_unlock();
	sched();		/* never returns (ZOMBIE is not RUNNABLE) */
	/* not reached */
	for (;;)
		;
}

/*
 * proc_wait -- SYS_wait body.  Block until a child of curproc is ZOMBIE, reap
 * it (free its kstack, mark UNUSED), store its exit status through *statusp
 * (a user VA reachable under the current user satp), and return its pid.
 * Returns -1 if the caller has no children.  R-P32: the child scan + claim runs
 * under sched_lock (transition the zombie to P_REAPING so neither the peer hart
 * nor the scheduler's parentless-reaper double-frees it), and the kstack/AS free
 * happens after releasing the lock (it calls kmem/hat_as_free).
 */
long
proc_wait(long *statusp)
{
	proc_t *p = curproc;

	for (;;) {
		int i, have_child = 0;
		proc_t *reap = 0;
		int pid = 0, xs = 0;

		sched_spin_lock();
		for (i = 0; i < NPROC; i++) {
			proc_t *c = &proc_tab[i];
			if (c->p_ppid != p->p_pid ||
			    c->p_state == P_UNUSED)
				continue;
			have_child = 1;
			if (c->p_state == P_ZOMBIE) {
				pid = c->p_pid;
				xs = c->p_xstat;
				c->p_state = P_REAPING;	/* claim it */
				reap = c;
				break;
			}
		}
		sched_spin_unlock();
		if (reap != 0) {
			/* free the kstack + the user AS outside the lock. */
			kmem_free(reap->p_kstack, KSTACK_SIZE);
			if (!reap->p_kthread && reap->p_uroot != 0)
				hat_as_free(reap->p_uroot);	/* R-P30 */
			sched_spin_lock();
			reap->p_uroot = 0;
			reap->p_state = P_UNUSED;
			reap->p_ppid = 0;
			sched_spin_unlock();
			if (statusp != 0)
				*statusp = xs;
			return (pid);
		}
		if (!have_child)
			return (-1);
		/* no zombie child yet: block + yield. */
		sched_spin_lock();
		p->p_state = P_WAITING;
		sched_spin_unlock();
		sched();
		/* woken (a child exited): re-scan. */
	}
}

/*
 * run_asfree -- R-P30.3 proof: fork+exec+exit-shaped AS lifecycle N times and
 * confirm the page-frame free count is STABLE (no leak).  Each iteration builds
 * a fresh user AS from an embedded ELF (exec_image -- the exact loader exec(2)
 * uses: allocates the root + leaf page tables + the segment/stack frames), then
 * FREES it with hat_as_free (the exact teardown proc_exit/wait now runs at
 * reap).  Before R-P30 the AS was leaked on exec/exit (R-P26 noted it); here the
 * frames-in-use count returns to its baseline every iteration.
 *
 * CRIB PROVENANCE: exercising as_dup/as_free over a process lifetime + watching
 * the frame accounting return to baseline is the illumos as_free / kmem leak-
 * accounting model; the fork/exec/exit AS churn is the R-P26 lifecycle.
 */
extern unsigned long kmem_pages_inuse(void);
extern void hat_as_free(unsigned long *root);

void
run_asfree(void)
{
	unsigned long base, after, peak = 0;
	int iter;
	const int N = 20;

	sbi_console_puts("\n");
	sbi_console_puts("[R-P30.3] as_free: fork+exec+exit an AS N times; "
	    "frames reclaimed (no leak)\n");
	sbi_console_puts("----- as_free proof output -----\n");

	base = kmem_pages_inuse();
	sbi_console_puts("  baseline frames in use: ");
	putdec_pub(base);
	sbi_console_puts("\n");

	for (iter = 0; iter < N; iter++) {
		struct uproc up;
		unsigned long hi;

		if (exec_image(&up, execee_elf_start) != 0) {
			sbi_console_puts("  exec_image FAILED at iter ");
			putdec_pub((unsigned long)iter);
			sbi_console_puts("\n");
			break;
		}
		hi = kmem_pages_inuse();
		if (hi > peak)
			peak = hi;
		/* free the AS root (the kstack from exec_image is a byte-heap
		   alloc; free it too so we compare like-for-like frames). */
		hat_as_free((unsigned long *)up.u_root);
		if ((iter % 5) == 0) {
			sbi_console_puts("  iter ");
			putdec_pub((unsigned long)iter);
			sbi_console_puts(": after-build=");
			putdec_pub(hi);
			sbi_console_puts(" after-free=");
			putdec_pub(kmem_pages_inuse());
			sbi_console_puts("\n");
		}
	}

	after = kmem_pages_inuse();
	sbi_console_puts("----- end as_free proof output -----\n");
	sbi_console_puts("  frames: baseline=");
	putdec_pub(base);
	sbi_console_puts(" peak-per-AS=");
	putdec_pub(peak);
	sbi_console_puts(" final=");
	putdec_pub(after);
	sbi_console_puts("\n");
	if (after == base && peak > base)
		sbi_console_puts("[R-P30.3] as_free PROVEN: "
		    "frame count returned to baseline after N AS builds+frees "
		    "(no leak).\n");
	else
		sbi_console_puts("[R-P30.3] as_free INCOMPLETE (frames leaked or "
		    "never allocated).\n");
}
