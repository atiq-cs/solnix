/*
 * mach_trap.S -- riscv64 trap dispatch, GROWN in R-P25 to handle traps from
 * U-mode (the userland process) as well as S-mode (the R-P24 kernel traps).
 *
 * R-P24 saved/restored the full integer file for an S-mode trap on the
 * interrupted sp.  R-P25 adds the U-mode case: a trap from U-mode arrives on
 * the (untrusted) user sp, and the kernel trap-stack top lives in sscratch.
 * _u_trap_entry (mach_uentry.S) does the sscratch/sp swap and jumps here with:
 *   - sp  = a valid kernel stack top (from sscratch if trapped from U, else
 *           the kernel sp unchanged),
 *   - sscratch = the OTHER value (the user sp if trapped from U, else 0).
 * We stash sscratch (the user sp or 0) into the frame R_SP slot, RESET
 * sscratch to the kernel stack top we are using (so the NEXT U-trap swaps in a
 * fresh kernel stack), dispatch, and on the way out restore sscratch + the
 * caller sp so sret returns to U (or S) transparently.
 *
 * Dispatch by scause: interrupt (sign bit) -> rv_interrupt(regs); ecall from
 * U/S (cause 8/9) -> rv_syscall(regs) after advancing sepc past the 4-byte
 * ecall; every other synchronous cause -> rv_trap(regs).  a0 = struct regs *.
 *
 * CRIB PROVENANCE: the "save full GPR frame, decode scause, dispatch, restore,
 * sret" shape is the illumos amd64 trap.S + R-P24 mach_trap.S; the U-mode
 * kernel-stack swap via sscratch + save/restore of the user sp is the RISC-V
 * privileged-spec trap convention (xv6-riscv kernelvec/usertrap, BSD riscv
 * cpu_trap); struct regs offsets are regs.h / the R-P20 genassym.
 */

/* struct regs offsets: r_<xN> = (N-1)*8 (regs.h layout). */
#define	R_RA	0	/* x1  */
#define	R_SP	8	/* x2  */
#define	R_GP	16	/* x3  */
#define	R_TP	24	/* x4  */
#define	R_T0	32	/* x5  */
#define	R_T1	40	/* x6  */
#define	R_T2	48	/* x7  */
#define	R_S0	56	/* x8  */
#define	R_S1	64	/* x9  */
#define	R_A0	72	/* x10 */
#define	R_A1	80	/* x11 */
#define	R_A2	88	/* x12 */
#define	R_A3	96	/* x13 */
#define	R_A4	104	/* x14 */
#define	R_A5	112	/* x15 */
#define	R_A6	120	/* x16 */
#define	R_A7	128	/* x17 */
#define	R_S2	136	/* x18 */
#define	R_S3	144	/* x19 */
#define	R_S4	152	/* x20 */
#define	R_S5	160	/* x21 */
#define	R_S6	168	/* x22 */
#define	R_S7	176	/* x23 */
#define	R_S8	184	/* x24 */
#define	R_S9	192	/* x25 */
#define	R_S10	200	/* x26 */
#define	R_S11	208	/* x27 */
#define	R_T3	216	/* x28 */
#define	R_T4	224	/* x29 */
#define	R_T5	232	/* x30 */
#define	R_T6	240	/* x31 */
#define	R_SEPC		248
#define	R_SSTATUS	256
#define	R_SCAUSE	264
#define	R_STVAL		272
#define	R_SIZE		280

#define	SCAUSE_ECALL_U	8
#define	SCAUSE_ECALL_S	9

	.section .text
	.align 2
	.globl	rv_trap_dispatch
	.type	rv_trap_dispatch, @function
rv_trap_dispatch:
	/*
	 * sp is a valid kernel stack top (set by _u_trap_entry); sscratch holds
	 * the swapped-out value (user sp if from U, 0 if from S).  Build the
	 * frame, save that value in R_SP, and reset sscratch to this kernel
	 * stack top so a later U-trap swaps in a fresh kernel stack.
	 */
	addi	sp, sp, -R_SIZE
	sd	ra, R_RA(sp)
	csrr	t0, sscratch		/* the caller sp (user) or 0 (kernel) */
	sd	t0, R_SP(sp)		/* stash it for the epilogue */
	csrw	sscratch, zero		/* in the kernel now: sscratch invariant 0 */
	sd	gp, R_GP(sp)
	sd	tp, R_TP(sp)
	sd	t0, R_T0(sp)
	sd	t1, R_T1(sp)
	sd	t2, R_T2(sp)
	sd	s0, R_S0(sp)
	sd	s1, R_S1(sp)
	sd	a0, R_A0(sp)
	sd	a1, R_A1(sp)
	sd	a2, R_A2(sp)
	sd	a3, R_A3(sp)
	sd	a4, R_A4(sp)
	sd	a5, R_A5(sp)
	sd	a6, R_A6(sp)
	sd	a7, R_A7(sp)
	sd	s2, R_S2(sp)
	sd	s3, R_S3(sp)
	sd	s4, R_S4(sp)
	sd	s5, R_S5(sp)
	sd	s6, R_S6(sp)
	sd	s7, R_S7(sp)
	sd	s8, R_S8(sp)
	sd	s9, R_S9(sp)
	sd	s10, R_S10(sp)
	sd	s11, R_S11(sp)
	sd	t3, R_T3(sp)
	sd	t4, R_T4(sp)
	sd	t5, R_T5(sp)
	sd	t6, R_T6(sp)
	csrr	t0, sepc
	sd	t0, R_SEPC(sp)
	csrr	t0, sstatus
	sd	t0, R_SSTATUS(sp)
	csrr	t1, scause
	sd	t1, R_SCAUSE(sp)
	csrr	t0, stval
	sd	t0, R_STVAL(sp)

	mv	a0, sp			/* a0 = struct regs * for every handler */

	bltz	t1, .Lintr		/* interrupt: scause sign bit set */

	li	t2, SCAUSE_ECALL_U
	beq	t1, t2, .Lsyscall
	li	t2, SCAUSE_ECALL_S
	beq	t1, t2, .Lsyscall

	call	rv_trap			/* any other synchronous cause */
	j	.Lret
.Lintr:
	call	rv_interrupt
	j	.Lret
.Lsyscall:
	/* advance the SAVED sepc past the 4-byte ecall before dispatch */
	ld	t0, R_SEPC(sp)
	addi	t0, t0, 4
	sd	t0, R_SEPC(sp)
	call	rv_syscall
.Lret:
	/*
	 * R-P33.1 SIGNAL DELIVERY: on the way back from any trap handler, if we
	 * are returning to U-mode and the running proc has a pending, deliverable
	 * signal, proc_deliver_signals rewrites this frame in place (sepc ->
	 * handler, a0 = signo, sp = a fresh sigframe on the user stack, ra = the
	 * sa_restorer).  a0 = the trap frame; sp (our kernel sp) still points at
	 * the frame after the call, so the epilogue below restores the rewritten
	 * frame and sret's into the handler.  (A fresh proc jumps straight to
	 * rv_user_frame_ret below, bypassing this check -- it has no pending
	 * signals yet.)
	 */
	mv	a0, sp
	call	proc_deliver_signals
.globl	rv_user_frame_ret
	.type	rv_user_frame_ret, @function
rv_user_frame_ret:
	/*
	 * R-P26 entry point for a freshly-scheduled proc: rv_swtch loaded this
	 * proc's context (c_ra=rv_user_frame_ret, c_sp=its trap frame, c_satp=
	 * its user AS), so we arrive here with sp = the trap frame and the user
	 * page table already installed.  The epilogue below restores the frame
	 * and sret's to U-mode -- identical to a normal syscall return.
	 */
	/* restore sepc + sstatus, then the full GPR frame, then sret */
	ld	t0, R_SEPC(sp)
	csrw	sepc, t0
	ld	t0, R_SSTATUS(sp)
	csrw	sstatus, t0
	/*
	 * If we are returning to U-mode (sstatus.SPP==0) restore sscratch to
	 * the kernel stack top so the next U-trap swaps correctly, and the
	 * user sp will be reloaded into sp below.  If returning to S-mode
	 * (SPP==1) leave sscratch = 0 and reload the kernel sp (== the value
	 * we stashed in R_SP, which was sscratch==0... so recompute).
	 */
	li	t1, (1 << 8)		/* SSTATUS_SPP */
	and	t1, t0, t1
	bnez	t1, .Lret_s		/* SPP==1: returning to S-mode */
	/* returning to U: sscratch = kernel stack top | hartid (tp holds the
	   per-hart id here -- set by _u_trap_entry on a trap, or the kernel
	   hartid on a fresh rv_user_frame_ret dispatch); sp = saved user sp. */
	addi	t0, sp, R_SIZE
	or	t0, t0, tp		/* R-P32: pack hartid in bit 0 */
	csrw	sscratch, t0
	ld	ra, R_RA(sp)
	ld	gp, R_GP(sp)
	ld	tp, R_TP(sp)
	ld	s0, R_S0(sp)
	ld	s1, R_S1(sp)
	ld	a0, R_A0(sp)
	ld	a1, R_A1(sp)
	ld	a2, R_A2(sp)
	ld	a3, R_A3(sp)
	ld	a4, R_A4(sp)
	ld	a5, R_A5(sp)
	ld	a6, R_A6(sp)
	ld	a7, R_A7(sp)
	ld	s2, R_S2(sp)
	ld	s3, R_S3(sp)
	ld	s4, R_S4(sp)
	ld	s5, R_S5(sp)
	ld	s6, R_S6(sp)
	ld	s7, R_S7(sp)
	ld	s8, R_S8(sp)
	ld	s9, R_S9(sp)
	ld	s10, R_S10(sp)
	ld	s11, R_S11(sp)
	ld	t2, R_T2(sp)
	ld	t3, R_T3(sp)
	ld	t4, R_T4(sp)
	ld	t5, R_T5(sp)
	ld	t6, R_T6(sp)
	ld	t0, R_T0(sp)
	ld	t1, R_T1(sp)
	ld	sp, R_SP(sp)		/* reload the user sp */
	sret

.Lret_s:
	/* returning to S-mode: keep sscratch = 0, sp unwinds via R_SIZE. */
	li	t0, 0
	csrw	sscratch, t0
	ld	ra, R_RA(sp)
	ld	gp, R_GP(sp)
	ld	tp, R_TP(sp)
	ld	s0, R_S0(sp)
	ld	s1, R_S1(sp)
	ld	a0, R_A0(sp)
	ld	a1, R_A1(sp)
	ld	a2, R_A2(sp)
	ld	a3, R_A3(sp)
	ld	a4, R_A4(sp)
	ld	a5, R_A5(sp)
	ld	a6, R_A6(sp)
	ld	a7, R_A7(sp)
	ld	s2, R_S2(sp)
	ld	s3, R_S3(sp)
	ld	s4, R_S4(sp)
	ld	s5, R_S5(sp)
	ld	s6, R_S6(sp)
	ld	s7, R_S7(sp)
	ld	s8, R_S8(sp)
	ld	s9, R_S9(sp)
	ld	s10, R_S10(sp)
	ld	s11, R_S11(sp)
	ld	t2, R_T2(sp)
	ld	t3, R_T3(sp)
	ld	t4, R_T4(sp)
	ld	t5, R_T5(sp)
	ld	t6, R_T6(sp)
	ld	t0, R_T0(sp)
	ld	t1, R_T1(sp)
	addi	sp, sp, R_SIZE
	sret
	.size	rv_trap_dispatch, . - rv_trap_dispatch
