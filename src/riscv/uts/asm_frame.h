/*
 * asm_frame.h — trap frame byte offsets shared by trap.S and trap.c (R-P3).
 *
 * The layout must match struct regs in trap.c exactly. Each field is 8 bytes.
 * Order is x1..x31 in register-number order (x0/zero is not stored), followed
 * by the four trap CSRs. TF_SIZE is padded to a 16-byte-aligned total so sp
 * stays ABI-aligned after `addi sp, sp, -TF_SIZE`.
 *
 * 31 GPRs + 4 CSRs = 35 slots * 8 = 280 bytes; round up to 288 (16-aligned).
 */

#ifndef	_ASM_FRAME_H
#define	_ASM_FRAME_H

#define	TF_RA		0	/* x1 */
#define	TF_SP		8	/* x2 (saved original sp) */
#define	TF_GP		16	/* x3 */
#define	TF_TP		24	/* x4 */
#define	TF_T0		32	/* x5 */
#define	TF_T1		40	/* x6 */
#define	TF_T2		48	/* x7 */
#define	TF_S0		56	/* x8 */
#define	TF_S1		64	/* x9 */
#define	TF_A0		72	/* x10 */
#define	TF_A1		80	/* x11 */
#define	TF_A2		88	/* x12 */
#define	TF_A3		96	/* x13 */
#define	TF_A4		104	/* x14 */
#define	TF_A5		112	/* x15 */
#define	TF_A6		120	/* x16 */
#define	TF_A7		128	/* x17 */
#define	TF_S2		136	/* x18 */
#define	TF_S3		144	/* x19 */
#define	TF_S4		152	/* x20 */
#define	TF_S5		160	/* x21 */
#define	TF_S6		168	/* x22 */
#define	TF_S7		176	/* x23 */
#define	TF_S8		184	/* x24 */
#define	TF_S9		192	/* x25 */
#define	TF_S10		200	/* x26 */
#define	TF_S11		208	/* x27 */
#define	TF_T3		216	/* x28 */
#define	TF_T4		224	/* x29 */
#define	TF_T5		232	/* x30 */
#define	TF_T6		240	/* x31 */
#define	TF_SEPC		248
#define	TF_SSTATUS	256
#define	TF_SCAUSE	264
#define	TF_STVAL	272
#define	TF_SIZE		288	/* 16-byte aligned */

#endif	/* _ASM_FRAME_H */
