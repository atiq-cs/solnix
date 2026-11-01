/*
 * crt0.S -- process entry for solnix riscv64 programs linked against newlib.
 *
 * Replaces newlib's libgloss crt0.o for two measured reasons:
 *
 *  1. newlib's crt0 passes envp = NULL to main and never sets `environ`, so
 *     getenv()/execve(environ) see an empty environment even when the kernel
 *     put one on the stack. Here envp = argv + argc + 1 (the psABI stack
 *     layout uproc.c builds), and environ is set before main.
 *
 *  2. The kernel keeps ONE signal-return trampoline address for ALL processes
 *     (uproc.c: `static unsigned long p_sigrestore_va`). Any program that
 *     installs a handler overwrites it, so a handler in program A returns to
 *     program B's trampoline address. Putting __solnix_sigreturn first in
 *     .text.init (which newlib.ld places first at 0x40010000) gives every
 *     binary built this way the SAME trampoline VA, so the global is harmless
 *     among them. Programs linked elsewhere (the 0xC0010000 toy-libc init/sh)
 *     still collide; do not mix them with handlers in one boot.
 */
	.section .text.init, "ax", @progbits
	.globl	__solnix_sigreturn
	.type	__solnix_sigreturn, @function
__solnix_sigreturn:
	li	a7, 139			/* SYS_rt_sigreturn */
	ecall
1:	j	1b
	.size	__solnix_sigreturn, . - __solnix_sigreturn

	.globl	_start
	.type	_start, @function
_start:
	.option push
	.option norelax
1:	auipc	gp, %pcrel_hi(__global_pointer$)
	addi	gp, gp, %pcrel_lo(1b)
	.option pop

	/* Save the kernel-built stack pointer before calling anything. */
	mv	s0, sp

	/* Clear .bss (crt0's job; the loader only maps memsz as zero pages
	 * when they are fresh, so do not rely on it). */
	la	a0, __bss_start
	la	a2, _end
	sub	a2, a2, a0
	li	a1, 0
	call	memset

	/* argc, argv, envp = argv + argc + 1 */
	ld	s1, 0(s0)		/* argc */
	addi	s2, s0, 8		/* argv */
	addi	t0, s1, 1
	slli	t0, t0, 3
	add	s3, s2, t0		/* envp */
	la	t1, environ
	sd	s3, 0(t1)

	la	a0, __libc_fini_array
	call	atexit
	call	__libc_init_array

	mv	a0, s1
	mv	a1, s2
	mv	a2, s3
	call	main
	tail	exit
	.size	_start, . - _start
