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
 * Copyright 2017 Hayashi Naoyuki
 * Copyright (c) 2004, 2010, Oracle and/or its affiliates. All rights reserved.
 *
 * Portions Copyright 2017 Hayashi Naoyuki; adapted for solnix from
 * n-hys/illumos-gate (usr/src/uts/riscv64/krtld/doreloc.c).
 */

#if	defined(_KERNEL)
#include	<sys/types.h>
#include	"reloc.h"
#else
#define	ELF_TARGET_RISCV
#if defined(DO_RELOC_LIBLD)
#undef DO_RELOC_LIBLD
#define	DO_RELOC_LIBLD_RISCV
#endif
#include	<stdio.h>
#include	"sgs.h"
#include	"machdep.h"
#include	"libld.h"
#include	"reloc.h"
#include	"conv.h"
#include	"msg.h"
#endif

/*
 * We need to build this code differently when it is used for
 * cross linking:
 *	- Data alignment requirements can differ from those
 *		of the running system, so we can't access data
 *		in units larger than a byte
 *	- We have to include code to do byte swapping when the
 *		target and linker host use different byte ordering,
 *		but such code is a waste when running natively.
 */
#if !defined(DO_RELOC_LIBLD) || defined(__riscv)
#define	DORELOC_NATIVE
#endif

/*
 * This table represents the current relocations that do_reloc() is able to
 * process.  The relocations below that are marked SPECIAL are relocations that
 * take special processing and shouldn't actually ever be passed to do_reloc().
 *
 * Field layout (illumos Rel_entry): { re_mask, re_flags, re_fsize, re_bshift,
 * re_sigbits }.  re_fsize is the width in bytes that do_reloc() stores; a byte
 * store only makes sense for the data relocations.  The RISC-V "instruction
 * field" relocations (BRANCH/JAL/CALL/*_HI20/*_LO12_*/RVC_*) splice their value
 * into scattered instruction immediate fields (B/J/U/I/S-type, RVC), which is
 * NOT a flat byte store; those are handled by the link-editor's machrel logic
 * and are marked FLG_RE_NOTSUP here so a flat do_reloc() refuses them rather
 * than corrupting the instruction.  The label-arithmetic relocations
 * (ADD/SUB/SET/SUB6) are read-modify-write byte stores and are handled below.
 *
 * Sizes / pc_relative / semantics cribbed from binutils-2.44
 * bfd/elfxx-riscv.c howto_table[] and the RISC-V ELF psABI
 * (riscv-non-isa/riscv-elf-psabi-doc) "Calculation" column.  Reloc numbers
 * match uts/common/sys/elf_riscv.h (R_RISCV_NUM = 58).
 */
const Rel_entry	reloc_table[R_RISCV_NUM] = {
/* 0  R_RISCV_NONE */		{0, FLG_RE_NOTREL, 0, 0, 0},
/* 1  R_RISCV_32          S + A */	{0, FLG_RE_NOTREL, 4, 0, 0},
/* 2  R_RISCV_64          S + A */	{0, FLG_RE_NOTREL, 8, 0, 0},
/* 3  R_RISCV_RELATIVE    B + A */	{0, FLG_RE_NOTREL, 8, 0, 0},
/* 4  R_RISCV_COPY */		{0, 0,             0, 0, 0},
/* 5  R_RISCV_JUMP_SLOT   S */	{0, FLG_RE_NOTREL, 8, 0, 0},
/* 6  R_RISCV_TLS_DTPMOD32 */	{0, FLG_RE_NOTSUP, 0, 0, 0},
/* 7  R_RISCV_TLS_DTPMOD64 */	{0, FLG_RE_NOTREL, 8, 0, 0},
/* 8  R_RISCV_TLS_DTPREL32 */	{0, FLG_RE_NOTSUP, 0, 0, 0},
/* 9  R_RISCV_TLS_DTPREL64 */	{0, FLG_RE_NOTREL, 8, 0, 0},
/* 10 R_RISCV_TLS_TPREL32 */	{0, FLG_RE_NOTSUP, 0, 0, 0},
/* 11 R_RISCV_TLS_TPREL64 */	{0, FLG_RE_NOTREL, 8, 0, 0},
/* 12 reserved */		{0, FLG_RE_NOTSUP, 0, 0, 0},
/* 13 reserved */		{0, FLG_RE_NOTSUP, 0, 0, 0},
/* 14 reserved */		{0, FLG_RE_NOTSUP, 0, 0, 0},
/* 15 reserved */		{0, FLG_RE_NOTSUP, 0, 0, 0},
/* 16 R_RISCV_BRANCH      S+A-P (B-type)  */	{0, FLG_RE_NOTSUP, 0, 0, 0},
/* 17 R_RISCV_JAL         S+A-P (J-type)  */	{0, FLG_RE_NOTSUP, 0, 0, 0},
/* 18 R_RISCV_CALL        S+A-P (auipc+jalr) */	{0, FLG_RE_NOTSUP, 0, 0, 0},
/* 19 R_RISCV_CALL_PLT    S+A-P via PLT   */	{0, FLG_RE_NOTSUP, 0, 0, 0},
/* 20 R_RISCV_GOT_HI20    G+GOT+A-P (U)   */	{0, FLG_RE_NOTSUP, 0, 0, 0},
/* 21 R_RISCV_TLS_GOT_HI20 */	{0, FLG_RE_NOTSUP, 0, 0, 0},
/* 22 R_RISCV_TLS_GD_HI20 */	{0, FLG_RE_NOTSUP, 0, 0, 0},
/* 23 R_RISCV_PCREL_HI20  S+A-P (U-type)  */	{0, FLG_RE_NOTSUP, 0, 0, 0},
/* 24 R_RISCV_PCREL_LO12_I pair lo (I)    */	{0, FLG_RE_NOTSUP, 0, 0, 0},
/* 25 R_RISCV_PCREL_LO12_S pair lo (S)    */	{0, FLG_RE_NOTSUP, 0, 0, 0},
/* 26 R_RISCV_HI20        S+A (U-type)    */	{0, FLG_RE_NOTSUP, 0, 0, 0},
/* 27 R_RISCV_LO12_I      S+A (I-type)    */	{0, FLG_RE_NOTSUP, 0, 0, 0},
/* 28 R_RISCV_LO12_S      S+A (S-type)    */	{0, FLG_RE_NOTSUP, 0, 0, 0},
/* 29 R_RISCV_TPREL_HI20 */	{0, FLG_RE_NOTSUP, 0, 0, 0},
/* 30 R_RISCV_TPREL_LO12_I */	{0, FLG_RE_NOTSUP, 0, 0, 0},
/* 31 R_RISCV_TPREL_LO12_S */	{0, FLG_RE_NOTSUP, 0, 0, 0},
/* 32 R_RISCV_TPREL_ADD  (relax marker)   */	{0, FLG_RE_NOTSUP, 0, 0, 0},
/* 33 R_RISCV_ADD8        V+S+A (byte)    */	{0, FLG_RE_NOTREL, 1, 0, 0},
/* 34 R_RISCV_ADD16       V+S+A           */	{0, FLG_RE_NOTREL, 2, 0, 0},
/* 35 R_RISCV_ADD32       V+S+A           */	{0, FLG_RE_NOTREL, 4, 0, 0},
/* 36 R_RISCV_ADD64       V+S+A           */	{0, FLG_RE_NOTREL, 8, 0, 0},
/* 37 R_RISCV_SUB8        V-S-A (byte)    */	{0, FLG_RE_NOTREL, 1, 0, 0},
/* 38 R_RISCV_SUB16       V-S-A           */	{0, FLG_RE_NOTREL, 2, 0, 0},
/* 39 R_RISCV_SUB32       V-S-A           */	{0, FLG_RE_NOTREL, 4, 0, 0},
/* 40 R_RISCV_SUB64       V-S-A           */	{0, FLG_RE_NOTREL, 8, 0, 0},
/* 41 R_RISCV_GNU_VTINHERIT */	{0, FLG_RE_NOTSUP, 0, 0, 0},
/* 42 R_RISCV_GNU_VTENTRY */	{0, FLG_RE_NOTSUP, 0, 0, 0},
/* 43 R_RISCV_ALIGN      (relax marker)   */	{0, FLG_RE_NOTSUP, 0, 0, 0},
/* 44 R_RISCV_RVC_BRANCH  S+A-P (CB)      */	{0, FLG_RE_NOTSUP, 0, 0, 0},
/* 45 R_RISCV_RVC_JUMP    S+A-P (CJ)      */	{0, FLG_RE_NOTSUP, 0, 0, 0},
/* 46 R_RISCV_RVC_LUI     S+A (C.LUI)     */	{0, FLG_RE_NOTSUP, 0, 0, 0},
/* 47 R_RISCV_GPREL_I     S+A-GP (I)      */	{0, FLG_RE_NOTSUP, 0, 0, 0},
/* 48 R_RISCV_GPREL_S     S+A-GP (S)      */	{0, FLG_RE_NOTSUP, 0, 0, 0},
/* 49 R_RISCV_TPREL_I     TLS LE (I)      */	{0, FLG_RE_NOTSUP, 0, 0, 0},
/* 50 R_RISCV_TPREL_S     TLS LE (S)      */	{0, FLG_RE_NOTSUP, 0, 0, 0},
/* 51 R_RISCV_RELAX      (relax marker)   */	{0, FLG_RE_NOTSUP, 0, 0, 0},
/* 52 R_RISCV_SUB6        V-S-A (6-bit)   */	{0, FLG_RE_NOTREL, 1, 0, 0},
/* 53 R_RISCV_SET6        S+A (6-bit)     */	{0, FLG_RE_NOTREL, 1, 0, 0},
/* 54 R_RISCV_SET8        S+A (byte)      */	{0, FLG_RE_NOTREL, 1, 0, 0},
/* 55 R_RISCV_SET16       S+A             */	{0, FLG_RE_NOTREL, 2, 0, 0},
/* 56 R_RISCV_SET32       S+A             */	{0, FLG_RE_NOTREL, 4, 0, 0},
/* 57 R_RISCV_32_PCREL    S+A-P           */	{0, FLG_RE_PCREL,  4, 0, 0},
};

#if defined(_KERNEL)
#define	lml	0		/* Needed by arglist of REL_ERR_* macros */
int
do_reloc_krtld(Word rtype, uchar_t *off, Xword *value, const char *sym,
    const char *file)
#elif defined(DO_RELOC_LIBLD)
/*ARGSUSED5*/
int
do_reloc_ld(Rel_desc *rdesc, uchar_t *off, Xword *value,
    rel_desc_sname_func_t rel_desc_sname_func,
    const char *file, int bswap, void *lml)
#else
int
do_reloc_rtld(Word rtype, uchar_t *off, Xword *value, const char *sym,
    const char *file, void *lml)
#endif
{
#ifdef DO_RELOC_LIBLD
#define	sym (* rel_desc_sname_func)(rdesc)
	Word	rtype = rdesc->rel_rtype;
#endif
	Xword	uvalue = 0;
	Xword	corevalue = *value;
	const	Rel_entry	*rep;

	rep = &reloc_table[rtype];

	switch (rep->re_fsize) {
	case 1: case 2: case 4: case 8:
		break;
	default:
		/*
		 * To keep chkmsg() happy: MSG_INTL(MSG_REL_UNSUPSZ)
		 */
		REL_ERR_UNSUPSZ(lml, file, sym, rtype, rep->re_fsize);
		return (0);
	}

	switch (rtype) {
	case R_RISCV_64:
	case R_RISCV_32:
	case R_RISCV_JUMP_SLOT:
	case R_RISCV_RELATIVE:
	case R_RISCV_TLS_DTPMOD64:
	case R_RISCV_TLS_DTPREL64:
	case R_RISCV_TLS_TPREL64:
	case R_RISCV_ADD8:
	case R_RISCV_ADD16:
	case R_RISCV_ADD32:
	case R_RISCV_ADD64:
	case R_RISCV_SUB8:
	case R_RISCV_SUB16:
	case R_RISCV_SUB32:
	case R_RISCV_SUB64:
	case R_RISCV_SUB6:
	case R_RISCV_SET6:
	case R_RISCV_SET8:
	case R_RISCV_SET16:
	case R_RISCV_SET32:
	case R_RISCV_32_PCREL:
		/*
		 * Flat data stores.  For ADD/SUB/SET the caller (link-editor
		 * machrel) has already folded the current field contents into
		 * *value per the psABI "Calculation" column (V +/- S + A), so
		 * do_reloc() just writes it out at re_fsize.
		 */
		uvalue = *value;
		break;
	}

	switch (rep->re_fsize) {
	case 1:
		*((uchar_t *)off) = (uchar_t)uvalue;
		break;
	case 2:
		*((Half *)off) = (Half)uvalue;
		break;
	case 4:
		*((Word *)off) = (Word)uvalue;
		break;
	case 8:
		*((Xword *)off) = uvalue;
		break;
	}
	return (1);

#ifdef DO_RELOC_LIBLD
#undef sym
#endif
}
