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
 * Standalone companion for machrel.riscv.c so the EM_RISCV sgs reloc
 * classification table compiles/verifies on its own.  In the real gate the
 * Rel_entry type comes from usr/src/cmd/sgs/include/_libld.h and the FLG_RE_*
 * flags from usr/src/uts/common/krtld/reloc.h; the R_RISCV_* numbers from
 * uts/common/sys/elf_riscv.h.  Kept in sync with those.
 */

#ifndef	_RELOC_RISCV_TABLE_H
#define	_RELOC_RISCV_TABLE_H

#include	<stdint.h>

typedef uint64_t	Xword;
typedef uint32_t	Word;
typedef unsigned char	uchar_t;

/* sgs Rel_entry field order: { re_mask, re_flags, re_fsize, re_bshift, re_sigbits } */
typedef struct {
	Xword	re_mask;
	Word	re_flags;
	uchar_t	re_fsize;
	uchar_t	re_bshift;
	uchar_t	re_sigbits;
} Rel_entry;

/* FLG_RE_* (subset RISC-V uses; values follow the illumos sgs bitfield style) */
#define	FLG_RE_NOTREL	0x00000001
#define	FLG_RE_PCREL	0x00000002
#define	FLG_RE_GOTADD	0x00000004
#define	FLG_RE_PLTREL	0x00000008
#define	FLG_RE_TLSINS	0x00000010
#define	FLG_RE_INSREL	0x00000020
#define	FLG_RE_NOTSUP	0x00000040

/* R_RISCV_* — the full psABI set (mirrors uts/common/sys/elf_riscv.h). */
#define	R_RISCV_NONE		0
#define	R_RISCV_32		1
#define	R_RISCV_64		2
#define	R_RISCV_RELATIVE	3
#define	R_RISCV_COPY		4
#define	R_RISCV_JUMP_SLOT	5
#define	R_RISCV_TLS_DTPMOD32	6
#define	R_RISCV_TLS_DTPMOD64	7
#define	R_RISCV_TLS_DTPREL32	8
#define	R_RISCV_TLS_DTPREL64	9
#define	R_RISCV_TLS_TPREL32	10
#define	R_RISCV_TLS_TPREL64	11
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
#define	R_RISCV_TPREL_ADD	32
#define	R_RISCV_ADD8		33
#define	R_RISCV_ADD16		34
#define	R_RISCV_ADD32		35
#define	R_RISCV_ADD64		36
#define	R_RISCV_SUB8		37
#define	R_RISCV_SUB16		38
#define	R_RISCV_SUB32		39
#define	R_RISCV_SUB64		40
#define	R_RISCV_GNU_VTINHERIT	41
#define	R_RISCV_GNU_VTENTRY	42
#define	R_RISCV_ALIGN		43
#define	R_RISCV_RVC_BRANCH	44
#define	R_RISCV_RVC_JUMP	45
#define	R_RISCV_RVC_LUI		46
#define	R_RISCV_GPREL_I		47
#define	R_RISCV_GPREL_S		48
#define	R_RISCV_TPREL_I		49
#define	R_RISCV_TPREL_S		50
#define	R_RISCV_RELAX		51
#define	R_RISCV_SUB6		52
#define	R_RISCV_SET6		53
#define	R_RISCV_SET8		54
#define	R_RISCV_SET16		55
#define	R_RISCV_SET32		56
#define	R_RISCV_32_PCREL	57
#define	R_RISCV_NUM		58

#endif	/* _RELOC_RISCV_TABLE_H */
