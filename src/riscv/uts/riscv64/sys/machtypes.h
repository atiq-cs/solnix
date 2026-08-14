/*
 * CDDL HEADER START
 *
 * The contents of this file are subject to the terms of the
 * Common Development and Distribution License (the "License").
 * You may not use this file except in compliance with the License.
 *
 * You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
 * or http://www.opensolaris.org/os/licensing.
 * See the License for the specific language governing permissions
 * and limitations under the License.
 *
 * When distributing Covered Code, include this CDDL HEADER in each
 * file and include the License file at usr/src/OPENSOLARIS.LICENSE.
 * If applicable, add the following below this CDDL HEADER, with the
 * fields enclosed by brackets "[]" replaced with your own identifying
 * information: Portions Copyright [yyyy] [name of copyright owner]
 *
 * CDDL HEADER END
 */

/*
 * machtypes.h — riscv64 machine-dependent types for illumos
 * <sys/machtypes.h> (the gate path is uts/riscv64/sys/machtypes.h).
 *
 * illumos requires a per-architecture <sys/machtypes.h> defining the lock
 * primitive types and the label_t (setjmp/longjmp save area). This is the
 * riscv64 analog of uts/intel/sys/machtypes.h and uts/sparc/sys/machtypes.h,
 * written to the RISC-V LP64D psABI (callee-saved register set) and the
 * illumos lock ABI.
 */

#ifndef	_SYS_MACHTYPES_H
#define	_SYS_MACHTYPES_H

#include <sys/feature_tests.h>

#ifdef	__cplusplus
extern "C" {
#endif

#if !defined(_ASM)

/*
 * Common definitions for lock and mutex types used across illumos.
 *
 * lock_t is the byte-sized spin-lock primitive backed by RISC-V amoswap.b /
 * lr.d + sc.d in uts/riscv/ml/lock_prim.s. It MUST be a single byte so the
 * dispatcher's per-cpu lock arrays and the adaptive-mutex owner field match
 * the MI expectations (like every other illumos arch).
 */
typedef	unsigned char	lock_t;		/* simple spin lock */

/*
 * The label_t is the setjmp()/longjmp() / on_fault() register save area.
 * On riscv64 the callee-saved state a non-local jump must restore is:
 *   ra  (x1)   return address
 *   sp  (x2)   stack pointer
 *   s0..s11 (x8,x9,x18..x27)  the 12 callee-saved integer registers
 *   gp  (x3)   global pointer  (preserved for kernel/rtld)
 *   tp  (x4)   thread pointer  (preserved)
 * That is 2 + 12 + 2 = 16 XLEN-wide slots. Callee-saved FP registers
 * (fs0..fs11, fcsr) are saved by the FPU ctxop, not label_t, matching the
 * illumos convention that label_t holds only the integer non-local-goto set.
 *
 * We size the array generously (at LABEL_NGREG) and index it symbolically in
 * uts/riscv/ml/setjmp.s so the layout is asserted in one place.
 */
#define	LABEL_NGREG	16

typedef struct _label_t {
	long	val[LABEL_NGREG];
} label_t;

#endif	/* !_ASM */

/* Symbolic indices into label_t.val[] (kept in sync with setjmp.s). */
#define	LABEL_RA	0
#define	LABEL_SP	1
#define	LABEL_GP	2
#define	LABEL_TP	3
#define	LABEL_S0	4	/* s0..s11 occupy slots 4..15 */

/*
 * Reset vector / boot magic and the maximum number of harts (CPUs) this port
 * supports at bring-up. MAXCPU here matches the secondary_stacks pool sizing
 * in locore.S (8 harts total = 1 boot + 7 secondaries for the K1 8-core X60).
 */
#define	NCPU		8
#define	MAXCPU		NCPU

#ifdef	__cplusplus
}
#endif

#endif	/* _SYS_MACHTYPES_H */
