/*
 * trap.S — illumos riscv64 S-mode trap vector (R-P3).
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
 * NOTE (R-P3 scope): we run entirely on the boot/kernel stack (no U-mode yet,
 * no per-cpu trap stack, no nested-trap handling). sp is already valid S-mode
 * kernel sp when we trap. R-P4 adds sscratch-based U/S stack swap + per-cpu.
 */

#include "asm_frame.h"

	.section .text
	.align 4			/* stvec Direct-mode target must be 4-aligned */
	.globl _trap_entry
	.type _trap_entry, @function
_trap_entry:
	/* Make room for the trap frame on the current stack. */
	addi	sp, sp, -TF_SIZE

	/* Save all integer registers x1..x31 (x0 is hardwired zero, skip). */
	sd	x1,  TF_RA(sp)
	/* x2 = sp: save the ORIGINAL sp (before we subtracted TF_SIZE). */
	addi	t0, sp, TF_SIZE
	sd	t0,  TF_SP(sp)
	sd	x3,  TF_GP(sp)
	sd	x4,  TF_TP(sp)
	sd	x5,  TF_T0(sp)
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

	/* Pop the frame (restores sp) and return from the trap. */
	addi	sp, sp, TF_SIZE
	sret

	.size _trap_entry, . - _trap_entry
