/*
 * setjmp.S -- RISC-V (riscv64, lp64d) setjmp/longjmp for the solnix libc.
 *
 * Saves the RISC-V psABI callee-saved register set into the jmp_buf and
 * restores it on longjmp, so a longjmp unwinds back to the setjmp call site
 * with the caller's stack, frame pointer, and return address intact:
 *   integer callee-saved:  ra, sp, s0(fp), s1, s2..s11  (13 words)
 *   float   callee-saved:  fs0..fs11                     (12 doubles)
 * gp/tp are fixed per-thread and not saved.  setjmp returns 0; longjmp makes
 * the matching setjmp return val (or 1 if val==0), per C89.
 *
 * jmp_buf layout (see setjmp.h): 13 uint64 integer slots [0..12] followed by
 * 12 uint64 fp slots [13..24].
 */
	.text

	.globl	setjmp
	.type	setjmp, @function
	.align	1
setjmp:
	sd	ra,  0*8(a0)
	sd	sp,  1*8(a0)
	sd	s0,  2*8(a0)
	sd	s1,  3*8(a0)
	sd	s2,  4*8(a0)
	sd	s3,  5*8(a0)
	sd	s4,  6*8(a0)
	sd	s5,  7*8(a0)
	sd	s6,  8*8(a0)
	sd	s7,  9*8(a0)
	sd	s8, 10*8(a0)
	sd	s9, 11*8(a0)
	sd	s10,12*8(a0)
	sd	s11,13*8(a0)
	fsd	fs0, 14*8(a0)
	fsd	fs1, 15*8(a0)
	fsd	fs2, 16*8(a0)
	fsd	fs3, 17*8(a0)
	fsd	fs4, 18*8(a0)
	fsd	fs5, 19*8(a0)
	fsd	fs6, 20*8(a0)
	fsd	fs7, 21*8(a0)
	fsd	fs8, 22*8(a0)
	fsd	fs9, 23*8(a0)
	fsd	fs10,24*8(a0)
	fsd	fs11,25*8(a0)
	li	a0, 0
	ret
	.size	setjmp, .-setjmp

	/* _setjmp is the same for this reduced (no signal-mask) libc */
	.globl	_setjmp
	.type	_setjmp, @function
	.set	_setjmp, setjmp

	.globl	longjmp
	.type	longjmp, @function
	.align	1
longjmp:
	ld	ra,  0*8(a0)
	ld	sp,  1*8(a0)
	ld	s0,  2*8(a0)
	ld	s1,  3*8(a0)
	ld	s2,  4*8(a0)
	ld	s3,  5*8(a0)
	ld	s4,  6*8(a0)
	ld	s5,  7*8(a0)
	ld	s6,  8*8(a0)
	ld	s7,  9*8(a0)
	ld	s8, 10*8(a0)
	ld	s9, 11*8(a0)
	ld	s10,12*8(a0)
	ld	s11,13*8(a0)
	fld	fs0, 14*8(a0)
	fld	fs1, 15*8(a0)
	fld	fs2, 16*8(a0)
	fld	fs3, 17*8(a0)
	fld	fs4, 18*8(a0)
	fld	fs5, 19*8(a0)
	fld	fs6, 20*8(a0)
	fld	fs7, 21*8(a0)
	fld	fs8, 22*8(a0)
	fld	fs9, 23*8(a0)
	fld	fs10,24*8(a0)
	fld	fs11,25*8(a0)
	/* return value: val, or 1 if val==0 */
	mv	a0, a1
	bnez	a0, 1f
	li	a0, 1
1:
	ret
	.size	longjmp, .-longjmp

	.globl	_longjmp
	.type	_longjmp, @function
	.set	_longjmp, longjmp
