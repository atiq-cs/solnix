/*
 * signal.c -- R-P33.1: a minimal POSIX/SunOS signal framework for the riscv64
 * kernel.  Per-proc pending mask + a handler table (sigaction/signal), kill(2)
 * posts a signal to a proc, and delivery happens on the RETURN-TO-U-MODE edge:
 * the trap-return path (proc_deliver_signals, called from mach_trap.S .Lret)
 * checks the running proc for a pending, deliverable signal and, if a handler is
 * installed, BUILDS A SIGNAL FRAME on the user stack (a saved copy of the
 * interrupted trap frame), rewrites the trap frame so the epilogue sret's into
 * the handler (a0 = signo, ra = the userland sa_restorer trampoline), and clears
 * the pending bit.  When the handler returns it `ret`s to the restorer, which
 * ecalls SYS_sigreturn; sigreturn copies the saved frame back so the proc
 * resumes exactly where the signal interrupted it.  Default actions:
 * SIGKILL/SIGTERM (+ the other term defaults) terminate the proc; SIGSEGV is
 * raised by the page-fault path on an unresolved user fault (default: terminate).
 *
 * CRIB PROVENANCE: the per-proc pending mask + disposition table + "deliver on
 * the way back to user mode, build a frame on the user stack, redirect the
 * saved PC to the handler, restore via a sigreturn syscall" model is illumos
 * uts/common/os/sig.c (sigtoproc/issig/psig/sendsig) + uts/*\/os/*_sig.c
 * sendsig() building the ucontext on the user stack + setcontext on return, and
 * the BSD/xv6-riscv usertrap signal path (sigframe on the user stack, sret to
 * the catcher, sigreturn); the RISC-V handoff (rewrite the trapframe sepc/a0/sp/
 * ra, sret to the handler) is the privileged-spec sret semantics applied to the
 * R-P25 trap frame (struct regs); default-action tables (SIG_DFL terminate vs
 * catch) are <sys/signal.h> + sig.c u_sigdefault.
 */

#include "sbi.h"
#include "mmu_riscv.h"

/* struct regs -- MUST match mach_trap.S / proc.c layout (x1..x31, then csrs). */
struct regs {
	unsigned long	r_x[31];	/* x1..x31 */
	unsigned long	r_sepc;
	unsigned long	r_sstatus;
	unsigned long	r_scause;
	unsigned long	r_stval;
};
#define	R_X_RA	0	/* x1  */
#define	R_X_SP	1	/* x2  */
#define	R_X_A0	9	/* x10 */
#define	R_X_A1	10	/* x11 */
#define	R_X_A2	11	/* x12 */

#define	SSTATUS_SPP	(1UL << 8)	/* prev priv: 0=U, 1=S */

/* reduced SunOS signal numbers (<sys/iso/signal_iso.h>). */
#define	SIGINT		2	/* R-P37.2: interrupt (^C); default terminate */
#define	SIGKILL		9
#define	SIGALRM		14
#define	SIGSEGV		11
#define	SIGTERM		15
#define	SIGUSR1		16
#define	SIGUSR2		17
#define	SIGCHLD		18
#define	SIGTSTP		24	/* R-P37.2: terminal stop (^Z); default stop */
#define	NSIG		32

/* sigprocmask `how` (<sys/signal.h>). */
#define	SIG_BLOCK	1
#define	SIG_UNBLOCK	2
#define	SIG_SETMASK	3

/* sa_flags (<sys/signal.h>) -- only SA_RESTART is honored here. */
#define	SA_RESTART	0x0008

/* dispositions stored in p_sighand[]: 0 = SIG_DFL, 1 = SIG_IGN, else a VA. */
#define	SIG_DFL_V	0UL
#define	SIG_IGN_V	1UL

/*
 * The signal frame the kernel writes onto the user stack: a saved copy of the
 * interrupted trap frame (so sigreturn can restore every register + sepc +
 * sstatus) plus the signo.  Placed below the interrupted user sp (past a small
 * redzone) 16-byte aligned; the kernel writes it directly through the user
 * pages (SUM is set on U-return traps).
 */
struct sigframe {
	struct regs	sf_saved;	/* the interrupted context to restore */
	unsigned long	sf_signo;	/* the delivered signal (informational) */
	unsigned long	sf_magic;	/* sanity guard for sigreturn */
};
#define	SIGFRAME_MAGIC	0x5347465253503333UL	/* "SGFRSP33" */

/*
 * proc.c owns proc_t; signal.c reaches the running proc + its per-proc signal
 * state through these accessors so it does not need the full proc_t layout.
 */
extern int curproc_active(void);
extern unsigned long *proc_sighand(void);	/* -> p_sighand[NSIG] of curproc */
extern volatile unsigned int *proc_sigpend(void);	/* -> &curproc->p_sigpend */
extern unsigned long proc_sigrestorer(void);	/* curproc->p_sigrestorer */
extern void proc_set_sigrestorer(unsigned long va);
extern int proc_sigaction_cur(int sig, unsigned long handler);
extern int proc_kill(int pid, int sig);		/* post sig to pid (proc.c) */
extern void proc_exit(int status);
extern int proc_getpid(void);
/* R-P34.1: signal-mask + per-signal-flags accessors (proc.c). */
extern volatile unsigned int *proc_sigmask(void);	/* -> &curproc->p_sigmask */
extern void proc_set_sigflags(int sig, unsigned int flags);
extern unsigned int proc_get_sigflags(int sig);
extern void proc_set_no_restart(void);
extern int proc_take_no_restart(void);

/* console helpers (main.c). */
extern void putdec_pub(unsigned long);
extern void puthex_pub(unsigned long);

/*
 * sig_is_term_default -- does SIG_DFL terminate the process for this signal?
 * SIGKILL/SIGTERM/SIGSEGV/SIGUSR1/SIGUSR2 all default to termination in this
 * reduced set (SunOS: USR1/USR2/TERM/KILL/SEGV are all fatal by default).
 */
static int
sig_is_term_default(int sig)
{
	switch (sig) {
	case SIGCHLD:
		return (0);	/* SIGCHLD default: IGNORE (child status change) */
	case SIGTSTP:
		return (0);	/* SIGTSTP default: STOP (not terminate) */
	case SIGINT:
	case SIGKILL:
	case SIGTERM:
	case SIGSEGV:
	case SIGALRM:
	case SIGUSR1:
	case SIGUSR2:
		return (1);
	default:
		return (1);	/* reduced set: default is terminate */
	}
}

/*
 * proc_sigaction -- SYS_sigaction body.  Install `handler` (a user VA, or
 * SIG_DFL_V=0 / SIG_IGN_V=1) for signal `sig` on the current proc, and record
 * the sa_restorer trampoline VA (the userland stub that ecalls SYS_sigreturn)
 * the first time it is provided.  Returns 0 or -1.
 *
 * The ABI: a0 = sig, a1 = handler VA, a2 = restorer VA (the userland sigreturn
 * trampoline).  Modeled on sigaction(2) reduced to sa_handler + sa_restorer.
 */
long
proc_sigaction(int sig, unsigned long handler, unsigned long restorer,
    unsigned long flags)
{
	if (!curproc_active())
		return (-1);
	if (sig < 1 || sig >= NSIG)
		return (-1);
	if (sig == SIGKILL)			/* SIGKILL cannot be caught */
		return (-1);
	if (proc_sigaction_cur(sig, handler) != 0)
		return (-1);
	if (restorer != 0)
		proc_set_sigrestorer(restorer);
	proc_set_sigflags(sig, (unsigned int)flags);	/* SA_RESTART etc. */
	return (0);
}

/*
 * proc_sigprocmask -- SYS_sigprocmask body.  Examine/change the calling proc's
 * BLOCKED-signal mask.  how = SIG_BLOCK|SIG_UNBLOCK|SIG_SETMASK, set = the new
 * mask bits, oldp (a user VA, or 0) receives the PREVIOUS mask.  A blocked
 * signal stays pending (p_sigpend) but is skipped by the delivery path until
 * unblocked, at which point the pending signal delivers on the next return-to-U.
 * SIGKILL cannot be blocked (masked out here).
 *
 * CRIB PROVENANCE: sigprocmask editing t_hold / p_holdmask with SIG_BLOCK/
 * UNBLOCK/SETMASK and the "blocked signals stay pending, deliver on unblock"
 * rule is illumos uts/common/os/sig.c sigprocmask()/schedctl + issig()
 * skipping held signals; POSIX sigprocmask(2).
 */
long
proc_sigprocmask(int how, unsigned long set, unsigned long *oldp)
{
	volatile unsigned int *mask;
	unsigned int old;

	if (!curproc_active())
		return (-1);
	mask = proc_sigmask();
	if (mask == 0)
		return (-1);
	old = *mask;
	if (oldp != 0)
		*oldp = (unsigned long)old;	/* SUM set on the U-return frame */
	switch (how) {
	case SIG_BLOCK:
		*mask = old | (unsigned int)set;
		break;
	case SIG_UNBLOCK:
		*mask = old & ~(unsigned int)set;
		break;
	case SIG_SETMASK:
		*mask = (unsigned int)set;
		break;
	default:
		return (-1);
	}
	*mask &= ~(1u << SIGKILL);		/* SIGKILL is never blockable */
	return (0);
}

/*
 * proc_sigsuspend -- SYS_sigsuspend body.  Atomically replace the blocked mask
 * with `mask` and block the proc until a signal that is NOT in `mask` is
 * pending + delivered.  Implemented cooperatively: install the temporary mask,
 * then spin-yield (WAITING) until a deliverable (unmasked) pending signal
 * appears; the trap-return delivery path (proc_deliver_signals) then runs the
 * handler.  On return the ORIGINAL mask is restored (the syscall return frame
 * carries it).  Always "fails" with EINTR after a caught signal (POSIX).
 *
 * CRIB PROVENANCE: sigsuspend swapping in a temporary hold mask, sleeping
 * until an unheld signal is posted, then restoring the mask + returning EINTR
 * is illumos sigsuspend()/cv_wait_sig + POSIX sigsuspend(2).
 */
extern void proc_wait_signal(void);	/* proc.c: WAITING until p_sigpend&~mask */
#define	RERR_EINTR	(-4)
long
proc_sigsuspend(unsigned long mask)
{
	volatile unsigned int *m;
	unsigned int saved;

	if (!curproc_active())
		return (RERR_EINTR);
	m = proc_sigmask();
	saved = *m;
	*m = (unsigned int)mask & ~(1u << SIGKILL);
	proc_wait_signal();		/* block until an unmasked signal pends */
	*m = saved;			/* restore the caller's mask */
	proc_set_no_restart();		/* sigsuspend is NEVER SA_RESTART'd (POSIX) */
	return (RERR_EINTR);
}

/*
 * proc_signal_fault -- called by the page-fault path (proc_pagefault) on an
 * UNRESOLVED user fault: raise SIGSEGV against the running proc.  Because the
 * reduced set has no SIGSEGV catcher wired here (a handler may still be
 * installed), we post it; delivery on the trap-return path then either runs the
 * catcher or terminates the proc via the default action.  Returns 1 (the fault
 * was "handled" by posting the signal, so rv_trap does NOT halt the kernel).
 */
int
proc_signal_fault(void)
{
	int self;
	if (!curproc_active())
		return (0);
	self = proc_getpid();
	sbi_console_puts("      [signal] SIGSEGV posted to pid ");
	putdec_pub((unsigned long)self);
	sbi_console_puts(" (unresolved user fault)\n");
	proc_kill(self, SIGSEGV);
	return (1);
}

/*
 * proc_deliver_signals -- the RETURN-TO-U delivery point, called from
 * mach_trap.S .Lret with a0 = the trap frame (struct regs *) about to be
 * restored.  If we are returning to U-mode and the running proc has a pending,
 * deliverable signal, act on it:
 *   - SIG_IGN: drop it.
 *   - a handler VA: build a sigframe on the user stack, redirect sepc to the
 *     handler (a0 = signo, ra = the restorer, sp = the sigframe).
 *   - SIG_DFL (terminate): proc_exit(128 + sig) -- never returns.
 * Only one signal is delivered per trip through U (the classic issig/psig
 * loop delivers one at a time); the rest stay pending for the next return.
 */
void
proc_deliver_signals(struct regs *r)
{
	volatile unsigned int *pend;
	volatile unsigned int *maskp;
	unsigned long *hand;
	unsigned int pmask, blocked;
	int sig;

	/* only deliver when returning to U-mode with a live user proc. */
	if ((r->r_sstatus & SSTATUS_SPP) != 0)
		return;			/* returning to S-mode: nothing to do */
	if (!curproc_active())
		return;

	pend = proc_sigpend();
	maskp = proc_sigmask();
	blocked = maskp ? *maskp : 0;
	blocked &= ~(1u << SIGKILL);	/* SIGKILL is never blocked */
	pmask = *pend & ~blocked;	/* R-P34.1: skip BLOCKED pending sigs */
	if (pmask == 0)
		return;			/* only blocked sigs pending: stay put */

	hand = proc_sighand();

	/* pick the lowest-numbered pending, DELIVERABLE (unblocked) signal. */
	for (sig = 1; sig < NSIG; sig++) {
		if ((pmask & (1u << sig)) == 0)
			continue;
		*pend &= ~(1u << sig);		/* consume this pending bit */

		if (sig != SIGKILL && hand[sig] == SIG_IGN_V)
			continue;		/* ignored: drop, look for more */

		if (sig != SIGKILL && hand[sig] != SIG_DFL_V &&
		    hand[sig] != SIG_IGN_V) {
			/* catch it: build a frame + redirect to the handler. */
			unsigned long usp = r->r_x[R_X_SP];
			unsigned long fp;
			struct sigframe *sf;
			unsigned long restorer = proc_sigrestorer();

			/*
			 * R-P34.1 SA_RESTART: if this signal interrupted a syscall
			 * that returned EINTR (-4) and the handler is SA_RESTART,
			 * rewind the SAVED sepc to the ecall so the syscall RE-RUNS
			 * when the handler returns (a0 still holds the syscall nr's
			 * args; a7 was preserved).  mach_trap.S advanced sepc by 4
			 * past the ecall on syscall entry, so back it up here.
			 */
			if ((proc_get_sigflags(sig) & SA_RESTART) != 0 &&
			    (long)r->r_x[R_X_A0] == -4 /* EINTR */ &&
			    !proc_take_no_restart()) {
				r->r_sepc -= 4;		/* re-execute the ecall */
				sbi_console_puts("      [signal] SA_RESTART: "
				    "restarting the interrupted syscall\n");
			}

			/* 16-align a sigframe below the user sp (past a redzone). */
			fp = usp - 128 - sizeof (struct sigframe);
			fp &= ~15UL;
			sf = (struct sigframe *)fp;

			/* SUM is set on the U-return frame, so we may write U pages. */
			sf->sf_saved = *r;		/* full interrupted context */
			sf->sf_signo = (unsigned long)sig;
			sf->sf_magic = SIGFRAME_MAGIC;

			/* redirect: sret into handler(signo) on the trimmed stack. */
			r->r_sepc = hand[sig];
			r->r_x[R_X_A0] = (unsigned long)sig;	/* handler arg */
			r->r_x[R_X_A1] = 0;
			r->r_x[R_X_A2] = 0;
			r->r_x[R_X_SP] = fp;			/* handler sp */
			r->r_x[R_X_RA] = restorer;		/* -> sigreturn */

			sbi_console_puts("      [signal] delivering sig ");
			putdec_pub((unsigned long)sig);
			sbi_console_puts(" to pid ");
			putdec_pub((unsigned long)proc_getpid());
			sbi_console_puts(" -> handler @");
			puthex_pub(hand[sig]);
			sbi_console_puts("\n");
			return;			/* one delivery per U-trip */
		}

		/* SIG_DFL (or SIGKILL): the default action. */
		if (sig == SIGTSTP) {
			/* R-P37.2: default SIGTSTP action -- STOP this proc. */
			extern void proc_stop_self(void);
			proc_stop_self();	/* parks P_STOPPED; returns if resumed */
			return;
		}
		if (sig_is_term_default(sig)) {
			sbi_console_puts("      [signal] sig ");
			putdec_pub((unsigned long)sig);
			sbi_console_puts(" default action: terminate pid ");
			putdec_pub((unsigned long)proc_getpid());
			sbi_console_puts("\n");
			proc_exit(128 + sig);	/* never returns */
		}
		/* non-terminate default (none in this reduced set): ignore. */
	}
}

/*
 * proc_sigreturn -- SYS_sigreturn body.  The userland sa_restorer stub calls
 * this after the handler returns.  The current trap frame's sp points AT the
 * sigframe we pushed (the handler ran on the trimmed stack and `ret`urned to
 * the restorer, which did NOT move sp below the frame).  Copy the saved context
 * back into the trap frame so the epilogue sret's back to where the signal
 * interrupted the proc.  Returns nothing meaningful (a0 is overwritten by the
 * restored frame).
 *
 * The syscall entry advanced the saved sepc past the ecall; we OVERWRITE
 * the whole frame from the saved copy, so that adjustment is discarded and the
 * interrupted sepc is restored exactly.
 */
void
proc_sigreturn(struct regs *r)
{
	struct sigframe *sf = (struct sigframe *)r->r_x[R_X_SP];

	if (!curproc_active())
		return;
	if (sf->sf_magic != SIGFRAME_MAGIC) {
		sbi_console_puts("      [signal] sigreturn: BAD frame magic "
		    "-- terminating pid ");
		putdec_pub((unsigned long)proc_getpid());
		sbi_console_puts("\n");
		proc_exit(139);			/* 128 + SIGSEGV */
		return;
	}
	*r = sf->sf_saved;			/* restore the interrupted frame */
}
