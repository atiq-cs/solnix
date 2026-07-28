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

/* From syscall.c: dispatch an ecall-from-U-mode. Advances tf->r_sepc past the
 * 4-byte ecall and writes the return value into tf->r_a0. */
extern void syscall_trap(struct regs *tf);
/* Set nonzero once a userland process is running (proc/exec), so an unexpected
 * trap taken from U-mode is reported with its context instead of parking as a
 * kernel bug. */
extern volatile int userland_active;

/* From timer.c: handle one S-mode timer interrupt (print tick, disarm). */
extern void timer_intr(void);

/* From plic.c: service S-mode external interrupts (claim/dispatch/complete). */
extern int plic_extintr(void);

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
			return;
		case IRQ_S_EXT:
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
