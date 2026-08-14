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
 * Gate-shape shim for the sgs libld interfaces the EM_RISCV machrel backend
 * (machrel.riscv.c) wires into.  In the real gate these declarations come from
 *   usr/src/cmd/sgs/include/{libld.h,_libld.h,machdep.h}
 *   usr/src/uts/common/krtld/reloc.h
 *   usr/src/head/sys/elf.h
 * and machrel.riscv.c compiles against them exactly as machrel.amd64.c /
 * machrel.sparc.c do.  It is reproduced here (field-order-faithful to the gate)
 * so the RISC-V backend compiles + self-tests standalone, before it is dropped
 * into a real sgs tree.  Every struct here is the gate struct trimmed to the
 * members the RISC-V backend touches; the member NAMES and TYPES match the gate
 * so the file is a drop-in.
 *
 * CRIB PROVENANCE (all illumos-gate, not invented):
 *   - Rel_desc / Rel_aux, Sym_desc, Ofl_desc, Os_desc, Is_desc field names +
 *     the FLG_REL_* / rel_flags bits: usr/src/cmd/sgs/include/_libld.h.
 *   - Gotndx / Gotref (GOT_REF_*) + Sym_aux->sa_PLTndx/sa_PLTGOTndx PLT slot
 *     bookkeeping: _libld.h + machrel.amd64.c ld_assign_got / ld_reloc_local.
 *   - ld_do_activerelocs / ld_reloc_local / ld_add_actrel / ld_reloc_targval_*
 *     / ld_assign_got_ndx signatures: machrel.amd64.c / machrel.sparc.c.
 *   - Rel_entry (reloc classification) + reloc_table[] convention:
 *     _libld.h + machrel.<mach>.c reloc_table[].
 */

#ifndef	_LIBLD_SHIM_H
#define	_LIBLD_SHIM_H

#include	<stdint.h>
#include	<stddef.h>

/* sgs base scalar types (usr/src/head/sys/elf.h + sgs sys/machelf.h). */
typedef uint64_t	Xword;
typedef int64_t		Sxword;
typedef uint32_t	Word;
typedef uint64_t	Addr;
typedef uint64_t	Off;
typedef unsigned char	uchar_t;
typedef int		Boolean;	/* sgs uses int TRUE/FALSE */

#ifndef	TRUE
#define	TRUE	1
#endif
#ifndef	FALSE
#define	FALSE	0
#endif

/*
 * sgs return codes (usr/src/cmd/sgs/include/_libld.h): the reloc-processing
 * passes return S_ERROR on a hard error, 1 on success, 0 to skip.
 */
#define	S_ERROR		(-1)

/*
 * Rel_entry -- one row of the per-machine reloc classification table.  Field
 * order matches _libld.h { re_mask, re_flags, re_fsize, re_bshift, re_sigbits }.
 * The RISC-V table lives in machrel.riscv.c as reloc_table[].
 */
typedef struct {
	Xword	re_mask;
	Word	re_flags;
	uchar_t	re_fsize;
	uchar_t	re_bshift;
	uchar_t	re_sigbits;
} Rel_entry;

/* FLG_RE_* reloc-attribute bits (subset RISC-V uses), from _libld.h. */
#define	FLG_RE_NOTREL		0x00000001
#define	FLG_RE_PCREL		0x00000002
#define	FLG_RE_GOTADD		0x00000004
#define	FLG_RE_PLTREL		0x00000008
#define	FLG_RE_TLSINS		0x00000010
#define	FLG_RE_INSREL		0x00000020	/* splices into an insn immediate */
#define	FLG_RE_NOTSUP		0x00000040
#define	FLG_RE_GOTPC		0x00000080

/*
 * GOT reference kind (Gotref in _libld.h).  A symbol may need distinct GOT
 * entries for a plain address vs a TLS model; the RISC-V backend uses the
 * general and TLS-IE references.
 */
typedef enum {
	GOT_REF_GENERIC = 0,
	GOT_REF_TLSIE,
	GOT_REF_TLSGD,
	GOT_REF_TLSLD
} Gotref;

/*
 * Gotndx -- one GOT-slot record hung off a Sym_desc (_libld.h).  A symbol
 * referenced by several relocs of the same Gotref shares one slot (idempotent
 * assignment); gn_gotndx is the slot index, gn_addend disambiguates addends.
 */
typedef struct {
	Gotref	gn_gotref;
	Sxword	gn_addend;
	Word	gn_gotndx;
	Word	gn_gotalign;
} Gotndx;

/*
 * Sym_aux / Sym_desc -- the link-editor's per-symbol descriptor (_libld.h,
 * trimmed).  sd_symndx/sd_name identify it; sd_GOTndxs is the list of GOT slots
 * (here a small fixed array + count instead of the gate's APlist, which is all
 * the RISC-V allocator needs); sd_aux carries PLT bookkeeping.
 */
#define	SYM_MAX_GOT	4

typedef struct sym_aux {
	Word	sa_PLTndx;	/* .plt entry index (M_PLT_NULL if none) */
	Word	sa_PLTGOTndx;	/* .got.plt entry index */
} Sym_aux;

typedef struct sym_desc {
	const char	*sd_name;
	Word		sd_symndx;
	Word		sd_flags;	/* FLG_SY_* */
	Addr		sd_value;	/* resolved st_value (S) */
	Gotndx		sd_GOTndxs[SYM_MAX_GOT];
	Word		sd_nGOT;	/* count of live sd_GOTndxs */
	Sym_aux		*sd_aux;
} Sym_desc;

#define	FLG_SY_LOCAL	0x0001
#define	FLG_SY_PLTPAD	0x0002

#define	M_PLT_NULL	((Word)-1)

/*
 * Os_desc / Is_desc -- output/input section descriptors (_libld.h, trimmed).
 * The RISC-V backend needs the output data pointer + shdr addr/offset to place
 * a relocation target and to compute P (the reloc site address).
 */
typedef struct os_desc {
	uint8_t	*os_outdata;	/* mapped output section bytes */
	Addr	os_shaddr;	/* output section run address */
	Off	os_shoff;	/* output section file offset */
} Os_desc;

typedef struct is_desc {
	uint8_t	*is_indata;	/* input section bytes */
	Os_desc	*is_osdesc;	/* the output section it maps into */
	Off	is_offset;	/* offset of this input sec in the output sec */
} Is_desc;

/*
 * Rel_aux -- the auxiliary reloc info split out of Rel_desc in modern gates
 * (_libld.h).  Carries the target output section + the symbol.
 */
typedef struct rel_aux {
	Os_desc	*ra_osdesc;	/* output section the reloc writes into */
	Word	ra_typedata;	/* ELF_R_TYPE_DATA (RISC-V: unused, 0) */
} Rel_aux;

/*
 * Rel_desc -- the link-editor's active-relocation descriptor (_libld.h,
 * trimmed to what the RISC-V backend reads).  This is the unit ld_reloc_local /
 * ld_do_activerelocs iterate over.
 *
 *   rel_rtype   R_RISCV_* type
 *   rel_roffset offset of the reloc site within its input section
 *   rel_raddend explicit addend (A)
 *   rel_sym     the referenced Sym_desc (S via sd_value)
 *   rel_isdesc  the input section holding the site
 *   rel_aux     target output section (ra_osdesc)
 *   rel_flags   FLG_REL_* processing flags
 */
typedef struct rel_desc {
	Word		rel_rtype;
	Xword		rel_roffset;
	Sxword		rel_raddend;
	Sym_desc	*rel_sym;
	Is_desc		*rel_isdesc;
	Rel_aux		*rel_aux;
	Word		rel_flags;
} Rel_desc;

#define	FLG_REL_GOT	0x0001	/* reloc against the GOT */
#define	FLG_REL_PLT	0x0002	/* reloc against a PLT entry */
#define	FLG_REL_LOAD	0x0004	/* section is loadable */

/*
 * Ofl_desc -- the output-file descriptor (_libld.h, trimmed).  The RISC-V
 * backend needs the GOT/PLT sizes it is growing + a place to hang the per-file
 * pcrel-pairing table (ofl_riscv_pcrel), and ofl_flags for the link mode.
 */
typedef struct ofl_desc {
	Word	ofl_flags;
	Xword	ofl_gotcnt;	/* # of .got slots allocated */
	Xword	ofl_pltcnt;	/* # of .plt entries allocated */
	Os_desc	*ofl_osgot;	/* .got output section */
	Os_desc	*ofl_osplt;	/* .plt output section */
	Os_desc	*ofl_osgotplt;	/* .got.plt output section */
	void	*ofl_riscv_pcrel;	/* Riscv_pcrel_htab (per-file) */
} Ofl_desc;

#define	FLG_OF_EXEC	0x0001
#define	FLG_OF_SHAROBJ	0x0002
#define	FLG_OF_RELOBJ	0x0004	/* ld -r */

#endif	/* _LIBLD_SHIM_H */
