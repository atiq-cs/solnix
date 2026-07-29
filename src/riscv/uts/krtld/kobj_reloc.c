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
 * Copyright 2007 Sun Microsystems, Inc.  All rights reserved.
 * Use is subject to license terms.
 *
 * Portions Copyright 2017 Hayashi Naoyuki; adapted for solnix from
 * n-hys/illumos-gate (usr/src/uts/riscv64/krtld/kobj_reloc.c).
 */


#include <sys/types.h>
#include <sys/param.h>
#include <sys/sysmacros.h>
#include <sys/systm.h>
#include <sys/user.h>
#include <sys/bootconf.h>
#include <sys/modctl.h>
#include <sys/elf.h>
#include <sys/kobj.h>
#include <sys/kobj_impl.h>
#include <vm/hat.h>
#include <sys/sdt_impl.h>
#include <sys/sbi.h>

#include "reloc.h"

#define	SDT_NOP		0x00000013

static uint64_t
sign_extend(uint64_t v, int num)
{
	return ((v + (1ul << (num - 1))) & ((1ul << num) - 1)) - (1ul << (num - 1));
}

__attribute__((weak))
int
sdt_write_instruction(sdt_instr_t *inst, sdt_instr_t val)
{
	*inst = val;
	sbi_remote_fence_i(0, -1ul);
	return 0;
}

static int
sdt_check_probepoint(struct module *mp, uintptr_t probe_start, uintptr_t probe_end, uintptr_t addr)
{
	uintptr_t* _probe_start = (uintptr_t *)probe_start;
	uintptr_t* _probe_end = (uintptr_t *)probe_end;
	while (_probe_start < _probe_end) {
		//_kobj_printf(ops, "%s: %lx %lx\n", mp->filename, *_probe_start, addr);
		if (*_probe_start == addr)
			return 0;
		_probe_start++;
	}
	return -1;
}

static int
sdt_reloc_resolve(struct module *mp, char *symname, uintptr_t jmpslot, uint_t rtype, int nreloc)
{
	/*
	 * The "statically defined tracing" (SDT) provider for DTrace uses
	 * a mechanism similar to TNF, but somewhat simpler.  (Surprise,
	 * surprise.)  The SDT mechanism works by replacing calls to the
	 * undefined routine __dtrace_probe_[name] with nop instructions.
	 * The relocations are logged, and SDT itself will later patch the
	 * running binary appropriately.
	 */
	if (strncmp(symname, sdt_prefix, strlen(sdt_prefix)) != 0)
		return (1);

	if (rtype != R_RISCV_JUMP_SLOT)
		return (1);

	uintptr_t probe_start = 0;
	uintptr_t probe_end = 0;

	if (mp->dso) {
		for (Word stndx = 0; stndx < mp->nsyms; stndx++) {
			Sym *symp = (Sym *)(mp->symtbl+(stndx * mp->symhdr->sh_entsize));
			const char *symname = (const char *)mp->strings + symp->st_name;
			if (strcmp(symname, "_probepoints_start") == 0)
				probe_start = symp->st_value;
			else if (strcmp(symname, "_probepoints_end") == 0)
				probe_end = symp->st_value;
		}
	} else {
		extern uintptr_t _probepoints_start[];
		extern uintptr_t _probepoints_end[];
		probe_start = (uintptr_t)_probepoints_start;
		probe_end = (uintptr_t)_probepoints_end;
	}

	//_kobj_printf(ops, "%s:%d probe_start = %lx\n",__func__,__LINE__,probe_start);
	//_kobj_printf(ops, "%s:%d probe_end   = %lx\n",__func__,__LINE__,probe_end);

	symname += strlen(sdt_prefix);

	uintptr_t text = (uintptr_t)(mp->dso? mp->dso: mp->text);
	int i;
	for (i = 0; i < nreloc; i++) {
		sdt_instr_t *plt = (sdt_instr_t *)(text + i * 0x10 + 0x20);
		// is auipc t3 ?
		if ((plt[0] & 0x00000fff) != 0x00000e17)
			return (1);

		// auipc t3, <label>
		uint64_t offset = (plt[0] & 0xfffff000);
		offset = sign_extend(offset, 32);
		uintptr_t slot = (uintptr_t)(&plt[0]) + offset;

		// ld t3, imm(t3)
		if ((plt[1] & 0x000fffff) != 0x000e3e03)
			return (1);
		offset = ((plt[1] >> 20) & ((1u << 12) - 1));
		offset = sign_extend(offset, 12);
		if (slot + offset == jmpslot)
			break;
	}
	if (i == nreloc) {
		return 1;
	}
	uintptr_t plt_offset = i * 0x10 + 0x20;
	size_t text_size = (mp->dso? mp->dso_text_size: mp->text_size);
	for (size_t off = 0; off < text_size; off += 4) {
		sdt_instr_t instr = *(sdt_instr_t *)(text + off);
		if ((instr & 0xfff) == 0x0ef) {
			// jal ra, 
			uint64_t literal_offset =
			    (((instr >> 31) & 0x1) << 20) |
			    (((instr >> 21) & 0x3FF) << 1) |
			    (((instr >> 20) & 0x1) << 11) |
			    (((instr >> 12) & 0xFF) << 12);
			literal_offset = sign_extend(literal_offset, 21);

			if (off + literal_offset == plt_offset) {
				uintptr_t base = (uintptr_t)(mp->dso? mp->dso: 0);
				if (sdt_check_probepoint(mp, base+ probe_start, base + probe_end, text + off) < 0) {
					_kobj_printf(ops, "sdt not found %lx %lx %s %s\n", text, off, mp->filename, symname);
					continue;
				}
				sdt_probedesc_t *sdp = kobj_alloc(sizeof (sdt_probedesc_t), KM_WAIT);
				sdp->sdpd_name = kobj_alloc(strlen(symname) + 1, KM_WAIT);
				bcopy(symname, sdp->sdpd_name, strlen(symname) + 1);
				sdp->sdpd_offset = text + off;
				sdp->sdpd_next = mp->sdt_probes;
				mp->sdt_probes = sdp;
				//_kobj_printf(ops, "sdt found %lx %s %lx\n", off, mp->filename, plt_offset);
				sdt_write_instruction((sdt_instr_t *)(text + off), SDT_NOP);
			}
		}
		else if ((instr & 0x000fffff) == 0x080e7) {
			// jalr	imm(ra)

			if (off < 4)
				continue;
			sdt_instr_t instr0 = *(sdt_instr_t *)(text + off - 4);
			if ((instr0 & 0x00000fff) != 0x00000097)
				continue;
			uint64_t offset = instr0 & 0xfffff000;
			offset = (off - 4) + sign_extend(offset, 32) + sign_extend((instr >> 20), 12);
			if (offset == plt_offset) {
				uintptr_t base = (uintptr_t)(mp->dso? mp->dso: 0);
				if (sdt_check_probepoint(mp, base+ probe_start, base + probe_end, text + off - 4) < 0) {
					_kobj_printf(ops, "sdt not found %lx %lx %s %s\n", text, off, mp->filename, symname);
					continue;
				}
				sdt_probedesc_t *sdp = kobj_alloc(sizeof (sdt_probedesc_t), KM_WAIT);
				sdp->sdpd_name = kobj_alloc(strlen(symname) + 1, KM_WAIT);
				bcopy(symname, sdp->sdpd_name, strlen(symname) + 1);
				sdp->sdpd_offset = text + off;
				sdp->sdpd_next = mp->sdt_probes;
				mp->sdt_probes = sdp;
				//_kobj_printf(ops, "sdt found %lx %s %lx\n", off, mp->filename, plt_offset);
				sdt_write_instruction((sdt_instr_t *)(text + off), SDT_NOP);
			}
		}
	}

	return (0);
}

int
/* ARGSUSED2 */
do_relocate(struct module *mp, char *reltbl, int nreloc,
	int relocsize, Addr baseaddr)
{
	Word stndx;
	long off;
	uintptr_t reladdr, rend;
	uint_t rtype;
	Elf64_Sxword addend;
	Addr value, destination;
	Sym *symref;
	int symnum;
	int err = 0;
	char *name = "";

	reladdr = (uintptr_t)reltbl;
	rend = reladdr + nreloc * relocsize;

#ifdef	KOBJ_DEBUG
	if (kobj_debug & D_RELOCATIONS) {
		_kobj_printf(ops, "krtld:\ttype\t\t\toffset\t   addend"
		    "      symbol\n");
		_kobj_printf(ops, "krtld:\t\t\t\t\t   value\n");
	}
#endif
	destination = baseaddr;

	symnum = -1;
	/* loop through relocations */
	while (reladdr < rend) {

		symnum++;
		rtype = ELF_R_TYPE(((Rela *)reladdr)->r_info);
		off = ((Rela *)reladdr)->r_offset;
		stndx = ELF_R_SYM(((Rela *)reladdr)->r_info);
		if (stndx >= mp->nsyms) {
			_kobj_printf(ops,
			    "do_relocate: bad strndx %d\n", symnum);
			return (-1);
		}
		if ((rtype > R_RISCV_NUM) || IS_TLS_INS(rtype)) {
			_kobj_printf(ops, "krtld: invalid relocation type %d",
			    rtype);
			_kobj_printf(ops, " at 0x%lx:", off);
			_kobj_printf(ops, " file=%s\n", mp->filename);
			err = 1;
			continue;
		}
		addend = (long)(((Rela *)reladdr)->r_addend);
		reladdr += relocsize;

#ifdef	KOBJ_DEBUG
		if (kobj_debug & D_RELOCATIONS) {
			Sym *symp;
			symp = (Sym *)
			    (mp->symtbl+(stndx * mp->symhdr->sh_entsize));
			_kobj_printf(ops, "krtld:\t%s",
			    conv_reloc_RISCV_type(rtype));
			_kobj_printf(ops, "\t0x%8lx", off);
			_kobj_printf(ops, " 0x%8lx", addend);
			_kobj_printf(ops, "  %s\n",
			    (const char *)mp->strings + symp->st_name);
		}
#endif

		if (rtype == R_RISCV_NONE)
			continue;

		if (!(mp->flags & KOBJ_EXEC))
			off += destination;

		/*
		 * if R_RISCV_RELATIVE, simply add base addr
		 * to reloc location
		 */
		if (rtype == R_RISCV_RELATIVE) {
			value = baseaddr;
			name = "";
		} else {
			/*
			 * get symbol table entry - if symbol is local
			 * value is base address of this object
			 */
			symref = (Sym *)
			    (mp->symtbl+(stndx * mp->symhdr->sh_entsize));
			if (ELF_ST_BIND(symref->st_info) == STB_LOCAL) {
				/* *** this is different for .o and .so */
				value = symref->st_value;
				if (symref->st_shndx != SHN_ABS) {
					value += (uintptr_t)mp->dso;
				}
			} else {
				/*
				 * It's global. Allow weak references.  If
				 * the symbol is undefined, give TNF (the
				 * kernel probes facility) a chance to see
				 * if it's a probe site, and fix it up if so.
				 */
				if (symref->st_shndx == SHN_UNDEF &&
				    sdt_reloc_resolve(mp, mp->strings + symref->st_name, off, rtype, nreloc) == 0)
					continue;

				/*
				 * calculate location of definition
				 * - symbol value plus base address of
				 * containing shared object
				 */
				value = symref->st_value;
				if (symref->st_shndx != SHN_ABS) {
					value += (uintptr_t)mp->dso;
				}
			}
			name = (char *)mp->strings + symref->st_name;
		} /* end not R_RISCV_RELATIVE */

		if (rtype != R_RISCV_JUMP_SLOT) {
			value += addend;
		}

		/*
		 * calculate final value -
		 * if PC-relative, subtract ref addr
		 */
		if (IS_PC_RELATIVE(rtype)) {
			value -= off;
		}

#ifdef	KOBJ_DEBUG
		if (kobj_debug & D_RELOCATIONS) {
			_kobj_printf(ops, "krtld:\t\t\t\t0x%8lx", off);
			_kobj_printf(ops, " 0x%8lx\n", value);
		}
#endif
		if (do_reloc_krtld(rtype, (unsigned char *)off, (Xword *)&value,
		    name, mp->filename) == 0)
			err = 1;
	} /* end of while loop */

	if (err)
		return (-1);

	return (0);
}

int
do_relocations(struct module *mp)
{
	uint_t shn;
	Shdr *shp, *rshp;
	uint_t nreloc;

	/* do the relocations */
	for (shn = 1; shn < mp->hdr.e_shnum; shn++) {
		rshp = (Shdr *)
		    (mp->shdrs + shn * mp->hdr.e_shentsize);
		if (rshp->sh_type == SHT_REL) {
			_kobj_printf(ops, "%s can't process type SHT_REL\n",
			    mp->filename);
			return (-1);
		}
		if (rshp->sh_type != SHT_RELA)
			continue;
		if (rshp->sh_link != mp->symtbl_section) {
			_kobj_printf(ops, "%s reloc for non-default symtab\n",
			    mp->filename);
			return (-1);
		}
		if (rshp->sh_info >= mp->hdr.e_shnum) {
			_kobj_printf(ops, "do_relocations: %s ", mp->filename);
			_kobj_printf(ops, " sh_info out of range %d\n", shn);
			goto bad;
		}
		nreloc = rshp->sh_size / rshp->sh_entsize;

		/* get the section header that this reloc table refers to */
		shp = (Shdr *)
		    (mp->shdrs + rshp->sh_info * mp->hdr.e_shentsize);
		/*
		 * Do not relocate any section that isn't loaded into memory.
		 * Most commonly this will skip over the .rela.stab* sections
		 */
		if (!(shp->sh_flags & SHF_ALLOC))
			continue;
#ifdef	KOBJ_DEBUG
		if (kobj_debug & D_RELOCATIONS) {
			_kobj_printf(ops, "krtld: relocating: file=%s ",
			    mp->filename);
			_kobj_printf(ops, " section=%d\n", shn);
		}
#endif
		if (do_relocate(mp, (char *)rshp->sh_addr,
		    nreloc, rshp->sh_entsize, shp->sh_addr) < 0) {
			_kobj_printf(ops,
			    "do_relocations: %s do_relocate failed\n",
			    mp->filename);
			goto bad;
		}
		kobj_free((void *)rshp->sh_addr, rshp->sh_size);
		rshp->sh_addr = 0;
	}
	mp->flags |= KOBJ_RELOCATED;
	return (0);
bad:
	kobj_free((void *)rshp->sh_addr, rshp->sh_size);
	rshp->sh_addr = 0;
	return (-1);
}
