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
 * The first illumos uts/riscv64 kernel object.
 *
 * This is a real (if trivial) loadable-module unit compiled with the RISC-V
 * cross toolchain against the illumos riscv64 machine-dependent headers
 * (<sys/isa_defs.h> riscv64 stanza + <sys/machtypes.h>).  The point is not the
 * module's behaviour but that:
 *
 *   1. the riscv64 MD headers compile in a kernel (_KERNEL, freestanding)
 *      compilation, selecting the correct ISA model (LP64, _LITTLE_ENDIAN,
 *      _ALIGNMENT_REQUIRED, label_t = 16 XLEN slots), and
 *   2. the object it produces is a valid EM_RISCV (243) ET_REL ELF64-LSB
 *      illumos kernel object -- the substrate every real uts/riscv64 module
 *      (unix, genunix, drivers) will be built as.
 *
 * It also carries a genassym-style set of compile-time asserts over the MD
 * types so a wrong label_t layout / data model / endianness fails the BUILD,
 * not a mysterious runtime trap later.
 *
 * In the gate this compiles as uts/riscv64/<mod>/<mod>.c through the standard
 * kmod build; here it is built freestanding with the R-P17 cross gcc to prove
 * the EM_RISCV object shape, pending the riscv64-solaris toolchain + sysroot.
 */

#define	_KERNEL
#define	_ASM_INLINES

#include <sys/isa_defs.h>
#include <sys/machtypes.h>

/*
 * Minimal in-object typedefs the module uses (the gate pulls these from
 * <sys/types.h>; kept local so the object builds before a riscv64 sysroot).
 */
typedef unsigned long	ulong_t;
typedef unsigned int	uint_t;
typedef int		int_t;

/*
 * Compile-time validation of the riscv64 MD contract.  Any drift in the ISA
 * model or the label_t save-area layout is a build error here.
 */
_Static_assert(sizeof (void *) == 8, "riscv64 must be LP64 (8-byte pointer)");
_Static_assert(sizeof (long) == 8, "riscv64 long must be 64-bit");
_Static_assert(sizeof (int) == 4, "riscv64 int must be 32-bit");
_Static_assert(sizeof (lock_t) == 1, "lock_t must be a single byte");
_Static_assert(sizeof (label_t) == LABEL_NGREG * sizeof (long),
    "label_t must be LABEL_NGREG XLEN-wide slots");
_Static_assert(LABEL_NGREG == 16, "riscv64 label_t = ra+sp+gp+tp+s0..s11");
#ifndef _LITTLE_ENDIAN
#error "riscv64 illumos must be little-endian"
#endif
#ifndef _ALIGNMENT_REQUIRED
#error "riscv64 must set _ALIGNMENT_REQUIRED (misaligned access may trap)"
#endif
#if _MAX_ALIGNMENT != 16
#error "riscv64 psABI max alignment is 16"
#endif

/*
 * A tiny piece of real code so the object has a .text with RISC-V relocations
 * against a data symbol -- exercising the R_RISCV_HI20/LO12/PCREL/CALL relocs
 * the R-P18 doreloc table + the R-P19 sgs INSREL encoders resolve.
 */
static label_t	riscv64_boot_label;	/* the module's setjmp save area */
uint_t		riscv64_module_id = 0;

/*
 * riscv64_save_context: store a couple of the callee-saved slots into the
 * module's label_t.  Referencing the global label_t + global id forces the
 * compiler to emit auipc/addi (PCREL_HI20/LO12) or lui/addi (HI20/LO12) plus a
 * call, i.e. the exact instruction-field relocs this port must resolve.
 */
int
riscv64_save_context(long ra, long sp)
{
	riscv64_boot_label.val[LABEL_RA] = ra;
	riscv64_boot_label.val[LABEL_SP] = sp;
	riscv64_module_id++;
	return ((int)(riscv64_boot_label.val[LABEL_RA] & 0xff));
}

/*
 * Module init/fini/info -- the illumos modlinkage shape (declared locally to
 * avoid pulling <sys/modctl.h> before the sysroot exists).  Real modules use
 * the gate's mod_install/mod_remove; these stubs give the object the expected
 * _init/_info/_fini entry symbols.
 */
int
_init(void)
{
	return (riscv64_save_context(0, 0));
}

int
_fini(void)
{
	return (0);
}

int
_info(void)
{
	return ((int)riscv64_module_id);
}
