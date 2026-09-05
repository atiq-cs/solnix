/*
 * asm_frame.h — trap frame byte offsets shared by trap.S and trap.c (R-P3).
 *
 * The layout must match struct regs in trap.c exactly. Each field is 8 bytes.
 * Order is x1..x31 in register-number order (x0/zero is not stored), followed
 * by the four trap CSRs. TF_SIZE is padded to a 16-byte-aligned total so sp
 * stays ABI-aligned after `addi sp, sp, -TF_SIZE`.
 *
 * 31 GPRs + 4 CSRs = 35 slots * 8 = 280 bytes; round up to 288 (16-aligned).
 * The one word of alignment padding is not waste: it is TF_CPUID, the kernel's
 * per-hart id parked where a trap from U-mode can reload it (see below).
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
/*
 * TF_CPUID — the KERNEL's per-hart id, parked in the trap frame's alignment pad.
 *
 * WHY THIS EXISTS. RISC-V reserves tp (x4) for the userland thread pointer, and
 * the TLS ABI requires tp to point at the running thread's TLS block, so
 * userland MUST own tp in U-mode. The kernel also wants a per-hart id in a
 * single register (this_cpu() is on the hot path of every dispatch decision).
 * Both can hold if the meaning of tp is split by privilege: userland's thread
 * pointer in U-mode, the kernel's per-hart id in S-mode, swapped at the U/S
 * boundary. TF_CPUID is where the S-mode value waits while U-mode runs.
 *
 * The slot is at TF_SIZE-8 from the frame base, i.e. at kstacktop-8, because the
 * U-trap frame is always built at (sscratch - TF_SIZE) and sscratch is the
 * kernel stack top. So the writer (a return to U, or usermode_entry) and the
 * reader (the next trap from U on the same thread) address the same word without
 * needing to agree on anything but the kernel stack top they already share.
 *
 * WHY NOT A CSR. sscratch is the only general-purpose S-mode scratch CSR, and it
 * is already the U/S kernel-stack discriminator: the trap entry relies on it
 * being exactly 0 in S-mode, so it cannot also carry a nonzero hart id there.
 * Packing the id into sscratch's low bits (the shape an older revision of this
 * port used) forces the trap entry to mask a GPR out of the swapped-in value
 * BEFORE any GPR has been saved to the frame -- which is precisely the
 * register-save ordering hazard the x5/t0 comment in trap.S exists to prevent.
 * A frame slot needs no scratch register at all and leaves sscratch's meaning
 * byte-for-byte as it was.
 */
#define	TF_CPUID	280
/*
 * The same slot addressed from the kernel stack TOP rather than the frame base,
 * for code that holds kstacktop but has not built a frame (usermode_entry).
 */
#define	TF_CPUID_FROM_KSTACKTOP	(TF_CPUID - TF_SIZE)
#define	TF_SIZE		288	/* 16-byte aligned */

#endif	/* _ASM_FRAME_H */
