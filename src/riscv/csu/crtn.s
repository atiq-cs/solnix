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
 * crtn.s -- RISC-V (riscv64) C runtime, last half.
 *
 * Supplies the FUNCTION EPILOGUES for _init and _fini.  Linked LAST of the crt
 * set, so its .init / .fini fragments close the two functions crti.s opened.
 *
 * illumos gate location: usr/src/lib/common/riscv/crtn.s (mirrors i386/sparc/
 * aarch64 crtn.s).
 *
 * CRIB PROVENANCE: the crti/crtn open/close split is the SVR4/illumos csu
 * convention; the riscv64 epilogue (ld ra,8(sp) / addi sp,sp,16 / ret) is the
 * RISC-V psABI standard function return.
 */

	.section .init, "ax", @progbits
	ld	ra, 8(sp)
	addi	sp, sp, 16
	ret

	.section .fini, "ax", @progbits
	ld	ra, 8(sp)
	addi	sp, sp, 16
	ret
