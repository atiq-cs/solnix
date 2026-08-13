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
 *	Copyright (c) 1984, 1986, 1987, 1988, 1989 AT&T
 *	  All Rights Reserved
 *
 * Copyright 2009 Sun Microsystems, Inc.  All rights reserved.
 * Use is subject to license terms.
 */
/*
 * Copyright 2019 Hayashi Naoyuki
 *
 * Portions Copyright 2019 Hayashi Naoyuki; adapted for solnix from
 * n-hys/illumos-gate (usr/src/uts/common/sys/elf_riscv.h).
 */

#pragma once

#ifdef	__cplusplus
extern "C" {
#endif

#define	ELF_RISCV_MAXPGSZ	0x200000	/* maximum page size */

/*
 * RISC-V relocation types — the FULL psABI set (0..57).  Cribbed from the
 * RISC-V ELF psABI (riscv-non-isa/riscv-elf-psabi-doc) and reconciled with the
 * GNU/binutils canonical names in bfd/elfxx-riscv.c; matches
 * uts/common/sys/elf_riscv.h.  The n-hys fork stopped at R_RISCV_TLS_TPREL64
 * (R_RISCV_NUM was 12), so reloc_table[rtype] out-of-bounds read on the
 * CALL_PLT(19)/PCREL_HI20(23)/RELAX(51) that gcc actually emits.
 */
#define R_RISCV_NUM		58

#define	R_RISCV_NONE		0
#define	R_RISCV_32		1
#define	R_RISCV_64		2
#define	R_RISCV_RELATIVE	3
#define	R_RISCV_COPY		4
#define	R_RISCV_JUMP_SLOT	5
#define	R_RISCV_JMP_SLOT	R_RISCV_JUMP_SLOT
#define	R_RISCV_TLS_DTPMOD32	6
#define	R_RISCV_TLS_DTPMOD64	7
#define	R_RISCV_TLS_DTPREL32	8
#define	R_RISCV_TLS_DTPREL64	9
#define	R_RISCV_TLS_TPREL32	10
#define	R_RISCV_TLS_TPREL64	11
/* 12..15 reserved */
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

/*
 * Processor specific section types
 */
#define	SHF_ORDERED		0x40000000
#define	SHF_EXCLUDE		0x80000000
#define	SHN_BEFORE		0xff00
#define	SHN_AFTER		0xff01

/*
 * There are consumers of this file that want to include elf defines for
 * all architectures.  This is a problem for the defines below, because
 * while they are architecture specific they have common names.  Hence to
 * prevent attempts to redefine these variables we'll check if any of
 * the other elf architecture header files have been included.  If
 * they have then we'll just stick with the existing definitions.
 */
#if !defined(_SYS_ELF_MACH_COMMON)
#define	_SYS_ELF_MACH_COMMON

/*
 * Plt and Got information; the first few .got and .plt entries are reserved
 *	PLT[0]	jump to dynamic linker
 *	GOT[0]	address of _DYNAMIC
 */
#define	M_PLT_INSSIZE		4	/* single plt instruction size */
#define	M_GOT_XDYNAMIC		0	/* got index for _DYNAMIC */
#define	M_GOT_XNumber		3	/* reserved no. of got entries */

/*
 * ELF64 bit PLT constants
 */
#define	M64_WORD_ALIGN		8
#define	M64_PLT_ENTSIZE		16	/* plt entry size in bytes */
#define	M64_PLT_ALIGN		16	/* alignment of .plt section */
#define	M64_GOT_ENTSIZE		8	/* got entry size in bytes */
#define	M64_PLT_RESERVSZ	32

/*
 * Make common alias for the 64 bit specific defines based on _ELF64
 */
/* architecture common defines */
#define	M_WORD_ALIGN		M64_WORD_ALIGN
#define	M_PLT_ENTSIZE		M64_PLT_ENTSIZE
#define	M_PLT_ALIGN		M64_PLT_ALIGN
#define	M_PLT_RESERVSZ		M64_PLT_RESERVSZ
#define	M_GOT_ENTSIZE		M64_GOT_ENTSIZE

#endif /* !_SYS_ELF_MACH_COMMON */

#ifdef	__cplusplus
}
#endif

