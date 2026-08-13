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
 * elf_riscv.h — the COMPLETE RISC-V ELF psABI relocation set for the illumos
 * gate path uts/common/sys/elf_riscv.h, plus the ELF64 PLT/GOT machine defines.
 *
 * PROVENANCE / crib note:
 *   The R_RISCV_* relocation-type numbers (0..57) are the RISC-V ELF psABI
 *   (github.com/riscv-non-isa/riscv-elf-psabi-doc), which is OS-independent.
 *   The full ordered table here is CRIBBED from NetBSD-current
 *       src/sys/arch/riscv/include/elf_machdep.h  (rev 1.11, jkoshy)
 *   — the mature BSD riscv64 reference — and reconciled with the GNU/binutils
 *   canonical names. Only the ABI-visible dynamic subset (0..11) existed in the
 *   n-hys illumos fork's uts/common/sys/elf_riscv.h (R_RISCV_NUM was 12); that
 *   subset is insufficient for actually relocating compiler output. A trivial
 *   `gcc -c` on this port's own cross toolchain (riscv64-unknown-elf, binutils
 *   2.44 / gcc 14.3.0) emits R_RISCV_CALL_PLT(19), R_RISCV_PCREL_HI20(23),
 *   R_RISCV_PCREL_LO12_I(24) and R_RISCV_RELAX(51) — none in the 12-entry set —
 *   so the Solaris link-editor (sgs) and krtld's do_reloc() MUST know the whole
 *   table. This header supplies it.
 *
 * NAMING: the psABI/GNU canonical spelling of reloc 5 is R_RISCV_JUMP_SLOT
 *   (binutils, glibc). The n-hys fork also used R_RISCV_JUMP_SLOT; NetBSD spells
 *   it R_RISCV_JMP_SLOT. We keep the GNU/illumos spelling R_RISCV_JUMP_SLOT and
 *   provide R_RISCV_JMP_SLOT as an alias so BSD-derived reloc tables port cleanly.
 */

#ifndef	_SYS_ELF_RISCV_H
#define	_SYS_ELF_RISCV_H

#ifdef	__cplusplus
extern "C" {
#endif

#define	ELF_RISCV_MAXPGSZ	0x200000	/* maximum page size (2 MiB) */

/*
 * RISC-V relocation types — the FULL psABI set. R_RISCV_NUM must cover the
 * whole table so reloc_table[] in krtld/doreloc.c and the sgs reloc engine
 * are sized correctly (was 12 in the n-hys fork; the real ABI has 0..57).
 */
#define	R_RISCV_NONE		0
#define	R_RISCV_32		1	/* S + A (32-bit) */
#define	R_RISCV_64		2	/* S + A (64-bit) */
#define	R_RISCV_RELATIVE	3	/* B + A */
#define	R_RISCV_COPY		4	/* must copy at load time */
#define	R_RISCV_JUMP_SLOT	5	/* create PLT entry (S) */
#define	R_RISCV_JMP_SLOT	R_RISCV_JUMP_SLOT	/* BSD/psABI alias */
#define	R_RISCV_TLS_DTPMOD32	6
#define	R_RISCV_TLS_DTPMOD64	7
#define	R_RISCV_TLS_DTPREL32	8
#define	R_RISCV_TLS_DTPREL64	9
#define	R_RISCV_TLS_TPREL32	10
#define	R_RISCV_TLS_TPREL64	11
/* 12..15 reserved */
#define	R_RISCV_BRANCH		16	/* PC-relative 12-bit B-type branch */
#define	R_RISCV_JAL		17	/* PC-relative 20-bit J-type jump */
#define	R_RISCV_CALL		18	/* PC-relative call (auipc+jalr pair) */
#define	R_RISCV_CALL_PLT	19	/* PC-relative call via PLT */
#define	R_RISCV_GOT_HI20	20	/* PC-relative GOT ref, %got_pcrel_hi */
#define	R_RISCV_TLS_GOT_HI20	21	/* PC-relative TLS IE GOT ref */
#define	R_RISCV_TLS_GD_HI20	22	/* PC-relative TLS GD GOT ref */
#define	R_RISCV_PCREL_HI20	23	/* PC-relative %pcrel_hi20 (auipc) */
#define	R_RISCV_PCREL_LO12_I	24	/* PC-relative %pcrel_lo12 (I-type) */
#define	R_RISCV_PCREL_LO12_S	25	/* PC-relative %pcrel_lo12 (S-type) */
#define	R_RISCV_HI20		26	/* absolute %hi20 (lui) */
#define	R_RISCV_LO12_I		27	/* absolute %lo12 (I-type) */
#define	R_RISCV_LO12_S		28	/* absolute %lo12 (S-type) */
#define	R_RISCV_TPREL_HI20	29	/* TLS LE %tprel_hi20 */
#define	R_RISCV_TPREL_LO12_I	30	/* TLS LE %tprel_lo12 (I-type) */
#define	R_RISCV_TPREL_LO12_S	31	/* TLS LE %tprel_lo12 (S-type) */
#define	R_RISCV_TPREL_ADD	32	/* TLS LE add for relaxation */
#define	R_RISCV_ADD8		33	/* 8-bit label subtraction: +S+A */
#define	R_RISCV_ADD16		34
#define	R_RISCV_ADD32		35
#define	R_RISCV_ADD64		36
#define	R_RISCV_SUB8		37	/* 8-bit label subtraction: -S-A */
#define	R_RISCV_SUB16		38
#define	R_RISCV_SUB32		39
#define	R_RISCV_SUB64		40
#define	R_RISCV_GNU_VTINHERIT	41	/* GNU C++ vtable hierarchy */
#define	R_RISCV_GNU_VTENTRY	42	/* GNU C++ vtable member usage */
#define	R_RISCV_ALIGN		43	/* alignment statement for relax */
#define	R_RISCV_RVC_BRANCH	44	/* PC-relative compressed branch */
#define	R_RISCV_RVC_JUMP	45	/* PC-relative compressed jump */
#define	R_RISCV_RVC_LUI		46	/* absolute compressed lui */
#define	R_RISCV_GPREL_I		47	/* GP-relative (I-type) */
#define	R_RISCV_GPREL_S		48	/* GP-relative (S-type) */
#define	R_RISCV_TPREL_I		49	/* TP-relative (I-type) */
#define	R_RISCV_TPREL_S		50	/* TP-relative (S-type) */
#define	R_RISCV_RELAX		51	/* instruction pair may be relaxed */
#define	R_RISCV_SUB6		52	/* 6-bit label subtraction */
#define	R_RISCV_SET6		53	/* 6-bit set */
#define	R_RISCV_SET8		54	/* 8-bit set */
#define	R_RISCV_SET16		55	/* 16-bit set */
#define	R_RISCV_SET32		56	/* 32-bit set */
#define	R_RISCV_32_PCREL	57	/* 32-bit PC-relative (S+A-P), FDE */

#define	R_RISCV_NUM		58	/* one past the last defined type */

/* psABI aliases used by some reloc engines. */
#define	R_RISCV_ADDR32		R_RISCV_32
#define	R_RISCV_ADDR64		R_RISCV_64

/*
 * Processor specific section types (shared illumos conventions).
 */
#define	SHF_ORDERED		0x40000000
#define	SHF_EXCLUDE		0x80000000
#define	SHN_BEFORE		0xff00
#define	SHN_AFTER		0xff01

/*
 * There are consumers of this file that want to include elf defines for
 * all architectures.  Guard the common-named machine defines so a
 * multi-arch include does not double-define them.
 */
#if !defined(_SYS_ELF_MACH_COMMON)
#define	_SYS_ELF_MACH_COMMON

/*
 * Plt and Got information; the first few .got and .plt entries are reserved.
 *	PLT[0]	jump to dynamic linker
 *	GOT[0]	address of _DYNAMIC
 * The riscv64 PLT0 is a fixed 32-byte thunk (auipc/ld/jalr sequence) that
 * loads GOT[1] (the rtld resolver) and jumps via GOT[0] (the link map);
 * subsequent PLT entries are 16 bytes.
 */
#define	M_PLT_INSSIZE		4	/* single plt instruction size */
#define	M_GOT_XDYNAMIC		0	/* got index for _DYNAMIC */
#define	M_GOT_XLINKMAP		1	/* got index for link map (rtld) */
#define	M_GOT_XRTLD		2	/* got index for rtld bind routine */
#define	M_GOT_XNumber		3	/* reserved no. of got entries */

/*
 * ELF64 PLT/GOT constants (riscv64 is 64-bit only for illumos).
 */
#define	M64_WORD_ALIGN		8
#define	M64_PLT_ENTSIZE		16	/* plt entry size in bytes */
#define	M64_PLT_ALIGN		16	/* alignment of .plt section */
#define	M64_GOT_ENTSIZE		8	/* got entry size in bytes */
#define	M64_PLT_RESERVSZ	32	/* PLT0 thunk size */

/* architecture common aliases (LP64D → the 64-bit defines) */
#define	M_WORD_ALIGN		M64_WORD_ALIGN
#define	M_PLT_ENTSIZE		M64_PLT_ENTSIZE
#define	M_PLT_ALIGN		M64_PLT_ALIGN
#define	M_PLT_RESERVSZ		M64_PLT_RESERVSZ
#define	M_GOT_ENTSIZE		M64_GOT_ENTSIZE

#endif /* !_SYS_ELF_MACH_COMMON */

#ifdef	__cplusplus
}
#endif

#endif	/* _SYS_ELF_RISCV_H */
