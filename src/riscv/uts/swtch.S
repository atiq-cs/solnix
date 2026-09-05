/*
 * swtch.S — illumos riscv64 kernel context switch (R-P5).
 *
 * The marquee R-P5 primitive: a real RISC-V kernel-thread context switch. This
 * is the analog of uts/i86pc resume()/_resume_from_idle and the aarch64-gate
 * cpu_switch — modeled on the NetBSD riscv cpu_switch.S idiom (clean RISC-V:
 * no register windows, just the callee-saved set + ra/sp/tp), reimplemented
 * from the RISC-V calling convention (no CDDL-incompatible source copied).
 *
 * RISC-V LP64 calling convention — what a switch must preserve across a call:
 *   ra (x1)      return address
 *   sp (x2)      stack pointer
 *   tp (x4)      thread pointer. THE tp SPLIT: in S-mode this is the KERNEL's
 *                per-hart id (this_cpu()); userland's TLS pointer lives in the
 *                process's saved user frame, not here. See proc.c this_cpu().
 *   s0-s11       callee-saved (s0=x8/fp, s1=x9, s2-s11=x18-x27)
 * Caller-saved regs (t0-t6, a0-a7) need NOT be saved: swtch() is a normal C
 * call, so the compiler already spilled anything live across it. That is the
 * whole trick — a cooperative switch only has to save the callee-saved set.
 *
 * struct rv_context layout (proc.c) — 15 * 8 = 120 bytes:
 *   0:  ra   8:  sp   16: tp (S-mode per-hart id)
 *   24: s0   32: s1   40: s2   48: s3   56: s4   64: s5
 *   72: s6   80: s7   88: s8   96: s9  104: s10 112: s11
 *   120: satp  (R-P8: per-thread address space; restored on switch so a
 *              kernel thread that yields mid-syscall resumes on its own AS)
 *   128: lofault (R-P10: per-thread copy_lofault snapshot; save/restore the
 *              global around a preemptive switch so a preempted armed copy is
 *              not observed/clobbered by the incoming thread)
 *
 * void rv_swtch(struct rv_context *old, struct rv_context *new);
 *   Save the current callee-saved context into *old, load *new, and return.
 *   Because we save `ra`, the switch "returns" into whatever code last called
 *   rv_swtch on the new thread — for a brand-new thread that is the trampoline
 *   rv_thread_start (set up by thread_create), which jumps to the entry point.
 */

	.section .text
	.align 2

/* struct rv_context field offsets (must match proc.c). */
#define	C_RA	0
#define	C_SP	8
#define	C_TP	16
#define	C_S0	24
#define	C_S1	32
#define	C_S2	40
#define	C_S3	48
#define	C_S4	56
#define	C_S5	64
#define	C_S6	72
#define	C_S7	80
#define	C_S8	88
#define	C_S9	96
#define	C_S10	104
#define	C_S11	112
#define	C_SATP	120
#define	C_LOFAULT 128

	.globl rv_swtch
	.type rv_swtch, @function
rv_swtch:
	/* Save current callee-saved context into *old (a0). */
	sd	ra, C_RA(a0)
	sd	sp, C_SP(a0)
	sd	tp, C_TP(a0)
	sd	s0, C_S0(a0)
	sd	s1, C_S1(a0)
	sd	s2, C_S2(a0)
	sd	s3, C_S3(a0)
	sd	s4, C_S4(a0)
	sd	s5, C_S5(a0)
	sd	s6, C_S6(a0)
	sd	s7, C_S7(a0)
	sd	s8, C_S8(a0)
	sd	s9, C_S9(a0)
	sd	s10, C_S10(a0)
	sd	s11, C_S11(a0)
	/* Save the current satp (R-P8 per-thread AS). */
	csrr	t0, satp
	sd	t0, C_SATP(a0)
	/*
	 * Save the current thread's armed copy_lofault (R-P10). copy.S arms the
	 * global around a user copy; if the clock preempts us mid-copy, snapshot
	 * the arm into our context so the incoming thread cannot observe or
	 * clobber it, and it is restored when we are switched back to.
	 */
	la	t1, copy_lofault
	ld	t0, 0(t1)
	sd	t0, C_LOFAULT(a0)

	/* Load new context from *new (a1). */
	ld	ra, C_RA(a1)
	ld	sp, C_SP(a1)
	ld	tp, C_TP(a1)
	ld	s0, C_S0(a1)
	ld	s1, C_S1(a1)
	ld	s2, C_S2(a1)
	ld	s3, C_S3(a1)
	ld	s4, C_S4(a1)
	ld	s5, C_S5(a1)
	ld	s6, C_S6(a1)
	ld	s7, C_S7(a1)
	ld	s8, C_S8(a1)
	ld	s9, C_S9(a1)
	ld	s10, C_S10(a1)
	ld	s11, C_S11(a1)

	/*
	 * Load the new thread's satp and flush the TLB. A satp of 0 means the
	 * thread has no recorded AS yet (a freshly created thread before it runs
	 * its body); skip the write so we keep the current (kernel) satp until
	 * the body sets its own. All live threads carry a real satp (the kernel
	 * satp for kernel threads, seeded at thread_create).
	 */
	ld	t0, C_SATP(a1)
	beqz	t0, 1f
	csrw	satp, t0
	sfence.vma
1:
	/* Restore the incoming thread's copy_lofault into the global (R-P10). */
	la	t1, copy_lofault
	ld	t0, C_LOFAULT(a1)
	sd	t0, 0(t1)

	/* Return into the new thread's ra. */
	ret
	.size rv_swtch, . - rv_swtch

/*
 * rv_thread_start — trampoline for a brand-new thread. thread_create seeds the
 * new context so that the first rv_swtch INTO it "returns" here with:
 *   s0 = entry function pointer
 *   s1 = entry argument
 * (s0/s1 are callee-saved, so rv_swtch restores them into place before ret.)
 * We move them into a0 + call the entry. If the entry returns, fall into
 * thread_exit (a thread's body should normally loop or explicitly exit).
 */
	.globl rv_thread_start
	.type rv_thread_start, @function
rv_thread_start:
	mv	a0, s1			/* arg */
	jalr	s0			/* call entry(arg) */
	call	thread_exit		/* entry returned: exit the thread */
	/* thread_exit does not return; but guard anyway. */
1:	wfi
	j	1b
	.size rv_thread_start, . - rv_thread_start
