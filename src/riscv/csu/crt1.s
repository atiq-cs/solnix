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
 * crt1.s -- RISC-V (riscv64) C runtime startup for a Solaris/illumos userland
 * executable.
 *
 * This is the object linked at the very front of a dynamically- or
 * statically-linked program (the `crt1.o%s` the gcc *startfile spec selects
 * for the non-shared, non-profiled case).  It defines `_start`, the ELF entry
 * point.  The kernel (exec) hands control here with:
 *
 *   sp -> [ argc ][ argv[0..argc-1] ][ NULL ][ envp... ][ NULL ][ auxv... ]
 *   (all integer registers otherwise undefined per the RISC-V psABI)
 *
 * _start must:
 *   1. clear the frame pointer / return address so a stack walk terminates;
 *   2. establish the global pointer `gp` from __global_pointer$ (linker-set)
 *      with relaxation temporarily disabled, so gp-relative loads work;
 *   3. load argc/argv/envp off the initial stack into the C argument
 *      registers a0/a1/a2, keeping sp 16-byte aligned;
 *   4. in the full Solaris model, call __fsr (FP state) then hand off to
 *      libc's __start / _init / main / exit chain;
 *   5. in this bootstrap (no libc yet), call main(argc, argv, envp) directly
 *      and pass its return value to the exit(2) syscall so a static hello
 *      program is a complete, valid riscv64 ELF executable that returns an
 *      exit status.
 *
 * illumos gate location: usr/src/lib/crt/riscv/crt1.s (mirrors the amd64
 * crt1.s and aarch64 crt1.s, whose bodies do steps 1-4 then `call _init;
 * call main; call exit`).
 *
 * CRIB PROVENANCE:
 *   - the initial-stack layout (argc at 0(sp), argv following, envp after the
 *     argv NULL) and the a0=argc/a1=argv/a2=envp handoff: RISC-V psABI
 *     "Program Startup" + the glibc/newlib riscv crt0/Scrt1 sequence.
 *   - the `.option push; .option norelax; lla gp,__global_pointer$;
 *     .option pop` gp init idiom: RISC-V psABI + binutils/gcc riscv startup
 *     (gp must be set before any relaxed gp-relative access).
 *   - the "clear ra/fp, call main, exit" driver body and the crt1/crti/crtn
 *     link order: the illumos csu convention (amd64/aarch64 crt1.s).
 *   - the exit(2) syscall number (SYS_exit == 1) and the `ecall` trap: the
 *     illumos/Solaris syscall convention (a7 = syscall number, args in a0..).
 */

#define	SYS_exit	1		/* illumos syscall trap number */

	.text
	.globl	_start
	.type	_start, @function
	.align	1
_start:
	/* 1. terminate the frame chain. */
	li	ra, 0
	li	s0, 0			/* fp */

	/* 2. set the global pointer (relaxation off across this load). */
	.option push
	.option norelax
	lla	gp, __global_pointer$
	.option pop

	/*
	 * 3. pull argc/argv/envp off the initial stack.
	 *    a0 = argc          = *sp
	 *    a1 = argv          = sp + 8
	 *    a2 = envp          = argv + (argc+1)*8   (past the argv NULL)
	 */
	ld	a0, 0(sp)		/* argc */
	addi	a1, sp, 8		/* argv */
	addi	a2, a0, 1		/* argc + 1 */
	slli	a2, a2, 3		/* (argc+1) * 8 */
	add	a2, a1, a2		/* envp = argv + (argc+1)*8 */

	/* keep sp 16-byte aligned for the C call (psABI). */
	andi	sp, sp, -16

	/*
	 * 4/5. Bootstrap hand-off: run static constructors via _init, call
	 * main, then exit with its return value.  (The full Solaris model
	 * routes through libc __start / __fsr; this direct form needs no libc,
	 * so a freestanding hello links + runs its exit status.)
	 */
	call	_init
	call	main			/* main(argc, argv, envp) */

	/* a0 already holds main's return value; exit(status). */
	li	a7, 1			/* SYS_exit (illumos syscall trap number) */
	ecall
	/* not reached */
1:	j	1b
	.size	_start, . - _start
