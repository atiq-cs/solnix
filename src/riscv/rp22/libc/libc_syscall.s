/*
 * libc_syscall.s -- the minimal riscv64-solaris libc: the two syscall stubs a
 * freestanding hello needs (write(2), exit(2)) plus the raw _syscall() trap,
 * expressed in the illumos/Solaris riscv64 syscall ABI.
 *
 * illumos syscall convention (riscv64):
 *   - syscall number in a7,
 *   - arguments in a0..a5 (up to 6),
 *   - `ecall` traps to the kernel,
 *   - on return a0 = result; the kernel sets the carry/error convention
 *     (SunOS returns error in the C bit / a0 negative-errno on this ABI);
 *     this bootstrap libc returns a0 verbatim (errno handling is a later
 *     R-P layer once the kernel trap path exists).
 *
 * These are the exact trap numbers from the native illumos <sys/syscall.h>
 * (SYS_exit == 1, SYS_write == 4), which the riscv64 kernel syscall table
 * (R-P8/R-P9) will dispatch once it runs.  Cross-assembles to EM_RISCV.
 *
 * CRIB PROVENANCE:
 *   - a7=nr / a0..a5=args / ecall trap form: the illumos/Solaris riscv64
 *     syscall ABI (same shape as the R-P20 crt1.s exit(2) trap) + the RISC-V
 *     psABI integer-argument register assignment.
 *   - the per-syscall stub shape (li a7,NR; ecall; ret): the illumos libc
 *     SYSCALL()/SYSTRAP() csu idiom (usr/src/lib/libc/<arch>/sys/*.s).
 */

#define	SYS_exit	1
#define	SYS_write	4

	.text

	/* long _syscall(long nr, ...): nr in a0, args shifted a1->a0 etc. */
	.globl	_syscall
	.type	_syscall, @function
	.align	1
_syscall:
	mv	a7, a0			/* syscall number */
	mv	a0, a1
	mv	a1, a2
	mv	a2, a3
	mv	a3, a4
	mv	a4, a5
	mv	a5, a6
	ecall
	ret
	.size	_syscall, . - _syscall

	/* ssize_t write(int fd, const void *buf, size_t n) */
	.globl	write
	.type	write, @function
	.align	1
write:
	li	a7, 4			/* SYS_write */
	ecall
	ret
	.size	write, . - write

	/* void _exit(int status) / exit(int status) */
	.globl	_exit
	.globl	exit
	.type	_exit, @function
	.align	1
_exit:
exit:
	li	a7, 1			/* SYS_exit */
	ecall
	/* not reached */
1:	j	1b
	.size	_exit, . - _exit
