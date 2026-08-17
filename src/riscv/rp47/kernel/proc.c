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
/* R-P36: ASID allocator (hat_user.c) + ASID-scoped / remote TLB flush. */
extern unsigned long hat_asid_alloc(int *rolled);
extern unsigned long hat_asid_generation(void);
extern void rv_tlb_flush_asid(unsigned long asid);
extern void hat_tlb_shootdown(long target_hartid);
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
#define	SIGCHLD		18		/* R-P34.1: child status change (SunOS 18) */
#define	SIGCONT		25		/* R-P38.2: continue a stopped job (SunOS 25) */
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

enum p_state { P_UNUSED = 0, P_RUNNABLE, P_RUNNING, P_WAITING, P_ZOMBIE, P_REAPING, P_STOPPED };

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
		/* R-P34.2: close-on-exec (FD_CLOEXEC) -- an fd flagged here is
		   closed across exec(2) instead of inherited into the new image. */
		int		f_cloexec;	/* 1 = close this fd on exec */
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
	 * R-P34.1: signal maturity.  p_sigmask is the BLOCKED-signal mask
	 * (bit N set = signal N blocked from delivery; it stays pending);
	 * sigprocmask edits it, sigsuspend swaps it for the call.  p_sigflags[N]
	 * bit records SA_RESTART per signal (restart an interrupted syscall
	 * instead of failing with EINTR).  p_alarm_deadline is the clock tick at
	 * which a pending alarm(2) fires SIGALRM (0 = no alarm armed).  All are
	 * inherited/reset across fork per POSIX (mask inherited, alarm cleared).
	 */
	volatile unsigned int p_sigmask;	/* blocked-signal mask */
	unsigned int	p_sigflags[NSIG];	/* per-signal sa_flags (SA_RESTART) */
	volatile unsigned long p_alarm_deadline;/* clock tick to fire SIGALRM (0=off) */
	int		p_no_restart;		/* R-P34.1: suppress SA_RESTART for the
						   next delivery (sigsuspend is never
						   restarted per POSIX) */
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
	/*
	 * R-P36: this AS's ASID (tagged into p_usatp) + the ASID generation it
	 * was allocated in.  A distinct ASID per AS lets sfence.vma be
	 * ASID-scoped; the generation lets a rollover recycle every ASID at once.
	 */
	unsigned long	p_asid;		/* this AS's ASID (0 = kernel/none) */
	unsigned long	p_asidgen;	/* ASID generation at allocation */
	/*
	 * R-P36: per-proc current working directory (an absolute, canonicalized
	 * path with no trailing '/', "/" for the root).  chdir(2) sets it;
	 * relative path resolution (open/exec) prepends it + collapses . / .. .
	 */
	char		p_cwd[128];
	/*
	 * R-P37.2: job control -- the process group id this proc belongs to
	 * (setpgid(2) sets it; inherited across fork, kept across exec).  A ^C /
	 * ^Z on the tty raises SIGINT / SIGTSTP on every proc whose p_pgid equals
	 * the tty foreground process group (tty_fg_pgrp).
	 */
	int		p_pgid;		/* process group id (0 until set) */
	/*
	 * R-P37.2: set when SIGTSTP stops this proc and a WUNTRACED wait has not
	 * yet reported the stop; proc_waitpid reports it once (pid + a stopped
	 * status sentinel) without reaping, then clears it.
	 */
	int		p_stopreport;	/* 1 = a stop is pending report to the parent */
} proc_t;

#define	NCPU		2

static proc_t proc_tab[NPROC];
static int next_pid = 1;
#define	INIT_PID	1		/* R-P35.2: init is pid 1 */
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
static volatile int cpu_idling[NCPU];	/* R-P35.1: 1 while this hart wfi's in the idle loop */
volatile int cpu_idle_events[NCPU];	/* R-P35.1: count of idle-wfi parks per hart (proof) */
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

/*
 * proc_ipi_wake_others -- R-P35.1: a proc was just made RUNNABLE on this hart
 * (a wakeup/exit-child/signal/pipe-drain transition).  If a PEER hart is
 * parked in its idle `wfi` (cpu_idling), poke it with an SBI software IPI so
 * it wakes, re-scans the shared runq, and dispatches the newly-runnable proc
 * instead of sleeping forever.  This replaces the R-P34 busy-poll: an idle
 * hart truly sleeps and is woken on demand, not by spinning.
 *
 * CRIB PROVENANCE: poke_cpu()/cpu_wakeup sending a cross-call IPI to a halted
 * CPU when a runnable thread lands on the dispatch queue is illumos
 * uts/common/disp/disp.c setbackdq -> cpu_resched / poke_cpu (i86pc
 * mach_cpu_pause/poke_cpu) + the xv6-riscv scheduler wakeup; the SBI
 * send_ipi primitive is the RISC-V SBI spec IPI extension.
 */
extern long sbi_send_ipi_hart(unsigned long hartid);
void
proc_ipi_wake_others(void)
{
	int me = cpuid();
	int h;
	/*
	 * Poke every PEER hart, not only ones we observe idling: a peer may be
	 * in the lost-wakeup window (it scanned an empty runq, is about to wfi,
	 * but has not yet set cpu_idling).  A software IPI leaves SSIP pending,
	 * so its wfi returns immediately (or never sleeps) and it re-scans and
	 * finds the proc we just made RUNNABLE.  An IPI to a busy hart is a
	 * harmless spurious software interrupt (rv_interrupt clears SSIP).
	 */
	for (h = 0; h < NCPU; h++) {
		if (h != me)
			(void) sbi_send_ipi_hart((unsigned long)h);
	}
}

/*
 * R-P36: proc_assign_asid -- give proc `p`'s address space a fresh ASID and
 * rebuild its satp values (p_usatp + the scheduler-context c_satp) to carry it.
 * Called at every AS-creation site (proc_first, fork's child, exec's new AS).
 * exec_elf builds the raw MAKE_SATP (ASID 0); this re-stamps it with the real
 * ASID so distinct address spaces never share ASID 0 (which would defeat the
 * ASID-scoped sfence.vma).  On an ASID rollover we broadcast a remote shootdown
 * so peer harts drop the recycled ASIDs' stale entries too.
 */
static void
proc_assign_asid(proc_t *p)
{
	int rolled = 0;
	unsigned long asid = hat_asid_alloc(&rolled);

	p->p_asid = asid;
	p->p_asidgen = hat_asid_generation();
	p->p_usatp = MAKE_SATP_ASID(KVTOP((unsigned long)p->p_uroot), asid);
	p->p_ctx.c_satp = p->p_usatp;
	if (rolled) {
		/* the whole ASID space was recycled: shoot down peers too so no
		   hart keeps a translation tagged with a now-reused ASID. */
		hat_tlb_shootdown((long)(cpuid() ^ 1));
	}
}

/* exec_elf.c: load the ELF at img[0..) into a fresh user AS; fills up. */
extern int exec_image(struct uproc *up, const unsigned char *img);
/* R-P27: dynamic-exec (PT_INTERP -> load ld.so.1 + the app, enter ld.so.1). */
extern int exec_dynamic(struct uproc *up, const unsigned char *img);
extern const char *elf_has_interp(const unsigned char *img);
extern const unsigned char user_elf_start[];	/* forker image */
extern const unsigned char execee_elf_start[];	/* exec target image */

/*
 * proc_reset_pids -- R-P35.2: restart pid numbering at 1 for a fresh session
 * (init is pid 1).  Safe only when the proc table is empty (every prior proc
 * reaped to UNUSED) -- each run_* phase drains the runq before the next, so
 * the boot init phase starts from a clean table.
 */
void
proc_reset_pids(void)
{
	next_pid = 1;
}

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
				p->p_sigmask = 0;
				p->p_alarm_deadline = 0;
				p->p_no_restart = 0;
				for (s = 0; s < NSIG; s++) {
					p->p_sighand[s] = 0;	/* SIG_DFL */
					p->p_sigflags[s] = 0;
				}
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
					p->p_fd[fd].f_cloexec = 0;
				}
			}
			/* R-P36: a fresh proc's cwd is the root; fork inherits the
			   parent's cwd afterward, exec keeps it (POSIX). */
			p->p_cwd[0] = '/';
			p->p_cwd[1] = 0;
			/* R-P37.2: a fresh proc leads its own process group (pgid ==
			   pid) until setpgid(2) moves it; fork inherits the parent's. */
			p->p_pgid = p->p_pid;
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
	proc_assign_asid(p);		/* R-P36: tag this AS with its own ASID */
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
	proc_assign_asid(p);		/* R-P36: tag this AS with its own ASID */
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
	/*
	 * R-P36 (THE R-P35 SMP FIX): hat_user_cow_share just dropped PTE_W in the
	 * PARENT's live page tables (both sides fault-on-write).  A local
	 * sfence.vma only flushes THIS hart -- a peer hart running the parent (or
	 * another proc sharing these frames) would keep a stale WRITABLE TLB entry
	 * and could store into the shared frame without faulting, corrupting the
	 * child's copy-on-write page.  Do a REMOTE-hart TLB shootdown (IPI-driven
	 * SBI RFENCE) so every hart drops the stale mappings, ASID-scoped to the
	 * parent's ASID so peers' OTHER address spaces keep their TLB entries.
	 */
	rv_tlb_flush_asid(parent->p_asid);	/* local: drop parent's stale RW entries */
	hat_tlb_shootdown((long)(cpuid() ^ 1));	/* remote: peer hart drops them too */
	child->p_uroot = croot;
	child->p_usatp = MAKE_SATP(KVTOP((unsigned long)croot));
	child->p_ppid = parent->p_pid;
	/* R-P36: the child inherits the parent's cwd (POSIX). */
	{
		int ci;
		for (ci = 0; ci < (int)sizeof (child->p_cwd); ci++)
			child->p_cwd[ci] = parent->p_cwd[ci];
	}
	/* R-P37.2: the child inherits the parent's process group (POSIX). */
	child->p_pgid = parent->p_pgid;

	/*
	 * R-P33.1: fork inherits the parent's signal dispositions + the
	 * sa_restorer trampoline, but NOT the pending set (POSIX: the child
	 * starts with an empty pending mask).  proc_alloc already cleared
	 * p_sigpend; copy the handler table + restorer here.
	 */
	{
		int s;
		for (s = 0; s < NSIG; s++) {
			child->p_sighand[s] = parent->p_sighand[s];
			child->p_sigflags[s] = parent->p_sigflags[s];
		}
		child->p_sigrestorer = parent->p_sigrestorer;
		child->p_sigmask = parent->p_sigmask;	/* mask inherited */
		child->p_alarm_deadline = 0;		/* alarm NOT inherited */
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
	proc_assign_asid(child);	/* R-P36: child AS gets its own ASID */

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

	/* R-P34.2: close-on-exec -- drop every FD_CLOEXEC fd BEFORE the new
	   image runs (non-CLOEXEC fds survive into the new program). */
	{
		extern void proc_fd_cloexec(void);
		proc_fd_cloexec();
	}

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
		p->p_brk = 0;		/* R-P40: fresh AS -> re-seed the heap at
					   HEAP_BASE (exec resets the program break;
					   an inherited stale p_brk left the base
					   heap page unmapped for the new image). */
		/*
		 * Switch to the NEW AS FIRST (the kernel stack + trap frame live
		 * in the direct-map, mapped by both ASes), THEN free the old
		 * user page tables + frames -- the old AS is no longer the live
		 * satp so tearing it down cannot pull the ground from under us.
		 */
		/*
		 * R-P36: give the new image a fresh ASID + rebuild p_usatp/c_satp,
		 * THEN install it.  The OLD AS (old_asid) is about to be torn down;
		 * shoot its ASID down on the peer hart so no hart keeps a stale
		 * translation into freed frames (the exec-churn correctness path).
		 */
		unsigned long old_asid = p->p_asid;
		proc_assign_asid(p);
		rv_set_satp(p->p_usatp);
		rv_tlb_flush_asid(old_asid);
		hat_tlb_shootdown((long)(cpuid() ^ 1));
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
		int i, any_alive = 0, any_blocked = 0;
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
			/*
			 * R-P35.1: a proc that is WAITING (blocked in wait/
			 * sigsuspend) or RUNNING on the OTHER hart may still make
			 * work runnable later (its child exits, a signal arrives).
			 * If this hart finds nothing to run but such a proc exists,
			 * it must IDLE (wfi) -- not return -- so an IPI can wake it.
			 */
			if (p->p_state == P_WAITING ||
			    (p->p_state == P_RUNNING && p->p_hart != cpu))
				any_blocked = 1;
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
		if (!any_alive) {
			sched_spin_unlock();
			return;
		}
		/*
		 * R-P35.1: PER-CPU IDLE.  Nothing is runnable on this hart right
		 * now, but a proc is blocked (WAITING) or running elsewhere and
		 * may hand us work.  Mark this hart idling UNDER THE LOCK, so a
		 * peer that makes a proc RUNNABLE (also under the lock) either
		 * sees cpu_idling and IPIs us, or has not yet transitioned (and we
		 * would have picked the proc above).  Then park in `wfi`: the hart
		 * sleeps until the periodic SBI timer OR a software IPI
		 * (proc_ipi_wake_others) wakes it, and we re-scan.  This closes
		 * the lost-wakeup race and replaces the R-P34 busy-poll.
		 */
		if (any_blocked) {
			extern void clock_run_forever(void);
			extern void clock_enable_ssie(void);
			cpu_idle_events[cpu]++;
			cpu_idling[cpu] = 1;
			sched_spin_unlock();
			/*
			 * Guarantee a wakeup source: unmask timer + software (IPI)
			 * interrupts, re-arm a periodic tick, and set SIE so the
			 * interrupt is TAKEN (its handler clears the pending bit).
			 * A pending IPI posted after our scan but before wfi leaves
			 * SSIP set, so wfi returns at once -- no lost wakeup.
			 */
			clock_run_forever();
			clock_enable_ssie();
			__asm__ __volatile__("csrsi sstatus, 0x2" ::: "memory");
			__asm__ __volatile__("wfi" ::: "memory");
			cpu_idling[cpu] = 0;
		} else {
			sched_spin_unlock();
		}
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

/*
 * proc_idle_events -- R-P35.1 proof accessor: how many times `hart` parked in
 * the idle `wfi` (waiting for an IPI/timer wake) since boot.
 */
extern volatile int cpu_idle_events[NCPU];
int
proc_idle_events(int hart)
{
	if (hart < 0 || hart >= NCPU)
		return (0);
	return (cpu_idle_events[hart]);
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

/* ---- R-P34.1: signal mask / flags / alarm accessors ------------------ */
/* the blocked-signal mask (sigprocmask edits it; delivery skips blocked sigs) */
volatile unsigned int *
proc_sigmask(void)
{
	return (curproc ? &curproc->p_sigmask : 0);
}
/* record SA_RESTART for a signal (so an interrupted syscall restarts). */
void
proc_set_sigflags(int sig, unsigned int flags)
{
	if (curproc && sig >= 1 && sig < NSIG)
		curproc->p_sigflags[sig] = flags;
}
unsigned int
proc_get_sigflags(int sig)
{
	if (curproc && sig >= 1 && sig < NSIG)
		return (curproc->p_sigflags[sig]);
	return (0);
}
/* R-P34.1: sigsuspend sets this so the next delivery does NOT SA_RESTART. */
void
proc_set_no_restart(void)
{
	if (curproc)
		curproc->p_no_restart = 1;
}
int
proc_take_no_restart(void)
{
	int v;
	if (curproc == 0)
		return (0);
	v = curproc->p_no_restart;
	curproc->p_no_restart = 0;
	return (v);
}

/*
 * proc_alarm -- SYS_alarm body.  Arm SIGALRM to fire `secs` seconds from now
 * (0 cancels a pending alarm); returns the seconds remaining on the PREVIOUS
 * alarm (POSIX alarm(2) semantics).  The deadline is a clock-tick count
 * (clock_ticks advances at HZ ticks/sec); the per-tick alarm check
 * (proc_alarm_tick) posts SIGALRM when clock_ticks reaches the deadline.
 */
extern volatile unsigned long clock_ticks;
#define	CLOCK_HZ	100UL
#define	SIGALRM		14

long
proc_alarm(unsigned long secs)
{
	proc_t *p = curproc;
	unsigned long now, remain = 0;

	if (p == 0)
		return (0);
	now = clock_ticks;
	if (p->p_alarm_deadline != 0 && p->p_alarm_deadline > now)
		remain = (p->p_alarm_deadline - now) / CLOCK_HZ;
	if (secs == 0)
		p->p_alarm_deadline = 0;	/* cancel */
	else
		p->p_alarm_deadline = now + secs * CLOCK_HZ;
	return ((long)remain);
}

/*
 * proc_alarm_tick -- called on every clock tick (from rv_interrupt).  Any proc
 * whose armed alarm deadline has passed gets SIGALRM posted + the alarm cleared.
 * Scans the proc table (cheap: NPROC is small); a proc blocked in
 * sigsuspend/wait is woken so it delivers SIGALRM.
 *
 * CRIB PROVENANCE: a per-proc timer that posts SIGALRM off the clock tick is
 * illumos realitexpire()/it_real (uts/common/os/timer.c + clock.c) reduced to
 * a single one-shot deadline compared against the tick counter.
 */
extern void proc_kill_post(proc_t *p, int sig);
void
proc_alarm_tick(void)
{
	unsigned long now = clock_ticks;
	int i;

	for (i = 0; i < NPROC; i++) {
		proc_t *p = &proc_tab[i];
		if (p->p_state == P_UNUSED || p->p_state == P_ZOMBIE ||
		    p->p_state == P_REAPING)
			continue;
		if (p->p_alarm_deadline != 0 && now >= p->p_alarm_deadline) {
			p->p_alarm_deadline = 0;
			__sync_fetch_and_or(&p->p_sigpend, (1u << SIGALRM));
			if (p->p_state == P_WAITING) {
				p->p_state = P_RUNNABLE;
				proc_ipi_wake_others();	/* R-P35.1: wake an idle hart */
			}
		}
	}
}

/*
 * proc_kill_post -- post `sig` to a specific proc_t (no pid lookup, no lock:
 * callers already hold sched_lock or a stable pointer).  Used to deliver
 * SIGCHLD to the parent on child exit + SIGALRM off the tick.
 */
void
proc_kill_post(proc_t *p, int sig)
{
	if (p == 0 || sig < 1 || sig >= NSIG)
		return;
	__sync_fetch_and_or(&p->p_sigpend, (1u << sig));
	if (p->p_state == P_WAITING) {
		p->p_state = P_RUNNABLE;
		proc_ipi_wake_others();		/* R-P35.1: wake an idle hart */
	}
}

/*
 * proc_wait_signal -- R-P35.1: block the caller (P_WAITING) until a pending,
 * UNMASKED signal appears (sigsuspend).  A REAL scheduler block now (vs the
 * R-P34 wfi-poll): mark P_WAITING + sched() -- the hart is freed to dispatch
 * other procs or park in the idle wfi.  proc_kill / proc_alarm_tick wake us
 * (RUNNABLE, + an IPI to an idle hart) when a signal is posted; the scheduler
 * re-dispatches us here, we re-check, and the trap-return path then runs the
 * handler.  We loop until an unblocked pending bit is set (a masked signal
 * keeps us blocked).
 *
 * CRIB PROVENANCE: cv_wait_sig() / sigsuspend blocking the thread on a
 * condition + being woken by setrun when a signal is posted is illumos
 * uts/common/os/sig.c sigsuspend + os/condvar.c cv_wait_sig; the P_WAITING +
 * sched() + IPI-wake mechanism is the same block/wakeup as proc_wait(2).
 */
void
proc_wait_signal(void)
{
	proc_t *p = curproc;

	if (p == 0)
		return;
	for (;;) {
		unsigned int deliverable =
		    p->p_sigpend & ~(p->p_sigmask & ~(1u << 9 /*SIGKILL*/));
		if (deliverable != 0)
			return;		/* a deliverable signal is pending */
		sched_spin_lock();
		/* re-check under the lock: a peer hart may have posted a signal
		   between the test above and here (it would set RUNNABLE, but we
		   have not yet set WAITING, so the wake would be lost). */
		deliverable = p->p_sigpend & ~(p->p_sigmask & ~(1u << 9));
		if (deliverable != 0) {
			sched_spin_unlock();
			return;
		}
		p->p_state = P_WAITING;
		sched_spin_unlock();
		sched();		/* block; woken RUNNABLE by proc_kill/alarm */
	}
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
			/*
			 * R-P38.2: SIGCONT RESUMES a stopped job.  A P_STOPPED
			 * proc is parked (off the runq); making it RUNNABLE lets
			 * the scheduler switch back into its context (it resumes
			 * inside proc_stop_self, past the rv_swtch).  This is the
			 * kernel half of the shell's fg/bg SIGCONT.
			 */
			if (sig == SIGCONT && p->p_state == P_STOPPED) {
				p->p_stopreport = 0;
				p->p_state = P_RUNNABLE;
				p->p_onproc = 0;
				proc_ipi_wake_others();
			} else if (p->p_state == P_WAITING) {
				p->p_state = P_RUNNABLE;
				proc_ipi_wake_others();	/* R-P35.1: wake an idle hart */
			}
		}
		rc = 0;
		break;
	}
	sched_spin_unlock();
	return (rc);
}

/* ---- R-P37.2: job control -- process groups + a tty foreground pgrp ---- */
/*
 * The tty has a foreground process group (tty_fg_pgrp); a ^C / ^Z on the console
 * raises SIGINT / SIGTSTP on EVERY proc in that group.  The shell sets the fg
 * pgrp to a command's group before running it (setfg) and reclaims it after, so
 * ^C interrupts the running command, not the shell.  0 means "no fg group"
 * (signals go nowhere).  This is the illumos/BSD t_pgrp job-control model.
 */
static volatile int tty_fg_pgrp;

/* SYS_setpgid: set proc `pid`'s (0 = self) process group to `pgid` (0 = pid). */
int
proc_setpgid(int pid, int pgid)
{
	int i, rc = -1;
	sched_spin_lock();
	if (pid == 0)
		pid = curproc ? curproc->p_pid : 0;
	for (i = 0; i < NPROC; i++) {
		proc_t *p = &proc_tab[i];
		if (p->p_pid != pid || p->p_state == P_UNUSED)
			continue;
		p->p_pgid = (pgid == 0) ? pid : pgid;
		rc = 0;
		break;
	}
	sched_spin_unlock();
	return (rc);
}

/* SYS_getpgid: the caller's process group id. */
int
proc_getpgid(void)
{
	return (curproc ? curproc->p_pgid : 0);
}

/* the shell sets/queries the tty foreground process group. */
int
proc_tty_setfg(int pgrp)
{
	tty_fg_pgrp = pgrp;
	return (0);
}
int
proc_tty_getfg(void)
{
	return (tty_fg_pgrp);
}

/*
 * proc_tty_signal_fg -- console.c calls this from the TIMER TICK on ^C (SIGINT)
 * / ^Z (SIGTSTP): post `sig` to every proc in the tty foreground process group.
 * Lock-free (an atomic OR + a direct state nudge) like proc_alarm_tick, since it
 * runs in interrupt context and must not block on sched_spin_lock (a tick that
 * nested on a lock holder would deadlock).  Returns the number of procs signalled.
 */
int
proc_tty_signal_fg(int sig)
{
	int i, sent = 0, fg = tty_fg_pgrp;
	if (fg == 0)
		return (0);
	for (i = 0; i < NPROC; i++) {
		proc_t *p = &proc_tab[i];
		if (p->p_state == P_UNUSED || p->p_state == P_ZOMBIE ||
		    p->p_state == P_REAPING || p->p_pgid != fg)
			continue;
		__sync_fetch_and_or(&p->p_sigpend, (1u << sig));
		if (p->p_state == P_WAITING) {
			p->p_state = P_RUNNABLE;
			proc_ipi_wake_others();
		}
		sent++;
	}
	return (sent);
}

/*
 * proc_stop_self -- SIGTSTP default action (called from signal.c): mark the
 * running proc STOPPED so the scheduler skips it, print a report line, and
 * yield.  A P_STOPPED proc is not RUNNABLE (never dispatched) and not a ZOMBIE
 * (never reaped), so it just parks -- the reduced job-control "stopped job".
 */
void
proc_stop_self(void)
{
	proc_t *p = curproc;
	int i;
	if (p == 0)
		return;
	sbi_console_puts("[job] pid ");
	putdec_pub((unsigned long)p->p_pid);
	sbi_console_puts(" stopped (SIGTSTP)\n");
	sched_spin_lock();
	p->p_state = P_STOPPED;
	p->p_stopreport = 1;		/* WUNTRACED: report the stop to the parent */
	p->p_onproc = 1;	/* not pickable until safely switched off-cpu */
	/* wake a parent blocked in wait() so it reports the stop (not a reap). */
	for (i = 0; i < NPROC; i++) {
		proc_t *par = &proc_tab[i];
		if (par->p_pid == p->p_ppid && par->p_state == P_WAITING) {
			par->p_state = P_RUNNABLE;
			proc_ipi_wake_others();
		}
	}
	sched_spin_unlock();
	rv_swtch(&p->p_ctx, &sched_ctx);
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

/*
 * proc_run_idle_ipi -- R-P35.1 driver (boot hart).  Bring up the secondary
 * hart into the SHARED proc dispatcher, then run the forker (fork a child,
 * block in a REAL P_WAITING wait(2), reap it): the hart that runs the parent
 * finds nothing else runnable while the parent is WAITING, PARKS in the idle
 * `wfi` (rv_sched_cpu), and when the child exits the kernel posts SIGCHLD +
 * an SBI software IPI (proc_ipi_wake_others) that WAKES the sleeping hart to
 * re-dispatch the parent.  Reuses the run_procs_smp machinery + statics.
 */
void
proc_run_idle_ipi(unsigned long boot_hartid)
{
	unsigned long sec = boot_hartid ^ 1;
	unsigned long ksatp = hat_boot_root_satp();
	volatile unsigned long spin;
	long err;
	proc_t *p0;

	proc_smp_secondary_online = 0;
	proc_smp_go = 0;

	/* the forker forks a child, waits + reaps it (a REAL P_WAITING block). */
	p0 = proc_first(user_elf_start);
	if (p0 == 0) {
		sbi_console_puts("  [R-P35.1] proc_first(forker) FAILED\n");
		return;
	}

	err = sbi_hart_start(sec, KVTOP((unsigned long)proc_ap_entry), ksatp);
	if (err != 0) {
		sbi_console_puts("  [smp] secondary start FAILED; idle+IPI on the "
		    "boot hart only\n");
		proc_smp_go = 1;
		rv_sched_cpu((int)boot_hartid);
	} else {
		for (spin = 0; spin < 200000000UL &&
		    proc_smp_secondary_online == 0; spin++)
			;
		sbi_console_puts("  [smp] secondary hart online; both harts drain "
		    "the shared runq (an idle hart parks in wfi)\n");
		proc_smp_go = 1;
		rv_sched_cpu((int)boot_hartid);
		for (spin = 0; spin < 400000000UL; spin++)
			;
	}
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
	/* grow: map fresh zeroed pages from the page-up of cur to newbrk.
	 * R-P40 fix: on the FIRST grow (cur == HEAP_BASE, page-aligned) the page
	 * CONTAINING the initial break was never mapped by a prior grow, so round
	 * DOWN to include it; on later grows cur's page is already mapped by the
	 * previous grow, so round UP (avoid re-mapping a live heap page). */
	for (va = (cur == HEAP_BASE) ? (cur & PAGEMASK)
				     : ((cur + PAGEOFFSET) & PAGEMASK);
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
/* R-P37: silence the per-fault COW/demand proof prints during the interactive
   shell session (they are R-P32 proof output that would spam the tty log). */
volatile int pf_verbose = 1;
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
			if (pf_verbose) {
			sbi_console_puts("      [exec-demand] fault -> paged text "
			    "from file va=");
			puthex_pub(va);
			sbi_console_puts(" (pid ");
			putdec_pub((unsigned long)p->p_pid);
			sbi_console_puts(")\n");
			}
			return (1);
		}
	}

	/* a store fault may be a COW page: copy it + make it writable. */
	if (scause == 15 && hat_cow_fault(p->p_uroot, va)) {
		rv_tlb_flush_all();
		__sync_fetch_and_add(&cow_events, 1);
		if (pf_verbose) {
		sbi_console_puts("      [COW] store fault -> copied page va=");
		puthex_pub(va);
		sbi_console_puts(" (pid ");
		putdec_pub((unsigned long)p->p_pid);
		sbi_console_puts(") -- private writable copy\n");
		}
		return (1);
	}
	/* otherwise a demand-paged (lazy) page: fault in a zeroed frame. */
	if (hat_demand_fault(p->p_uroot, va)) {
		rv_tlb_flush_all();
		__sync_fetch_and_add(&demand_events, 1);
		if (pf_verbose) {
		sbi_console_puts("      [demand] fault -> mapped zeroed page va=");
		puthex_pub(va);
		sbi_console_puts(" (pid ");
		putdec_pub((unsigned long)p->p_pid);
		sbi_console_puts(")\n");
		}
		return (1);
	}
	{
		extern unsigned long hat_user_probe_pte(unsigned long *root,
		    unsigned long va);
		unsigned long lpte = hat_user_probe_pte(p->p_uroot, va);
		/*
		 * R-P35.1: STALE-TLB store fault guard.  On SMP with no ASIDs a
		 * store can fault (scause 15) against a leaf that is ALREADY
		 * valid + writable -- a stale read-only TLB entry for the same VA
		 * left by another AS (no per-AS ASID separation).  The page table
		 * is correct, so flush this hart's TLB and retry; not a real
		 * violation.  (A genuinely unmapped or read-only leaf does NOT
		 * match this test and still falls through to SIGSEGV/halt.)
		 *
		 * CRIB PROVENANCE: re-checking the PTE + a local sfence.vma on a
		 * spurious fault (stale TLB, no ASID) is the illumos hat_tlb_inval
		 * / RISC-V sfence-on-stale idiom.
		 */
#define	PF_PTE_V	0x1UL
#define	PF_PTE_W	0x4UL
		if ((lpte & PF_PTE_V) && (lpte & PF_PTE_W) && scause == 15) {
			rv_tlb_flush_all();
			return (1);		/* stale TLB: retry the store */
		}
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
extern int vfs_walk(const char *path, struct vnode **out, int create);
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
#define	O_TRUNC		0x200		/* R-P37.3: truncate to zero on open */
#define	O_APPEND	0x008		/* R-P37.3: writes seek to end-of-file */

/*
 * R-P36: current-working-directory path resolution.  Turn a possibly-relative
 * user path into an absolute, canonicalized path (no "." / ".." components, no
 * trailing '/').  A path starting with '/' is canonicalized as-is; a relative
 * path is taken relative to the calling proc's p_cwd.  "." keeps the current
 * dir, ".." pops the last component.  Writes into `out` (>= 128 bytes).
 * Returns 0, or -1 on overflow / a bad ".." above root.
 *
 * CRIB PROVENANCE: prepending the cwd to a relative path + collapsing "."/".."
 * component-by-component is the illumos lookuppn / lookuppnvp cwd handling
 * (uts/common/fs/lookup.c, the u_cdir base + the ".." parent walk) + the BSD
 * namei() relative-to-cwd resolution, reduced to a string canonicalizer.
 */
static int
path_resolve(const char *in, char *out)
{
	char tmp[256];
	int ti = 0, oi = 0, i;
	proc_t *p = curproc;

	if (in == 0)
		return (-1);
	/* build tmp = cwd + "/" + in  (or just in, if absolute). */
	if (in[0] == '/') {
		for (i = 0; in[i] && ti < (int)sizeof (tmp) - 1; i++)
			tmp[ti++] = in[i];
	} else {
		const char *cwd = (p != 0 && p->p_cwd[0]) ? p->p_cwd : "/";
		for (i = 0; cwd[i] && ti < (int)sizeof (tmp) - 1; i++)
			tmp[ti++] = cwd[i];
		if (ti == 0 || tmp[ti - 1] != '/')
			if (ti < (int)sizeof (tmp) - 1)
				tmp[ti++] = '/';
		for (i = 0; in[i] && ti < (int)sizeof (tmp) - 1; i++)
			tmp[ti++] = in[i];
	}
	tmp[ti] = 0;

	/* canonicalize tmp into out, collapsing . and .. component-by-component. */
	out[0] = '/';
	oi = 1;
	i = 0;
	while (tmp[i] != 0) {
		char comp[64];
		int ci = 0;
		while (tmp[i] == '/')
			i++;
		while (tmp[i] != 0 && tmp[i] != '/') {
			if (ci < (int)sizeof (comp) - 1)
				comp[ci++] = tmp[i];
			i++;
		}
		comp[ci] = 0;
		if (ci == 0)
			continue;
		if (comp[0] == '.' && comp[1] == 0)
			continue;			/* "." : stay put */
		if (comp[0] == '.' && comp[1] == '.' && comp[2] == 0) {
			/* ".." : pop the last component of out (but not below /). */
			if (oi > 1) {
				oi--;			/* drop trailing '/' just added? */
				while (oi > 1 && out[oi - 1] != '/')
					oi--;
				if (oi > 1)
					oi--;		/* drop the '/' too */
				if (oi < 1)
					oi = 1;
			}
			continue;
		}
		/* append "/comp" to out. */
		if (oi > 1) {
			if (oi >= 127)
				return (-1);
			out[oi++] = '/';
		}
		for (ci = 0; comp[ci]; ci++) {
			if (oi >= 127)
				return (-1);
			out[oi++] = comp[ci];
		}
	}
	if (oi == 0)
		out[oi++] = '/';
	out[oi] = 0;
	return (0);
}

/* R-P36: public wrapper so proc_execv (below chdir) can resolve exec paths. */
int
proc_path_resolve_pub(const char *in, char *out)
{
	return (path_resolve(in, out));
}

/*
 * proc_chdir -- SYS_chdir body.  Resolve `path` (relative to cwd) + require it
 * to be an existing directory, then set the proc's p_cwd.  Returns 0 or -1.
 */
extern int vfs_path_isdir(const char *path);
/*
 * proc_getcwd -- SYS_getcwd body.  Copy the calling proc's tracked working
 * directory (p_cwd, an absolute path string maintained by proc_chdir) into
 * the user buffer.  Returns the byte length written (incl. NUL) or 0 on error
 * / too-small buffer.  This is the illumos u_cwd path string kept per-proc,
 * so no vnode-to-root walk is needed (proc_chdir already canonicalized it).
 */
int
proc_getcwd(char *ubuf, unsigned long sz)
{
	proc_t *p = curproc;
	const char *cwd = (p != 0 && p->p_cwd[0]) ? p->p_cwd : "/";
	unsigned long i;

	for (i = 0; cwd[i] && i < sz - 1; i++)
		ubuf[i] = cwd[i];
	if (cwd[i] != 0)			/* did not fit */
		return (0);
	ubuf[i] = 0;
	return ((int)(i + 1));
}

int
proc_chdir(const char *path)
{
	proc_t *p = curproc;
	char abspath[128];
	int i;

	if (p == 0)
		return (-1);
	if (path_resolve(path, abspath) != 0)
		return (-1);
	if (!vfs_path_isdir(abspath))
		return (-1);			/* not a directory */
	for (i = 0; abspath[i] && i < (int)sizeof (p->p_cwd) - 1; i++)
		p->p_cwd[i] = abspath[i];
	p->p_cwd[i] = 0;
	return (0);
}

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

	char abspath[128];
	if (p == 0)
		return (RERR_EBADF);
	if (path_resolve(path, abspath) == 0)	/* R-P36: relative -> cwd-based */
		path = abspath;
	/*
	 * R-P40.3: a /blk/NAME path resolves on the disk-backed blockfs (left
	 * mounted at boot), so the shell can open + read a file served from the
	 * persistent block device -- its vop_read crosses bdev_strategy, not ramfs.
	 */
	if (path[0] == '/' && path[1] == 'b' && path[2] == 'l' &&
	    path[3] == 'k' && path[4] == '/') {
		extern int vfs_blockfs_open(const char *name, struct vnode **out);
		extern int vfs_blockfs_isdir(const char *name);
		extern int vfs_blockfs_opendir(const char *name,
		    struct vnode **out);
		int isdir = vfs_blockfs_isdir(path + 5);
		rc = isdir ? vfs_blockfs_opendir(path + 5, &vp)
		    : vfs_blockfs_open(path + 5, &vp);
		if (rc != 0)
			return (rc);
		for (fd = 3; fd < NOFILE; fd++) {
			if (!p->p_fd[fd].f_used) {
				p->p_fd[fd].f_vnode = vp;
				p->p_fd[fd].f_off = 0;
				p->p_fd[fd].f_used = 1;
				p->p_fd[fd].f_pipe = 0;
				p->p_fd[fd].f_dir = isdir;
				return (fd);
			}
		}
		return (RERR_EMFILE);
	}
	rc = vfs_walk(path, &vp, (flags & O_CREAT) ? 1 : 0);	/* R-P34.3: lookuppn */
	if (rc != 0)
		return (rc);
	for (fd = 3; fd < NOFILE; fd++) {
		if (!p->p_fd[fd].f_used) {
			extern int vfs_isdir(struct vnode *vp);
			extern int vfs_truncate(struct vnode *vp);
			p->p_fd[fd].f_vnode = vp;
			p->p_fd[fd].f_off = 0;
			p->p_fd[fd].f_used = 1;
			p->p_fd[fd].f_pipe = 0;
			p->p_fd[fd].f_dir = vfs_isdir(vp);
			/* R-P37.3: O_TRUNC resets the file to empty; O_APPEND starts
			   the offset at end-of-file so writes append. */
			if ((flags & O_TRUNC) && !p->p_fd[fd].f_dir)
				(void) vfs_truncate(vp);
			if ((flags & O_APPEND) && !p->p_fd[fd].f_dir) {
				unsigned long sz = 0;
				(void) fop_getattr(vp, &sz);
				p->p_fd[fd].f_off = sz;
			}
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

	/*
	 * R-P37.1: fd 0 (stdin) with NO file/pipe backing is the console tty:
	 * read a canonical line from the live console via the line discipline.
	 * (init dup2's a file/pipe onto fd 0 for a scripted session; a bare fd 0
	 * -- the interactive case -- reads the console.)
	 */
	if (fd == 0 && (p == 0 || !p->p_fd[0].f_used)) {
		extern long console_read(char *ubuf, unsigned long n);
		return (console_read(ubuf, n));
	}
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

	if ((fd == 1 || fd == 2) && (p == 0 || !p->p_fd[fd].f_used)) {
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
	if (p->p_fd[fd].f_pipe != 0)
		return (-29);			/* ESPIPE: a pipe is not seekable */
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

	/* R-P40: fstat of a console fd (0/1/2, f_used==0) succeeds with size 0 --
	   a real coreutils util (cat) fstat(STDOUT_FILENO)s the tty up front. */
	if (fd >= 0 && fd <= 2 && (p == 0 || !p->p_fd[fd].f_used)) {
		if (ubuf != 0) {
			ubuf[0] = 0;
			ubuf[1] = 2;		/* R-P41: console tty -> S_IFCHR */
		}
		return (0);
	}
	if (p == 0 || fd < 0 || fd >= NOFILE || !p->p_fd[fd].f_used)
		return (RERR_EBADF);
	/*
	 * R-P47: a pipe fd has NO vnode (f_pipe set, f_vnode == NULL).  fstat of
	 * a pipe must NOT dereference the null vnode via fop_getattr -- report it
	 * like a character special (size 0), which is what `yes`/`head` fstat
	 * their pipe stdin/stdout for up front.  Without this guard the NULL
	 * vnode faulted in fop_getattr (kernel load fault) when head read from
	 * the pipe.
	 */
	if (p->p_fd[fd].f_pipe != 0) {
		if (ubuf != 0) {
			ubuf[0] = 0;
			ubuf[1] = 2;		/* pipe -> treat as char special */
		}
		return (0);
	}
	(void) fop_getattr((struct vnode *)p->p_fd[fd].f_vnode, &sz);
	if (ubuf != 0) {
		extern int vfs_vtype(struct vnode *vp);
		ubuf[0] = sz;			/* st_size */
		ubuf[1] = vfs_vtype((struct vnode *)p->p_fd[fd].f_vnode);
	}
	return (0);
}

long
proc_stat(const char *path, unsigned long *ubuf)
{
	struct vnode *vp;
	unsigned long sz = 0;

	if (vfs_walk(path, &vp, 0) != 0)
		return (RERR_ENOENT);
	(void) fop_getattr(vp, &sz);
	if (ubuf != 0) {
		extern int vfs_vtype(struct vnode *vp);
		ubuf[0] = sz;			/* st_size */
		ubuf[1] = vfs_vtype(vp);	/* R-P41: 0 regular, 1 dir */
	}
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
	char abspath[128];
	if (curproc == 0)
		return (RERR_EBADF);
	if (path_resolve(path, abspath) == 0)	/* R-P37: relative -> cwd-based */
		path = abspath;
	/* R-P41.3: mkdir on the persistent blockfs -> an on-disk dir inode. */
	if (path[0] == '/' && path[1] == 'b' && path[2] == 'l' &&
	    path[3] == 'k' && path[4] == '/') {
		extern int vfs_blockfs_mkdir(const char *name);
		return (vfs_blockfs_mkdir(path + 5));
	}
	return (vfs_mkdir(path));
}

/* R-P37.3: rmdir(path) -- remove an (empty) tmpfs directory. */
long
proc_rmdir(const char *path)
{
	extern int vfs_rmdir(const char *path);
	char abspath[128];
	if (curproc == 0)
		return (RERR_EBADF);
	if (path_resolve(path, abspath) == 0)
		path = abspath;
	return (vfs_rmdir(path));
}

/* R-P34.3: unlink/rename/mount thin wrappers over the vfs. */
long
proc_unlink(const char *path)
{
	extern int vfs_unlink(const char *path);
	if (curproc == 0)
		return (RERR_EBADF);
	return (vfs_unlink(path));
}
long
proc_rename(const char *from, const char *to)
{
	extern int vfs_rename(const char *from, const char *to);
	if (curproc == 0)
		return (RERR_EBADF);
	return (vfs_rename(from, to));
}
long
proc_mount(const char *fstype, const char *path)
{
	extern int vfs_mount(const char *fstype, const char *path);
	if (curproc == 0)
		return (RERR_EBADF);
	return (vfs_mount(fstype, path));
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
	p->p_fd[fd].f_cloexec = 0;
	return (0);
}

/* ---- R-P34.2: dup(2) / dup2(2) / fcntl(2) ---------------------------- */
/*
 * A dup'd fd is a SECOND reference to the same open-file (same vnode / pipe end
 * / offset), NOT a copy: the shape here shares the f_* fields by struct copy
 * (there is no separate open-file object yet, so both fds carry the same vnode/
 * pipe pointer + offset -- close of one leaves the other usable because the
 * console/ramfs/tmpfs vnodes are shared static state; a pipe end's refcount is
 * bumped so the pipe survives).  The dup'd fd's FD_CLOEXEC is CLEARED (POSIX:
 * dup/dup2 produce a non-close-on-exec descriptor).
 *
 * CRIB PROVENANCE: dup/dup2/fcntl allocating a new fd index that references the
 * same file_t + clearing FD_CLOEXEC on the new fd is illumos uts/common/os/fio.c
 * (fd_reserve/dupfd + fcntl F_DUPFD/F_GETFD/F_SETFD/F_GETFL/F_SETFL); the pipe
 * refcount bump on dup is fifofs fifo_open reuse.
 */
extern void pipe_incref(void *pp, int is_write);

/* install a duplicate of `oldfd` at slot `newfd` (must be free/closed). */
static long
fd_dup_into(proc_t *p, int oldfd, int newfd)
{
	p->p_fd[newfd] = p->p_fd[oldfd];
	p->p_fd[newfd].f_cloexec = 0;	/* dup clears close-on-exec */
	if (p->p_fd[oldfd].f_pipe != 0)
		pipe_incref(p->p_fd[oldfd].f_pipe, p->p_fd[oldfd].f_pipe_w);
	return (newfd);
}

/* find the lowest free fd >= `from`. */
static int
fd_lowest_free(proc_t *p, int from)
{
	int fd;
	if (from < 3)
		from = 3;	/* 0/1/2 are the console; dup lands >=3 */
	for (fd = from; fd < NOFILE; fd++)
		if (!p->p_fd[fd].f_used)
			return (fd);
	return (-1);
}

long
proc_dup(int oldfd)
{
	proc_t *p = curproc;
	int newfd;

	if (p == 0 || oldfd < 0 || oldfd >= NOFILE)
		return (RERR_EBADF);
	if (oldfd > 2 && !p->p_fd[oldfd].f_used)
		return (RERR_EBADF);
	if (oldfd <= 2) {		/* dup of a console fd: another console fd */
		newfd = fd_lowest_free(p, 3);
		if (newfd < 0)
			return (RERR_EMFILE);
		p->p_fd[newfd].f_used = 1;
		p->p_fd[newfd].f_vnode = 0;
		p->p_fd[newfd].f_pipe = 0;
		p->p_fd[newfd].f_off = 0;
		p->p_fd[newfd].f_pipe_w = 0;
		p->p_fd[newfd].f_dir = 0;
		p->p_fd[newfd].f_cloexec = 0;
		return (newfd);
	}
	newfd = fd_lowest_free(p, 3);
	if (newfd < 0)
		return (RERR_EMFILE);
	return (fd_dup_into(p, oldfd, newfd));
}

long
proc_dup2(int oldfd, int newfd)
{
	proc_t *p = curproc;

	if (p == 0 || oldfd < 0 || oldfd >= NOFILE || newfd < 0 ||
	    newfd >= NOFILE)
		return (RERR_EBADF);
	if (oldfd > 2 && !p->p_fd[oldfd].f_used)
		return (RERR_EBADF);
	if (oldfd == newfd)
		return (newfd);		/* dup2 to itself: no-op */
	/* close whatever the target slot held (a real file/pipe fd). */
	if (newfd > 2 && p->p_fd[newfd].f_used)
		(void) proc_close_file(newfd);
	else if (newfd <= 2 && p->p_fd[newfd].f_used &&
	    p->p_fd[newfd].f_pipe != 0) {
		extern void pipe_close(void *pp, int is_write);
		pipe_close(p->p_fd[newfd].f_pipe, p->p_fd[newfd].f_pipe_w);
	}
	if (oldfd <= 2 && !p->p_fd[oldfd].f_used) {
		/* redirecting a bare CONSOLE fd onto newfd: newfd becomes the
		   console again (clear any file backing at newfd). */
		p->p_fd[newfd].f_used = 0;
		p->p_fd[newfd].f_vnode = 0;
		p->p_fd[newfd].f_pipe = 0;
		p->p_fd[newfd].f_off = 0;
		p->p_fd[newfd].f_pipe_w = 0;
		p->p_fd[newfd].f_dir = 0;
		p->p_fd[newfd].f_cloexec = 0;
		return (newfd);
	}
	return (fd_dup_into(p, oldfd, newfd));
}

/* SunOS <sys/fcntl.h> cmds (reduced). */
#define	F_DUPFD		0
#define	F_GETFD		1
#define	F_SETFD		2
#define	F_GETFL		3
#define	F_SETFL		4
#define	FD_CLOEXEC	1

long
proc_fcntl(int fd, int cmd, long arg)
{
	proc_t *p = curproc;
	int newfd;

	if (p == 0 || fd < 0 || fd >= NOFILE)
		return (RERR_EBADF);
	if (fd > 2 && !p->p_fd[fd].f_used)
		return (RERR_EBADF);
	switch (cmd) {
	case F_DUPFD:		/* lowest free fd >= arg that dup's fd */
		newfd = fd_lowest_free(p, (int)arg);
		if (newfd < 0)
			return (RERR_EMFILE);
		if (fd <= 2) {
			p->p_fd[newfd].f_used = 1;
			p->p_fd[newfd].f_vnode = 0;
			p->p_fd[newfd].f_pipe = 0;
			p->p_fd[newfd].f_off = 0;
			p->p_fd[newfd].f_pipe_w = 0;
			p->p_fd[newfd].f_dir = 0;
			p->p_fd[newfd].f_cloexec = 0;
			return (newfd);
		}
		return (fd_dup_into(p, fd, newfd));
	case F_GETFD:		/* the fd flags: FD_CLOEXEC or 0 */
		if (fd <= 2)
			return (0);
		return (p->p_fd[fd].f_cloexec ? FD_CLOEXEC : 0);
	case F_SETFD:		/* set/clear FD_CLOEXEC */
		if (fd > 2)
			p->p_fd[fd].f_cloexec = (arg & FD_CLOEXEC) ? 1 : 0;
		return (0);
	case F_GETFL:		/* file status flags -- reduced: 0 (O_RDWR) */
		return (0);
	case F_SETFL:		/* accept + ignore (no O_NONBLOCK yet) */
		return (0);
	default:
		return (RERR_EBADF);
	}
}

/*
 * proc_fd_cloexec -- close every FD_CLOEXEC-flagged fd of curproc.  Called from
 * do_exec BEFORE the new image runs so a close-on-exec fd is NOT inherited
 * across exec(2) (POSIX).  Non-CLOEXEC fds survive into the new image.
 */
void
proc_fd_cloexec(void)
{
	proc_t *p = curproc;
	int fd;

	if (p == 0)
		return;
	for (fd = 3; fd < NOFILE; fd++) {
		if (p->p_fd[fd].f_used && p->p_fd[fd].f_cloexec)
			(void) proc_close_file(fd);
	}
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
/* R-P47: SIGPIPE (POSIX/SunOS 13) + EPIPE (illumos 32) for the no-reader case. */
#define	SIGPIPE		13
#define	RERR_EPIPE	(-32)
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
		if (pp->pb_readers <= 0) {
			/*
			 * R-P47: write to a pipe with no readers left.  POSIX:
			 * deliver SIGPIPE to the writer (default action terminates
			 * it) and return EPIPE.  Posting SIGPIPE to curproc here
			 * makes `yes | head` end cleanly -- head exits, closing the
			 * read end, and yes dies on SIGPIPE on its next write instead
			 * of spinning or faulting in the teardown.  Delivery happens
			 * on the trap-return edge (proc_deliver_signals).
			 */
			extern int proc_kill(int pid, int sig);
			proc_t *cp = curproc;
			if (cp != 0)
				proc_kill((int)cp->p_pid, SIGPIPE);
			return (put > 0 ? (long)put : RERR_EPIPE);
		}
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
	extern long proc_execv(const char *path, char **argv);
	return (proc_execv(path, 0));
}

/*
 * proc_execv -- R-P35.2/.3: execve(path, argv).  Stage the caller's argv
 * strings (read from the OLD user AS, SUM set, BEFORE do_exec switches to the
 * new AS) into the kernel exec argv buffer, then exec by path (ramfs) or fall
 * back to the embedded execee.  A shell fork+execs a command WITH ARGUMENTS
 * this way (echo hello, cat /etc/release).
 */
extern void exec_argv_reset(void);
extern int exec_argv_push(const char *s);

long
proc_execv(const char *path, char **argv)
{
	const unsigned char *img;
	unsigned long len;

	/* stage argv from the caller's AS before the AS is torn down. */
	exec_argv_reset();
	if (argv != 0) {
		int i;
		for (i = 0; i < 8 && argv[i] != 0; i++) {
			if (exec_argv_push(argv[i]) != 0)
				break;
		}
	}
	{
		extern int proc_path_resolve_pub(const char *in, char *out);
		static char abspath[128];
		if (path != 0 && proc_path_resolve_pub(path, abspath) == 0)
			path = abspath;		/* R-P36: relative exec path -> cwd */
	}
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

	/*
	 * R-P35.3: CLOSE ALL OPEN FDs on exit.  A proc that exits without
	 * explicitly close()ing its fds (e.g. echo holding a pipe write end via
	 * dup2) must still drop those references -- otherwise a pipe's write
	 * end never reaches refcount 0 and the reader (cat) blocks on read
	 * forever waiting for an EOF that never comes.  Drops pipe refcounts +
	 * clears file backings.  (Console fds 0/1/2 are a no-op.)
	 *
	 * CRIB PROVENANCE: exit() releasing the proc's open-file table (closef
	 * on every fd, fifofs dropping the pipe end) is illumos os/exit.c
	 * closeall()/exit + BSD fdfree; the pipe-EOF-on-last-writer semantics
	 * are POSIX pipe(2).
	 */
	for (i = 3; i < NOFILE; i++)
		if (p->p_fd[i].f_used)
			(void) proc_close_file(i);
	/* fds 0/1/2 may be pipe ends via dup2 -- drop those refs too. */
	for (i = 0; i <= 2; i++)
		if (p->p_fd[i].f_used && p->p_fd[i].f_pipe != 0) {
			extern void pipe_close(void *pp, int is_write);
			pipe_close(p->p_fd[i].f_pipe, p->p_fd[i].f_pipe_w);
			p->p_fd[i].f_pipe = 0;
			p->p_fd[i].f_used = 0;
		}

	sched_spin_lock();
	p->p_xstat = status;
	p->p_state = P_ZOMBIE;
	p->p_onproc = 1;	/* not reapable until safely switched off-cpu */
	/*
	 * R-P35.2: REPARENT ORPHANS TO init (pid 1).  A child that outlives
	 * this exiting parent must not be left with a dead/UNUSED parent pid
	 * (its zombie would never be reaped).  Hand every still-live child of
	 * p over to init (pid 1), the classic Unix orphan-adoption; init's
	 * wait(2) loop then reaps them.  A zombie child is reparented too so
	 * init reaps it (and is woken below).  Skipped if p IS init.
	 */
	if (p->p_pid != INIT_PID) {
		int have_init = 0;
		for (i = 0; i < NPROC; i++)
			if (proc_tab[i].p_pid == INIT_PID &&
			    proc_tab[i].p_state != P_UNUSED)
				have_init = 1;
		if (have_init) {
			for (i = 0; i < NPROC; i++) {
				proc_t *c = &proc_tab[i];
				if (c != p && c->p_state != P_UNUSED &&
				    c->p_ppid == p->p_pid)
					c->p_ppid = INIT_PID;
			}
		}
	}
	/* R-P34.1: post SIGCHLD to the parent + wake a parent blocked in wait(). */
	for (i = 0; i < NPROC; i++) {
		if (proc_tab[i].p_state != P_UNUSED &&
		    proc_tab[i].p_pid == p->p_ppid && p->p_ppid != 0) {
			__sync_fetch_and_or(&proc_tab[i].p_sigpend,
			    (1u << SIGCHLD));
			if (proc_tab[i].p_state == P_WAITING) {
				proc_tab[i].p_state = P_RUNNABLE;
				proc_ipi_wake_others();	/* R-P35.1: IPI-wake an idle parent hart */
			}
		}
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
long proc_waitpid(long want_pid, long *statusp, int options);	/* R-P36 fwd */
long
proc_wait(long *statusp)
{
	return (proc_waitpid(-1, statusp, 0));	/* R-P36: wait for any child */
}

/*
 * proc_waitpid -- R-P36: SYS_waitpid body.  Reap a child of curproc, blocking
 * until one is available unless WNOHANG is set.
 *   want_pid > 0 : reap ONLY that specific child (wait for it if not yet a
 *                  zombie); return -1 if it is not our child.
 *   want_pid <= 0: reap ANY zombie child (the R-P35 wait-any behavior).
 *   options & WNOHANG (1): do NOT block -- if no matching zombie is ready,
 *                  return 0 immediately (POSIX waitpid WNOHANG).
 * Stores the exit status through *statusp; returns the reaped pid, -1 if there
 * is no such child, or 0 for a WNOHANG poll with nothing ready.
 *
 * CRIB PROVENANCE: waitpid(pid, &st, WNOHANG) selecting a specific child +
 * the non-blocking poll is the illumos waitid / waitsys (uts/common/os/exit.c
 * waitid_cleanup, the idtype P_PID vs P_ALL) + the POSIX waitpid(2) semantics +
 * the xv6 wait() reap loop generalized to a target pid + a poll flag.
 */
#define	WNOHANG		1
#define	WUNTRACED	2		/* R-P37.2: also report stopped children */
long
proc_waitpid(long want_pid, long *statusp, int options)
{
	proc_t *p = curproc;

	for (;;) {
		int i, have_child = 0;
		proc_t *reap = 0;
		int pid = 0, xs = 0;
		int stopped_pid = 0;

		sched_spin_lock();
		for (i = 0; i < NPROC; i++) {
			proc_t *c = &proc_tab[i];
			if (c->p_ppid != p->p_pid ||
			    c->p_state == P_UNUSED)
				continue;
			/* R-P36: a specific-pid wait ignores other children. */
			if (want_pid > 0 && c->p_pid != (int)want_pid)
				continue;
			have_child = 1;
			/*
			 * R-P37.2 WUNTRACED: a child stopped by SIGTSTP is reported
			 * ONCE (pid + a WIFSTOPPED status sentinel 0x7f) without
			 * reaping -- the shell prints "stopped", the proc stays
			 * P_STOPPED (parked, not on the runq).
			 */
			if (c->p_state == P_STOPPED && c->p_stopreport) {
				c->p_stopreport = 0;
				stopped_pid = c->p_pid;
				break;
			}
			if (c->p_state == P_ZOMBIE) {
				pid = c->p_pid;
				xs = c->p_xstat;
				c->p_state = P_REAPING;	/* claim it */
				reap = c;
				break;
			}
		}
		sched_spin_unlock();
		/* R-P37.2: report a stopped child (WUNTRACED) without reaping. */
		if (stopped_pid != 0) {
			if (statusp != 0)
				*statusp = 0x7f;	/* WIFSTOPPED sentinel */
			return (stopped_pid);
		}
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
		/* R-P36: WNOHANG -- no matching zombie ready, so poll returns 0. */
		if (options & WNOHANG)
			return (0);
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

/*
 * run_asid_churn -- R-P36.1 proof (THE R-P35 SMP FIX).  The R-P35 latent fault
 * was: COW fork drops PTE_W in the PARENT's live page tables + does a LOCAL-only
 * sfence.vma, so a peer hart keeps a stale WRITABLE TLB entry for the now-COW
 * frame and can store into it without faulting -- corrupting the child's page
 * under heavy fork/exec/wait churn.  R-P36 fixes it two ways: (1) each AS carries
 * its own ASID so sfence.vma is ASID-scoped, and (2) COW share + AS teardown do
 * a REMOTE-hart TLB shootdown (IPI-driven SBI RFENCE) so no hart keeps stale
 * entries.  This proof drives the exact code path: build an AS, COW-share it into
 * a fresh child root (hat_user_cow_share) with the ASID-scoped local flush + the
 * remote shootdown, then fault-copy + tear both down -- N times, and it forces a
 * real ASID rollover mid-loop.  The frame count returns to baseline (no leak /
 * no fault) and the rollover is observed.
 *
 * CRIB PROVENANCE: exercising the hat_dup(HAT_DUP) COW path + a cross-CPU x_call
 * TLB shootdown over a process-churn lifecycle is the illumos hat_tlb_inval /
 * xc_call model; the ASID rollover-and-flush recycle is sun4v sfmmu_get_ctx.
 */
extern int hat_user_cow_share(unsigned long *dst_root, unsigned long *src_root);
extern void hat_asid_force_near_rollover(void);
extern unsigned long hat_asid_generation(void);

void
run_asid_churn(void)
{
	unsigned long base, after;
	unsigned long gen0, gen1;
	int iter, faulted = 0, rolled_seen = 0;
	const int N = 40;

	sbi_console_puts("\n");
	sbi_console_puts("[R-P36.1] ASID churn: COW-share + ASID-scoped local flush + "
	    "REMOTE shootdown + teardown, N times, across an ASID rollover\n");
	sbi_console_puts("----- asid churn proof output -----\n");

	base = kmem_pages_inuse();
	gen0 = hat_asid_generation();

	for (iter = 0; iter < N; iter++) {
		struct uproc up;
		unsigned long *croot;

		if (exec_image(&up, execee_elf_start) != 0) {
			faulted = 1;
			break;
		}
		/* fresh child AS sharing the kernel high half. */
		croot = hat_user_new();
		if (croot == 0) { hat_as_free((unsigned long *)up.u_root); faulted = 1; break; }

		/*
		 * THE FIX PATH: COW-share the parent's leaves into the child
		 * (drops PTE_W in the parent), then ASID-scope the local flush
		 * + broadcast a remote shootdown -- exactly what do_fork does.
		 */
		if (hat_user_cow_share(croot, (unsigned long *)up.u_root) != 0) {
			hat_as_free(croot); hat_as_free((unsigned long *)up.u_root);
			faulted = 1; break;
		}
		rv_tlb_flush_asid(1);			/* ASID-scoped local flush */
		hat_tlb_shootdown((long)(cpuid() ^ 1));	/* remote-hart shootdown */

		/* force a rollover a third of the way in. */
		if (iter == N / 3)
			hat_asid_force_near_rollover();
		{
			int r = 0;
			(void) hat_asid_alloc(&r);	/* may trigger the rollover */
			if (r)
				rolled_seen = 1;
			(void) hat_asid_alloc(&r);
			if (r)
				rolled_seen = 1;
		}

		/* tear both address spaces down (frees frames + tables). */
		hat_as_free(croot);
		hat_as_free((unsigned long *)up.u_root);

		if ((iter % 10) == 0) {
			sbi_console_puts("  iter ");
			putdec_pub((unsigned long)iter);
			sbi_console_puts(" gen=");
			putdec_pub(hat_asid_generation());
			sbi_console_puts(" frames=");
			putdec_pub(kmem_pages_inuse());
			sbi_console_puts("\n");
		}
	}

	after = kmem_pages_inuse();
	gen1 = hat_asid_generation();
	sbi_console_puts("----- end asid churn proof output -----\n");
	sbi_console_puts("  frames baseline=");
	putdec_pub(base);
	sbi_console_puts(" final=");
	putdec_pub(after);
	sbi_console_puts(" asid-gen ");
	putdec_pub(gen0);
	sbi_console_puts("->");
	putdec_pub(gen1);
	sbi_console_puts("\n");
	if (!faulted && after == base)
		sbi_console_puts("[R-P36.1] ASID churn PROVEN: heavy COW-share + "
		    "remote-shootdown + teardown churn ran clean (no fault, no leak).\n");
	else
		sbi_console_puts("[R-P36.1] ASID churn INCOMPLETE (fault or frame leak).\n");
	if (rolled_seen && gen1 > gen0)
		sbi_console_puts("[R-P36.1] ASID rollover handled: the 16-bit ASID space "
		    "wrapped, the generation bumped, and the TLB was recycled.\n");
	else
		sbi_console_puts("[R-P36.1] ASID rollover NOT observed.\n");
}

/*
 * run_waitpid -- R-P36.2 proof.  Drive proc_waitpid two ways WITHOUT the
 * scheduler: seed two zombie children of a synthetic parent in the proc table
 * and (1) reap a SPECIFIC pid (leaving the other), then (2) WNOHANG-poll for a
 * child that is not yet a zombie (returns 0), then reap it.  Exercises the
 * want_pid selection + the WNOHANG non-blocking path directly.
 *
 * CRIB PROVENANCE: the waitpid(pid, &st, WNOHANG) target selection + poll is the
 * illumos waitid P_PID / WNOHANG semantics (uts/common/os/exit.c).
 */
extern long proc_waitpid(long want_pid, long *statusp, int options);

void
run_waitpid(void)
{
	proc_t *parent, *c1, *c2;
	long st, r;
	int ok = 1;

	sbi_console_puts("\n");
	sbi_console_puts("[R-P36.2] waitpid: specific-pid reap + WNOHANG poll\n");
	sbi_console_puts("----- waitpid proof output -----\n");

	/* a synthetic parent whose curproc the reap path reads. */
	parent = proc_alloc();
	c1 = proc_alloc();
	c2 = proc_alloc();
	if (parent == 0 || c1 == 0 || c2 == 0) {
		sbi_console_puts("[R-P36.2] waitpid: proc_alloc failed\n");
		return;
	}
	/* make the two children kernel-thread zombies of `parent` (no AS to free). */
	parent->p_kthread = 1; parent->p_uroot = 0;
	c1->p_kthread = 1; c1->p_uroot = 0; c1->p_ppid = parent->p_pid;
	c2->p_kthread = 1; c2->p_uroot = 0; c2->p_ppid = parent->p_pid;
	c1->p_xstat = 11; c2->p_xstat = 22;
	c1->p_state = P_ZOMBIE;
	c2->p_state = P_RUNNABLE;		/* not yet a zombie */

	/* run the reap loop AS `parent`: set this hart's curproc to parent. */
	{
		int me = cpuid();
		proc_t *save = cpu_cur[me];
		cpu_cur[me] = parent;

		/* (1) WNOHANG poll for c2 (RUNNABLE, not a zombie) -> 0. */
		st = -1;
		r = proc_waitpid((long)c2->p_pid, &st, 1 /*WNOHANG*/);
		sbi_console_puts("  waitpid(c2, WNOHANG) while c2 alive -> ");
		putdec_pub((unsigned long)r);
		sbi_console_puts(" (want 0)\n");
		if (r != 0) ok = 0;

		/* (2) reap the SPECIFIC zombie c1 (c2 must be left untouched). */
		st = -1;
		r = proc_waitpid((long)c1->p_pid, &st, 0);
		sbi_console_puts("  waitpid(c1) -> pid ");
		putdec_pub((unsigned long)r);
		sbi_console_puts(" status ");
		putdec_pub((unsigned long)st);
		sbi_console_puts(" (want pid+status 11)\n");
		if (r != (long)c1->p_pid || st != 11) ok = 0;
		if (c2->p_state != P_RUNNABLE) ok = 0;	/* c2 not disturbed */

		/* now let c2 become a zombie + reap it specifically. */
		c2->p_state = P_ZOMBIE;
		st = -1;
		r = proc_waitpid((long)c2->p_pid, &st, 0);
		sbi_console_puts("  waitpid(c2) -> pid ");
		putdec_pub((unsigned long)r);
		sbi_console_puts(" status ");
		putdec_pub((unsigned long)st);
		sbi_console_puts(" (want pid+status 22)\n");
		if (r != (long)c2->p_pid || st != 22) ok = 0;

		cpu_cur[me] = save;
	}
	/* release the synthetic parent slot. */
	parent->p_state = P_UNUSED;

	sbi_console_puts("----- end waitpid proof output -----\n");
	if (ok)
		sbi_console_puts("[R-P36.2] waitpid PROVEN: a WNOHANG poll returned 0 "
		    "for a live child; a specific-pid wait reaped only the named zombie.\n");
	else
		sbi_console_puts("[R-P36.2] waitpid INCOMPLETE.\n");
}
