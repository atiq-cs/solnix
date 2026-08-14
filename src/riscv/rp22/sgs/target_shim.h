/*
 * target_shim.h -- the sgs libld Target-dispatch interface, reproduced
 * field-order-faithful to the gate so the EM_RISCV machrel backend can be
 * SELECTED by e_machine the way the illumos native ld does it.
 *
 * In the real gate this is usr/src/cmd/sgs/libld/common/_libld.h (the Target
 * struct, the ld_targ global) + libld.h (the ld_targ_init_* prototypes) +
 * target.c (ld_config_target()).  The gate is not checked out on this host, so
 * this shim reproduces exactly those declarations (names + member order match
 * the gate) around the R-P21 machrel.riscv.c entry points, and provides a
 * faithful ld_config_target() so the selection path is exercised end to end.
 *
 * CRIB PROVENANCE (all illumos-gate, not invented):
 *   - the Target struct with the t_m (Machine: m_mach/m_class/m_data/...),
 *     and t_mr (Target_machrel: mr_reloc_table + the mr_* backend function
 *     pointers ld_reloc_local/ld_do_activerelocs/ld_assign_got_ndx/...)
 *     sub-structs: usr/src/cmd/sgs/libld/common/_libld.h.
 *   - the single "Target ld_targ;" global + ld_config_target()'s
 *     "switch (mach) { case EM_x: ld_targ = init_x(); }" dispatch:
 *     usr/src/cmd/sgs/libld/common/target.c + machrel.MACH.c
 *     ld_targ_init_MACH() convention (amd64/sparc/i386).
 *   - EM_RISCV = 243 (the psABI e_machine).
 */
#ifndef _RP22_TARGET_SHIM_H
#define _RP22_TARGET_SHIM_H

#include "_libld_shim.h"

#ifndef _RP22_HALF_DEFINED
#define _RP22_HALF_DEFINED
typedef unsigned short	Half;	/* ELF Elf64_Half (e_machine) */
#endif

#ifndef EM_RISCV
#define	EM_RISCV	243
#endif
#ifndef EM_X86_64
#define	EM_X86_64	62
#endif

/*
 * Target_mach -- the machine descriptor sub-struct (gate Target.t_m).  Only
 * the members the selection path + the backend consult are reproduced.
 */
typedef struct {
	Half		m_mach;		/* e_machine this Target serves */
	Half		m_machplus;	/* alternate e_machine (0 if none) */
	Word		m_flagsplus;	/* e_flags OR-ed for m_machplus */
	Word		m_class;	/* ELFCLASS64 */
	Word		m_data;		/* ELFDATA2LSB */

	Word		m_segm_align;	/* segment / page alignment */
	Word		m_word_align;	/* natural word alignment */

	Word		m_r_copy;	/* R_*_COPY */
	Word		m_r_glob_dat;	/* R_*_GLOB_DAT */
	Word		m_r_jmp_slot;	/* R_*_JUMP_SLOT */
	Word		m_r_num;	/* R_*_NUM */
	Word		m_r_none;	/* R_*_NONE */
	Word		m_r_relative;	/* R_*_RELATIVE */
	Word		m_r_register;	/* R_*_REGISTER (0 on riscv) */
} Target_mach;

/*
 * Target_machrel -- the relocation backend sub-struct (gate Target.t_mr).
 * The mr_* function pointers ARE the R-P21 machrel.riscv.c entry points; this
 * is what ld dispatches through once ld_targ is selected.
 */
typedef struct {
	const Rel_entry	*mr_reloc_table;
	uintptr_t	(*mr_reloc_local)(Rel_desc *, Ofl_desc *);
	uintptr_t	(*mr_do_activerelocs)(Rel_desc *, Word, Ofl_desc *);
	Gotndx *	(*mr_assign_got_ndx)(Sym_desc *, Gotref, Sxword,
			    Ofl_desc *);
	uintptr_t	(*mr_finish_pcrel)(Ofl_desc *);
} Target_machrel;

/*
 * Target -- the top-level per-machine descriptor ld_targ.  (Gate: also has
 * t_id / t_ver / t_uts substructs; trimmed here to the machine + machrel parts
 * the selection + reloc path use.)
 */
typedef struct {
	Target_mach	t_m;
	Target_machrel	t_mr;
} Target;

/* the single global the whole linker consults, exactly as the gate names it */
extern Target ld_targ;

/* per-machine initialisers (gate: machrel.MACH.c ld_targ_init_MACH()) */
extern const Target *ld_targ_init_riscv(void);

/* the selection entry point (gate: libld/common/target.c) */
extern int ld_config_target(Half mach);

#endif /* _RP22_TARGET_SHIM_H */
