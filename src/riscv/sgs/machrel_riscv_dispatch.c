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
 * Solaris link-editor (sgs/libld) EM_RISCV machine reloc dispatch.
 *
 * This is the reloc-apply core the libld MACH descriptor points at.  In the
 * illumos gate the per-target link-editor behaviour is a Target/ld_targ record
 * (usr/src/cmd/sgs/libld/common/machrel.<arch>.c) whose ->t_mr member holds
 * function pointers (ld_reloc_local, ld_reloc_GOTOP, ld_do_activerelocs,
 * ld_perform_outreloc, ...) plus a Rel_entry classification table.  The two
 * arch-specific facts a new target must supply are:
 *
 *   (1) the reloc CLASSIFICATION table (does this type want GOT/PLT, is it
 *       PC-relative, TLS, an instruction-field splice, or a link-time marker)
 *       -- provided by sgs_reloc_table_riscv[] in machrel.riscv.c; and
 *   (2) the reloc APPLY math -- how the computed value is written into the
 *       section contents.  For RISC-V that is two paths: a flat little-endian
 *       byte store (R_RISCV_32/64/ADD/SUB/SET/RELATIVE/JUMP_SLOT/32_PCREL) and
 *       the instruction-field splice (everything FLG_RE_INSREL, in
 *       machrel_riscv_insn.c).
 *
 * ld_do_reloc_riscv() below is that apply core: it consults the classification
 * table, computes the RISC-V "Calculation" (S + A, or S + A - P for the
 * PC-relative types), and dispatches to the flat store or the instruction
 * encoder.  It is the routine the MACH descriptor's ld_do_activerelocs and
 * krtld's do_reloc() both reduce to.  The GOT/PLT slot allocation and the
 * %pcrel_hi/%pcrel_lo pairing bookkeeping are libld scaffolding layered on top
 * (out of scope for this standalone apply core; the classification flags mark
 * where they hook in).
 *
 * CRIB PROVENANCE:
 *   - the flat-store vs instruction-field split, the S+A / S+A-P calculation,
 *     and the read-modify-write model: binutils-2.44 bfd/elfnn-riscv.c
 *     perform_relocation() + relocate_section() and the RISC-V psABI
 *     "Calculation" column.
 *   - the instruction-field encode math: machrel_riscv_insn.c (itself cribbed
 *     from binutils include/opcode/riscv.h ENCODE_* + perform_relocation).
 *   - the Rel_entry / FLG_RE_x / Target-descriptor shape: the illumos sgs
 *     libld machrel.<arch>.c convention (x86/sparc/aarch64 targets).
 */

#include	<stdint.h>
#include	<string.h>
#include	"reloc_riscv_table.h"

/* From machrel_riscv_insn.c (the FLG_RE_INSREL encoder). */
extern int ld_reloc_riscv_insn(uint32_t rtype, int64_t value, uint8_t *dest);

/* The classification table from machrel.riscv.c. */
extern const Rel_entry sgs_reloc_table_riscv[R_RISCV_NUM];

/* Flat little-endian load/store of the low re_fsize bytes of value. */
static int64_t
riscv_flat_load(const uint8_t *dest, uint32_t fsize)
{
	int64_t v = 0;
	uint32_t i;
	for (i = 0; i < fsize; i++)
		v |= (int64_t)dest[i] << (8 * i);
	return (v);
}

static void
riscv_flat_store(uint8_t *dest, int64_t value, uint32_t fsize)
{
	uint32_t i;
	for (i = 0; i < fsize; i++)
		dest[i] = (uint8_t)(value >> (8 * i));
}

/*
 * Apply one RISC-V relocation.
 *   rtype  : R_RISCV_* type
 *   dest   : pointer to the section contents at r_offset
 *   sym    : S -- resolved symbol value (or GOT/PLT/TLS-adjusted, computed by
 *            the caller's slot logic; opaque here)
 *   addend : A -- reloc addend (RELA)
 *   pc     : P -- the run/link address of dest (address of the reloc site);
 *            only consulted for PC-relative types
 * Returns 0 on success, -1 for an unsupported/marker type (caller decides
 * whether that is benign, e.g. R_RISCV_RELAX/ALIGN, or an error).
 */
int
ld_do_reloc_riscv(uint32_t rtype, uint8_t *dest, int64_t sym, int64_t addend,
    int64_t pc)
{
	const Rel_entry *re;
	int64_t value;

	if (rtype >= R_RISCV_NUM)
		return (-1);
	re = &sgs_reloc_table_riscv[rtype];

	/* Link-time markers / unsupported: no contents change. */
	if ((re->re_flags & FLG_RE_NOTSUP) && !(re->re_flags & FLG_RE_INSREL))
		return (-1);

	/* RISC-V "Calculation": S + A, PC-biased for PC-relative types. */
	value = sym + addend;
	if (re->re_flags & FLG_RE_PCREL)
		value -= pc;

	if (re->re_flags & FLG_RE_INSREL)
		return (ld_reloc_riscv_insn(rtype, value, dest));

	/* Flat data reloc: byte store of re_fsize bytes. */
	if (re->re_fsize == 0)
		return (-1);

	/*
	 * R_RISCV_ADD/SUB/SET families and SUB6 are in-place modify (used for
	 * label-difference and .uleb128/debug relocs), not plain overwrite.
	 * Math cribbed from binutils bfd/elfxx-riscv.c riscv_elf_add_sub_reloc.
	 */
	switch (rtype) {
	case R_RISCV_ADD8:
	case R_RISCV_ADD16:
	case R_RISCV_ADD32:
	case R_RISCV_ADD64:
		value = riscv_flat_load(dest, re->re_fsize) + value;
		break;
	case R_RISCV_SUB8:
	case R_RISCV_SUB16:
	case R_RISCV_SUB32:
	case R_RISCV_SUB64:
		value = riscv_flat_load(dest, re->re_fsize) - value;
		break;
	case R_RISCV_SUB6: {
		int64_t old = riscv_flat_load(dest, 1);
		value = (old & ~0x3f) | (((old & 0x3f) - value) & 0x3f);
		break;
	}
	case R_RISCV_SET6: {
		int64_t old = riscv_flat_load(dest, 1);
		value = (old & ~0x3f) | (value & 0x3f);
		break;
	}
	default:
		break;		/* 32/64/RELATIVE/32_PCREL/SET8..32: overwrite */
	}
	riscv_flat_store(dest, value, re->re_fsize);
	return (0);
}

#ifdef DISPATCH_SELFTEST
/*
 * Proof: drive a real relocation record set through ld_do_reloc_riscv() and
 * show (a) a flat R_RISCV_64 lands the absolute address, (b) a PC-relative
 * R_RISCV_32_PCREL subtracts P, (c) the HI20/LO12_I instruction pair
 * reconstructs a symbol address into an auipc/addi sequence, and (d) a marker
 * (R_RISCV_RELAX) is a no-op.  assert() only.
 */
#include	<assert.h>
#include	<stdio.h>

#define	RV_X(x, s, n)	(((x) >> (s)) & ((1U << (n)) - 1))
#define	SEXT12(v)	((int64_t)((int32_t)((uint32_t)(v) << 20) >> 20))
#define	EXTRACT_UTYPE_IMM(x)	((int64_t)(int32_t)((x) & 0xfffff000))
#define	EXTRACT_ITYPE_IMM(x)	SEXT12(RV_X(x, 20, 12))
#define	RISCV_IMM_REACH	(1LL << 12)
#define	RISCV_CONST_HIGH_PART(v) \
	(((v) + (RISCV_IMM_REACH / 2)) & ~(RISCV_IMM_REACH - 1))

static uint32_t
rd32(const uint8_t *p)
{
	return ((uint32_t)p[0] | (uint32_t)p[1] << 8 |
	    (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24);
}
static uint64_t
rd64(const uint8_t *p)
{
	uint64_t v = 0; int i;
	for (i = 0; i < 8; i++) v |= (uint64_t)p[i] << (8 * i);
	return (v);
}

int
main(void)
{
	uint8_t buf[16];

	/* (a) R_RISCV_64 flat absolute: value = S + A. */
	memset(buf, 0, sizeof (buf));
	assert(ld_do_reloc_riscv(R_RISCV_64, buf, 0x4000, 0x20, 0) == 0);
	assert(rd64(buf) == 0x4020);

	/* (b) R_RISCV_32_PCREL: value = S + A - P. */
	memset(buf, 0, sizeof (buf));
	assert(ld_do_reloc_riscv(R_RISCV_32_PCREL, buf, 0x9000, 0, 0x8000)
	    == 0);
	assert(rd32(buf) == 0x1000);

	/* (c) HI20 + LO12_I pair reconstruct a symbol address S+A. */
	{
		int64_t S = 0x00021abc, A = 0;
		/* auipc a0,0 (0x517) then addi a0,a0,0 (0x50513) */
		buf[0]=0x17; buf[1]=0x05; buf[2]=0x00; buf[3]=0x00;
		buf[4]=0x13; buf[5]=0x05; buf[6]=0x05; buf[7]=0x00;
		assert(ld_do_reloc_riscv(R_RISCV_HI20, buf, S, A, 0) == 0);
		assert(ld_do_reloc_riscv(R_RISCV_LO12_I, buf + 4, S, A, 0)
		    == 0);
		int64_t hi = EXTRACT_UTYPE_IMM(rd32(buf));
		int64_t lo = EXTRACT_ITYPE_IMM(rd32(buf + 4));
		assert(hi + lo == S + A);
		/* base opcode/reg bits survived the splice */
		assert((rd32(buf) & 0xfff) == 0x517);
		assert((rd32(buf + 4) & 0xfffff) == 0x50513);
	}

	/* (d) R_RISCV_ADD32 in-place add: contents += (S + A). */
	{
		memset(buf, 0, sizeof (buf));
		buf[0] = 0x10;			/* existing low byte = 0x10 */
		assert(ld_do_reloc_riscv(R_RISCV_ADD32, buf, 0x100, 0x5, 0)
		    == 0);
		assert(rd32(buf) == 0x10 + 0x105);
		assert(ld_do_reloc_riscv(R_RISCV_SUB32, buf, 0x5, 0, 0) == 0);
		assert(rd32(buf) == 0x10 + 0x105 - 0x5);
	}

	/* (e) R_RISCV_RELAX marker: no-op (returns -1, contents unchanged). */
	{
		uint8_t save[4] = {0xde, 0xad, 0xbe, 0xef};
		memcpy(buf, save, 4);
		assert(ld_do_reloc_riscv(R_RISCV_RELAX, buf, 1, 2, 3) == -1);
		assert(memcmp(buf, save, 4) == 0);
	}

	printf("PASS: ld_do_reloc_riscv dispatch "
	    "(flat64 / 32_PCREL / HI20+LO12_I pair / ADD32+SUB32 / RELAX)\n");
	return (0);
}
#endif	/* DISPATCH_SELFTEST */
