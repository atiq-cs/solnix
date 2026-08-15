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
#define	SIGKILL		9
#define	SIGSEGV		11
#define	SIGTERM		15
#define	SIGUSR1		16
#define	SIGUSR2		17
#define	NSIG		32

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
	case SIGKILL:
	case SIGTERM:
	case SIGSEGV:
	case SIGUSR1:
	case SIGUSR2:
		return (1);
	default:
		return (1);	/* reduced set: every default is terminate */
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
proc_sigaction(int sig, unsigned long handler, unsigned long restorer)
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
	return (0);
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
	unsigned long *hand;
	unsigned int pmask;
	int sig;

	/* only deliver when returning to U-mode with a live user proc. */
	if ((r->r_sstatus & SSTATUS_SPP) != 0)
		return;			/* returning to S-mode: nothing to do */
	if (!curproc_active())
		return;

	pend = proc_sigpend();
	pmask = *pend;
	if (pmask == 0)
		return;

	hand = proc_sighand();

	/* pick the lowest-numbered pending signal (SIGKILL first-ish). */
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
 * NOTE: the syscall entry advanced the saved sepc past the ecall; we OVERWRITE
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
