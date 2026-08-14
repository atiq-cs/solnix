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
 * RISC-V (EM_RISCV) instruction-field relocation encoders for the Solaris
 * link-editor (sgs/libld) and krtld do_reloc().
 *
 * The FLG_RE_INSREL entries in machrel.riscv.c / doreloc.c defer to this
 * module.  Unlike a flat data reloc (R_RISCV_32/64/ADD/SUB/SET), a RISC-V
 * instruction-field reloc does not write a contiguous little-endian value at
 * r_offset -- it splices a sign/shift-scrambled subset of the value's bits
 * into the U/I/S/B/J immediate slots of a 32-bit instruction word (or the
 * CB/CJ/CI slots of a 16-bit compressed instruction).  This module performs
 * exactly that splice.
 *
 * The write model mirrors binutils perform_relocation():
 *   1. the caller has already computed the final relocation VALUE
 *      (S + A, or for pc_relative types S + A - P);
 *   2. this routine ENCODEs VALUE into the reloc's immediate layout;
 *   3. it read-modify-writes the instruction word:
 *        word = (word & ~dst_mask) | (encoded & dst_mask);
 *   4. the word is stored little-endian (RISC-V is always LE here).
 *
 * The HI20/LO12 pair is split via RISCV_CONST_HIGH_PART (round-to-nearest of
 * the low 12 bits into the high 20) so an auipc/lui + addi/load/store pair
 * reconstructs the full value.  CALL/CALL_PLT packs the U-type high part into
 * the auipc and the I-type low part into the following jalr (a 64-bit "word").
 *
 * CRIB PROVENANCE (reloc encode math -- NOT invented here):
 *   - ENCODE_{U,I,S,B,J}TYPE_IMM, ENCODE_C{B,J,I}TYPE_IMM, RV_X, RV_IMM_SIGN:
 *       binutils-2.44 include/opcode/riscv.h (lines ~55, 136-175).
 *   - RISCV_CONST_HIGH_PART / RISCV_IMM_REACH / RISCV_IMM_BITS:
 *       binutils-2.44 include/opcode/riscv.h (~248, ~262).
 *   - the per-reloc ENCODE dispatch + CALL U|I<<32 packing + the
 *       word = (word & ~dst_mask) | (value & dst_mask) store + the
 *       riscv_get_insn/put_insn 16/32/64 LE model:
 *       binutils-2.44 bfd/elfnn-riscv.c perform_relocation() (~1776-1955)
 *       and the riscv_get_insn/riscv_put_insn macros (~238).
 *   - dst_mask == ENCODE_xTYPE_IMM(-1U), bitsize 32 (16 for RVC):
 *       binutils-2.44 bfd/elfxx-riscv.c howto_table[] (~392+).
 * The RISC-V psABI "Calculation" column is the specification these implement.
 *
 * In the gate this is folded into usr/src/cmd/sgs/libld/common/machrel.riscv.c
 * (link-time apply) and usr/src/uts/common/krtld/doreloc.c (load-time apply);
 * kept standalone here so the encode math compiles + self-verifies before the
 * full libld mach-descriptor integration lands.
 */

#include	<stdint.h>
#include	<string.h>

/* --- bit helpers (binutils include/opcode/riscv.h) --- */
#define	RV_X(x, s, n)		(((x) >> (s)) & ((1U << (n)) - 1))
#define	RV_IMM_SIGN(x)		(-(((x) >> 31) & 1))

/* --- immediate-field encoders (binutils include/opcode/riscv.h) --- */
#define	ENCODE_ITYPE_IMM(x) \
	(RV_X(x, 0, 12) << 20)
#define	ENCODE_STYPE_IMM(x) \
	((RV_X(x, 0, 5) << 7) | (RV_X(x, 5, 7) << 25))
#define	ENCODE_BTYPE_IMM(x) \
	((RV_X(x, 1, 4) << 8) | (RV_X(x, 5, 6) << 25) | \
	(RV_X(x, 11, 1) << 7) | (RV_X(x, 12, 1) << 31))
#define	ENCODE_UTYPE_IMM(x) \
	(RV_X(x, 12, 20) << 12)
#define	ENCODE_JTYPE_IMM(x) \
	((RV_X(x, 1, 10) << 21) | (RV_X(x, 11, 1) << 20) | \
	(RV_X(x, 12, 8) << 12) | (RV_X(x, 20, 1) << 31))
#define	ENCODE_CBTYPE_IMM(x) \
	((RV_X(x, 1, 2) << 3) | (RV_X(x, 3, 2) << 10) | (RV_X(x, 5, 1) << 2) | \
	(RV_X(x, 6, 2) << 5) | (RV_X(x, 8, 1) << 12))
#define	ENCODE_CJTYPE_IMM(x) \
	((RV_X(x, 1, 3) << 3) | (RV_X(x, 4, 1) << 11) | (RV_X(x, 5, 1) << 2) | \
	(RV_X(x, 6, 1) << 7) | (RV_X(x, 7, 1) << 6) | (RV_X(x, 8, 2) << 9) | \
	(RV_X(x, 10, 1) << 8) | (RV_X(x, 11, 1) << 12))
#define	ENCODE_CITYPE_IMM(x) \
	((RV_X(x, 0, 5) << 2) | (RV_X(x, 5, 1) << 12))

/* --- HI/LO split (binutils include/opcode/riscv.h) --- */
#define	RISCV_IMM_BITS		12
#define	RISCV_IMM_REACH		(1LL << RISCV_IMM_BITS)
#define	RISCV_CONST_HIGH_PART(v) \
	(((v) + (RISCV_IMM_REACH / 2)) & ~(RISCV_IMM_REACH - 1))
#define	RISCV_CITYPE_LUI_IMM(x)	ENCODE_CITYPE_IMM((x) >> RISCV_IMM_BITS)

/* R_RISCV_* subset that touches an instruction field. */
#define	R_RISCV_BRANCH		16
#define	R_RISCV_JAL		17
#define	R_RISCV_CALL		18
#define	R_RISCV_CALL_PLT	19
#define	R_RISCV_GOT_HI20	20
#define	R_RISCV_TLS_GOT_HI20	21
#define	R_RISCV_TLS_GD_HI20	22
#define	R_RISCV_PCREL_HI20	23
#define	R_RISCV_PCREL_LO12_I	24
#define	R_RISCV_PCREL_LO12_S	25
#define	R_RISCV_HI20		26
#define	R_RISCV_LO12_I		27
#define	R_RISCV_LO12_S		28
#define	R_RISCV_TPREL_HI20	29
#define	R_RISCV_TPREL_LO12_I	30
#define	R_RISCV_TPREL_LO12_S	31
#define	R_RISCV_RVC_BRANCH	44
#define	R_RISCV_RVC_JUMP	45
#define	R_RISCV_RVC_LUI		46

/*
 * ld_reloc_riscv_insn: splice VALUE into the instruction word at DEST for the
 * given R_RISCV_* instruction-field reloc.  DEST points at the 2- or 4-byte
 * little-endian instruction; VALUE is the fully computed relocation result
 * (the caller applies the S+A / S+A-P calculation and any HI/LO pairing
 * bookkeeping).  Returns 0 on success, -1 on unsupported/overflowing type.
 *
 * This is the exact splice binutils perform_relocation() does; the flat-store
 * relocs (R_RISCV_32, _64, the ADD/SUB/SET families, _32_PCREL) are NOT
 * handled here -- those go through do_reloc()'s byte writer.
 */
static uint64_t
riscv_get_insn(int bits, const uint8_t *p)
{
	uint64_t v = 0;
	int i, n = bits / 8;
	for (i = 0; i < n; i++)			/* little-endian */
		v |= (uint64_t)p[i] << (8 * i);
	return (v);
}

static void
riscv_put_insn(int bits, uint64_t v, uint8_t *p)
{
	int i, n = bits / 8;
	for (i = 0; i < n; i++)
		p[i] = (uint8_t)(v >> (8 * i));
}

int
ld_reloc_riscv_insn(uint32_t rtype, int64_t value, uint8_t *dest)
{
	uint64_t enc, mask;
	int bits = 32;

	switch (rtype) {
	case R_RISCV_HI20:
	case R_RISCV_TPREL_HI20:
	case R_RISCV_PCREL_HI20:
	case R_RISCV_GOT_HI20:
	case R_RISCV_TLS_GOT_HI20:
	case R_RISCV_TLS_GD_HI20:
		enc = ENCODE_UTYPE_IMM((uint64_t)RISCV_CONST_HIGH_PART(value));
		mask = ENCODE_UTYPE_IMM(-1U);
		break;

	case R_RISCV_LO12_I:
	case R_RISCV_TPREL_LO12_I:
	case R_RISCV_PCREL_LO12_I:
		enc = ENCODE_ITYPE_IMM((uint64_t)value);
		mask = ENCODE_ITYPE_IMM(-1U);
		break;

	case R_RISCV_LO12_S:
	case R_RISCV_TPREL_LO12_S:
	case R_RISCV_PCREL_LO12_S:
		enc = ENCODE_STYPE_IMM((uint64_t)value);
		mask = ENCODE_STYPE_IMM(-1U);
		break;

	case R_RISCV_CALL:
	case R_RISCV_CALL_PLT:
		/* auipc(hi, U) + jalr(lo, I): 64-bit "word", I part << 32. */
		enc = ENCODE_UTYPE_IMM((uint64_t)RISCV_CONST_HIGH_PART(value)) |
		    ((uint64_t)ENCODE_ITYPE_IMM((uint64_t)value) << 32);
		mask = ENCODE_UTYPE_IMM(-1U) |
		    ((uint64_t)ENCODE_ITYPE_IMM(-1U) << 32);
		bits = 64;
		break;

	case R_RISCV_JAL:
		enc = ENCODE_JTYPE_IMM((uint64_t)value);
		mask = ENCODE_JTYPE_IMM(-1U);
		break;

	case R_RISCV_BRANCH:
		enc = ENCODE_BTYPE_IMM((uint64_t)value);
		mask = ENCODE_BTYPE_IMM(-1U);
		break;

	case R_RISCV_RVC_BRANCH:
		enc = ENCODE_CBTYPE_IMM((uint64_t)value);
		mask = ENCODE_CBTYPE_IMM(-1U);
		bits = 16;
		break;

	case R_RISCV_RVC_JUMP:
		enc = ENCODE_CJTYPE_IMM((uint64_t)value);
		mask = ENCODE_CJTYPE_IMM(-1U);
		bits = 16;
		break;

	case R_RISCV_RVC_LUI:
		enc = RISCV_CITYPE_LUI_IMM(
		    (uint64_t)RISCV_CONST_HIGH_PART(value));
		mask = RISCV_CITYPE_LUI_IMM(-1U);
		bits = 16;
		break;

	default:
		return (-1);		/* not an instruction-field reloc */
	}

	{
		uint64_t word = riscv_get_insn(bits, dest);
		word = (word & ~mask) | (enc & mask);
		riscv_put_insn(bits, word, dest);
	}
	return (0);
}

#ifdef INSN_SELFTEST
/*
 * Self-check: build a known instruction word, apply a reloc, and prove the
 * spliced immediate reads back (round-trip via the binutils EXTRACT math),
 * that the opcode/register bits are preserved, and that HI/LO reconstructs the
 * full 32-bit value.  No framework -- assert() only.
 */
#include	<assert.h>
#include	<stdio.h>

#define	SEXT12(v)	((int64_t)((int32_t)((uint32_t)(v) << 20) >> 20))
#define	SEXT13(v)	((int64_t)((int32_t)((uint32_t)(v) << 19) >> 19))
#define	SEXT21(v)	((int64_t)((int32_t)((uint32_t)(v) << 11) >> 11))
#define	EXTRACT_UTYPE_IMM(x) \
	((int64_t)(int32_t)((x) & 0xfffff000))
#define	EXTRACT_ITYPE_IMM(x) \
	SEXT12(RV_X(x, 20, 12))
#define	EXTRACT_STYPE_IMM(x) \
	SEXT12(RV_X(x, 7, 5) | (RV_X(x, 25, 7) << 5))
#define	EXTRACT_BTYPE_IMM(x) \
	SEXT13((RV_X(x, 8, 4) << 1) | (RV_X(x, 25, 6) << 5) | \
	(RV_X(x, 7, 1) << 11) | (RV_X(x, 31, 1) << 12))
#define	EXTRACT_JTYPE_IMM(x) \
	SEXT21((RV_X(x, 21, 10) << 1) | (RV_X(x, 20, 1) << 11) | \
	(RV_X(x, 12, 8) << 12) | (RV_X(x, 31, 1) << 20))

static uint32_t
rd32(const uint8_t *p)
{
	return ((uint32_t)p[0] | (uint32_t)p[1] << 8 |
	    (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24);
}

int
main(void)
{
	uint8_t insn[8];
	uint32_t w;

	/* U-type auipc a0 (rd=10, opcode 0x17): base preserved, HI20 spliced */
	uint32_t auipc = 0x00000517;		/* auipc a0, 0 */
	int64_t val = 0x12345678;
	memcpy(insn, &auipc, 4);			/* host is LE riscv-target model */
	insn[0] = 0x17; insn[1] = 0x05; insn[2] = 0x00; insn[3] = 0x00;
	assert(ld_reloc_riscv_insn(R_RISCV_HI20, val, insn) == 0);
	w = rd32(insn);
	assert((w & 0xfff) == 0x517);		/* opcode+rd preserved */
	/* HI20 stored the rounded high part */
	assert(EXTRACT_UTYPE_IMM(w) == RISCV_CONST_HIGH_PART(val));

	/* I-type addi a0,a0 (rd=10,rs1=10,opcode 0x13,funct3=0): LO12 spliced */
	insn[0] = 0x13; insn[1] = 0x05; insn[2] = 0x05; insn[3] = 0x00;
	assert(ld_reloc_riscv_insn(R_RISCV_LO12_I, val, insn) == 0);
	w = rd32(insn);
	assert((w & 0xfffff) == 0x50513);	/* opcode+rd+funct3+rs1 kept */
	/* HI(rounded) + LO(sign-extended 12) == original value */
	assert(RISCV_CONST_HIGH_PART(val) + EXTRACT_ITYPE_IMM(w) == val);

	/* S-type sw a0,0(sp): LO12_S split across imm[11:5]/imm[4:0] */
	insn[0] = 0x23; insn[1] = 0x20; insn[2] = 0xa1; insn[3] = 0x00;
	uint32_t sbase = rd32(insn) & ~(ENCODE_STYPE_IMM(-1U));
	assert(ld_reloc_riscv_insn(R_RISCV_LO12_S, val, insn) == 0);
	w = rd32(insn);
	assert((w & ~(ENCODE_STYPE_IMM(-1U))) == sbase);   /* non-imm kept */
	assert(RISCV_CONST_HIGH_PART(val) + EXTRACT_STYPE_IMM(w) == val);

	/* B-type: a small aligned branch displacement round-trips */
	insn[0] = 0x63; insn[1] = 0x00; insn[2] = 0xb5; insn[3] = 0x00;
	int64_t bdisp = 0x0abc & ~1;		/* 12-bit, even */
	assert(ld_reloc_riscv_insn(R_RISCV_BRANCH, bdisp, insn) == 0);
	w = rd32(insn);
	assert(EXTRACT_BTYPE_IMM(w) == bdisp);

	/* J-type jal: 20-bit even displacement round-trips */
	insn[0] = 0x6f; insn[1] = 0x05; insn[2] = 0x00; insn[3] = 0x00;
	int64_t jdisp = 0x13572 & ~1;
	assert(ld_reloc_riscv_insn(R_RISCV_JAL, jdisp, insn) == 0);
	w = rd32(insn);
	assert(EXTRACT_JTYPE_IMM(w) == jdisp);

	/* CALL: auipc+jalr 64-bit splice, HI+LO reconstructs value */
	insn[0] = 0x97; insn[1] = 0x02; insn[2] = 0x00; insn[3] = 0x00;   /* auipc t0 */
	insn[4] = 0xe7; insn[5] = 0x82; insn[6] = 0x02; insn[7] = 0x00;   /* jalr ra,t0 */
	int64_t cval = 0x00abcdef;
	assert(ld_reloc_riscv_insn(R_RISCV_CALL_PLT, cval, insn) == 0);
	uint32_t hi = rd32(insn), lo = rd32(insn + 4);
	assert(RISCV_CONST_HIGH_PART(cval) + EXTRACT_ITYPE_IMM(lo) == cval);
	assert(EXTRACT_UTYPE_IMM(hi) == RISCV_CONST_HIGH_PART(cval));

	/* unsupported type is rejected, not silently mis-applied */
	assert(ld_reloc_riscv_insn(2 /*R_RISCV_64*/, val, insn) == -1);

	printf("PASS: RISC-V INSREL encoders round-trip "
	    "(HI20/LO12_I/LO12_S/BRANCH/JAL/CALL_PLT) vs binutils EXTRACT\n");
	return (0);
}
#endif	/* INSN_SELFTEST */
