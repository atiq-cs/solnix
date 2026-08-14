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
 * genassym.c -- RISC-V (riscv64) illumos kernel assembly-offset generator.
 *
 * The MD assembly (locore.S, trap.S, swtch.S, setjmp.s) reaches into C structs
 * by numeric byte offset -- e.g. swtch.S does `sd ra, C_RA(a0)` into a
 * `struct rv_context`, trap.S builds a `struct regs` at TF_* offsets, and
 * setjmp.s indexes label_t at LABEL_*.  Those offsets MUST match the C struct
 * layout the compiler chooses.  Today they are hand-maintained in swtch.S /
 * asm_frame.h / machtypes.h and merely GUARDED by _Static_asserts in the C
 * files.  genassym replaces the hand-maintenance: it compiles the ACTUAL C
 * structs and emits an assym.h whose #defines are, by construction, the
 * compiler's real offsets.  This is the illumos uts genassym idiom.
 *
 * Mechanism (freestanding -- runs at build time as a cross object, no libc):
 * for each wanted value we emit a specially-formatted line into a dedicated
 * section via inline asm, embedding the compiler-computed constant as an
 * immediate.  A tiny post-processing script (genassym.sh) extracts those lines
 * into `#define NAME value`.  This is exactly how the gate + BSD genassym work
 * (the compiler does the offsetof arithmetic; the toolchain just needs to be
 * able to place an integer constant in the output -- no execution needed).
 *
 * CRIB PROVENANCE:
 *   - the OFFSET/SIZE/ASSYM "let the compiler compute struct offsets, emit
 *     them as assembler defines" mechanism: illumos usr/src/uts genassym.c
 *     files + sys/assym.h, and the equivalent BSD sys/arch/riscv/riscv/
 *     genassym.cf.
 *   - the struct definitions: the R-P1..R-P16 illumos riscv64 MD tree
 *     (struct regs -> regs.h, struct rv_context -> proc.c, label_t ->
 *     sys/machtypes.h) -- the same structs the .S files consume.
 *   - the "emit constant into a section, sed it back out" freestanding trick:
 *     the classic genassym.sh pipeline (works without a runnable target libc,
 *     essential for a cross build).
 *
 * The emitted header (assym.h) is the authoritative source the .S files should
 * include instead of carrying their own C_x / TF_x / LABEL_x copies.
 */

#include	<stddef.h>	/* offsetof */

/*
 * The MD structs, as the kernel sees them.  (In-gate these come via the real
 * uts headers; carried inline here so the generator is self-contained and
 * compiles against the bootstrap sysroot.)
 */
struct regs {
	unsigned long r_ra, r_sp, r_gp, r_tp;
	unsigned long r_t0, r_t1, r_t2;
	unsigned long r_s0, r_s1;
	unsigned long r_a0, r_a1, r_a2, r_a3, r_a4, r_a5, r_a6, r_a7;
	unsigned long r_s2, r_s3, r_s4, r_s5, r_s6, r_s7, r_s8, r_s9, r_s10,
	    r_s11;
	unsigned long r_t3, r_t4, r_t5, r_t6;
	unsigned long r_sepc, r_sstatus, r_scause, r_stval;
};

struct rv_context {
	unsigned long c_ra, c_sp, c_tp;
	unsigned long c_s[12];			/* s0..s11 */
	unsigned long c_satp;
	unsigned long c_lofault;
};

#define	LABEL_NGREG	16
typedef struct _label_t {
	long	val[LABEL_NGREG];
} label_t;

/*
 * Emit one "define" record: the string NAME followed by the integer VALUE, in
 * a dedicated ".assym" section, framed by sentinels the extraction script
 * greps for.  The value is a compile-time constant, so the compiler folds it
 * to an immediate -- no runtime, no libc.
 */
#define	ASSYM(name, value) \
	__asm__ __volatile__ ( \
	    "\n.pushsection .assym,\"\",@progbits\n" \
	    "\t.asciz \"@ASSYM@ " #name " %0\"\n" \
	    ".popsection\n" \
	    : : "i" ((long)(value)))

#define	OFFSET(s, m)	ASSYM(s##_##m, offsetof(struct s, m))
#define	SIZE(s)		ASSYM(s##_SIZE, sizeof (struct s))

/*
 * The generator "body".  It is never called; the ASSYM records land in the
 * .assym section at compile time.  Marking it used keeps it in the object.
 */
void
genassym(void)
{
	/* struct regs (trap frame) -- consumed by trap.S at TF_* offsets. */
	OFFSET(regs, r_ra);
	OFFSET(regs, r_sp);
	OFFSET(regs, r_gp);
	OFFSET(regs, r_tp);
	OFFSET(regs, r_a0);
	OFFSET(regs, r_a7);
	OFFSET(regs, r_sepc);
	OFFSET(regs, r_sstatus);
	OFFSET(regs, r_scause);
	OFFSET(regs, r_stval);
	SIZE(regs);

	/* struct rv_context -- consumed by swtch.S at C_* offsets. */
	OFFSET(rv_context, c_ra);
	OFFSET(rv_context, c_sp);
	OFFSET(rv_context, c_tp);
	OFFSET(rv_context, c_satp);
	OFFSET(rv_context, c_lofault);
	/* c_s[0] and c_s[11] bound the callee-saved slot range. */
	ASSYM(rv_context_c_s0, offsetof(struct rv_context, c_s[0]));
	ASSYM(rv_context_c_s11, offsetof(struct rv_context, c_s[11]));
	SIZE(rv_context);

	/* label_t (setjmp/longjmp save area) -- consumed by setjmp.s. */
	ASSYM(LABEL_RA, offsetof(label_t, val[0]));
	ASSYM(LABEL_SP, offsetof(label_t, val[1]));
	ASSYM(LABEL_S0, offsetof(label_t, val[4]));
	ASSYM(label_t_SIZE, sizeof (label_t));
}
