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
 * crti.s -- RISC-V (riscv64) C runtime, first half.
 *
 * Supplies the FUNCTION PROLOGUES for the _init and _fini routines: this
 * object is linked FIRST of the crt set, so its .init / .fini fragments open
 * the two functions.  crtn.s (linked last) closes them.  Between the two, the
 * compiler-emitted .init_array / crtbegin fragments and every object's .init
 * contributions are concatenated into the body of _init.
 *
 * illumos gate location: usr/src/lib/common/riscv/crti.s (mirrors the
 * i386/sparc/aarch64 crti.s).  RISC-V lowering:
 *   - stack grows down, 16-byte aligned (psABI); save ra at 8(sp).
 *   - .init/.fini are ordinary functions; the addi/sd prologue matches what
 *     gcc emits for a leaf-with-call frame on riscv64.
 *
 * CRIB PROVENANCE: the crti/crtn "open the function, let fragments fall in,
 * close it" split is the SVR4/illumos csu convention (i386/sparc/aarch64
 * crti.s).  The riscv64 frame (addi sp,sp,-16 / sd ra,8(sp)) is the RISC-V
 * psABI standard call frame.
 */

	.section .init, "ax", @progbits
	.globl	_init
	.type	_init, @function
	.align	1
_init:
	addi	sp, sp, -16
	sd	ra, 8(sp)
	/* body: .init fragments from crtbegin + each object are appended here */

	.section .fini, "ax", @progbits
	.globl	_fini
	.type	_fini, @function
	.align	1
_fini:
	addi	sp, sp, -16
	sd	ra, 8(sp)
	/* body: .fini fragments are appended here */
