/*
 * mach_clock.S -- riscv64 timer-interrupt bottom half, an R-P22.3 MD unit.
 *
 * On qemu-virt the periodic clock is the SBI timer (set via the SBI TIME
 * extension) delivered as a supervisor timer interrupt (scause = INT | 5).
 * rv_clock_intr() reprograms the next deadline through an SBI ecall (EID
 * 0x54494D45 "TIME", FID 0, next_time in a0) and calls the C clock() tick.
 * This unit adds an SBI ecall + a gp-relative load of the tick period to the
 * partial-link reloc mix.
 *
 * CRIB PROVENANCE: the SBI TIME ecall (a7=EID, a6=FID, a0=abs time) is the
 * RISC-V SBI spec sbi_set_timer(); the "read time, add period, set next,
 * call clock()" cadence is the illumos MD clock bottom-half (the R-P6 clock
 * slice); the CSR time read (rdtime) is the RISC-V unprivileged spec.
 */

#include	"assym.h"

#define	SBI_EID_TIME	0x54494D45	/* "TIME" */

	.section .text
	.align 2

	.globl	rv_clock_intr
	.type	rv_clock_intr, @function
rv_clock_intr:
	addi	sp, sp, -16
	sd	ra, 8(sp)

	/* next = rdtime + rv_clock_period ; program via SBI set_timer. */
	rdtime	t0			/* current time */
	/* gp-relative load of the tick period (PCREL_HI20/LO12 pair) */
	lla	t1, rv_clock_period	/* auipc+addi %pcrel */
	ld	t1, 0(t1)
	add	a0, t0, t1		/* next deadline */
	li	a6, 0			/* FID 0 */
	li	a7, SBI_EID_TIME
	ecall				/* sbi_set_timer(next) */

	call	clock			/* R_RISCV_CALL_PLT: the C tick */

	ld	ra, 8(sp)
	addi	sp, sp, 16
	ret
	.size	rv_clock_intr, . - rv_clock_intr

	/* the tick period (cycles); a real value is board-tuned at boot. */
	.section .sdata,"aw",@progbits
	.align 3
	.globl	rv_clock_period
	.type	rv_clock_period, @object
	.size	rv_clock_period, 8
rv_clock_period:
	.dword	100000			/* placeholder; boot recomputes from DTB */
