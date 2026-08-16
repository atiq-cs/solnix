/*
 * crt1.s -- RISC-V (riscv64) C runtime startup for a solnix libc-linked
 * program.  The kernel exec hands control here with the RISC-V psABI initial
 * stack: sp -> [argc][argv...][NULL][envp...][NULL][auxv...].  _start:
 *   1. terminates the frame chain (ra=0, fp=0);
 *   2. sets gp from __global_pointer$ with relaxation off;
 *   3. loads argc/argv/envp into a0/a1/a2 and 16-byte-aligns sp;
 *   4. calls __libc_start(argc, argv, envp), which stashes environ, runs _init
 *      (.init_array constructors), calls main, and calls exit() -- exit runs
 *      the atexit hooks (e.g. coreutils close_stdout) and flushes libc stdio
 *      before trapping SYS_exit.  __libc_start does not return.
 *
 * CRIB PROVENANCE: the initial-stack layout + a0=argc/a1=argv/a2=envp handoff
 * is the RISC-V psABI "Program Startup" (glibc/newlib Scrt1); the gp init idiom
 * (.option norelax; lla gp,__global_pointer$) is the RISC-V psABI startup; the
 * "clear ra/fp, hand to the libc start routine, never return" body is the
 * illumos csu crt1 (amd64/aarch64) convention, here routing exit through libc
 * so stdio is flushed + atexit runs (the C89 exit contract).
 */
	.text
	.globl	_start
	.type	_start, @function
	.align	1
_start:
	li	ra, 0
	li	s0, 0			/* fp */

	.option push
	.option norelax
	lla	gp, __global_pointer$
	.option pop

	ld	a0, 0(sp)		/* argc */
	addi	a1, sp, 8		/* argv */
	addi	a2, a0, 1		/* argc + 1 */
	slli	a2, a2, 3		/* (argc+1) * 8 */
	add	a2, a1, a2		/* envp = argv + (argc+1)*8 */

	andi	sp, sp, -16		/* psABI 16-byte alignment */

	call	__libc_start		/* (argc, argv, envp); never returns */
1:	j	1b
	.size	_start, . - _start
