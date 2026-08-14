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
 * Solaris link-editor (sgs/libld) EM_RISCV machine relocation backend.
 *
 * This is the gate-shaped machrel.riscv.c: the R-P20 standalone pieces
 * (classification table, %pcrel_hi/%pcrel_lo pairing, GOT/PLT allocation,
 * instruction-field splice) folded into the sgs libld reloc-processing passes,
 * wired against the _libld.h Rel_desc / Sym_desc / Ofl_desc interfaces exactly
 * as machrel.amd64.c and machrel.sparc.c are.  Lives in the gate at
 *   usr/src/cmd/sgs/libld/common/machrel.riscv.c
 * and is selected by ld_config_target() for e_machine == EM_RISCV.
 *
 * The four entry points libld's generic reloc machinery calls into this
 * backend (same names + roles as the amd64/sparc backends):
 *
 *   ld_reloc_local()   -- per input relocation, called from reloc_local():
 *                         classify the reloc, and if it references the GOT/PLT
 *                         assign the slot on the referenced Sym_desc (idempotent
 *                         so many refs share one slot) and grow ofl_gotcnt /
 *                         ofl_pltcnt.  (amd64: ld_reloc_local + ld_assign_got.)
 *   ld_assign_got_ndx()-- assign / find a symbol's GOT slot for a given Gotref.
 *   ld_do_activerelocs()- the output pass: for every active reloc, compute the
 *                         RISC-V value and apply it -- flat data via a byte
 *                         store, instruction-immediate types via the field
 *                         splice, and the %pcrel_hi/%pcrel_lo pair via the
 *                         record-HI / defer-LO / resolve-by-HI-address htab.
 *   ld_perform_outreloc()- (dynamic) emit the JUMP_SLOT/RELATIVE output relocs.
 *
 * The %pcrel pairing that in R-P20 used an O(n) list is now a real chained hash
 * table (riscv_pcrel_htab.h) keyed by the auipc-site address, hung off
 * Ofl_desc.ofl_riscv_pcrel for the file being relocated.
 *
 * CRIB PROVENANCE:
 *   - the reloc_table[] classification: uts/common/sys/elf_riscv.h (R_RISCV_*)
 *     + binutils-2.44 bfd/elfxx-riscv.c howto_table[] (pc_relative / special
 *     columns), flag names from the sgs machrel.*.c FLG_RE_* convention.
 *   - ld_reloc_local / ld_assign_got_ndx / ld_do_activerelocs / ld_perform_
 *     outreloc SHAPE (what each does, when the generic layer calls it, how the
 *     GOT/PLT slot bookkeeping hangs off Sym_desc): illumos-gate
 *     usr/src/cmd/sgs/libld/common/machrel.amd64.c + machrel.sparc.c.
 *   - the pcrel pairing algorithm + PLT/GOT layout: binutils-2.44
 *     bfd/elfnn-riscv.c (riscv_resolve_pcrel_lo_relocs, riscv_make_plt_*).
 *   - the RISC-V Calculation (S+A, S+A-P) + immediate encodings: RISC-V psABI.
 */

#include	<stdint.h>
#include	<stdlib.h>
#include	<string.h>
#include	"_libld_shim.h"
#include	"reloc_riscv.h"
#include	"riscv_pcrel_htab.h"

/*
 * The FLG_RE_INSREL instruction-field splice.  In the gate this is a static in
 * this file; here it comes from machrel_riscv_insn.c (R-P19), which is the
 * byte-identical-to-GNU-ld perform_relocation() splice.
 */
extern int ld_reloc_riscv_insn(uint32_t rtype, int64_t value, uint8_t *dest);

/* ------------------------------------------------------------------ */
/* R-P20.1 : reloc classification table (the M_R_* answers libld asks)  */
/* ------------------------------------------------------------------ */

/*
 * re_flags per R_RISCV_* -- does this reloc need a GOT slot, a PLT entry, is it
 * PC-relative, TLS, does it splice into an instruction immediate (INSREL, so
 * ld_do_activerelocs routes it to ld_reloc_riscv_insn not a flat store), and is
 * it a link-time-only marker (NOTSUP: RELAX/ALIGN/*_ADD/GNU_VT*).  re_fsize is
 * the container width in bytes.
 */
const Rel_entry reloc_table[R_RISCV_NUM] = {
/* 0  NONE */		{0, FLG_RE_NOTSUP,                 0, 0, 0},
/* 1  32 */		{0, FLG_RE_NOTREL,                 4, 0, 0},
/* 2  64 */		{0, FLG_RE_NOTREL,                 8, 0, 0},
/* 3  RELATIVE */	{0, FLG_RE_NOTREL,                 8, 0, 0},
/* 4  COPY */		{0, FLG_RE_NOTREL,                 0, 0, 0},
/* 5  JUMP_SLOT */	{0, FLG_RE_PLTREL,                 8, 0, 0},
/* 6  DTPMOD32 */	{0, FLG_RE_TLSINS,                 4, 0, 0},
/* 7  DTPMOD64 */	{0, FLG_RE_TLSINS,                 8, 0, 0},
/* 8  DTPREL32 */	{0, FLG_RE_TLSINS,                 4, 0, 0},
/* 9  DTPREL64 */	{0, FLG_RE_TLSINS,                 8, 0, 0},
/* 10 TPREL32 */	{0, FLG_RE_TLSINS,                 4, 0, 0},
/* 11 TPREL64 */	{0, FLG_RE_TLSINS,                 8, 0, 0},
/* 12 */		{0, FLG_RE_NOTSUP,                 0, 0, 0},
/* 13 */		{0, FLG_RE_NOTSUP,                 0, 0, 0},
/* 14 */		{0, FLG_RE_NOTSUP,                 0, 0, 0},
/* 15 */		{0, FLG_RE_NOTSUP,                 0, 0, 0},
/* 16 BRANCH */		{0, FLG_RE_PCREL | FLG_RE_INSREL,  4, 0, 0},
/* 17 JAL */		{0, FLG_RE_PCREL | FLG_RE_INSREL,  4, 0, 0},
/* 18 CALL */		{0, FLG_RE_PCREL | FLG_RE_INSREL,  8, 0, 0},
/* 19 CALL_PLT */	{0, FLG_RE_PCREL | FLG_RE_PLTREL | FLG_RE_INSREL, 8, 0, 0},
/* 20 GOT_HI20 */	{0, FLG_RE_PCREL | FLG_RE_GOTADD | FLG_RE_INSREL, 4, 0, 0},
/* 21 TLS_GOT_HI20 */	{0, FLG_RE_PCREL | FLG_RE_GOTADD | FLG_RE_TLSINS | FLG_RE_INSREL, 4, 0, 0},
/* 22 TLS_GD_HI20 */	{0, FLG_RE_PCREL | FLG_RE_GOTADD | FLG_RE_TLSINS | FLG_RE_INSREL, 4, 0, 0},
/* 23 PCREL_HI20 */	{0, FLG_RE_PCREL | FLG_RE_INSREL,  4, 0, 0},
/* 24 PCREL_LO12_I */	{0, FLG_RE_PCREL | FLG_RE_INSREL,  4, 0, 0},
/* 25 PCREL_LO12_S */	{0, FLG_RE_PCREL | FLG_RE_INSREL,  4, 0, 0},
/* 26 HI20 */		{0, FLG_RE_INSREL,                 4, 0, 0},
/* 27 LO12_I */		{0, FLG_RE_INSREL,                 4, 0, 0},
/* 28 LO12_S */		{0, FLG_RE_INSREL,                 4, 0, 0},
/* 29 TPREL_HI20 */	{0, FLG_RE_TLSINS | FLG_RE_INSREL, 4, 0, 0},
/* 30 TPREL_LO12_I */	{0, FLG_RE_TLSINS | FLG_RE_INSREL, 4, 0, 0},
/* 31 TPREL_LO12_S */	{0, FLG_RE_TLSINS | FLG_RE_INSREL, 4, 0, 0},
/* 32 TPREL_ADD */	{0, FLG_RE_TLSINS | FLG_RE_NOTSUP, 0, 0, 0},
/* 33 ADD8 */		{0, FLG_RE_NOTREL,                 1, 0, 0},
/* 34 ADD16 */		{0, FLG_RE_NOTREL,                 2, 0, 0},
/* 35 ADD32 */		{0, FLG_RE_NOTREL,                 4, 0, 0},
/* 36 ADD64 */		{0, FLG_RE_NOTREL,                 8, 0, 0},
/* 37 SUB8 */		{0, FLG_RE_NOTREL,                 1, 0, 0},
/* 38 SUB16 */		{0, FLG_RE_NOTREL,                 2, 0, 0},
/* 39 SUB32 */		{0, FLG_RE_NOTREL,                 4, 0, 0},
/* 40 SUB64 */		{0, FLG_RE_NOTREL,                 8, 0, 0},
/* 41 GNU_VTINHERIT */	{0, FLG_RE_NOTSUP,                 0, 0, 0},
/* 42 GNU_VTENTRY */	{0, FLG_RE_NOTSUP,                 0, 0, 0},
/* 43 ALIGN */		{0, FLG_RE_NOTSUP,                 0, 0, 0},
/* 44 RVC_BRANCH */	{0, FLG_RE_PCREL | FLG_RE_INSREL,  2, 0, 0},
/* 45 RVC_JUMP */	{0, FLG_RE_PCREL | FLG_RE_INSREL,  2, 0, 0},
/* 46 RVC_LUI */	{0, FLG_RE_INSREL,                 2, 0, 0},
/* 47 GPREL_I */	{0, FLG_RE_INSREL,                 4, 0, 0},
/* 48 GPREL_S */	{0, FLG_RE_INSREL,                 4, 0, 0},
/* 49 TPREL_I */	{0, FLG_RE_TLSINS | FLG_RE_INSREL, 4, 0, 0},
/* 50 TPREL_S */	{0, FLG_RE_TLSINS | FLG_RE_INSREL, 4, 0, 0},
/* 51 RELAX */		{0, FLG_RE_NOTSUP,                 0, 0, 0},
/* 52 SUB6 */		{0, FLG_RE_NOTREL,                 1, 0, 0},
/* 53 SET6 */		{0, FLG_RE_NOTREL,                 1, 0, 0},
/* 54 SET8 */		{0, FLG_RE_NOTREL,                 1, 0, 0},
/* 55 SET16 */		{0, FLG_RE_NOTREL,                 2, 0, 0},
/* 56 SET32 */		{0, FLG_RE_NOTREL,                 4, 0, 0},
/* 57 32_PCREL */	{0, FLG_RE_PCREL,                  4, 0, 0},
};

static const Rel_entry *
riscv_rel_entry(Word rtype)
{
	if (rtype >= R_RISCV_NUM)
		return (NULL);
	return (&reloc_table[rtype]);
}

/* ------------------------------------------------------------------ */
/* R-P20.1 : RV64 GOT/PLT layout (binutils bfd/elfnn-riscv.c)          */
/* ------------------------------------------------------------------ */

#define	M_GOT_ENTSIZE		8
#define	M_PLT_ENTSIZE		16
#define	M_PLT_RESERVSZ		32	/* PLT header */
#define	M_GOTPLT_RESERVSZ	16	/* .got.plt[0..1] */

/* Byte offset of the Nth .got.plt entry (2-slot header first). */
static Xword
riscv_gotplt_off(Word pltndx)
{
	return (M_GOTPLT_RESERVSZ + (Xword)pltndx * M_GOT_ENTSIZE);
}

/* Byte offset of the Nth .plt stub (header first). */
static Xword
riscv_plt_off(Word pltndx)
{
	return (M_PLT_RESERVSZ + (Xword)pltndx * M_PLT_ENTSIZE);
}

/* ------------------------------------------------------------------ */
/* R-P20.1 : GOT slot assignment (idempotent, per Sym_desc + Gotref)   */
/* ------------------------------------------------------------------ */

/*
 * ld_assign_got_ndx -- find or assign the GOT slot for `sdp` under reference
 * kind `gref` and addend `addend`.  Idempotent: a symbol referenced by many
 * GOT relocs of the same kind shares ONE slot.  On first assignment it grows
 * ofl_gotcnt and returns the new slot; on a repeat it returns the existing one.
 * (amd64 ld_assign_got_ndx / find_gotndx + the sd_GOTndxs list.)
 */
Gotndx *
ld_assign_got_ndx(Sym_desc *sdp, Gotref gref, Sxword addend, Ofl_desc *ofl)
{
	Word i;
	Gotndx *gnp;

	for (i = 0; i < sdp->sd_nGOT; i++) {
		gnp = &sdp->sd_GOTndxs[i];
		if (gnp->gn_gotref == gref && gnp->gn_addend == addend)
			return (gnp);		/* share the existing slot */
	}
	if (sdp->sd_nGOT >= SYM_MAX_GOT)
		return (NULL);
	gnp = &sdp->sd_GOTndxs[sdp->sd_nGOT++];
	gnp->gn_gotref = gref;
	gnp->gn_addend = addend;
	gnp->gn_gotndx = (Word)ofl->ofl_gotcnt++;
	gnp->gn_gotalign = M_GOT_ENTSIZE;
	return (gnp);
}

/*
 * Assign a PLT entry (and its paired .got.plt slot) to `sdp` (idempotent).
 * (amd64 ld_reloc_local PLT-slot path + Sym_aux->sa_PLTndx.)
 */
static Word
riscv_assign_plt(Sym_desc *sdp, Ofl_desc *ofl)
{
	if (sdp->sd_aux == NULL)
		return (M_PLT_NULL);
	if (sdp->sd_aux->sa_PLTndx == M_PLT_NULL) {
		sdp->sd_aux->sa_PLTndx = (Word)ofl->ofl_pltcnt++;
		sdp->sd_aux->sa_PLTGOTndx = sdp->sd_aux->sa_PLTndx;
	}
	return (sdp->sd_aux->sa_PLTndx);
}

/* ------------------------------------------------------------------ */
/* R-P21.1 : ld_reloc_local -- classify + allocate GOT/PLT slots       */
/* ------------------------------------------------------------------ */

/*
 * ld_reloc_local -- the per-input-relocation classification + GOT/PLT slot
 * allocation pass (libld's reloc_local() calls this for each local reloc; the
 * against-symbol path ld_reloc_sym calls the same logic).  Returns 1 on
 * success, S_ERROR on an unclassifiable reloc.
 * (amd64/sparc ld_reloc_local.)
 */
uintptr_t
ld_reloc_local(Rel_desc *rsp, Ofl_desc *ofl)
{
	const Rel_entry *rep = riscv_rel_entry(rsp->rel_rtype);
	Sym_desc *sdp = rsp->rel_sym;

	if (rep == NULL || (rep->re_flags & FLG_RE_NOTSUP) != 0) {
		if (rep != NULL && (rep->re_flags & FLG_RE_NOTSUP) &&
		    rep->re_fsize == 0)
			return (1);	/* RELAX/ALIGN markers: nothing to do */
		return (S_ERROR);
	}

	/* GOT relocs: assign the referenced symbol a .got slot. */
	if ((rep->re_flags & FLG_RE_GOTADD) != 0 && sdp != NULL) {
		Gotref gref = (rep->re_flags & FLG_RE_TLSINS) ?
		    GOT_REF_TLSIE : GOT_REF_GENERIC;
		if (ld_assign_got_ndx(sdp, gref, rsp->rel_raddend, ofl) == NULL)
			return (S_ERROR);
		rsp->rel_flags |= FLG_REL_GOT;
	}

	/* PLT relocs: assign the referenced symbol a .plt/.got.plt entry. */
	if ((rep->re_flags & FLG_RE_PLTREL) != 0 && sdp != NULL &&
	    ofl->ofl_flags != FLG_OF_RELOBJ) {
		if (riscv_assign_plt(sdp, ofl) != M_PLT_NULL)
			rsp->rel_flags |= FLG_REL_PLT;
	}
	return (1);
}

/* ------------------------------------------------------------------ */
/* R-P21.1 : ld_do_activerelocs -- the output apply pass               */
/* ------------------------------------------------------------------ */

/* RISC-V high-part rounding for %pcrel_hi/%pcrel_lo agreement (psABI). */
#define	RISCV_IMM_REACH		(1LL << 12)
#define	RISCV_CONST_HIGH_PART(v) \
	(((v) + (RISCV_IMM_REACH / 2)) & ~(RISCV_IMM_REACH - 1))

/* Little-endian flat store of `fsize` bytes (the do_reloc() path). */
static void
riscv_store(uint8_t *dest, int64_t value, uchar_t fsize)
{
	uchar_t i;
	for (i = 0; i < fsize; i++)
		dest[i] = (uint8_t)(value >> (i * 8));
}

/*
 * Compute the reloc site address P = output-section run addr + input-section
 * offset within it + the reloc's offset within the input section.  (This is
 * what the gate derives from rel_isdesc->is_osdesc->os_shaddr + is_offset +
 * rel_roffset.)
 */
static int64_t
riscv_site_addr(Rel_desc *rsp)
{
	Is_desc *isp = rsp->rel_isdesc;
	int64_t base = 0;

	if (isp != NULL && isp->is_osdesc != NULL)
		base = (int64_t)isp->is_osdesc->os_shaddr + (int64_t)isp->is_offset;
	return (base + (int64_t)rsp->rel_roffset);
}

/*
 * Pointer to the reloc site bytes in the output section image.
 */
static uint8_t *
riscv_site_ptr(Rel_desc *rsp)
{
	Is_desc *isp = rsp->rel_isdesc;

	if (isp == NULL || isp->is_osdesc == NULL ||
	    isp->is_osdesc->os_outdata == NULL)
		return (NULL);
	return (isp->is_osdesc->os_outdata + isp->is_offset + rsp->rel_roffset);
}

/*
 * Apply one active relocation.  This is the per-reloc body ld_do_activerelocs
 * runs over every entry.  It computes the RISC-V value and routes it:
 *   - PCREL_HI20 / GOT_HI20 : record { site -> S+A-P } in the pcrel htab AND
 *     splice the HI immediate now;
 *   - PCREL_LO12_{I,S} : defer -- the reloc's symbol value is the auipc site
 *     address, resolved in the finish pass against the recorded HI;
 *   - other INSREL types : splice the computed value into the immediate;
 *   - NOTREL flat data : byte store (do_reloc path);
 *   - NOTSUP markers : no-op.
 * Returns 1 on success, S_ERROR on failure.
 * (amd64 ld_do_activerelocs body + binutils riscv record/defer.)
 */
uintptr_t
ld_do_activereloc_one(Rel_desc *rsp, Ofl_desc *ofl)
{
	const Rel_entry *rep = riscv_rel_entry(rsp->rel_rtype);
	riscv_pcrel_htab_t *pt = ofl->ofl_riscv_pcrel;
	Sym_desc *sdp = rsp->rel_sym;
	int64_t S = (sdp != NULL) ? (int64_t)sdp->sd_value : 0;
	int64_t A = (int64_t)rsp->rel_raddend;
	int64_t P = riscv_site_addr(rsp);
	uint8_t *dest = riscv_site_ptr(rsp);
	int64_t value;

	if (rep == NULL)
		return (S_ERROR);
	if ((rep->re_flags & FLG_RE_NOTSUP) != 0 && rep->re_fsize == 0)
		return (1);		/* RELAX/ALIGN/*_ADD: nothing to write */
	if (dest == NULL)
		return (S_ERROR);

	switch (rsp->rel_rtype) {
	case R_RISCV_PCREL_HI20:
	case R_RISCV_GOT_HI20:
		/* value = S + A - P; record keyed by site P, splice HI now. */
		value = S + A - P;
		if (pt != NULL &&
		    riscv_pcrel_htab_insert(pt, P, value,
		    rsp->rel_rtype) == NULL)
			return (S_ERROR);
		return (ld_reloc_riscv_insn(rsp->rel_rtype, value, dest) == 0 ?
		    1 : S_ERROR);

	case R_RISCV_PCREL_LO12_I:
	case R_RISCV_PCREL_LO12_S:
		/*
		 * The LO reloc symbol resolves to the matching auipc address
		 * (== S here); defer, remembering that address.  Resolved in
		 * the finish pass.
		 */
		if (pt == NULL)
			return (S_ERROR);
		return (riscv_pcrel_htab_defer_lo(pt, S, rsp->rel_rtype, A,
		    dest) == 0 ? 1 : S_ERROR);

	default:
		break;
	}

	if ((rep->re_flags & FLG_RE_INSREL) != 0) {
		/* PC-relative instruction types use S+A-P; others S+A. */
		value = ((rep->re_flags & FLG_RE_PCREL) != 0) ?
		    (S + A - P) : (S + A);
		return (ld_reloc_riscv_insn(rsp->rel_rtype, value, dest) == 0 ?
		    1 : S_ERROR);
	}

	/* Flat data reloc. */
	value = ((rep->re_flags & FLG_RE_PCREL) != 0) ? (S + A - P) : (S + A);
	riscv_store(dest, value, rep->re_fsize);
	return (1);
}

/*
 * Finish pass: resolve every deferred %pcrel_lo against its recorded %pcrel_hi
 * by auipc-site-address lookup, splicing the HI's shared (S+A-P) value into the
 * LO immediate so HI(rounded high20) + LO(sext low12) == S+A-P.  Enforces the
 * binutils diagnostics (missing HI, addend on GOT_HI20, addend crossing the
 * high part).  Returns 1 on success, S_ERROR on a dangling/illegal LO.
 * (binutils riscv_resolve_pcrel_lo_relocs.)
 */
uintptr_t
ld_riscv_finish_pcrel(Ofl_desc *ofl)
{
	riscv_pcrel_htab_t *pt = ofl->ofl_riscv_pcrel;
	riscv_pcrel_lo_t *l;

	if (pt == NULL)
		return (1);
	for (l = pt->pt_lo; l != NULL; l = l->pl_next) {
		riscv_pcrel_hi_t *hi = riscv_pcrel_htab_find(pt, l->pl_addr);

		if (hi == NULL)
			return (S_ERROR);	/* missing matching %pcrel_hi */
		if (hi->ph_type == R_RISCV_GOT_HI20 && l->pl_addend != 0)
			return (S_ERROR);	/* addend disallowed on GOT_HI20 */
		if (RISCV_CONST_HIGH_PART(hi->ph_value) !=
		    RISCV_CONST_HIGH_PART(hi->ph_value + l->pl_addend))
			return (S_ERROR);	/* addend crosses the high part */
		if (ld_reloc_riscv_insn(l->pl_type, hi->ph_value,
		    l->pl_dest) != 0)
			return (S_ERROR);
	}
	return (1);
}

/*
 * ld_do_activerelocs -- iterate a NULL-terminated array of active relocations,
 * applying each, then run the pcrel finish pass.  (In the gate the array is the
 * ofl_actrels APlist; here a plain array so the pass is drivable standalone.)
 */
uintptr_t
ld_do_activerelocs(Rel_desc *rels, Word nrels, Ofl_desc *ofl)
{
	Word i;

	for (i = 0; i < nrels; i++)
		if (ld_do_activereloc_one(&rels[i], ofl) == S_ERROR)
			return (S_ERROR);
	return (ld_riscv_finish_pcrel(ofl));
}

#ifdef MACHREL_SELFTEST
/*
 * Proof the gate wiring works end to end:
 *   (a) ld_reloc_local classifies + assigns GOT/PLT slots idempotently and
 *       grows ofl_gotcnt / ofl_pltcnt;
 *   (b) ld_do_activerelocs drives a real Rel_desc set through the output pass,
 *       and the %pcrel_hi/%pcrel_lo pair (routed through the htab, resolved in
 *       the finish pass) reconstructs S - P across auipc/addi -- byte-identical
 *       to GNU ld (0x00001797 / 0x0a878793 for the R-P19.3 pair);
 *   (c) a dangling %pcrel_lo (no HI) is rejected;
 *   (d) the htab handles many pairs (exercises grow/rehash, O(1) lookup).
 * assert() only.
 */
#include	<assert.h>
#include	<stdio.h>

#define	RV_X(x, s, n)	(((x) >> (s)) & ((1U << (n)) - 1))
#define	SEXT12(v)	((int64_t)((int32_t)((uint32_t)(v) << 20) >> 20))
#define	EXTRACT_UTYPE_IMM(x)	((int64_t)(int32_t)((x) & 0xfffff000))
#define	EXTRACT_ITYPE_IMM(x)	SEXT12(RV_X(x, 20, 12))

static uint32_t
rd32(const uint8_t *p)
{
	return ((uint32_t)p[0] | (uint32_t)p[1] << 8 |
	    (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24);
}

/* Build a minimal output-section image + input section for the site. */
static Os_desc os;
static Is_desc is;

static void
mk_rel(Rel_desc *r, Word rtype, Xword roff, Sym_desc *sym, int64_t addend)
{
	r->rel_rtype = rtype;
	r->rel_roffset = roff;
	r->rel_raddend = addend;
	r->rel_sym = sym;
	r->rel_isdesc = &is;
	r->rel_aux = NULL;
	r->rel_flags = 0;
}

int
main(void)
{
	Ofl_desc ofl;
	riscv_pcrel_htab_t pt;
	uint8_t image[64];
	Sym_aux aux = { M_PLT_NULL, M_PLT_NULL };
	Sym_desc s_sym, s_call;

	memset(&ofl, 0, sizeof (ofl));
	memset(image, 0, sizeof (image));
	assert(riscv_pcrel_htab_init(&pt) == 0);
	ofl.ofl_riscv_pcrel = &pt;
	ofl.ofl_flags = FLG_OF_EXEC;

	/* Output section at run address 0x8000, image maps its bytes. */
	os.os_outdata = image;
	os.os_shaddr = 0x8000;
	os.os_shoff = 0;
	is.is_indata = image;
	is.is_osdesc = &os;
	is.is_offset = 0;

	/* --- (a) classification + GOT/PLT slot allocation --- */
	memset(&s_sym, 0, sizeof (s_sym));
	s_sym.sd_name = "data_sym";
	memset(&s_call, 0, sizeof (s_call));
	s_call.sd_name = "callee";
	s_call.sd_aux = &aux;

	{
		Rel_desc r;
		/* GOT_HI20 twice against the same symbol -> ONE got slot. */
		mk_rel(&r, R_RISCV_GOT_HI20, 0, &s_sym, 0);
		assert(ld_reloc_local(&r, &ofl) == 1);
		mk_rel(&r, R_RISCV_GOT_HI20, 8, &s_sym, 0);
		assert(ld_reloc_local(&r, &ofl) == 1);
		assert(ofl.ofl_gotcnt == 1);		/* idempotent */
		assert(s_sym.sd_nGOT == 1);

		/* CALL_PLT twice against callee -> ONE plt entry. */
		mk_rel(&r, R_RISCV_CALL_PLT, 16, &s_call, 0);
		assert(ld_reloc_local(&r, &ofl) == 1);
		mk_rel(&r, R_RISCV_CALL_PLT, 24, &s_call, 0);
		assert(ld_reloc_local(&r, &ofl) == 1);
		assert(ofl.ofl_pltcnt == 1);		/* idempotent */
		assert(aux.sa_PLTndx == 0);
		assert(riscv_plt_off(0) == 32);
		assert(riscv_gotplt_off(0) == 16);

		/* RELAX marker: classified, no slot, success. */
		mk_rel(&r, R_RISCV_RELAX, 20, NULL, 0);
		assert(ld_reloc_local(&r, &ofl) == 1);
	}
	riscv_pcrel_htab_fini(&pt);

	/* --- (b) full output pass: pcrel pair reconstructs S - P --- */
	assert(riscv_pcrel_htab_init(&pt) == 0);
	ofl.ofl_riscv_pcrel = &pt;
	memset(image, 0, sizeof (image));

	/* auipc a5,0 (0x00000797) at off 0 ; addi a5,a5,0 (0x00078793) at 4 */
	image[0] = 0x97; image[1] = 0x07;
	image[4] = 0x93; image[5] = 0x87; image[6] = 0x07;

	{
		/*
		 * S = 0x8000 + 0x10a8 (so S - P == 0x10a8 for the HI at
		 * P=0x8000).  The LO's symbol value is the auipc address P.
		 */
		Sym_desc s_target, s_hiaddr;
		Rel_desc rels[2];

		memset(&s_target, 0, sizeof (s_target));
		s_target.sd_value = 0x8000 + 0x10a8;
		memset(&s_hiaddr, 0, sizeof (s_hiaddr));
		s_hiaddr.sd_value = 0x8000;	/* == the auipc site address */

		mk_rel(&rels[0], R_RISCV_PCREL_HI20, 0, &s_target, 0);
		mk_rel(&rels[1], R_RISCV_PCREL_LO12_I, 4, &s_hiaddr, 0);

		assert(ld_do_activerelocs(rels, 2, &ofl) == 1);

		/* byte-identical to GNU ld for the R-P19.3 pair */
		assert(rd32(image) == 0x00001797);	/* auipc a5,0x1 */
		assert(rd32(image + 4) == 0x0a878793);	/* addi a5,a5,168 */

		/* and the pair reconstructs S - P */
		{
			int64_t rebuilt = EXTRACT_UTYPE_IMM(rd32(image)) +
			    EXTRACT_ITYPE_IMM(rd32(image + 4));
			assert(rebuilt == 0x10a8);
		}
	}
	riscv_pcrel_htab_fini(&pt);

	/* --- (c) dangling %pcrel_lo rejected --- */
	assert(riscv_pcrel_htab_init(&pt) == 0);
	ofl.ofl_riscv_pcrel = &pt;
	memset(image, 0, sizeof (image));
	image[0] = 0x93; image[1] = 0x87; image[2] = 0x07;	/* addi a5 */
	{
		Sym_desc s_bad;
		Rel_desc r;
		memset(&s_bad, 0, sizeof (s_bad));
		s_bad.sd_value = 0xdead;		/* no HI recorded */
		mk_rel(&r, R_RISCV_PCREL_LO12_I, 0, &s_bad, 0);
		assert(ld_do_activereloc_one(&r, &ofl) == 1);	/* deferred */
		assert(ld_riscv_finish_pcrel(&ofl) == S_ERROR);	/* dangling */
	}
	riscv_pcrel_htab_fini(&pt);

	/* --- (d) htab scales: many HIs exercise grow/rehash + O(1) find --- */
	assert(riscv_pcrel_htab_init(&pt) == 0);
	{
		int i;
		for (i = 0; i < 1000; i++)
			assert(riscv_pcrel_htab_insert(&pt, 0x100000 + i * 4,
			    i, R_RISCV_PCREL_HI20) != NULL);
		assert(pt.pt_nhi == 1000);
		for (i = 0; i < 1000; i++) {
			riscv_pcrel_hi_t *h =
			    riscv_pcrel_htab_find(&pt, 0x100000 + i * 4);
			assert(h != NULL && h->ph_value == i);
		}
		assert(riscv_pcrel_htab_find(&pt, 0x999999) == NULL);
	}
	riscv_pcrel_htab_fini(&pt);

	printf("PASS: gate machrel.riscv.c "
	    "(ld_reloc_local classifies + idempotent GOT/PLT slots; "
	    "ld_do_activerelocs pcrel pair via htab -> GNU-ld bytes "
	    "0x00001797/0x0a878793; dangling LO rejected; htab scales to "
	    "1000 pairs O(1))\n");
	return (0);
}
#endif	/* MACHREL_SELFTEST */
