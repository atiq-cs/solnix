/*
 * mach_trap.S -- riscv64 trap dispatch, the R-P22.3 growth over the R-P21
 * mach_locore.S trap prologue.  Where mach_locore.S saved the frame and made a
 * single call, this dispatches the trap by scause: an interrupt (scause sign
 * bit set) routes to rv_interrupt(), an ecall (environment call from U/S) to
 * rv_syscall(), and every other synchronous cause to rv_trap().  It also saves
 * the FULL caller GPR set into the struct regs frame at the genassym-generated
 * regs_r_* offsets, so restore-and-sret is exact.
 *
 * This unit exercises, in ONE object, the whole kernel MD reloc set the sgs
 * machrel.riscv.c backend must resolve: CALL_PLT (x3 external C handlers),
 * PCREL_HI20/LO12 pairs (the la to the per-hart trap-frame base), BRANCH /
 * RVC_BRANCH (the scause dispatch), and the auipc/jalr long call.
 *
 * CRIB PROVENANCE: the "save regs, decode scause, dispatch to interrupt vs
 * syscall vs synchronous-trap C handlers, restore, sret" shape is the illumos
 * amd64 trap.S / the R-P3 riscv trap.S; the CSR names (sepc/sstatus/scause/
 * stval, the SCAUSE_INT sign bit, ecall cause 8/9) are the RISC-V privileged
 * spec; all struct offsets come from genassym (assym.h).
 */

#include	"assym.h"

/* RISC-V privileged-spec scause synchronous codes we special-case. */
#define	SCAUSE_ECALL_U	8		/* ecall from user mode */
#define	SCAUSE_ECALL_S	9		/* ecall from supervisor mode */

	.section .text
	.align 2

	.globl	rv_trap_dispatch
	.type	rv_trap_dispatch, @function
rv_trap_dispatch:
	addi	sp, sp, -regs_SIZE
	/* full integer save set into the struct regs frame */
	sd	ra, regs_r_ra(sp)
	sd	gp, regs_r_gp(sp)
	sd	tp, regs_r_tp(sp)
	sd	a0, regs_r_a0(sp)
	sd	a7, regs_r_a7(sp)
	csrr	t0, sepc
	sd	t0, regs_r_sepc(sp)
	csrr	t0, sstatus
	sd	t0, regs_r_sstatus(sp)
	csrr	t1, scause
	sd	t1, regs_r_scause(sp)
	csrr	t0, stval
	sd	t0, regs_r_stval(sp)

	mv	a0, sp			/* a0 = struct regs * for every handler */

	/* Interrupt? scause sign bit set -> rv_interrupt(regs). */
	bltz	t1, .Lintr		/* R_RISCV_BRANCH */

	/* ecall (syscall)? scause == 8 or 9 -> rv_syscall(regs). */
	li	t2, SCAUSE_ECALL_U
	beq	t1, t2, .Lsyscall	/* R_RISCV_BRANCH */
	li	t2, SCAUSE_ECALL_S
	beq	t1, t2, .Lsyscall	/* R_RISCV_BRANCH */

	/* Any other synchronous cause -> rv_trap(regs). */
	call	rv_trap			/* R_RISCV_CALL_PLT */
	j	.Lret			/* R_RISCV_JAL */
.Lintr:
	call	rv_interrupt		/* R_RISCV_CALL_PLT */
	j	.Lret			/* R_RISCV_JAL */
.Lsyscall:
	/* advance sepc past the ecall (4 bytes) before dispatch */
	ld	t0, regs_r_sepc(sp)
	addi	t0, t0, 4
	sd	t0, regs_r_sepc(sp)
	call	rv_syscall		/* R_RISCV_CALL_PLT */
.Lret:
	ld	t0, regs_r_sepc(sp)
	csrw	sepc, t0
	ld	ra, regs_r_ra(sp)
	addi	sp, sp, regs_SIZE
	sret
	.size	rv_trap_dispatch, . - rv_trap_dispatch
