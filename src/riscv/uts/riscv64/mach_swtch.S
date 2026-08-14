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
 * mach_swtch.S -- illumos riscv64 kernel context switch, now driven by the
 * genassym-GENERATED struct offsets (assym.h) instead of the hand-maintained
 * #define C_RA 0 / C_SP 8 ... block that the R-P5 swtch.S carried.
 *
 * This is the R-P21.3 conversion: every field offset comes from
 * rv_context_c_* / label_t_* symbols the genassym unit emitted from the ACTUAL
 * C struct, so the .S can never drift from proc.c's struct rv_context.  This is
 * the standard illumos/BSD kernel build discipline: MD assembly references C
 * layout only through <assym.h>, never open-coded numbers.
 *
 * void rv_swtch(struct rv_context *old, struct rv_context *new);
 *
 * CRIB PROVENANCE: the switch body (save callee-saved set + ra/sp/tp + satp +
 * lofault into *old, load *new) is the R-P5 swtch.S (RISC-V LP64 calling
 * convention; NetBSD riscv cpu_switch.S idiom).  The offset SOURCE is now
 * genassym (assym.h), the R-P20 unit.
 */

#include	"assym.h"

	.section .text
	.align 2

	.globl	rv_swtch
	.type	rv_swtch, @function
rv_swtch:
	/* Save current callee-saved context into *old (a0). */
	sd	ra, rv_context_c_ra(a0)
	sd	sp, rv_context_c_sp(a0)
	sd	tp, rv_context_c_tp(a0)
	sd	s0, rv_context_c_s0(a0)
	sd	s11, rv_context_c_s11(a0)
	/* Save the current satp + lofault (per-thread AS + copy fault snapshot). */
	csrr	t0, satp
	sd	t0, rv_context_c_satp(a0)
	ld	t1, rv_lofault		/* PCREL_HI20/LO12 external data ref */
	sd	t1, rv_context_c_lofault(a0)

	/* Load new context from *new (a1). */
	ld	ra, rv_context_c_ra(a1)
	ld	sp, rv_context_c_sp(a1)
	ld	tp, rv_context_c_tp(a1)
	ld	s0, rv_context_c_s0(a1)
	ld	s11, rv_context_c_s11(a1)
	ld	t0, rv_context_c_satp(a1)
	csrw	satp, t0
	sfence.vma
	ld	t1, rv_context_c_lofault(a1)
	la	t2, rv_lofault		/* CALL-shaped pcrel pair (AUIPC+ADDI) */
	sd	t1, 0(t2)
	ret
	.size	rv_swtch, . - rv_swtch

/*
 * void rv_savectx(label_t *lbl); a setjmp-style save using the genassym
 * LABEL_* offsets (proves label_t offsets flow from genassym too).
 */
	.globl	rv_savectx
	.type	rv_savectx, @function
rv_savectx:
	sd	ra, LABEL_RA(a0)
	sd	sp, LABEL_SP(a0)
	sd	s0, LABEL_S0(a0)
	li	a0, 0
	ret
	.size	rv_savectx, . - rv_savectx
