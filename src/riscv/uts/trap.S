/*
 * trap.S — illumos riscv64 S-mode trap vector (R-P3, R-P7 U/S split).
 *
 * The stvec target. On any S-mode trap (exception or interrupt) the hardware:
 *   - writes the cause to scause, the faulting/return PC to sepc, aux info to
 *     stval, saves the prior interrupt-enable/privilege into sstatus.SPIE/SPP,
 *     clears sstatus.SIE, and jumps here (Direct mode: all traps -> _trap_entry).
 *
 * We save the interrupted integer register state into a trap frame on the
 * current stack (regs_t layout, see trap.c), snapshot the trap CSRs into the
 * same frame, call C trap(frame), then restore and `sret` back to sepc.
 *
 * This is the riscv64 analog of uts/i86pc locore trap stubs and richlowe
 * arm64-gate uts/aarch64 exception vectors: a thin asm shim that builds a
 * frame and calls the C dispatcher. Reimplemented from the Priv Spec.
 *
 * R-P7 U/S split: on entry we swap sp with sscratch. The convention is that
 * sscratch holds the per-process KERNEL stack top while the CPU is in U-mode,
 * and 0 while in S-mode (set by usermode_entry / restored below). After the
 * `csrrw sp, sscratch, sp`, if the value now in sscratch (the old sp) reveals
 * we came from U-mode (sscratch was nonzero => it was the kernel sp, now sp is
 * it) we build the frame on the kernel stack and save the user sp from
 * sscratch. If we came from S-mode (sscratch was 0), we swap back and use the
 * current kernel sp — exactly the R-P3 behaviour, so the timer/PLIC/probe
 * paths are unchanged. This is the NetBSD riscv trapframe U/S idiom,
 * reimplemented from the Priv Spec.
 */

#include "asm_frame.h"
#include "riscv_regs.h"

	.section .text
	.align 4			/* stvec Direct-mode target must be 4-aligned */
	.globl _trap_entry
	.type _trap_entry, @function
_trap_entry:
	/*
	 * Swap sp <-> sscratch. t6 is saved into sscratch temporarily? No: we
	 * cannot clobber any GPR before saving it. Use the atomic csrrw: after
	 * it, sp = old sscratch, sscratch = old sp. We then need one scratch
	 * register to test; save it to the frame we are about to build, but we
	 * do not yet know if sp is valid. Trick: sscratch is 0 in S-mode, so if
	 * after the swap sp==0 we were in S-mode and must swap back.
	 */
	csrrw	sp, sscratch, sp	/* sp <-> sscratch */
	bnez	sp, 1f			/* sp!=0 => from U-mode, sp=kernel stack */
	/* From S-mode: sscratch was 0. Swap back to recover the real sp. */
	csrrw	sp, sscratch, sp	/* sp = real kernel sp, sscratch = 0 again */
1:
	/* sp now points at a valid kernel stack (U case) or the S-mode sp. */

	/* Make room for the trap frame on the current (kernel) stack. */
	addi	sp, sp, -TF_SIZE

	/* Save all integer registers x1..x31 (x0 is hardwired zero, skip). */
	sd	x1,  TF_RA(sp)
	/*
	 * x5 (t0) MUST be saved before anything uses t0 as scratch, and the TF_SP
	 * computation below needs a scratch register. Saving it here rather than in
	 * register order is deliberate: doing the csrr first would overwrite the
	 * interrupted code's t0 and then store the WRONG value into TF_T0, so the
	 * restore path would hand the interrupted code a corrupted t0. That
	 * silently miscompiles any interruptible loop that keeps a live value in
	 * t0 -- it presents as a wild pointer dereference far from the real cause.
	 */
	sd	x5,  TF_T0(sp)
	/*
	 * x2 = sp: recover the ORIGINAL (interrupted) sp. It is currently in
	 * sscratch (we swapped it there on entry): for the U case sscratch holds
	 * the user sp; for the S case sscratch is 0 and the real prior sp was
	 * sp+TF_SIZE. Read sscratch: if 0 (S-mode) use sp+TF_SIZE, else use it.
	 * t0 is free to clobber now that x5 is in the frame.
	 */
	csrr	t0, sscratch
	bnez	t0, 2f
	addi	t0, sp, TF_SIZE		/* S-mode: prior sp */
2:
	sd	t0,  TF_SP(sp)
	sd	x3,  TF_GP(sp)
	sd	x4,  TF_TP(sp)
	sd	x6,  TF_T1(sp)
	sd	x7,  TF_T2(sp)
	sd	x8,  TF_S0(sp)
	sd	x9,  TF_S1(sp)
	sd	x10, TF_A0(sp)
	sd	x11, TF_A1(sp)
	sd	x12, TF_A2(sp)
	sd	x13, TF_A3(sp)
	sd	x14, TF_A4(sp)
	sd	x15, TF_A5(sp)
	sd	x16, TF_A6(sp)
	sd	x17, TF_A7(sp)
	sd	x18, TF_S2(sp)
	sd	x19, TF_S3(sp)
	sd	x20, TF_S4(sp)
	sd	x21, TF_S5(sp)
	sd	x22, TF_S6(sp)
	sd	x23, TF_S7(sp)
	sd	x24, TF_S8(sp)
	sd	x25, TF_S9(sp)
	sd	x26, TF_S10(sp)
	sd	x27, TF_S11(sp)
	sd	x28, TF_T3(sp)
	sd	x29, TF_T4(sp)
	sd	x30, TF_T5(sp)
	sd	x31, TF_T6(sp)

	/* Snapshot the trap CSRs into the frame for C to decode. */
	csrr	t0, sepc
	sd	t0, TF_SEPC(sp)
	csrr	t0, sstatus
	sd	t0, TF_SSTATUS(sp)
	csrr	t0, scause
	sd	t0, TF_SCAUSE(sp)
	csrr	t0, stval
	sd	t0, TF_STVAL(sp)

	/*
	 * Call C dispatcher: void trap(regs_t *tf). The frame pointer (sp) is
	 * the argument. trap() may modify TF_SEPC (e.g. to skip a faulting
	 * instruction) before we restore.
	 */
	mv	a0, sp
	call	trap

	/*
	 * Restore. sepc/sstatus may have been updated by trap(); write them
	 * back to the CSRs so sret returns to the (possibly advanced) PC with
	 * the restored interrupt-enable state.
	 */
	ld	t0, TF_SEPC(sp)
	csrw	sepc, t0
	ld	t0, TF_SSTATUS(sp)
	csrw	sstatus, t0

	/*
	 * Set sscratch for the return. If we are returning to U-mode
	 * (sstatus.SPP==0), sscratch must hold the kernel stack top to use on
	 * the NEXT trap from U-mode; we use the top of THIS frame (sp+TF_SIZE),
	 * which is the kernel stack we entered on. If returning to S-mode
	 * (SPP==1), sscratch must be 0 (S-mode convention). t0 still holds the
	 * restored sstatus.
	 */
	andi	t1, t0, SSTATUS_SPP
	bnez	t1, 3f			/* SPP=1 => returning to S-mode */
	addi	t1, sp, TF_SIZE		/* SPP=0 => kernel stack top for next U trap */
	csrw	sscratch, t1
	j	4f
3:
	csrw	sscratch, zero
4:

	/* Restore integer registers (x0 skipped; sp restored last via addi). */
	ld	x1,  TF_RA(sp)
	ld	x3,  TF_GP(sp)
	ld	x4,  TF_TP(sp)
	ld	x5,  TF_T0(sp)
	ld	x6,  TF_T1(sp)
	ld	x7,  TF_T2(sp)
	ld	x8,  TF_S0(sp)
	ld	x9,  TF_S1(sp)
	ld	x10, TF_A0(sp)
	ld	x11, TF_A1(sp)
	ld	x12, TF_A2(sp)
	ld	x13, TF_A3(sp)
	ld	x14, TF_A4(sp)
	ld	x15, TF_A5(sp)
	ld	x16, TF_A6(sp)
	ld	x17, TF_A7(sp)
	ld	x18, TF_S2(sp)
	ld	x19, TF_S3(sp)
	ld	x20, TF_S4(sp)
	ld	x21, TF_S5(sp)
	ld	x22, TF_S6(sp)
	ld	x23, TF_S7(sp)
	ld	x24, TF_S8(sp)
	ld	x25, TF_S9(sp)
	ld	x26, TF_S10(sp)
	ld	x27, TF_S11(sp)
	ld	x28, TF_T3(sp)
	ld	x29, TF_T4(sp)
	ld	x30, TF_T5(sp)
	ld	x31, TF_T6(sp)

	/*
	 * Restore sp (x2) LAST from the frame. TF_SP holds the correct prior sp
	 * for BOTH cases: for a trap from U-mode it is the USER sp (saved from
	 * sscratch on entry); for a trap from S-mode it is the prior kernel sp
	 * (sp+TF_SIZE, computed + saved on entry). Loading it here — instead of
	 * `addi sp, sp, TF_SIZE` — is what returns userland to its own stack on
	 * sret. (This is the R-P7 fix: the R-P3 code only ever popped the kernel
	 * frame, which left U-mode running on the kernel stack.)
	 */
	ld	x2,  TF_SP(sp)
	sret

	.size _trap_entry, . - _trap_entry

/*
 * usermode_entry(struct regs *tf, unsigned long kstacktop)
 *   a0 = pointer to the user trap frame (r_sepc=entry PC, r_sp=user sp,
 *        r_a0.. = argc/argv style args), a1 = kernel stack top to install in
 *   sscratch for the next trap-from-U. Sets sstatus for a return to U-mode
 *   (SPP=0 so sret drops to U, SPIE=1 so interrupts enable in U, SUM=1 so the
 *   kernel may later touch user pages), loads the full user GPR set + sepc,
 *   then `sret` into U-mode. Does not return.
 *
 * This is the one-way door from S-mode into a userland process. The satp for
 * the process address space must already be loaded by the caller (as_switch).
 */
	.globl usermode_entry
	.type usermode_entry, @function
usermode_entry:
	/* Install the kernel stack top for the next trap-from-U. */
	csrw	sscratch, a1

	/* Build sstatus: clear SPP (=>U), set SPIE (=>SIE in U), set SUM. */
	csrr	t0, sstatus
	li	t1, SSTATUS_SPP
	not	t1, t1
	and	t0, t0, t1		/* SPP = 0 */
	li	t1, SSTATUS_SPIE
	or	t0, t0, t1		/* SPIE = 1 */
	li	t1, SSTATUS_SUM
	or	t0, t0, t1		/* SUM = 1 */
	csrw	sstatus, t0

	/* sepc = user entry PC (from tf->r_sepc). */
	ld	t0, TF_SEPC(a0)
	csrw	sepc, t0

	/*
	 * Load the user GPRs from the frame. Load a0 (x10) LAST since a0 is our
	 * frame pointer; use t0 as the base to preserve the frame pointer until
	 * the end. Actually simpler: keep a0 as base, load everything except a0,
	 * then load a0. sp (x2) is the user stack.
	 */
	ld	x1,  TF_RA(a0)
	ld	x2,  TF_SP(a0)
	ld	x3,  TF_GP(a0)
	ld	x4,  TF_TP(a0)
	ld	x5,  TF_T0(a0)
	ld	x6,  TF_T1(a0)
	ld	x7,  TF_T2(a0)
	ld	x8,  TF_S0(a0)
	ld	x9,  TF_S1(a0)
	/* x10 = a0 loaded last */
	ld	x11, TF_A1(a0)
	ld	x12, TF_A2(a0)
	ld	x13, TF_A3(a0)
	ld	x14, TF_A4(a0)
	ld	x15, TF_A5(a0)
	ld	x16, TF_A6(a0)
	ld	x17, TF_A7(a0)
	ld	x18, TF_S2(a0)
	ld	x19, TF_S3(a0)
	ld	x20, TF_S4(a0)
	ld	x21, TF_S5(a0)
	ld	x22, TF_S6(a0)
	ld	x23, TF_S7(a0)
	ld	x24, TF_S8(a0)
	ld	x25, TF_S9(a0)
	ld	x26, TF_S10(a0)
	ld	x27, TF_S11(a0)
	ld	x28, TF_T3(a0)
	ld	x29, TF_T4(a0)
	ld	x30, TF_T5(a0)
	ld	x31, TF_T6(a0)
	ld	x10, TF_A0(a0)		/* a0 last */

	sret				/* enter U-mode at sepc */
	.size usermode_entry, . - usermode_entry

/*
 * (R-P7's uproc_enter_trampoline was removed in R-P8: the multi-process model
 * launches each user process on a normal kernel thread via thread_create ->
 * rv_thread_start -> user_thread_body, which calls usermode_entry directly. No
 * dedicated rv_swtch trampoline is needed anymore.)
 */
