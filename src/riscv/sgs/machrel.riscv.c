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
 * Solaris link-editor (sgs/libld) RISC-V (EM_RISCV) machine relocation
 * classification table.
 *
 * This is the sgs-side companion to krtld/doreloc.c's do_reloc() byte-store
 * table.  Where doreloc.c answers "how many bytes does this reloc write", this
 * table answers the questions libld asks while BUILDING an object: does this
 * reloc need a GOT slot, a PLT entry, is it PC-relative, is it a TLS reloc, is
 * it a static-only (link-time, never a dynamic) reloc, and does it splice into
 * an instruction immediate field (so it must be handled by the RISC-V
 * instruction-field path rather than a flat store).
 *
 * In the real gate this content lives in
 *   usr/src/cmd/sgs/libld/common/machrel.riscv.c
 * as the M_R_* switch / reloc-attribute lookups keyed by R_RISCV_*.  It is
 * carried here as a standalone, compilable reloc-classification table so the
 * EM_RISCV mach descriptor has a complete 0..57 mapping (the n-hys fork only
 * classified the 12 dynamic relocs; gcc emits CALL_PLT(19)/PCREL_HI20(23)/
 * PCREL_LO12_I(24)/RELAX(51), which were unclassified and would fault libld).
 *
 * CRIB PROVENANCE:
 *   - reloc numbers + names: uts/common/sys/elf_riscv.h (== RISC-V ELF psABI,
 *     riscv-non-isa/riscv-elf-psabi-doc), reconciled with GNU/binutils.
 *   - per-reloc GOT/PLT/PCREL/TLS/instruction-field classification: binutils
 *     2.44 bfd/elfxx-riscv.c howto_table[] (pc_relative + special_function
 *     columns) and bfd/elfnn-riscv.c relocate_section() dispatch, plus the
 *     RISC-V psABI "Calculation" column.  The flag names follow the illumos
 *     sgs Rel_entry / FLG_RE_* convention used by the other machrel.*.c.
 */

#include	<stdint.h>
#include	"reloc_riscv_table.h"	/* R_RISCV_* + FLG_RE_* + Rel_entry */

/*
 * Classification flags (mirrors the illumos sgs FLG_RE_* set that libld
 * consults; only the subset RISC-V uses is defined in the companion header).
 *
 *   FLG_RE_NOTREL   plain absolute data reloc (no PC bias)
 *   FLG_RE_PCREL    PC-relative
 *   FLG_RE_GOTADD   references/creates a GOT entry
 *   FLG_RE_PLTREL   references/creates a PLT entry
 *   FLG_RE_TLSINS   TLS relocation
 *   FLG_RE_INSREL   splices into an instruction immediate field (B/J/U/I/S,
 *                   RVC) rather than a flat byte store; handled by the RISC-V
 *                   instruction-field relocation path, NOT do_reloc()
 *   FLG_RE_NOTSUP   link-time-only marker / no runtime action (RELAX/ALIGN/
 *                   *_ADD/GNU_VT*)
 *
 * re_fsize is the container width in bytes (0 = variable / no store).
 */
const Rel_entry	sgs_reloc_table_riscv[R_RISCV_NUM] = {
/* 0  R_RISCV_NONE */		{0, FLG_RE_NOTSUP,                 0, 0, 0},
/* 1  R_RISCV_32 */		{0, FLG_RE_NOTREL,                 4, 0, 0},
/* 2  R_RISCV_64 */		{0, FLG_RE_NOTREL,                 8, 0, 0},
/* 3  R_RISCV_RELATIVE */	{0, FLG_RE_NOTREL,                 8, 0, 0},
/* 4  R_RISCV_COPY */		{0, FLG_RE_NOTREL,                 0, 0, 0},
/* 5  R_RISCV_JUMP_SLOT */	{0, FLG_RE_PLTREL,                 8, 0, 0},
/* 6  R_RISCV_TLS_DTPMOD32 */	{0, FLG_RE_TLSINS,                 4, 0, 0},
/* 7  R_RISCV_TLS_DTPMOD64 */	{0, FLG_RE_TLSINS,                 8, 0, 0},
/* 8  R_RISCV_TLS_DTPREL32 */	{0, FLG_RE_TLSINS,                 4, 0, 0},
/* 9  R_RISCV_TLS_DTPREL64 */	{0, FLG_RE_TLSINS,                 8, 0, 0},
/* 10 R_RISCV_TLS_TPREL32 */	{0, FLG_RE_TLSINS,                 4, 0, 0},
/* 11 R_RISCV_TLS_TPREL64 */	{0, FLG_RE_TLSINS,                 8, 0, 0},
/* 12 reserved */		{0, FLG_RE_NOTSUP,                 0, 0, 0},
/* 13 reserved */		{0, FLG_RE_NOTSUP,                 0, 0, 0},
/* 14 reserved */		{0, FLG_RE_NOTSUP,                 0, 0, 0},
/* 15 reserved */		{0, FLG_RE_NOTSUP,                 0, 0, 0},
/* 16 R_RISCV_BRANCH */		{0, FLG_RE_PCREL | FLG_RE_INSREL,  4, 0, 0},
/* 17 R_RISCV_JAL */		{0, FLG_RE_PCREL | FLG_RE_INSREL,  4, 0, 0},
/* 18 R_RISCV_CALL */		{0, FLG_RE_PCREL | FLG_RE_INSREL,  8, 0, 0},
/* 19 R_RISCV_CALL_PLT */	{0, FLG_RE_PCREL | FLG_RE_PLTREL | FLG_RE_INSREL, 8, 0, 0},
/* 20 R_RISCV_GOT_HI20 */	{0, FLG_RE_PCREL | FLG_RE_GOTADD | FLG_RE_INSREL, 4, 0, 0},
/* 21 R_RISCV_TLS_GOT_HI20 */	{0, FLG_RE_PCREL | FLG_RE_GOTADD | FLG_RE_TLSINS | FLG_RE_INSREL, 4, 0, 0},
/* 22 R_RISCV_TLS_GD_HI20 */	{0, FLG_RE_PCREL | FLG_RE_GOTADD | FLG_RE_TLSINS | FLG_RE_INSREL, 4, 0, 0},
/* 23 R_RISCV_PCREL_HI20 */	{0, FLG_RE_PCREL | FLG_RE_INSREL,  4, 0, 0},
/* 24 R_RISCV_PCREL_LO12_I */	{0, FLG_RE_PCREL | FLG_RE_INSREL,  4, 0, 0},
/* 25 R_RISCV_PCREL_LO12_S */	{0, FLG_RE_PCREL | FLG_RE_INSREL,  4, 0, 0},
/* 26 R_RISCV_HI20 */		{0, FLG_RE_INSREL,                 4, 0, 0},
/* 27 R_RISCV_LO12_I */		{0, FLG_RE_INSREL,                 4, 0, 0},
/* 28 R_RISCV_LO12_S */		{0, FLG_RE_INSREL,                 4, 0, 0},
/* 29 R_RISCV_TPREL_HI20 */	{0, FLG_RE_TLSINS | FLG_RE_INSREL, 4, 0, 0},
/* 30 R_RISCV_TPREL_LO12_I */	{0, FLG_RE_TLSINS | FLG_RE_INSREL, 4, 0, 0},
/* 31 R_RISCV_TPREL_LO12_S */	{0, FLG_RE_TLSINS | FLG_RE_INSREL, 4, 0, 0},
/* 32 R_RISCV_TPREL_ADD */	{0, FLG_RE_TLSINS | FLG_RE_NOTSUP, 0, 0, 0},
/* 33 R_RISCV_ADD8 */		{0, FLG_RE_NOTREL,                 1, 0, 0},
/* 34 R_RISCV_ADD16 */		{0, FLG_RE_NOTREL,                 2, 0, 0},
/* 35 R_RISCV_ADD32 */		{0, FLG_RE_NOTREL,                 4, 0, 0},
/* 36 R_RISCV_ADD64 */		{0, FLG_RE_NOTREL,                 8, 0, 0},
/* 37 R_RISCV_SUB8 */		{0, FLG_RE_NOTREL,                 1, 0, 0},
/* 38 R_RISCV_SUB16 */		{0, FLG_RE_NOTREL,                 2, 0, 0},
/* 39 R_RISCV_SUB32 */		{0, FLG_RE_NOTREL,                 4, 0, 0},
/* 40 R_RISCV_SUB64 */		{0, FLG_RE_NOTREL,                 8, 0, 0},
/* 41 R_RISCV_GNU_VTINHERIT */	{0, FLG_RE_NOTSUP,                 0, 0, 0},
/* 42 R_RISCV_GNU_VTENTRY */	{0, FLG_RE_NOTSUP,                 0, 0, 0},
/* 43 R_RISCV_ALIGN */		{0, FLG_RE_NOTSUP,                 0, 0, 0},
/* 44 R_RISCV_RVC_BRANCH */	{0, FLG_RE_PCREL | FLG_RE_INSREL,  2, 0, 0},
/* 45 R_RISCV_RVC_JUMP */	{0, FLG_RE_PCREL | FLG_RE_INSREL,  2, 0, 0},
/* 46 R_RISCV_RVC_LUI */	{0, FLG_RE_INSREL,                 2, 0, 0},
/* 47 R_RISCV_GPREL_I */	{0, FLG_RE_INSREL,                 4, 0, 0},
/* 48 R_RISCV_GPREL_S */	{0, FLG_RE_INSREL,                 4, 0, 0},
/* 49 R_RISCV_TPREL_I */	{0, FLG_RE_TLSINS | FLG_RE_INSREL, 4, 0, 0},
/* 50 R_RISCV_TPREL_S */	{0, FLG_RE_TLSINS | FLG_RE_INSREL, 4, 0, 0},
/* 51 R_RISCV_RELAX */		{0, FLG_RE_NOTSUP,                 0, 0, 0},
/* 52 R_RISCV_SUB6 */		{0, FLG_RE_NOTREL,                 1, 0, 0},
/* 53 R_RISCV_SET6 */		{0, FLG_RE_NOTREL,                 1, 0, 0},
/* 54 R_RISCV_SET8 */		{0, FLG_RE_NOTREL,                 1, 0, 0},
/* 55 R_RISCV_SET16 */		{0, FLG_RE_NOTREL,                 2, 0, 0},
/* 56 R_RISCV_SET32 */		{0, FLG_RE_NOTREL,                 4, 0, 0},
/* 57 R_RISCV_32_PCREL */	{0, FLG_RE_PCREL,                  4, 0, 0},
};
