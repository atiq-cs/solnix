/*
 * regs.h — illumos riscv64 trap frame (struct regs) shared across the trap,
 * syscall, and userland-exec paths (R-P7).
 *
 * The layout MUST match asm_frame.h byte offsets (trap.S builds the frame at
 * those offsets); trap.c carries _Static_asserts that catch any drift. This
 * header is extracted from trap.c so syscall.c / as.c / proc.c can decode a
 * user trap frame (syscall args in r_a0..r_a7, r_sepc = the ecall PC) without
 * re-declaring the struct. Analog of uts/common/sys/regset.h (struct regs).
 */

#ifndef	_RISCV_REGS_FRAME_H
#define	_RISCV_REGS_FRAME_H

struct regs {
	unsigned long r_ra;	/* x1 */
	unsigned long r_sp;	/* x2 */
	unsigned long r_gp;	/* x3 */
	unsigned long r_tp;	/* x4 */
	unsigned long r_t0;	/* x5 */
	unsigned long r_t1;	/* x6 */
	unsigned long r_t2;	/* x7 */
	unsigned long r_s0;	/* x8 */
	unsigned long r_s1;	/* x9 */
	unsigned long r_a0;	/* x10 */
	unsigned long r_a1;	/* x11 */
	unsigned long r_a2;	/* x12 */
	unsigned long r_a3;	/* x13 */
	unsigned long r_a4;	/* x14 */
	unsigned long r_a5;	/* x15 */
	unsigned long r_a6;	/* x16 */
	unsigned long r_a7;	/* x17 */
	unsigned long r_s2;	/* x18 */
	unsigned long r_s3;	/* x19 */
	unsigned long r_s4;	/* x20 */
	unsigned long r_s5;	/* x21 */
	unsigned long r_s6;	/* x22 */
	unsigned long r_s7;	/* x23 */
	unsigned long r_s8;	/* x24 */
	unsigned long r_s9;	/* x25 */
	unsigned long r_s10;	/* x26 */
	unsigned long r_s11;	/* x27 */
	unsigned long r_t3;	/* x28 */
	unsigned long r_t4;	/* x29 */
	unsigned long r_t5;	/* x30 */
	unsigned long r_t6;	/* x31 */
	unsigned long r_sepc;
	unsigned long r_sstatus;
	unsigned long r_scause;
	unsigned long r_stval;
};

/*
 * usermode_entry (trap.S) — load the user frame and sret into U-mode. Does not
 * return. a1 = kernel stack top for the next trap-from-U (sscratch).
 */
extern void usermode_entry(struct regs *tf, unsigned long kstacktop);

#endif	/* _RISCV_REGS_FRAME_H */
