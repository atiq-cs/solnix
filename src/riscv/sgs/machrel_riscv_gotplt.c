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
 * Solaris link-editor (sgs/libld) EM_RISCV GOT / PLT slot allocation.
 *
 * When libld classifies a reloc as FLG_RE_GOTADD (R_RISCV_GOT_HI20,
 * R_RISCV_TLS_GOT_HI20) or FLG_RE_PLTREL (R_RISCV_CALL_PLT, R_RISCV_JUMP_SLOT),
 * the referenced symbol needs a slot in .got / .got.plt and (for PLT) a stub
 * in .plt.  This module is the arch-specific slot allocator: it assigns each
 * such symbol a GOT and/or PLT index, grows the section sizes accordingly, and
 * emits the RISC-V PLT header + per-entry instruction stubs.
 *
 * RV64 layout constants (binutils bfd/elfnn-riscv.c ~296-307):
 *   GOT_ENTRY_SIZE      = 8   (RISCV_ELF_WORD_BYTES, 64-bit)
 *   PLT_HEADER_INSNS    = 8   PLT_HEADER_SIZE = 32
 *   PLT_ENTRY_INSNS     = 4   PLT_ENTRY_SIZE  = 16
 *   GOTPLT_HEADER_SIZE  = 2 * GOT_ENTRY_SIZE = 16   (.got.plt[0]=_DYNAMIC,
 *                                                    .got.plt[1]=link map)
 * The Nth PLT symbol takes:
 *   .plt      offset  PLT_HEADER_SIZE + N * PLT_ENTRY_SIZE
 *   .got.plt  offset  GOTPLT_HEADER_SIZE + N * GOT_ENTRY_SIZE
 * A GOT (non-PLT) symbol takes .got offset N * GOT_ENTRY_SIZE.
 *
 * PLT entry stub (binutils riscv_make_plt_entry):
 *   auipc  t3, %pcrel_hi(.got.plt[entry])
 *   ld     t3, %pcrel_lo(.got.plt[entry])(t3)
 *   jalr   t1, t3
 *   nop
 * PLT header stub (binutils riscv_make_plt_header): the 8-insn
 * _dl_runtime_resolve trampoline.
 *
 * CRIB PROVENANCE (layout + stub instructions are binutils, NOT invented):
 *   binutils-2.44 bfd/elfnn-riscv.c:
 *     - GOT_ENTRY_SIZE / PLT_*_SIZE / GOTPLT_HEADER_SIZE (~296-307);
 *     - riscv_make_plt_header() 8-insn resolver template (~318);
 *     - riscv_make_plt_entry() 4-insn stub (auipc/ld/jalr/nop) (~356);
 *     - the "PLT_HEADER + N*PLT_ENTRY", ".got.plt GOTPLT_HEADER + N*GOT" and
 *       ".got N*GOT" slot arithmetic (allocate_dynrelocs / size_dynamic_sections
 *       ~1262-1354).
 *   The RISCV_UTYPE/ITYPE/RTYPE opcode encodings plus the X_T register
 *   numbers are binutils include/opcode/riscv.h; reproduced here as literal
 *   instruction builders.
 *
 * In the gate this is the ld_allocate_got / calc_plt_addr / ld_fillin_gotplt
 * portion of usr/src/cmd/sgs/libld/common/machrel.riscv.c.  Standalone +
 * self-testing here so the slot math and stub bytes are proven independently.
 */

#include	<stdint.h>
#include	<string.h>

/* RV64 GOT/PLT layout (binutils constants). */
#define	RISCV_GOT_ENTRY_SIZE	8
#define	RISCV_PLT_HEADER_SIZE	32
#define	RISCV_PLT_ENTRY_SIZE	16
#define	RISCV_GOTPLT_HEADER_SIZE (2 * RISCV_GOT_ENTRY_SIZE)

/* Register numbers (binutils include/opcode/riscv.h X_* / ABI). */
#define	X_T0	5
#define	X_T1	6
#define	X_T2	7
#define	X_T3	28

/* Base opcodes / funct fields for the stub instructions. */
#define	OP_AUIPC	0x17
#define	OP_OP		0x33		/* R-type (sub) */
#define	OP_OPIMM	0x13		/* I-type (addi/srli) */
#define	OP_LOAD		0x03		/* ld */
#define	OP_JALR		0x67
#define	F3_ADDI		0x0
#define	F3_SRLI		0x5
#define	F3_LD		0x3		/* funct3 for ld (64-bit) */
#define	F3_SUB		0x0
#define	F7_SUB		0x20
#define	RISCV_NOP	0x00000013	/* addi x0,x0,0 */

/* Immediate-field encoders (binutils include/opcode/riscv.h). */
#define	RV_X(x, s, n)	(((x) >> (s)) & ((1U << (n)) - 1))
#define	ENCODE_ITYPE_IMM(x)	(RV_X(x, 0, 12) << 20)
#define	ENCODE_UTYPE_IMM(x)	(RV_X(x, 12, 20) << 12)
#define	RISCV_IMM_REACH		(1LL << 12)
#define	RISCV_CONST_HIGH_PART(v) \
	(((v) + (RISCV_IMM_REACH / 2)) & ~(RISCV_IMM_REACH - 1))
#define	RISCV_PCREL_HIGH(target, pc) \
	RISCV_CONST_HIGH_PART((int64_t)(target) - (int64_t)(pc))
#define	RISCV_PCREL_LOW(target, pc) \
	(((int64_t)(target) - (int64_t)(pc)) - \
	RISCV_CONST_HIGH_PART((int64_t)(target) - (int64_t)(pc)))

static uint32_t
rv_utype(uint32_t op, uint32_t rd, int64_t imm)
{
	return (op | (rd << 7) | (uint32_t)ENCODE_UTYPE_IMM((uint64_t)imm));
}
static uint32_t
rv_itype(uint32_t op, uint32_t f3, uint32_t rd, uint32_t rs1, int64_t imm)
{
	return (op | (f3 << 12) | (rd << 7) | (rs1 << 15) |
	    (uint32_t)ENCODE_ITYPE_IMM((uint64_t)imm));
}

/*
 * Per-symbol GOT/PLT bookkeeping.  gd_gotndx / gd_pltndx are -1 until a slot
 * is assigned; assigning is idempotent (a symbol referenced by many relocs
 * gets ONE slot), matching libld's "allocate on first reference" convention.
 */
typedef struct {
	int	gd_gotndx;	/* index into .got (or -1) */
	int	gd_pltndx;	/* index into .plt/.got.plt (or -1) */
} riscv_gotplt_desc_t;

typedef struct {
	uint32_t	ga_ngot;	/* count of .got entries assigned */
	uint32_t	ga_nplt;	/* count of .plt entries assigned */
} riscv_gotplt_alloc_t;

void
ld_riscv_gotplt_init(riscv_gotplt_alloc_t *a)
{
	a->ga_ngot = 0;
	a->ga_nplt = 0;
}

/* Assign a .got slot to a symbol (idempotent). */
int
ld_riscv_assign_got(riscv_gotplt_alloc_t *a, riscv_gotplt_desc_t *d)
{
	if (d->gd_gotndx < 0)
		d->gd_gotndx = (int)a->ga_ngot++;
	return (d->gd_gotndx);
}

/* Assign a .plt (+ paired .got.plt) slot to a symbol (idempotent). */
int
ld_riscv_assign_plt(riscv_gotplt_alloc_t *a, riscv_gotplt_desc_t *d)
{
	if (d->gd_pltndx < 0)
		d->gd_pltndx = (int)a->ga_nplt++;
	return (d->gd_pltndx);
}

/* Byte offset of the Nth .got entry. */
uint64_t
ld_riscv_got_off(int gotndx)
{
	return ((uint64_t)gotndx * RISCV_GOT_ENTRY_SIZE);
}

/* Byte offset of the Nth .plt stub (header comes first). */
uint64_t
ld_riscv_plt_off(int pltndx)
{
	return (RISCV_PLT_HEADER_SIZE + (uint64_t)pltndx * RISCV_PLT_ENTRY_SIZE);
}

/* Byte offset of the Nth symbol's .got.plt entry (2-slot header first). */
uint64_t
ld_riscv_gotplt_off(int pltndx)
{
	return (RISCV_GOTPLT_HEADER_SIZE +
	    (uint64_t)pltndx * RISCV_GOT_ENTRY_SIZE);
}

/* Final .plt section size for ga_nplt symbols (0 if none). */
uint64_t
ld_riscv_plt_size(const riscv_gotplt_alloc_t *a)
{
	if (a->ga_nplt == 0)
		return (0);
	return (RISCV_PLT_HEADER_SIZE +
	    (uint64_t)a->ga_nplt * RISCV_PLT_ENTRY_SIZE);
}

/* Final .got.plt section size (header + one slot per PLT symbol). */
uint64_t
ld_riscv_gotplt_size(const riscv_gotplt_alloc_t *a)
{
	if (a->ga_nplt == 0)
		return (0);
	return (RISCV_GOTPLT_HEADER_SIZE +
	    (uint64_t)a->ga_nplt * RISCV_GOT_ENTRY_SIZE);
}

/* Final .got section size. */
uint64_t
ld_riscv_got_size(const riscv_gotplt_alloc_t *a)
{
	return ((uint64_t)a->ga_ngot * RISCV_GOT_ENTRY_SIZE);
}

/*
 * Emit the 4-instruction PLT entry stub for the pltndx'th symbol into `dest`
 * (16 bytes, little-endian).  plt_addr = run address of this stub;
 * gotplt_addr = run address of this symbol's .got.plt entry.
 * (binutils riscv_make_plt_entry.)
 */
void
ld_riscv_fill_plt_entry(uint8_t *dest, uint64_t plt_addr, uint64_t gotplt_addr)
{
	uint32_t e[4];
	int i;

	e[0] = rv_utype(OP_AUIPC, X_T3, RISCV_PCREL_HIGH(gotplt_addr, plt_addr));
	e[1] = rv_itype(OP_LOAD, F3_LD, X_T3, X_T3,
	    RISCV_PCREL_LOW(gotplt_addr, plt_addr));
	e[2] = rv_itype(OP_JALR, 0, X_T1, X_T3, 0);
	e[3] = RISCV_NOP;

	for (i = 0; i < 4; i++) {
		dest[i * 4 + 0] = (uint8_t)e[i];
		dest[i * 4 + 1] = (uint8_t)(e[i] >> 8);
		dest[i * 4 + 2] = (uint8_t)(e[i] >> 16);
		dest[i * 4 + 3] = (uint8_t)(e[i] >> 24);
	}
}

/*
 * Emit the 8-instruction PLT header (the lazy-resolve trampoline) into `dest`
 * (32 bytes).  plt_addr = run address of .plt[0]; gotplt_addr = run address of
 * .got.plt[0].  (binutils riscv_make_plt_header.)
 */
void
ld_riscv_fill_plt_header(uint8_t *dest, uint64_t plt_addr, uint64_t gotplt_addr)
{
	uint32_t e[8];
	int i;
	int64_t hi = RISCV_PCREL_HIGH(gotplt_addr, plt_addr);
	int64_t lo = RISCV_PCREL_LOW(gotplt_addr, plt_addr);

	e[0] = rv_utype(OP_AUIPC, X_T2, hi);
	e[1] = OP_OP | (F3_SUB << 12) | (X_T1 << 7) | (X_T1 << 15) |
	    (X_T3 << 20) | (F7_SUB << 25);			/* sub t1,t1,t3 */
	e[2] = rv_itype(OP_LOAD, F3_LD, X_T3, X_T2, lo);	/* ld t3,lo(t2) */
	e[3] = rv_itype(OP_OPIMM, F3_ADDI, X_T1, X_T1,
	    -(RISCV_PLT_HEADER_SIZE + 12));			/* addi t1,t1,-.. */
	e[4] = rv_itype(OP_OPIMM, F3_ADDI, X_T0, X_T2, lo);	/* addi t0,t2,lo */
	e[5] = rv_itype(OP_OPIMM, F3_SRLI, X_T1, X_T1, 1);	/* srli t1,t1,1
	    (log2(16/8) for RV64) */
	e[6] = rv_itype(OP_LOAD, F3_LD, X_T0, X_T0,
	    RISCV_GOT_ENTRY_SIZE);				/* ld t0,8(t0) */
	e[7] = rv_itype(OP_JALR, 0, 0, X_T3, 0);		/* jr t3 */

	for (i = 0; i < 8; i++) {
		dest[i * 4 + 0] = (uint8_t)e[i];
		dest[i * 4 + 1] = (uint8_t)(e[i] >> 8);
		dest[i * 4 + 2] = (uint8_t)(e[i] >> 16);
		dest[i * 4 + 3] = (uint8_t)(e[i] >> 24);
	}
}

#ifdef GOTPLT_SELFTEST
/*
 * Proof: slot assignment is idempotent + monotonic, section sizes match the
 * binutils layout, offsets are correctly header-biased, and the emitted PLT
 * entry stub decodes to auipc t3 / ld t3 / jalr t1,t3 / nop with a pcrel
 * hi/lo that reconstructs the .got.plt target.  assert() only.
 */
#include	<assert.h>
#include	<stdio.h>

#define	SEXT12(v)	((int64_t)((int32_t)((uint32_t)(v) << 20) >> 20))
#define	EXTRACT_UTYPE_IMM(x)	((int64_t)(int32_t)((x) & 0xfffff000))
#define	EXTRACT_ITYPE_IMM(x)	SEXT12(RV_X(x, 20, 12))

static uint32_t
rd32(const uint8_t *p)
{
	return ((uint32_t)p[0] | (uint32_t)p[1] << 8 |
	    (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24);
}

int
main(void)
{
	riscv_gotplt_alloc_t a;
	riscv_gotplt_desc_t s0 = { -1, -1 }, s1 = { -1, -1 };
	uint8_t stub[32];

	ld_riscv_gotplt_init(&a);

	/* GOT slot assignment: idempotent, monotonic. */
	assert(ld_riscv_assign_got(&a, &s0) == 0);
	assert(ld_riscv_assign_got(&a, &s0) == 0);	/* same symbol -> same */
	assert(ld_riscv_assign_got(&a, &s1) == 1);
	assert(a.ga_ngot == 2);
	assert(ld_riscv_got_size(&a) == 2 * 8);
	assert(ld_riscv_got_off(1) == 8);

	/* PLT slot assignment + header-biased offsets. */
	assert(ld_riscv_assign_plt(&a, &s0) == 0);
	assert(ld_riscv_assign_plt(&a, &s0) == 0);	/* idempotent */
	assert(ld_riscv_assign_plt(&a, &s1) == 1);
	assert(a.ga_nplt == 2);
	assert(ld_riscv_plt_size(&a) == 32 + 2 * 16);
	assert(ld_riscv_gotplt_size(&a) == 16 + 2 * 8);
	assert(ld_riscv_plt_off(0) == 32);		/* header first */
	assert(ld_riscv_plt_off(1) == 32 + 16);
	assert(ld_riscv_gotplt_off(0) == 16);		/* 2-slot header first */
	assert(ld_riscv_gotplt_off(1) == 16 + 8);

	/* empty allocator: no .plt / .got.plt at all. */
	{
		riscv_gotplt_alloc_t e;
		ld_riscv_gotplt_init(&e);
		assert(ld_riscv_plt_size(&e) == 0);
		assert(ld_riscv_gotplt_size(&e) == 0);
	}

	/*
	 * Emit a PLT entry stub and decode it: auipc t3 / ld t3,lo(t3) /
	 * jalr t1,t3 / nop, and the pcrel hi/lo must reconstruct the target.
	 */
	{
		uint64_t plt = 0x2000, gotplt = 0x3abc;
		uint32_t i0, i1, i2, i3;
		int64_t rebuilt;

		ld_riscv_fill_plt_entry(stub, plt, gotplt);
		i0 = rd32(stub); i1 = rd32(stub + 4);
		i2 = rd32(stub + 8); i3 = rd32(stub + 12);
		assert((i0 & 0x7f) == OP_AUIPC);
		assert(((i0 >> 7) & 0x1f) == X_T3);		/* rd = t3 */
		assert((i1 & 0x7f) == OP_LOAD);
		assert(((i1 >> 12) & 0x7) == F3_LD);
		assert((i2 & 0x7f) == OP_JALR);
		assert(((i2 >> 7) & 0x1f) == X_T1);		/* rd = t1 */
		assert(i3 == RISCV_NOP);
		/* auipc t3 uses PC of stub[0]; ld uses PC of stub[0] too (bfd) */
		rebuilt = plt + EXTRACT_UTYPE_IMM(i0) + EXTRACT_ITYPE_IMM(i1);
		assert(rebuilt == (int64_t)gotplt);
	}

	/* PLT header: 8 insns, first is auipc t2. */
	{
		uint32_t h0;
		ld_riscv_fill_plt_header(stub, 0x2000, 0x3abc);
		h0 = rd32(stub);
		assert((h0 & 0x7f) == OP_AUIPC);
		assert(((h0 >> 7) & 0x1f) == X_T2);
		assert(rd32(stub + 28) != 0);		/* jr t3 emitted */
	}

	printf("PASS: RISC-V GOT/PLT allocation "
	    "(idempotent slots, binutils layout sizes/offsets, PLT stub "
	    "auipc/ld/jalr/nop reconstructs .got.plt target)\n");
	return (0);
}
#endif	/* GOTPLT_SELFTEST */
