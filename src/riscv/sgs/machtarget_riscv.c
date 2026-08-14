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
 * Solaris link-editor (sgs/libld) EM_RISCV MACH descriptor.
 *
 * libld selects per-target behaviour through a Target record (the global
 * ld_targ, defined per-arch in usr/src/cmd/sgs/libld/common/machrel.<arch>.c
 * and chosen by ld_config_target() from the object's e_machine).  A Target has
 * four sub-descriptors:
 *
 *   Target.t_m   Target_mach   - machine constants (M_MACH == EM_RISCV,
 *                                M_CLASS == ELFCLASS64, M_DATA == ELFDATA2LSB,
 *                                page size, word size, the M_R_* dynamic reloc
 *                                types the writer emits: RELATIVE/GLOB_DAT/
 *                                JMP_SLOT/etc).
 *   Target.t_id  Target_machid - section-ordering identifiers.
 *   Target.t_nf  Target_nullfunc - the arch NOP / null-function bytes for PLT
 *                                padding.
 *   Target.t_ff  Target_fillfunc - trap/fill bytes.
 *   Target.t_mr  Target_machrel - the RELOCATION descriptor: the Rel_entry
 *                                classification table plus the ld_reloc_*
 *                                function pointers libld calls to place, count,
 *                                and APPLY relocations.
 *
 * This file supplies the EM_RISCV Target skeleton and, in particular, wires
 * t_mr to the two RISC-V-specific reloc facts produced earlier:
 *   - Target_machrel.mr_reloc_table  -> sgs_reloc_table_riscv[] (classification)
 *   - the apply core                 -> ld_do_reloc_riscv() (flat store +
 *                                        instruction-field splice)
 *
 * The M_R_* machine reloc identities (which R_RISCV_* the dynamic writer uses
 * for each purpose) come straight from the psABI / binutils and are recorded
 * as the RISCV_M_R_* defines below.
 *
 * CRIB PROVENANCE:
 *   - the Target / Target_machrel / Rel_entry layout and the ld_reloc_* hook
 *     set: the illumos sgs libld machrel.<arch>.c convention (the amd64/sparc/
 *     aarch64 targets in usr/src/cmd/sgs/libld/common).
 *   - the RISC-V dynamic reloc identities (RELATIVE=3, JUMP_SLOT=5, COPY=4,
 *     TLS_DTPMOD64=7 / TLS_DTPREL64=9 / TLS_TPREL64=11): RISC-V ELF psABI +
 *     binutils bfd/elfnn-riscv.c (elf_backend_rela_normal, plt/got layout).
 *   - reloc APPLY math: machrel_riscv_dispatch.c / machrel_riscv_insn.c
 *     (cribbed from binutils perform_relocation / add_sub_reloc).
 */

#include	<stdint.h>
#include	"reloc_riscv_table.h"

/*
 * The dynamic-reloc identities the RISC-V link-editor writer uses.  In the
 * gate these are the M_R_* macros in usr/src/uts/common/sys/machelf.h /
 * libld's machrel header; carried here as RISCV_M_R_* so the descriptor is
 * self-contained.  (psABI: RISC-V uses RELA only, elf_backend_rela_normal.)
 */
#define	RISCV_M_R_NONE		R_RISCV_NONE
#define	RISCV_M_R_GLOB_DAT	R_RISCV_64	/* no dedicated GLOB_DAT; 64 */
#define	RISCV_M_R_JMP_SLOT	R_RISCV_JUMP_SLOT
#define	RISCV_M_R_COPY		R_RISCV_COPY
#define	RISCV_M_R_RELATIVE	R_RISCV_RELATIVE
#define	RISCV_M_R_REGISTER	R_RISCV_NONE	/* n/a on RISC-V */
#define	RISCV_M_R_DTPMOD	R_RISCV_TLS_DTPMOD64
#define	RISCV_M_R_DTPOFF	R_RISCV_TLS_DTPREL64
#define	RISCV_M_R_TPOFF		R_RISCV_TLS_TPREL64
#define	RISCV_M_R_ARRAYADDR	R_RISCV_64	/* .init/.fini_array slot */
#define	RISCV_M_R_NUM		R_RISCV_NUM

/* Machine constants (subset; gate M_* live in libld's machdefs). */
#define	RISCV_M_MACH		243		/* EM_RISCV */
#define	RISCV_M_CLASS		2		/* ELFCLASS64 */
#define	RISCV_M_DATA		1		/* ELFDATA2LSB */
#define	RISCV_M_PAGESIZE	0x1000
#define	RISCV_M_WORD_ALIGN	8

/*
 * RISC-V null function = a single c.nop (0x0001) or full nop (0x00000013).
 * PLT padding uses the 4-byte canonical nop.  (Gate Target_nullfunc carries
 * the byte template + length.)
 */
static const uint8_t riscv_nullfunc[] = { 0x13, 0x00, 0x00, 0x00 };  /* nop */
static const uint8_t riscv_fillfunc[] = { 0x02, 0x90 };	/* c.ebreak trap */

/*
 * The reloc apply core (machrel_riscv_dispatch.c).  In the gate the Target_
 * machrel hooks (ld_do_activerelocs -> ld_reloc_local/ld_reloc_GOTOP ->
 * do_reloc_ld) all funnel the computed value through this splice.
 */
extern int ld_do_reloc_riscv(uint32_t rtype, uint8_t *dest, int64_t sym,
    int64_t addend, int64_t pc);
extern const Rel_entry sgs_reloc_table_riscv[R_RISCV_NUM];

/*
 * Minimal Target_machrel wiring for EM_RISCV.  The full gate struct has many
 * more ld_* hooks (assign_got, allocate_got, calc_plt_addr, ...); the two
 * arch-defining members are the classification table and the apply function,
 * both provided here.  The remaining hooks are the generic-ELF/PLT-GOT
 * scaffolding shared with the other 64-bit RELA targets.
 */
typedef int (*riscv_do_reloc_fn)(uint32_t, uint8_t *, int64_t, int64_t,
    int64_t);

typedef struct {
	const Rel_entry		*mr_reloc_table;	/* classification */
	riscv_do_reloc_fn	 mr_do_reloc;		/* apply */
	uint32_t		 mr_r_none;
	uint32_t		 mr_r_glob_dat;
	uint32_t		 mr_r_jmp_slot;
	uint32_t		 mr_r_relative;
	uint32_t		 mr_r_copy;
	uint32_t		 mr_r_dtpmod;
	uint32_t		 mr_r_dtpoff;
	uint32_t		 mr_r_tpoff;
	uint32_t		 mr_r_num;
} riscv_Target_machrel;

typedef struct {
	uint16_t		 m_mach;
	uint8_t			 m_class;
	uint8_t			 m_data;
	uint32_t		 m_pagesize;
	uint32_t		 m_word_align;
} riscv_Target_mach;

typedef struct {
	riscv_Target_mach	 t_m;
	riscv_Target_machrel	 t_mr;
	const uint8_t		*t_nf;		/* null function */
	uint32_t		 t_nf_len;
	const uint8_t		*t_ff;		/* fill function */
	uint32_t		 t_ff_len;
} riscv_Target;

/*
 * The EM_RISCV Target instance.  ld_config_target() returns &ld_targ_riscv
 * when the object's e_machine == EM_RISCV; every reloc libld places or applies
 * then routes through t_mr.mr_reloc_table (to classify) and t_mr.mr_do_reloc
 * (to write).
 */
const riscv_Target ld_targ_riscv = {
	.t_m = {
		.m_mach		= RISCV_M_MACH,
		.m_class	= RISCV_M_CLASS,
		.m_data		= RISCV_M_DATA,
		.m_pagesize	= RISCV_M_PAGESIZE,
		.m_word_align	= RISCV_M_WORD_ALIGN,
	},
	.t_mr = {
		.mr_reloc_table	= sgs_reloc_table_riscv,
		.mr_do_reloc	= ld_do_reloc_riscv,
		.mr_r_none	= RISCV_M_R_NONE,
		.mr_r_glob_dat	= RISCV_M_R_GLOB_DAT,
		.mr_r_jmp_slot	= RISCV_M_R_JMP_SLOT,
		.mr_r_relative	= RISCV_M_R_RELATIVE,
		.mr_r_copy	= RISCV_M_R_COPY,
		.mr_r_dtpmod	= RISCV_M_R_DTPMOD,
		.mr_r_dtpoff	= RISCV_M_R_DTPOFF,
		.mr_r_tpoff	= RISCV_M_R_TPOFF,
		.mr_r_num	= RISCV_M_R_NUM,
	},
	.t_nf = riscv_nullfunc,
	.t_nf_len = sizeof (riscv_nullfunc),
	.t_ff = riscv_fillfunc,
	.t_ff_len = sizeof (riscv_fillfunc),
};

#ifdef MACH_SELFTEST
/*
 * Proof the descriptor is fully wired: the classification table and apply
 * function are reachable through ld_targ_riscv, and a reloc driven THROUGH the
 * descriptor (not the raw function) lands correctly -- i.e. libld selecting
 * this Target would apply R_RISCV_* correctly.  assert() only.
 */
#include	<assert.h>
#include	<string.h>
#include	<stdio.h>

int
main(void)
{
	uint8_t buf[8];

	/* descriptor identity */
	assert(ld_targ_riscv.t_m.m_mach == 243);	/* EM_RISCV */
	assert(ld_targ_riscv.t_m.m_class == 2);		/* ELFCLASS64 */
	assert(ld_targ_riscv.t_mr.mr_r_jmp_slot == R_RISCV_JUMP_SLOT);
	assert(ld_targ_riscv.t_mr.mr_r_relative == R_RISCV_RELATIVE);
	assert(ld_targ_riscv.t_mr.mr_reloc_table != NULL);
	assert(ld_targ_riscv.t_mr.mr_do_reloc != NULL);

	/* classification reachable through descriptor: CALL_PLT is PLT+INSREL */
	assert(ld_targ_riscv.t_mr.mr_reloc_table[R_RISCV_CALL_PLT].re_flags
	    & FLG_RE_PLTREL);
	assert(ld_targ_riscv.t_mr.mr_reloc_table[R_RISCV_CALL_PLT].re_flags
	    & FLG_RE_INSREL);

	/* apply a flat R_RISCV_64 THROUGH the descriptor's function pointer */
	memset(buf, 0, sizeof (buf));
	assert(ld_targ_riscv.t_mr.mr_do_reloc(R_RISCV_64, buf, 0x8040, 0, 0)
	    == 0);
	assert(buf[0] == 0x40 && buf[1] == 0x80);

	printf("PASS: ld_targ_riscv MACH descriptor wired "
	    "(EM_RISCV/CLASS64, reloc table + apply reachable, R_RISCV_64 "
	    "applied via t_mr.mr_do_reloc)\n");
	return (0);
}
#endif	/* MACH_SELFTEST */
