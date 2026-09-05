/*
 * trap.c — illumos riscv64 S-mode trap dispatcher (R-P3).
 *
 * Called from _trap_entry (trap.S) with a pointer to the saved register frame.
 * Decodes scause (interrupt vs exception + cause code), reports sepc/stval via
 * the SBI console, and takes the minimum action:
 *
 *   - S-mode timer interrupt (IRQ_S_TIMER): call the timer handler (which
 *     prints a tick and rearms/masks), then return to resume the interrupted
 *     code.
 *   - A recognized "probe" fault used by the bring-up self-test
 *     (trap_probe_active): report, advance sepc past the faulting instruction,
 *     and resume — this is how R-P3 proves the synchronous-trap path works
 *     without wedging.
 *   - Anything else: report fully and park (wfi loop). This is the R-P3
 *     "unexpected trap" policy; real fault handling (page-in, signal, etc.)
 *     is later phases.
 *
 * This is the illumos-idiom C trap dispatcher (cf. uts/i86pc/os/trap.c and
 * richlowe arm64-gate uts/aarch64 trap.c): asm shim -> C decode. Reimplemented
 * from the Priv Spec; no CDDL-incompatible source copied.
 */

#include "sbi.h"
#include "riscv_regs.h"
#include "asm_frame.h"
#include "regs.h"

/*
 * struct regs (regs.h) is the saved trap frame. MUST match asm_frame.h
 * offsets. The _Static_asserts below catch any drift between the struct and
 * the asm.
 */

_Static_assert(__builtin_offsetof(struct regs, r_ra) == TF_RA, "TF_RA");
_Static_assert(__builtin_offsetof(struct regs, r_sp) == TF_SP, "TF_SP");
_Static_assert(__builtin_offsetof(struct regs, r_t6) == TF_T6, "TF_T6");
_Static_assert(__builtin_offsetof(struct regs, r_sepc) == TF_SEPC, "TF_SEPC");
_Static_assert(__builtin_offsetof(struct regs, r_sstatus) == TF_SSTATUS, "TF_SSTATUS");
_Static_assert(__builtin_offsetof(struct regs, r_scause) == TF_SCAUSE, "TF_SCAUSE");
_Static_assert(__builtin_offsetof(struct regs, r_stval) == TF_STVAL, "TF_STVAL");
_Static_assert(sizeof (struct regs) <= TF_SIZE, "TF_SIZE too small");
/*
 * TF_CPUID (the parked S-mode per-hart id, THE tp SPLIT) lives in the frame's
 * 16-byte alignment padding, so it must sit at or past the end of struct regs
 * and still be a whole word inside the frame. If struct regs ever grows a field
 * that reaches 280, this fires rather than letting the trap entry silently clobber
 * a saved register with a hart id.
 */
_Static_assert(TF_CPUID >= (int)sizeof (struct regs), "TF_CPUID overlaps struct regs");
_Static_assert(TF_CPUID + 8 <= TF_SIZE, "TF_CPUID outside the trap frame");
_Static_assert(TF_CPUID_FROM_KSTACKTOP == TF_CPUID - TF_SIZE,
    "TF_CPUID must be reachable from the kernel stack top");

/* From syscall.c: dispatch an ecall-from-U-mode. Advances tf->r_sepc past the
 * 4-byte ecall and writes the return value into tf->r_a0. */
extern void syscall_trap(struct regs *tf);
/* Set nonzero once a userland process is running (proc/exec), so an unexpected
 * trap taken from U-mode is reported with its context instead of parking as a
 * kernel bug. */
extern volatile int userland_active;
/* From uproc.c: handle a store fault on a copy-on-write page (R-P9). Returns 1
 * if the fault was a COW page that has now been split private (retry store). */
extern int proc_cow_fault(unsigned long va);

/* From timer.c: handle one S-mode timer interrupt (print tick, disarm). */
extern void timer_intr(void);

/* From proc.c: clock-tick preemption — yield to another runnable thread if any.
 * Returns 1 if it preempted (R-P9 gate 5). */
extern int thread_preempt(void);

/* From uproc.c: deliver a pending signal on return-to-U (R-P11). */
extern void proc_deliver_signals(struct regs *tf);

/* Count of clock-tick preemptions of a user thread (R-P9 gate 5 proof). */
volatile unsigned long preempt_count = 0;
/*
 * preempt_enabled — gate 5 master switch. Clock-tick preemption of user threads.
 * R-P10: ENABLED. The R-P9 re-entrancy blocker (a global copy_lofault clobbered
 * across a preemptive swtch) is fixed: copy_lofault is now per-thread (saved and
 * restored in swtch.S like the per-thread satp), so an armed copy cannot be
 * observed or clobbered across a preemptive switch. A user thread that never
 * yields is now time-sliced off the clock (kernel-mode timer traps, SPP==1, are
 * still never preempted, so no lock-holder is preempted).
 */
volatile int preempt_enabled = 1;

/* From plic.c: service S-mode external interrupts (claim/dispatch/complete). */
extern int plic_extintr(void);
/* From aia.c: service S-ext IRQs via IMSIC stopei when AIA is the live model. */
extern int aia_is_active(void);
extern int aia_extintr(void);
/* From proc.c: an IPI (S-soft) woke this hart to re-run its dispatcher (SMP). */
extern void ipi_intr(void);

/* The asm trap vector target (trap.S). Installed into stvec by set_trap_vector. */
extern void _trap_entry(void);

/* trap_selftest deliberate-fault target: an unmapped canonical Sv39 VA. It sits
 * one page above the HAT's 4 KiB alias mapping (which maps exactly one page at
 * 0x40000000), so a load here takes a load-page-fault (scause 13) once Sv39 is
 * on — proving the synchronous-trap path with a real page fault. */
#define	SELFTEST_BAD_VA		0x40001000UL

/*
 * trap_probe_active — set by the bring-up self-test (trap_selftest) around a
 * deliberate faulting access so the dispatcher knows to report-and-resume
 * instead of parking. Cleared once the expected fault is consumed.
 */
volatile int trap_probe_active = 0;
/* Set to the scause we observed during the probe, for the self-test to check. */
volatile unsigned long trap_probe_scause = 0;

/*
 * copy_lofault — the fault-recovery PC armed by copyin/copyout (copy.S) around
 * a user-memory access. When nonzero and a load/store page (or access) fault is
 * taken, trap() redirects sepc here (returning EFAULT) instead of parking. This
 * is the RISC-V analog of illumos t_lofault. Single-cpu userland dispatch in
 * R-P9, so one global is correct; a per-thread t_lofault is the SMP-userland
 * upgrade. (NOTE: the ceiling — one global lofault — is documented above.)
 */
volatile unsigned long copy_lofault = 0;

static void
puthex(unsigned long v)
{
	static const char hex[] = "0123456789abcdef";
	int i;

	sbi_console_puts("0x");
	for (i = 60; i >= 0; i -= 4)
		sbi_console_putchar(hex[(v >> i) & 0xf]);
}

/*
 * set_trap_vector — point stvec at _trap_entry in Direct mode (low 2 bits = 0,
 * so all traps vector to the single entry). Called from mlsetup. _trap_entry
 * is 4-byte aligned (trap.S) as Direct mode requires.
 */
void
set_trap_vector(void)
{
	unsigned long v = (unsigned long)&_trap_entry;

	v &= ~0x3UL;			/* MODE = 0 (Direct) in bits [1:0] */
	__asm__ __volatile__("csrw stvec, %0" :: "r"(v) : "memory");
}

/* Human-readable name for a synchronous exception cause code. */
static const char *
exc_name(unsigned long code)
{
	switch (code) {
	case EXC_INST_MISALIGNED:	return ("instruction address misaligned");
	case EXC_INST_ACCESS:		return ("instruction access fault");
	case EXC_ILLEGAL_INST:		return ("illegal instruction");
	case EXC_BREAKPOINT:		return ("breakpoint");
	case EXC_LOAD_MISALIGNED:	return ("load address misaligned");
	case EXC_LOAD_ACCESS:		return ("load access fault");
	case EXC_STORE_MISALIGNED:	return ("store address misaligned");
	case EXC_STORE_ACCESS:		return ("store access fault");
	case EXC_ECALL_U:		return ("ecall from U-mode");
	case EXC_ECALL_S:		return ("ecall from S-mode");
	case EXC_INST_PAGE_FAULT:	return ("instruction page fault");
	case EXC_LOAD_PAGE_FAULT:	return ("load page fault");
	case EXC_STORE_PAGE_FAULT:	return ("store page fault");
	default:			return ("unknown exception");
	}
}

static const char *
irq_name(unsigned long code)
{
	switch (code) {
	case IRQ_S_SOFT:	return ("supervisor software");
	case IRQ_S_TIMER:	return ("supervisor timer");
	case IRQ_S_EXT:		return ("supervisor external");
	default:		return ("unknown interrupt");
	}
}

static void
trap_report(struct regs *tf, const char *tag)
{
	unsigned long code = SCAUSE_CODE(tf->r_scause);

	sbi_console_puts("[trap] ");
	sbi_console_puts(tag);
	sbi_console_puts(": scause=");
	puthex(tf->r_scause);
	sbi_console_puts(" (");
	if (tf->r_scause & SCAUSE_INT)
		sbi_console_puts(irq_name(code));
	else
		sbi_console_puts(exc_name(code));
	sbi_console_puts(")\n");

	sbi_console_puts("       sepc=");
	puthex(tf->r_sepc);
	sbi_console_puts(" stval=");
	puthex(tf->r_stval);
	sbi_console_puts(" sstatus=");
	puthex(tf->r_sstatus);
	sbi_console_puts("\n");
}

static void __attribute__((noreturn))
trap_park(struct regs *tf)
{
	sbi_console_puts("[trap] unexpected trap -> parking hart.\n");
	(void) tf;
	for (;;)
		__asm__ __volatile__("wfi");
}

/*
 * trap — the C trap dispatcher. Entered from _trap_entry with the saved
 * frame. See file banner for the R-P3 policy.
 */
void
trap(struct regs *tf)
{
	unsigned long code = SCAUSE_CODE(tf->r_scause);

	if (tf->r_scause & SCAUSE_INT) {
		/* Interrupt. */
		switch (code) {
		case IRQ_S_TIMER:
			timer_intr();
			/*
			 * Clock-tick PREEMPTION (R-P9 gate 5): if this timer
			 * interrupt was taken while a USER thread ran (trap from
			 * U-mode, sstatus.SPP==0), preempt it — yield to the next
			 * runnable thread. This makes multi-process scheduling
			 * preemptive, not purely cooperative: a user process that
			 * never yields is still time-sliced off the clock. When
			 * we are switched back the trap returns + sret's to the
			 * interrupted PC on this thread's own satp + curproc
			 * (swtch restores both).
			 */
			if ((tf->r_sstatus & SSTATUS_SPP) == 0 &&
			    preempt_enabled) {
				if (thread_preempt())
					preempt_count++;
			}
			/*
			 * R-P11: a timer tick is also an async signal-delivery
			 * point. If we are returning to a user thread, deliver any
			 * pending signal (e.g. a ^C SIGINT posted from the console
			 * ISR, or a SIGKILL from kill(2)) even though the user did
			 * no syscall this tick. Runs after any preempt swtch, on
			 * whichever thread we resume as.
			 */
			if ((tf->r_sstatus & SSTATUS_SPP) == 0)
				proc_deliver_signals(tf);
			return;
		case IRQ_S_SOFT:
			/*
			 * S-mode software interrupt = inter-processor interrupt
			 * (R-P13 SMP). Clear sip.SSIP and let the hart re-check its
			 * runq (ipi_intr yields if something is now runnable).
			 */
			__asm__ __volatile__("csrc sip, %0" :: "r"(SIE_SSIE));
			ipi_intr();
			return;
		case IRQ_S_EXT:
			/* Route to AIA (IMSIC/stopei) if the AIA model is live, else
			 * the legacy PLIC claim/complete. Chosen at boot from DTB. */
			if (aia_is_active())
				(void) aia_extintr();
			else
				(void) plic_extintr();
			return;
		default:
			trap_report(tf, "interrupt");
			trap_park(tf);
		}
	}

	/* Synchronous exception. */
	if (code == EXC_ECALL_U) {
		/* System call from userland: dispatch + return to U-mode. */
		syscall_trap(tf);
		return;
	}

	/*
	 * Copy-on-write store fault. A store to a COW-shared page (marked
	 * read-only at fork) faults here — whether the store came from U-mode
	 * (the process writing its own memory) or from S-mode (a kernel
	 * copyout writing a user COW buffer). proc_cow_fault splits the page
	 * private in the current process's AS and returns 1 (retry the store);
	 * it returns 0 for a non-COW address (a genuine fault / bad pointer),
	 * which then falls through to the copyin/copyout lofault catch below.
	 * Runs BEFORE the lofault check so a copyout to a COW page is split
	 * rather than turned into a spurious EFAULT.
	 */
	if (code == EXC_STORE_PAGE_FAULT) {
		if (proc_cow_fault(tf->r_stval))
			return;		/* split done: retry the faulting store */
	}

	/*
	 * Fault-safe copyin/copyout catch. If a copy primitive armed a recovery
	 * label and this is a load/store fault (bad user pointer), redirect the
	 * return PC to the recovery label and clear the arm. The copy routine
	 * lands on _copy_fault and returns -1 (EFAULT) to its caller — no panic.
	 *
	 * SPP==1 IS REQUIRED. copy_lofault is a KERNEL text address, so this
	 * redirect is only meaningful when the faulting copy was executing in
	 * S-mode. If the trap came from U-mode (SPP==0), sret would drop to U-mode
	 * at a kernel VA userland cannot execute, turning a recoverable EFAULT into
	 * an immediate instruction page fault whose stval and sepc BOTH equal
	 * _copy_fault -- a confusing crash far from its cause. The arm is a global
	 * rather than per-frame, so a U-mode fault CAN arrive while some copy is
	 * armed without belonging to it; requiring SPP makes the guard say what it
	 * means.
	 *
	 * NOTE: global arm. rv_context.c_lofault already saves/restores it per
	 * thread, which is a hint that making copy_lofault per-thread outright is
	 * the real upgrade.
	 */
	if (copy_lofault != 0 && (tf->r_sstatus & SSTATUS_SPP) != 0 &&
	    (code == EXC_LOAD_PAGE_FAULT || code == EXC_STORE_PAGE_FAULT ||
	    code == EXC_LOAD_ACCESS || code == EXC_STORE_ACCESS)) {
		tf->r_sepc = copy_lofault;
		copy_lofault = 0;
		return;
	}

	if (trap_probe_active) {
		/*
		 * Expected bring-up probe fault. Report, record the cause, and
		 * advance sepc past the faulting instruction so we resume. The
		 * instruction may be compressed (RVC, 2 bytes) or full (4 bytes);
		 * decode the length from the low 2 opcode bits at sepc so we
		 * resume on an instruction boundary instead of guessing +4.
		 * Per the ISA: (insn[1:0] != 0b11) => 16-bit compressed.
		 */
		unsigned short op = *(volatile unsigned short *)tf->r_sepc;
		unsigned long ilen = ((op & 0x3) == 0x3) ? 4 : 2;

		trap_report(tf, "probe (expected)");
		trap_probe_scause = tf->r_scause;
		trap_probe_active = 0;
		tf->r_sepc += ilen;
		return;
	}

	trap_report(tf, "exception");
	trap_park(tf);
}

/*
 * trap_selftest — R-P3 proof that the synchronous-trap path works. Arms the
 * probe flag and issues a load from an unmapped canonical VA. The hardware
 * faults (load page fault, scause 13) into _trap_entry -> trap(), which
 * reports the decoded scause/sepc/stval, advances sepc, and resumes here.
 * Verifies we saw the expected cause. Called from mlsetup AFTER paging is on.
 */
void
trap_selftest(void)
{
	volatile unsigned long v;

	sbi_console_puts("[trap] self-test: deliberate load from unmapped VA ");
	puthex(SELFTEST_BAD_VA);
	sbi_console_puts(" (expect scause=0xd load page fault)\n");

	trap_probe_scause = 0;
	trap_probe_active = 1;
	v = *(volatile unsigned long *)SELFTEST_BAD_VA;	/* faults -> trap() */
	(void) v;

	if (trap_probe_scause == (EXC_LOAD_PAGE_FAULT) ||
	    trap_probe_scause == (EXC_LOAD_ACCESS)) {
		sbi_console_puts("[trap] self-test OK: trap taken, decoded, resumed.\n");
	} else {
		sbi_console_puts("[trap] self-test WARN: unexpected/absent probe cause=");
		puthex(trap_probe_scause);
		sbi_console_puts("\n");
	}
}
