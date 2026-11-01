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
 *
 * USER RANGE CHECK. A fault only catches an UNMAPPED address. Every address
 * space also maps the kernel image and all of DRAM (identity, no PTE_U), and
 * S-mode may touch those, so without a range check a user pointer into a
 * kernel slot was read or written by the kernel. Each routine therefore
 * refuses, before arming copy_lofault, any [uaddr, uaddr+n) that is not inside
 * one user root slot (1 or 3), the same rule as hat_user_range_ok(). The
 * illumos analog is the kernelbase compare at the top of copyin/copyout.
 */

	.section .text
	.align 2

	/* Branch to _copy_efault unless [\ua, \ua+a2) is in one user slot. */
	.macro	URANGE ua
	beqz	a2, 9f			/* n == 0: nothing is touched */
	add	t3, \ua, a2
	addi	t3, t3, -1		/* last byte */
	bltu	t3, \ua, _copy_efault	/* wraps */
	srli	t4, \ua, 30		/* Sv39 root slot of the first byte */
	srli	t3, t3, 30
	bne	t3, t4, _copy_efault	/* crosses a slot */
	li	t3, 1
	beq	t4, t3, 9f
	li	t3, 3
	bne	t4, t3, _copy_efault	/* not slot 1 or 3: a kernel address */
9:
	.endm

	/* rvsmp-b: t1 = &copy_lofault[tp] (per-hart slot; tp = S-mode hart id). */
	.macro	LOFAULT r
	la	\r, copy_lofault
	slli	t5, tp, 3
	add	\r, \r, t5
	.endm

	.globl copyin
	.type copyin, @function
copyin:
	/* a0 = uaddr (src), a1 = kaddr (dst), a2 = n. */
	URANGE	a0
	la	t0, _copy_fault
	LOFAULT	t1
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
	LOFAULT	t1
	sd	zero, 0(t1)		/* disarm */
	li	a0, 0			/* success */
	ret
	.size copyin, . - copyin

	.globl copyout
	.type copyout, @function
copyout:
	/* a0 = kaddr (src), a1 = uaddr (dst), a2 = n. */
	URANGE	a1
	la	t0, _copy_fault
	LOFAULT	t1
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
	LOFAULT	t1
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

	/* A refused range: copy_lofault was never armed, so nothing to clear. */
	.globl _copy_efault
	.type _copy_efault, @function
_copy_efault:
	li	a0, -1
	ret
	.size _copy_efault, . - _copy_efault
