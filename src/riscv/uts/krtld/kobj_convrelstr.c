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
 * Copyright 2006 Sun Microsystems, Inc.  All rights reserved.
 * Use is subject to license terms.
 *
 * Portions Copyright 2017 Hayashi Naoyuki; adapted for solnix from
 * n-hys/illumos-gate (usr/src/uts/riscv64/krtld/kobj_convrelstr.c).
 */

#include	<sys/types.h>
#include	"reloc.h"

/*
 * This is a 'stub' of the orignal version defined in liblddbg.so.  This stub
 * returns the 'int string' of the relocation in question instead of converting
 * the relocation to it's full syntax.
 */
const char *
conv_reloc_RISCV_type(Word type)
{
	static char 	strbuf[32];
	int		ndx = 31;

	switch (type) {
	case R_RISCV_NONE:
		return "R_RISCV_NONE";
	case R_RISCV_32:
		return "R_RISCV_32";
	case R_RISCV_64:
		return "R_RISCV_64";
	case R_RISCV_RELATIVE:
		return "R_RISCV_RELATIVE";
	case R_RISCV_COPY:
		return "R_RISCV_COPY";
	case R_RISCV_JUMP_SLOT:
		return "R_RISCV_JUMP_SLOT";
	case R_RISCV_TLS_DTPMOD32:
		return "R_RISCV_TLS_DTPMOD32";
	case R_RISCV_TLS_DTPMOD64:
		return "R_RISCV_TLS_DTPMOD64";
	case R_RISCV_TLS_DTPREL32:
		return "R_RISCV_TLS_DTPREL32";
	case R_RISCV_TLS_DTPREL64:
		return "R_RISCV_TLS_DTPREL64";
	case R_RISCV_TLS_TPREL32:
		return "R_RISCV_TLS_TPREL32";
	case R_RISCV_TLS_TPREL64:
		return "R_RISCV_TLS_TPREL64";
	case R_RISCV_BRANCH:
		return "R_RISCV_BRANCH";
	case R_RISCV_JAL:
		return "R_RISCV_JAL";
	case R_RISCV_CALL:
		return "R_RISCV_CALL";
	case R_RISCV_CALL_PLT:
		return "R_RISCV_CALL_PLT";
	case R_RISCV_GOT_HI20:
		return "R_RISCV_GOT_HI20";
	case R_RISCV_TLS_GOT_HI20:
		return "R_RISCV_TLS_GOT_HI20";
	case R_RISCV_TLS_GD_HI20:
		return "R_RISCV_TLS_GD_HI20";
	case R_RISCV_PCREL_HI20:
		return "R_RISCV_PCREL_HI20";
	case R_RISCV_PCREL_LO12_I:
		return "R_RISCV_PCREL_LO12_I";
	case R_RISCV_PCREL_LO12_S:
		return "R_RISCV_PCREL_LO12_S";
	case R_RISCV_HI20:
		return "R_RISCV_HI20";
	case R_RISCV_LO12_I:
		return "R_RISCV_LO12_I";
	case R_RISCV_LO12_S:
		return "R_RISCV_LO12_S";
	case R_RISCV_TPREL_HI20:
		return "R_RISCV_TPREL_HI20";
	case R_RISCV_TPREL_LO12_I:
		return "R_RISCV_TPREL_LO12_I";
	case R_RISCV_TPREL_LO12_S:
		return "R_RISCV_TPREL_LO12_S";
	case R_RISCV_TPREL_ADD:
		return "R_RISCV_TPREL_ADD";
	case R_RISCV_ADD8:
		return "R_RISCV_ADD8";
	case R_RISCV_ADD16:
		return "R_RISCV_ADD16";
	case R_RISCV_ADD32:
		return "R_RISCV_ADD32";
	case R_RISCV_ADD64:
		return "R_RISCV_ADD64";
	case R_RISCV_SUB8:
		return "R_RISCV_SUB8";
	case R_RISCV_SUB16:
		return "R_RISCV_SUB16";
	case R_RISCV_SUB32:
		return "R_RISCV_SUB32";
	case R_RISCV_SUB64:
		return "R_RISCV_SUB64";
	case R_RISCV_GNU_VTINHERIT:
		return "R_RISCV_GNU_VTINHERIT";
	case R_RISCV_GNU_VTENTRY:
		return "R_RISCV_GNU_VTENTRY";
	case R_RISCV_ALIGN:
		return "R_RISCV_ALIGN";
	case R_RISCV_RVC_BRANCH:
		return "R_RISCV_RVC_BRANCH";
	case R_RISCV_RVC_JUMP:
		return "R_RISCV_RVC_JUMP";
	case R_RISCV_RVC_LUI:
		return "R_RISCV_RVC_LUI";
	case R_RISCV_GPREL_I:
		return "R_RISCV_GPREL_I";
	case R_RISCV_GPREL_S:
		return "R_RISCV_GPREL_S";
	case R_RISCV_TPREL_I:
		return "R_RISCV_TPREL_I";
	case R_RISCV_TPREL_S:
		return "R_RISCV_TPREL_S";
	case R_RISCV_RELAX:
		return "R_RISCV_RELAX";
	case R_RISCV_SUB6:
		return "R_RISCV_SUB6";
	case R_RISCV_SET6:
		return "R_RISCV_SET6";
	case R_RISCV_SET8:
		return "R_RISCV_SET8";
	case R_RISCV_SET16:
		return "R_RISCV_SET16";
	case R_RISCV_SET32:
		return "R_RISCV_SET32";
	case R_RISCV_32_PCREL:
		return "R_RISCV_32_PCREL";
	}

	strbuf[ndx--] = '\0';
	do {
		strbuf[ndx--] = '0' + (type % 10);
		type = type / 10;
	} while ((ndx >= (int)0) && (type > (Word)0));

	return (&strbuf[ndx + 1]);
}
