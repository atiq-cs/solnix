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
 * Solaris link-editor (sgs/libld) EM_RISCV %pcrel_hi / %pcrel_lo relocation
 * PAIRING.
 *
 * RISC-V forms a 32-bit PC-relative address with two instructions:
 *
 *     auipc  rX, %pcrel_hi(sym)   ; R_RISCV_PCREL_HI20  at address HI
 *     addi   rY, rX, %pcrel_lo(HI); R_RISCV_PCREL_LO12_I (or _S load/store)
 *
 * The %pcrel_hi carries the real target symbol; it computes the high 20 bits
 * of (sym - HI).  The %pcrel_lo does NOT carry the target symbol -- its reloc
 * symbol resolves to the ADDRESS OF THE auipc INSTRUCTION (the HI label).  Its
 * low 12 bits must be taken from the SAME (sym - HI) value the HI computed, so
 * that HI(rounded) + LO(sign-extended) == sym - HI exactly.  The linker must
 * therefore:
 *
 *   1. when it applies a %pcrel_hi, record { HI_site_addr -> value }
 *      (value = S + A - HI_site_addr) in a hash keyed by the HI site address;
 *   2. when it sees a %pcrel_lo, its resolved symbol value is the HI site
 *      address -- defer it, remembering that address;
 *   3. after the section is relocated, resolve every deferred %pcrel_lo by
 *      looking up the HI entry by the recorded HI address and splicing the
 *      HI's stored value (not the LO's own S+A-P) into the LO instruction.
 *
 * This two-pass "record HI, defer LO, resolve LO against HI" model is exactly
 * binutils.  In the illumos gate this bookkeeping lives inside
 * usr/src/cmd/sgs/libld/common/machrel.riscv.c (a Riscv_pcrel_relocs threaded
 * through ld_do_activerelocs over one input section, resolved before the
 * section's output is written) and in krtld/kobj_reloc.c at module-load time.
 *
 * CRIB PROVENANCE (algorithm is binutils, NOT invented here):
 *   binutils-2.44 bfd/elfnn-riscv.c:
 *     - the riscv_pcrel_hi_reloc / riscv_pcrel_lo_reloc / riscv_pcrel_relocs
 *       structs (~1962-2002);
 *     - riscv_record_pcrel_hi_reloc()  offset = value - addr; hash INSERT keyed
 *       by HI address (~2086);
 *     - riscv_record_pcrel_lo_reloc()  the LO's "addr" == its resolved symbol
 *       value == the HI address (~2106, and the relocate_section call site
 *       ~2907 passes `relocation` = the LO symbol value = HI address);
 *     - riscv_resolve_pcrel_lo_relocs()  htab_find by HI address, then
 *       perform_relocation(lo, entry->value) -- splice HI's value into LO
 *       (~2125); the "missing matching %pcrel_hi" and "addend != 0 for
 *       GOT_HI20" / overflow diagnostics.
 *   The immediate splice itself is ld_reloc_riscv_insn() (machrel_riscv_insn.c,
 *   cribbed from perform_relocation()); the HI/LO rounding is
 *   RISCV_CONST_HIGH_PART.
 *
 * Standalone + self-testing here so the pairing logic is proven before the
 * full _libld.h Rel_desc integration; the gate wiring is the same hash, keyed
 * off Rel_desc->rel_roffset (HI) and the LO's resolved symbol value.
 */

#include	<stdint.h>
#include	<stdlib.h>
#include	<string.h>

/* From machrel_riscv_insn.c: the FLG_RE_INSREL immediate splice. */
extern int ld_reloc_riscv_insn(uint32_t rtype, int64_t value, uint8_t *dest);

/* R_RISCV_* subset this module keys on. */
#define	R_RISCV_GOT_HI20	20
#define	R_RISCV_PCREL_HI20	23
#define	R_RISCV_PCREL_LO12_I	24
#define	R_RISCV_PCREL_LO12_S	25
#define	R_RISCV_LO12_I		27
#define	R_RISCV_LO12_S		28

#define	RISCV_IMM_BITS		12
#define	RISCV_IMM_REACH		(1LL << RISCV_IMM_BITS)
#define	RISCV_CONST_HIGH_PART(v) \
	(((v) + (RISCV_IMM_REACH / 2)) & ~(RISCV_IMM_REACH - 1))

/*
 * One recorded %pcrel_hi.  `addr` is the address of the auipc (the HI reloc
 * site) -- the key.  `value` is the pcrel offset the HI computed (S + A - HI),
 * the value a matching %pcrel_lo must reuse.  (binutils riscv_pcrel_hi_reloc.)
 */
typedef struct riscv_pcrel_hi {
	int64_t			ph_addr;	/* auipc site address (key) */
	int64_t			ph_value;	/* S + A - addr */
	uint32_t		ph_type;	/* HI reloc type */
	int			ph_absolute;	/* rewritten to non-pcrel */
	struct riscv_pcrel_hi	*ph_next;
} riscv_pcrel_hi_t;

/*
 * One deferred %pcrel_lo.  `addr` is the resolved value of the LO reloc's
 * symbol == the address of the matching auipc.  (binutils
 * riscv_pcrel_lo_reloc.)
 */
typedef struct riscv_pcrel_lo {
	int64_t			pl_addr;	/* HI (auipc) address to match */
	uint32_t		pl_type;	/* LO12_I / LO12_S */
	int64_t			pl_addend;	/* LO reloc addend */
	uint8_t			*pl_dest;	/* LO instruction site */
	struct riscv_pcrel_lo	*pl_next;
} riscv_pcrel_lo_t;

typedef struct {
	riscv_pcrel_hi_t	*pr_hi;		/* recorded HIs (per section) */
	riscv_pcrel_lo_t	*pr_lo;		/* deferred LOs (per section) */
} riscv_pcrel_relocs_t;

void
ld_riscv_pcrel_init(riscv_pcrel_relocs_t *p)
{
	p->pr_hi = NULL;
	p->pr_lo = NULL;
}

void
ld_riscv_pcrel_fini(riscv_pcrel_relocs_t *p)
{
	riscv_pcrel_hi_t *h = p->pr_hi;
	riscv_pcrel_lo_t *l = p->pr_lo;
	while (h != NULL) {
		riscv_pcrel_hi_t *n = h->ph_next;
		free(h);
		h = n;
	}
	while (l != NULL) {
		riscv_pcrel_lo_t *n = l->pl_next;
		free(l);
		l = n;
	}
	p->pr_hi = NULL;
	p->pr_lo = NULL;
}

/*
 * Record a %pcrel_hi at auipc-site `addr` whose target resolves to `symval` (S)
 * plus reloc `addend` (A).  Splices the HI immediate now (value = S+A-addr) and
 * remembers value keyed by addr so the matching %pcrel_lo reuses it.
 * (binutils riscv_record_pcrel_hi_reloc + the PCREL_HI20 apply.)
 */
int
ld_riscv_record_pcrel_hi(riscv_pcrel_relocs_t *p, uint32_t rtype,
    int64_t addr, int64_t symval, int64_t addend, uint8_t *dest)
{
	riscv_pcrel_hi_t *e = malloc(sizeof (*e));
	int64_t value = symval + addend - addr;		/* S + A - P */

	if (e == NULL)
		return (-1);
	e->ph_addr = addr;
	e->ph_value = value;
	e->ph_type = rtype;
	e->ph_absolute = 0;
	e->ph_next = p->pr_hi;
	p->pr_hi = e;

	/* Apply the HI immediate (auipc high 20). */
	return (ld_reloc_riscv_insn(rtype, value, dest));
}

/*
 * Defer a %pcrel_lo.  `hi_addr` is the LO reloc's resolved symbol value, which
 * is the address of the matching auipc.  Nothing is spliced yet.
 * (binutils riscv_record_pcrel_lo_reloc.)
 */
int
ld_riscv_record_pcrel_lo(riscv_pcrel_relocs_t *p, uint32_t rtype,
    int64_t hi_addr, int64_t addend, uint8_t *dest)
{
	riscv_pcrel_lo_t *e = malloc(sizeof (*e));

	if (e == NULL)
		return (-1);
	e->pl_addr = hi_addr;
	e->pl_type = rtype;
	e->pl_addend = addend;
	e->pl_dest = dest;
	e->pl_next = p->pr_lo;
	p->pr_lo = e;
	return (0);
}

static riscv_pcrel_hi_t *
riscv_find_hi(riscv_pcrel_relocs_t *p, int64_t addr)
{
	riscv_pcrel_hi_t *h;
	for (h = p->pr_hi; h != NULL; h = h->ph_next)
		if (h->ph_addr == addr)		/* NOTE: O(n) list scan;
			gate uses a hash (htab) keyed by HI addr -- swap in
			when a section has many pcrel pairs */
			return (h);
	return (NULL);
}

/*
 * Resolve every deferred %pcrel_lo against its recorded %pcrel_hi.  For each,
 * find the HI by the auipc address, then splice the HI's stored value (not the
 * LO's own S+A-P) into the LO immediate.  Returns 0 on success, -1 if a LO has
 * no matching HI or an addend rule is violated (the caller reports the
 * dangerous-relocation error).
 * (binutils riscv_resolve_pcrel_lo_relocs.)
 */
int
ld_riscv_resolve_pcrel_lo(riscv_pcrel_relocs_t *p)
{
	riscv_pcrel_lo_t *l;

	for (l = p->pr_lo; l != NULL; l = l->pl_next) {
		riscv_pcrel_hi_t *hi = riscv_find_hi(p, l->pl_addr);

		if (hi == NULL)
			return (-1);		/* missing matching %pcrel_hi */

		/*
		 * A %pcrel_lo with a nonzero addend against a GOT_HI20 is
		 * disallowed (the HI was redirected to the PLT/GOT).  binutils
		 * "%pcrel_lo with addend isn't allowed for R_RISCV_GOT_HI20".
		 */
		if (hi->ph_type == R_RISCV_GOT_HI20 && l->pl_addend != 0)
			return (-1);

		/*
		 * Adding the LO addend must not push the value into a different
		 * high part (that would break the HI/LO agreement).  binutils
		 * "%pcrel_lo overflow with an addend".
		 */
		if (RISCV_CONST_HIGH_PART(hi->ph_value) !=
		    RISCV_CONST_HIGH_PART(hi->ph_value + l->pl_addend))
			return (-1);

		/*
		 * Splice the HI's value (the shared S+A-HI) into the LO
		 * immediate.  Both HI and LO thus encode the same pcrel value,
		 * so HI(rounded high 20) + LO(sign-extended low 12) == S+A-HI.
		 */
		if (ld_reloc_riscv_insn(l->pl_type, hi->ph_value, l->pl_dest)
		    != 0)
			return (-1);
	}
	return (0);
}

#ifdef PCREL_SELFTEST
/*
 * Proof the pairing reconstructs a real PC-relative address across an
 * auipc/addi pair, matching what GNU ld produces:
 *   (a) a normal HI/LO pair: the reassembled hi<<12-rounded + lo(sext) equals
 *       (S + A - PC) -- i.e. loading `sym` PC-relative works;
 *   (b) LO resolved out of the RECORDED HI value even when the LO reloc's own
 *       symbol is the auipc address, not sym (the whole point of the pairing);
 *   (c) a LO with no matching HI is rejected;
 *   (d) a byte-for-byte check against the known-good GNU-ld bytes for the
 *       R-P19.3 riscv64_boot_label pair (auipc a5 + addi a5).
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

int
main(void)
{
	riscv_pcrel_relocs_t pr;
	uint8_t buf[8];

	/*
	 * (a)+(b): sym S at 0x00021abc, auipc HI site at PC 0x8000.
	 * The addi's %pcrel_lo(HI) reloc symbol resolves to 0x8000 (the HI
	 * address), NOT to sym.  The pairing must still reconstruct S-PC.
	 */
	int64_t S = 0x00021abc, A = 0, HI = 0x8000;
	ld_riscv_pcrel_init(&pr);

	/* auipc a5,0 (0x00000797) ; addi a5,a5,0 (0x00078793) */
	buf[0] = 0x97; buf[1] = 0x07; buf[2] = 0x00; buf[3] = 0x00;
	buf[4] = 0x93; buf[5] = 0x87; buf[6] = 0x07; buf[7] = 0x00;

	assert(ld_riscv_record_pcrel_hi(&pr, R_RISCV_PCREL_HI20, HI, S, A,
	    buf) == 0);
	/* LO reloc symbol == HI address 0x8000, addend 0. */
	assert(ld_riscv_record_pcrel_lo(&pr, R_RISCV_PCREL_LO12_I, HI, 0,
	    buf + 4) == 0);
	assert(ld_riscv_resolve_pcrel_lo(&pr) == 0);

	{
		uint32_t hi = rd32(buf), lo = rd32(buf + 4);
		int64_t rebuilt = EXTRACT_UTYPE_IMM(hi) + EXTRACT_ITYPE_IMM(lo);
		assert(rebuilt == S + A - HI);		/* PC-relative to sym */
		/* base opcode/reg bits survived */
		assert((hi & 0xfff) == 0x797);		/* auipc a5 */
		assert((lo & 0xfffff) == 0x78793);	/* addi a5,a5 */
	}
	ld_riscv_pcrel_fini(&pr);

	/* (c): a LO with no matching HI is an error. */
	ld_riscv_pcrel_init(&pr);
	buf[0] = 0x93; buf[1] = 0x87; buf[2] = 0x07; buf[3] = 0x00;
	assert(ld_riscv_record_pcrel_lo(&pr, R_RISCV_PCREL_LO12_I,
	    0xdead, 0, buf) == 0);
	assert(ld_riscv_resolve_pcrel_lo(&pr) == -1);
	ld_riscv_pcrel_fini(&pr);

	/*
	 * (d): the R-P19.3 fact -- GNU ld emitted auipc a5,0x1 (0x00001797) +
	 * addi a5,a5,168 (0x0a878793) for the riscv64_boot_label pair when the
	 * pcrel offset was 0x10a8 at that site.  Feed value 0x10a8 and confirm
	 * the pairing produces exactly those bytes.
	 */
	ld_riscv_pcrel_init(&pr);
	buf[0] = 0x97; buf[1] = 0x07; buf[2] = 0x00; buf[3] = 0x00;
	buf[4] = 0x93; buf[5] = 0x87; buf[6] = 0x07; buf[7] = 0x00;
	/* S - HI == 0x10a8 : choose S=0x10a8, HI=0. */
	assert(ld_riscv_record_pcrel_hi(&pr, R_RISCV_PCREL_HI20, 0, 0x10a8, 0,
	    buf) == 0);
	assert(ld_riscv_record_pcrel_lo(&pr, R_RISCV_PCREL_LO12_I, 0, 0,
	    buf + 4) == 0);
	assert(ld_riscv_resolve_pcrel_lo(&pr) == 0);
	assert(rd32(buf) == 0x00001797);	/* auipc a5,0x1 */
	assert(rd32(buf + 4) == 0x0a878793);	/* addi a5,a5,168 */
	ld_riscv_pcrel_fini(&pr);

	printf("PASS: RISC-V %%pcrel_hi/%%pcrel_lo pairing "
	    "(reconstruct S-PC across auipc/addi, LO resolved from recorded "
	    "HI, missing-HI rejected, GNU-ld bytes 0x00001797/0x0a878793)\n");
	return (0);
}
#endif	/* PCREL_SELFTEST */
