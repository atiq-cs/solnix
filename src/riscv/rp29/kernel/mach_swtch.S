/*
 * mach_swtch.S -- R-P24 minimal riscv64 kernel context switch (the dispatcher
 * on-ramp).  A reduced rv_swtch: save the callee-saved register set + ra/sp +
 * satp of the outgoing thread into *old, load the incoming thread's from *new,
 * switch the address space (satp), and ret -- so `ret` returns into the new
 * thread's saved ra.  This is the single primitive swtch() needs to hand a CPU
 * from one kthread_t to another.
 *
 *   void rv_swtch(struct rv_context *old, struct rv_context *new);
 *
 * The struct rv_context layout matches startup.c: c_ra, c_sp, c_s0..c_s11,
 * c_satp at fixed offsets (kept in sync via the literal offsets below; the full
 * kernel drives these from genassym -- R-P21 mach_swtch.S -- but the R-P24
 * minimal seam uses a self-contained struct so it needs no rv_lofault/global
 * data refs).
 *
 * CRIB PROVENANCE: the "save callee-saved + ra/sp + satp into old, load new,
 * sfence.vma, ret" switch body is the R-P5/R-P21 riscv swtch.S (RISC-V LP64
 * callee-saved set s0..s11; NetBSD riscv cpu_switch.S idiom); trimmed of the
 * lofault/genassym coupling for the R-P24 minimal dispatcher.
 */

/* struct rv_context offsets (startup.c). */
#define	C_RA	0
#define	C_SP	8
#define	C_S0	16
#define	C_S1	24
#define	C_S2	32
#define	C_S3	40
#define	C_S4	48
#define	C_S5	56
#define	C_S6	64
#define	C_S7	72
#define	C_S8	80
#define	C_S9	88
#define	C_S10	96
#define	C_S11	104
#define	C_SATP	112
#define	C_FCSR	120
#define	C_F0	128	/* c_f[0]; c_f[i] at C_F0 + i*8 */

	.section .text
	.align 2
	.globl	rv_swtch
	.type	rv_swtch, @function
rv_swtch:
	/* save outgoing context into *old (a0) */
	sd	ra, C_RA(a0)
	sd	sp, C_SP(a0)
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
	csrr	t0, satp
	sd	t0, C_SATP(a0)

	/*
	 * R-P29 FP context save.  Enable FP (sstatus.FS=Dirty) so the fsd/frcsr
	 * are legal in the kernel, then save f0..f31 + fcsr of the OUTGOING
	 * context into *old.  Two FP-using procs thus keep independent FP state
	 * across a preemptive switch (the illumos fpu_save / fp_save).
	 */
	li	t0, (3 << 13)		/* SSTATUS_FS = Dirty */
	csrs	sstatus, t0
	frcsr	t1
	sd	t1, C_FCSR(a0)
	fsd	f0,  C_F0+0*8(a0)
	fsd	f1,  C_F0+1*8(a0)
	fsd	f2,  C_F0+2*8(a0)
	fsd	f3,  C_F0+3*8(a0)
	fsd	f4,  C_F0+4*8(a0)
	fsd	f5,  C_F0+5*8(a0)
	fsd	f6,  C_F0+6*8(a0)
	fsd	f7,  C_F0+7*8(a0)
	fsd	f8,  C_F0+8*8(a0)
	fsd	f9,  C_F0+9*8(a0)
	fsd	f10, C_F0+10*8(a0)
	fsd	f11, C_F0+11*8(a0)
	fsd	f12, C_F0+12*8(a0)
	fsd	f13, C_F0+13*8(a0)
	fsd	f14, C_F0+14*8(a0)
	fsd	f15, C_F0+15*8(a0)
	fsd	f16, C_F0+16*8(a0)
	fsd	f17, C_F0+17*8(a0)
	fsd	f18, C_F0+18*8(a0)
	fsd	f19, C_F0+19*8(a0)
	fsd	f20, C_F0+20*8(a0)
	fsd	f21, C_F0+21*8(a0)
	fsd	f22, C_F0+22*8(a0)
	fsd	f23, C_F0+23*8(a0)
	fsd	f24, C_F0+24*8(a0)
	fsd	f25, C_F0+25*8(a0)
	fsd	f26, C_F0+26*8(a0)
	fsd	f27, C_F0+27*8(a0)
	fsd	f28, C_F0+28*8(a0)
	fsd	f29, C_F0+29*8(a0)
	fsd	f30, C_F0+30*8(a0)
	fsd	f31, C_F0+31*8(a0)

	/* load incoming context from *new (a1) */
	ld	ra, C_RA(a1)
	ld	sp, C_SP(a1)
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
	ld	t0, C_SATP(a1)
	csrw	satp, t0
	sfence.vma

	/*
	 * R-P29 FP context restore: load f0..f31 + fcsr of the INCOMING context
	 * from *new (FS already Dirty from the save above).  Then ret into the
	 * incoming ra.
	 */
	ld	t1, C_FCSR(a1)
	fscsr	t1
	fld	f0,  C_F0+0*8(a1)
	fld	f1,  C_F0+1*8(a1)
	fld	f2,  C_F0+2*8(a1)
	fld	f3,  C_F0+3*8(a1)
	fld	f4,  C_F0+4*8(a1)
	fld	f5,  C_F0+5*8(a1)
	fld	f6,  C_F0+6*8(a1)
	fld	f7,  C_F0+7*8(a1)
	fld	f8,  C_F0+8*8(a1)
	fld	f9,  C_F0+9*8(a1)
	fld	f10, C_F0+10*8(a1)
	fld	f11, C_F0+11*8(a1)
	fld	f12, C_F0+12*8(a1)
	fld	f13, C_F0+13*8(a1)
	fld	f14, C_F0+14*8(a1)
	fld	f15, C_F0+15*8(a1)
	fld	f16, C_F0+16*8(a1)
	fld	f17, C_F0+17*8(a1)
	fld	f18, C_F0+18*8(a1)
	fld	f19, C_F0+19*8(a1)
	fld	f20, C_F0+20*8(a1)
	fld	f21, C_F0+21*8(a1)
	fld	f22, C_F0+22*8(a1)
	fld	f23, C_F0+23*8(a1)
	fld	f24, C_F0+24*8(a1)
	fld	f25, C_F0+25*8(a1)
	fld	f26, C_F0+26*8(a1)
	fld	f27, C_F0+27*8(a1)
	fld	f28, C_F0+28*8(a1)
	fld	f29, C_F0+29*8(a1)
	fld	f30, C_F0+30*8(a1)
	fld	f31, C_F0+31*8(a1)
	ret
	.size	rv_swtch, . - rv_swtch
