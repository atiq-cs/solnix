/*
 * mach_uentry.S -- R-P25 sub-task 1: enter U-mode + the kernel-stack swap on a
 * trap taken from U-mode.
 *
 *   rv_user_enter(struct uproc *up):
 *     install the user address space (satp), set sscratch = the lwp kernel
 *     trap stack top, program sstatus.SPP=0 (return to U-mode) + SPIE, set
 *     sepc = user entry, load the user sp, and sret -- the first instruction
 *     of the user process runs in U-mode.
 *
 *   rv_set_sscratch(v): raw sscratch write (kernel-stack pointer for U-traps).
 *
 * TRAP-FROM-U KERNEL-STACK SWAP: _trap_entry (locore.S) jumps here first.
 * When the CPU is in U-mode sscratch holds the kernel trap-stack top and sp is
 * the (untrusted) user sp; when the CPU is in the kernel sscratch is 0 and sp
 * is already a good kernel stack.  We `csrrw sp, sscratch, sp` to atomically
 * swap them: if the swapped-out value (now in sscratch) came from U we are on
 * the kernel stack; if sscratch was 0 (kernel trap) we swap back and keep the
 * current sp.  Either way we land in rv_trap_dispatch on a valid kernel stack
 * with sscratch restored, so a nested trap still swaps correctly.
 *
 * CRIB PROVENANCE: the "sscratch holds the kernel stack in U-mode, csrrw swap
 * on trap entry, 0 in kernel" idiom is the RISC-V privileged-spec trap-handler
 * convention (xv6-riscv usertrap/uservec, BSD riscv cpu_exception_handler);
 * the "sret to U with SPP=0, SPIE set, sepc=entry, user sp" handoff is the
 * privileged spec sret semantics + the illumos lwp_rtt / exec user-return.
 */

/* struct uproc offsets (proc_riscv.h). */
#define	U_SATP		0
#define	U_ENTRY		8
#define	U_SP		16
#define	U_KSTACK_TOP	24

/* sstatus bits. */
#define	SSTATUS_SIE	(1 << 1)
#define	SSTATUS_SPIE	(1 << 5)
#define	SSTATUS_SPP	(1 << 8)	/* previous privilege: 1=S, 0=U */
#define	SSTATUS_SUM	(1 << 18)	/* permit S-mode access to U pages */

	.section .text
	.align 2

	/* void rv_set_sscratch(unsigned long v) */
	.globl	rv_set_sscratch
	.type	rv_set_sscratch, @function
rv_set_sscratch:
	csrw	sscratch, a0
	ret
	.size	rv_set_sscratch, . - rv_set_sscratch

	/* void rv_user_enter(struct uproc *up) : a0 = up */
	.globl	rv_user_enter
	.type	rv_user_enter, @function
rv_user_enter:
	/* kernel trap stack for U-traps -> sscratch */
	ld	t0, U_KSTACK_TOP(a0)
	csrw	sscratch, t0

	/* sepc = user entry */
	ld	t0, U_ENTRY(a0)
	csrw	sepc, t0

	/* sstatus: clear SPP (return to U), set SPIE (enable ints in U). */
	csrr	t0, sstatus
	li	t1, SSTATUS_SPP
	not	t1, t1
	and	t0, t0, t1		/* SPP = 0 */
	li	t1, SSTATUS_SPIE
	or	t0, t0, t1		/* SPIE = 1 */
	li	t1, SSTATUS_SUM
	or	t0, t0, t1		/* SUM = 1: kernel may read/write U pages */
	csrw	sstatus, t0

	/* user sp (saved before we clobber it via the AS switch order) */
	ld	t2, U_SP(a0)

	/* install the user address space. */
	ld	t0, U_SATP(a0)
	csrw	satp, t0
	sfence.vma

	/* set the user sp and go. a0..a7 undefined for U per psABI; crt reads
	   argc/argv/envp off the stack, not registers. */
	mv	sp, t2
	sret
	.size	rv_user_enter, . - rv_user_enter

	/*
	 * _u_trap_entry -- the stvec landing pad (R-P25 replaces the locore
	 * _trap_entry wiring).  Swap to a kernel stack if we trapped from
	 * U-mode, then fall into rv_trap_dispatch.
	 */
	.align 2
	.globl	_u_trap_entry
	.type	_u_trap_entry, @function
_u_trap_entry:
	csrrw	sp, sscratch, sp	/* sp <-> sscratch */
	bnez	sp, 1f			/* sscratch was nonzero: trapped from U,
					   now on the kernel stack */
	/* sscratch was 0: kernel trap.  swap back, keep the kernel sp. */
	csrrw	sp, sscratch, sp
1:
	j	rv_trap_dispatch
	.size	_u_trap_entry, . - _u_trap_entry

/*
 * rv_ksetjmp / rv_klongjmp -- a minimal label_t (setjmp/longjmp) so the kernel
 * can enter U-mode and get control back on exit(2): the exec path saves a
 * kernel context with rv_ksetjmp (returns 0), rv_user_enter drops to U-mode,
 * and the exit(2) syscall calls rv_klongjmp(&ctx, status) which returns to the
 * rv_ksetjmp call site with the given nonzero status.  Saves the callee-saved
 * set + ra/sp (the C caller preserves the rest).
 *
 * struct rv_klabel { ra, sp, s0..s11 } -- 14 words.
 *
 * CRIB PROVENANCE: this is the illumos on_fault/setjmp label_t idiom + the
 * RISC-V LP64 callee-saved set (s0..s11); the "enter U, longjmp back on the
 * exit syscall" control return is the exec/lwp_exit unwind reduced to one
 * static process.
 */
#define	KL_RA	0
#define	KL_SP	8
#define	KL_S0	16	/* s0..s11 at 16,24,...,104 */

	.align 2
	.globl	rv_ksetjmp
	.type	rv_ksetjmp, @function
rv_ksetjmp:				/* int rv_ksetjmp(struct rv_klabel *) */
	sd	ra, KL_RA(a0)
	sd	sp, KL_SP(a0)
	sd	s0, KL_S0+0(a0)
	sd	s1, KL_S0+8(a0)
	sd	s2, KL_S0+16(a0)
	sd	s3, KL_S0+24(a0)
	sd	s4, KL_S0+32(a0)
	sd	s5, KL_S0+40(a0)
	sd	s6, KL_S0+48(a0)
	sd	s7, KL_S0+56(a0)
	sd	s8, KL_S0+64(a0)
	sd	s9, KL_S0+72(a0)
	sd	s10, KL_S0+80(a0)
	sd	s11, KL_S0+88(a0)
	li	a0, 0			/* direct return: 0 */
	ret
	.size	rv_ksetjmp, . - rv_ksetjmp

	.align 2
	.globl	rv_klongjmp
	.type	rv_klongjmp, @function
rv_klongjmp:				/* void rv_klongjmp(struct rv_klabel *, int) */
	ld	ra, KL_RA(a0)
	ld	sp, KL_SP(a0)
	ld	s0, KL_S0+0(a0)
	ld	s1, KL_S0+8(a0)
	ld	s2, KL_S0+16(a0)
	ld	s3, KL_S0+24(a0)
	ld	s4, KL_S0+32(a0)
	ld	s5, KL_S0+40(a0)
	ld	s6, KL_S0+48(a0)
	ld	s7, KL_S0+56(a0)
	ld	s8, KL_S0+64(a0)
	ld	s9, KL_S0+72(a0)
	ld	s10, KL_S0+80(a0)
	ld	s11, KL_S0+88(a0)
	mv	a0, a1			/* longjmp return value = status (nonzero) */
	ret
	.size	rv_klongjmp, . - rv_klongjmp
