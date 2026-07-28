/*
 * copy.S — illumos riscv64 fault-safe copyin/copyout primitives (R-P9).
 *
 * The syscall layer must never trust a user pointer. A bad user address passed
 * to read()/write()/wait4() must return EFAULT, not panic the kernel. This is
 * the RISC-V analog of uts/intel/ia32/ml/copy.s (copyin/copyout with a
 * t_lofault recovery label) and the NetBSD riscv copyin/copyout with a
 * fault-handler PC: a byte-copy loop whose faulting load/store is "caught" by
 * the trap dispatcher, which redirects sepc to a recovery label that returns
 * failure instead of parking the hart.
 *
 * Contract with trap.c:
 *   - Before touching user memory each routine stores the address of its
 *     _copy_fault recovery label into the global `copy_lofault` (a C ulong).
 *   - trap()'s page-fault path, seeing copy_lofault != 0 on a load/store page
 *     fault, sets sepc = copy_lofault, clears copy_lofault, and sret's back —
 *     landing on _copy_fault, which returns -1 (EFAULT).
 *   - On clean completion each routine zeroes copy_lofault and returns 0.
 *
 * SUM is already set (usermode_entry set sstatus.SUM=1 and it is preserved into
 * S-mode for the duration of the syscall), so S-mode loads/stores of a mapped
 * user page succeed directly; only an UNMAPPED / bad-permission user page
 * faults, which is exactly what we catch.
 *
 * long copyin (const void *uaddr, void *kaddr, unsigned long n);
 * long copyout(const void *kaddr, void *uaddr, unsigned long n);
 *   Return 0 on success, -1 if a fault was taken (EFAULT to the caller).
 */

	.section .text
	.align 2

	.globl copyin
	.type copyin, @function
copyin:
	/* a0 = uaddr (src), a1 = kaddr (dst), a2 = n. */
	la	t0, _copy_fault
	la	t1, copy_lofault
	sd	t0, 0(t1)		/* arm the recovery label */
	mv	t2, zero		/* i = 0 */
1:
	beq	t2, a2, 2f		/* i == n -> done */
	add	t3, a0, t2		/* &uaddr[i] */
	lb	t4, 0(t3)		/* FAULTS here if uaddr bad -> _copy_fault */
	add	t5, a1, t2		/* &kaddr[i] */
	sb	t4, 0(t5)
	addi	t2, t2, 1
	j	1b
2:
	la	t1, copy_lofault
	sd	zero, 0(t1)		/* disarm */
	li	a0, 0			/* success */
	ret
	.size copyin, . - copyin

	.globl copyout
	.type copyout, @function
copyout:
	/* a0 = kaddr (src), a1 = uaddr (dst), a2 = n. */
	la	t0, _copy_fault
	la	t1, copy_lofault
	sd	t0, 0(t1)		/* arm the recovery label */
	mv	t2, zero		/* i = 0 */
1:
	beq	t2, a2, 2f
	add	t3, a0, t2		/* &kaddr[i] */
	lb	t4, 0(t3)
	add	t5, a1, t2		/* &uaddr[i] */
	sb	t4, 0(t5)		/* FAULTS here if uaddr bad -> _copy_fault */
	addi	t2, t2, 1
	j	1b
2:
	la	t1, copy_lofault
	sd	zero, 0(t1)		/* disarm */
	li	a0, 0
	ret
	.size copyout, . - copyout

/*
 * _copy_fault — the recovery label. trap() redirects sepc here (with
 * copy_lofault already cleared) when a copyin/copyout load/store faults. We
 * return -1 to the C caller. sp/ra are intact because the fault interrupted a
 * leaf routine mid-loop; sret restored the full GPR set, and ra still points at
 * the copyin/copyout caller.
 */
	.globl _copy_fault
	.type _copy_fault, @function
_copy_fault:
	li	a0, -1
	ret
	.size _copy_fault, . - _copy_fault
