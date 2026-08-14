/*
 * target.c -- the sgs libld Target-dispatch layer for the riscv64 native ld.
 *
 * This is the R-P22.1 piece that RETIRES the GNU-ld crutch: it wires the
 * R-P21 machrel.riscv.c backend (its reloc_table[] + the four entry points)
 * into a real gate-shaped Target descriptor (ld_targ_riscv) and provides the
 * ld_config_target() selection function the illumos native ld calls once per
 * link to pick the backend by the object's e_machine.  For an EM_RISCV object
 * ld_config_target(EM_RISCV) installs ld_targ_riscv into the single global
 * ld_targ, and every subsequent reloc call in the linker dispatches through
 * ld_targ.t_mr.mr_* -- i.e. through machrel.riscv.c, NOT GNU ld.
 *
 * CRIB PROVENANCE (all illumos-gate):
 *   - ld_targ_init_MACH() building a static Target and returning &it, and
 *     ld_config_target() switching on e_machine to select it: the gate
 *     usr/src/cmd/sgs/libld/common/target.c + machrel.amd64.c
 *     ld_targ_init_x86_64() / machrel.sparc.c ld_targ_init_sparc() convention.
 *   - the RISC-V dynamic reloc constants (R_RISCV_RELATIVE=3, COPY=4,
 *     JUMP_SLOT=5, NONE=0, NUM=58): uts/common/sys/elf_riscv.h + the psABI.
 *   - ELFCLASS64 / ELFDATA2LSB, the 4 KiB segment align, 8-byte word align:
 *     the riscv64 psABI (LP64D, little-endian, RV64).
 */

#include "target_shim.h"
#include "reloc_riscv.h"

/* the backend's reloc classification table + entry points (machrel.riscv.c) */
extern const Rel_entry reloc_table[];
extern uintptr_t ld_reloc_local(Rel_desc *, Ofl_desc *);
extern uintptr_t ld_do_activerelocs(Rel_desc *, Word, Ofl_desc *);
extern Gotndx *ld_assign_got_ndx(Sym_desc *, Gotref, Sxword, Ofl_desc *);
extern uintptr_t ld_riscv_finish_pcrel(Ofl_desc *);

#ifndef ELFCLASS64
#define	ELFCLASS64	2
#endif
#ifndef ELFDATA2LSB
#define	ELFDATA2LSB	1
#endif

/*
 * ld_targ_init_riscv -- build (once) and return the EM_RISCV Target.  Mirrors
 * the gate machrel.amd64.c ld_targ_init_x86_64(): a file-static Target filled
 * with the machine descriptor + the machrel backend function pointers.
 */
const Target *
ld_targ_init_riscv(void)
{
	static const Target _ld_targ = {
		{			/* t_m: Target_mach */
			EM_RISCV,	/* m_mach */
			0,		/* m_machplus */
			0,		/* m_flagsplus */
			ELFCLASS64,	/* m_class (RV64) */
			ELFDATA2LSB,	/* m_data (little-endian) */
			0x1000,		/* m_segm_align (4 KiB page) */
			8,		/* m_word_align (LP64) */
			R_RISCV_COPY,		/* m_r_copy */
			R_RISCV_64,		/* m_r_glob_dat (RV uses R_RISCV_64) */
			R_RISCV_JUMP_SLOT,	/* m_r_jmp_slot */
			R_RISCV_NUM,		/* m_r_num */
			R_RISCV_NONE,		/* m_r_none */
			R_RISCV_RELATIVE,	/* m_r_relative */
			0			/* m_r_register (none on riscv) */
		},
		{			/* t_mr: Target_machrel */
			reloc_table,		/* mr_reloc_table */
			ld_reloc_local,		/* mr_reloc_local */
			ld_do_activerelocs,	/* mr_do_activerelocs */
			ld_assign_got_ndx,	/* mr_assign_got_ndx */
			ld_riscv_finish_pcrel	/* mr_finish_pcrel */
		}
	};
	return (&_ld_targ);
}

/*
 * ld_config_target -- SELECT the machine backend for a link by e_machine.
 * The illumos native ld calls this once the first input object's ELF header
 * is read; it installs the matching Target into the single global ld_targ.
 * Returns 1 on a supported machine, 0 otherwise (ld then errors "unsupported
 * ELF machine type", the amd64/sparc default: case).
 */
Target ld_targ;			/* the single global ld consults everywhere */

int
ld_config_target(Half mach)
{
	const Target *t;

	switch (mach) {
	case EM_RISCV:
		t = ld_targ_init_riscv();
		break;
	default:
		return (0);		/* unsupported e_machine */
	}
	ld_targ = *t;
	return (1);
}
