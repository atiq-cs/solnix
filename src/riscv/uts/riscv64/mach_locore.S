/*
 * CDDL HEADER START
 *
 * The contents of this file are subject to the terms of the
 * Common Development and Distribution License (the "License").
 * You may not use this file except in compliance with the License.
 *
 * You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
 * or http://www.opensolaris.org/os/licensing.
 * See the License for the specific language governing permissions
 * and limitations under the License.
 *
 * When distributing Covered Code, include this CDDL HEADER in each
 * file and include the License file at usr/src/OPENSOLARIS.LICENSE.
 * If applicable, add the following below this CDDL HEADER, with the
 * fields enclosed by brackets "[]" replaced with your own identifying
 * information: Portions Copyright [yyyy] [name of copyright owner]
 *
 * CDDL HEADER END
 */

/*
 * mach_locore.S -- a genassym-driven riscv64 trap-entry / save-frame slice.
 *
 * The R-P21.3 companion to mach_swtch.S: a locore-style trap prologue that
 * saves the interrupted register set into a `struct regs` trap frame using the
 * genassym-GENERATED regs_r_* offsets (assym.h) rather than open-coded numbers.
 * It exercises the load-bearing kernel reloc set for the partial link -- an
 * external CALL to the C trap handler (R_RISCV_CALL_PLT), the PCREL pair to the
 * per-hart trap-frame pointer, and BRANCH -- exactly the relocs the sgs
 * machrel.riscv.c backend resolves.
 *
 * CRIB PROVENANCE: the trap-save shape (build a struct regs frame, sd the GPRs
 * at their offsets, read the trap CSRs sepc/sstatus/scause/stval, then call the
 * C handler) is the R-P3 trap.S; the offset SOURCE is genassym (assym.h).
 */

#include	"assym.h"

	.section .text
	.align 2

	.globl	rv_trap_entry
	.type	rv_trap_entry, @function
rv_trap_entry:
	/* Make room for a struct regs trap frame on the stack. */
	addi	sp, sp, -regs_SIZE
	/* Save the caller GPRs at their genassym offsets. */
	sd	ra, regs_r_ra(sp)
	sd	gp, regs_r_gp(sp)
	sd	tp, regs_r_tp(sp)
	sd	a0, regs_r_a0(sp)
	sd	a7, regs_r_a7(sp)
	/* Snapshot the trap CSRs into the frame. */
	csrr	t0, sepc
	sd	t0, regs_r_sepc(sp)
	csrr	t0, sstatus
	sd	t0, regs_r_sstatus(sp)
	csrr	t0, scause
	sd	t0, regs_r_scause(sp)
	csrr	t0, stval
	sd	t0, regs_r_stval(sp)
	/* Branch on synchronous vs interrupt (scause sign bit). */
	bltz	t0, 1f			/* R_RISCV_BRANCH */
	/* Hand the frame to the C trap handler. */
	mv	a0, sp
	call	rv_trap			/* R_RISCV_CALL_PLT to C */
1:
	/* Restore + return from trap. */
	ld	ra, regs_r_ra(sp)
	ld	t0, regs_r_sepc(sp)
	csrw	sepc, t0
	addi	sp, sp, regs_SIZE
	sret
	.size	rv_trap_entry, . - rv_trap_entry
