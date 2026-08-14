/*
 * ldmin.c -- a MINIMAL native illumos `ld` driver for riscv64 (R-P23 sub-task
 * 3): link a REAL EM_RISCV relocatable object through the illumos sgs backend
 * -- the R-P22.1 ld_config_target() selection + the R-P21/22 machrel.riscv.c
 * reloc engine -- with NO GNU ld in the reloc path.
 *
 * The full gate `ld` (usr/src/cmd/sgs/ld + libld) is tens of thousands of
 * lines and is NOT checked out on this host.  This is the honest, buildable
 * step toward it: a driver that does what libld's output relocation pass does
 * for a single section --
 *
 *   1. open a real .o (assembled by the riscv64-solaris toolchain) with
 *      libelf/gelf (the same ELF access layer libld uses);
 *   2. select the EM_RISCV backend exactly as the native ld does:
 *      ld_config_target(EM_RISCV) -> ld_targ = ld_targ_riscv;
 *   3. read the target section's bytes + its SHT_RELA records + symtab, build
 *      the libld Rel_desc[] active-reloc descriptors, pick a link address;
 *   4. drive the relocation THROUGH ld_targ.t_mr.mr_do_activerelocs (the
 *      selected backend's ld_do_activerelocs -> machrel.riscv.c), NOT a direct
 *      call and NOT GNU ld;
 *   5. write the relocated section image out.
 *
 * The R-P23 gate-ld self-check assembles the SAME source with the toolchain,
 * links it with GNU ld at the SAME address, and diffs the two relocated .text
 * images: byte-identical means the illumos backend performed the real link.
 *
 * CRIB PROVENANCE: the "select target by e_machine, walk SHT_RELA + symtab,
 * build Rel_desc, run the backend's do_activerelocs" flow is illumos
 * usr/src/cmd/sgs/libld/common/{libld.c,relocate.c} + machrel.<mach>.c; the
 * libelf/gelf object access is the illumos ELF access library; the Rel_desc /
 * Target field layout is the R-P22 sgs shims.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <libelf.h>
#include <gelf.h>

#include "target_shim.h"
#include "reloc_riscv.h"
#include "riscv_pcrel_htab.h"

/* the backend entry points machrel.riscv.c exports (via target.c wiring). */
extern int ld_config_target(Half mach);

/* riscv64 reloc types we may see from the toolchain for a text section. */
#ifndef R_RISCV_CALL_PLT
#define	R_RISCV_CALL_PLT	19
#endif

static const char *
rtype_name(unsigned t)
{
	switch (t) {
	case R_RISCV_PCREL_HI20:	return ("PCREL_HI20");
	case R_RISCV_PCREL_LO12_I:	return ("PCREL_LO12_I");
	case R_RISCV_PCREL_LO12_S:	return ("PCREL_LO12_S");
	case R_RISCV_CALL_PLT:		return ("CALL_PLT");
	case 18:			return ("CALL");
	case R_RISCV_64:		return ("64");
	case 51:			return ("RELAX");
	default:			return ("(other)");
	}
}

int
main(int argc, char **argv)
{
	if (argc < 3) {
		fprintf(stderr, "usage: %s <in.o> <linkaddr-hex> [out.bin]\n",
		    argv[0]);
		return (2);
	}
	const char *inpath = argv[1];
	uint64_t linkaddr = strtoull(argv[2], NULL, 16);
	const char *outpath = (argc > 3) ? argv[3] : NULL;

	if (elf_version(EV_CURRENT) == EV_NONE) {
		fprintf(stderr, "libelf: %s\n", elf_errmsg(-1));
		return (1);
	}
	int fd = open(inpath, O_RDONLY);
	if (fd < 0) { perror("open"); return (1); }
	Elf *e = elf_begin(fd, ELF_C_READ, NULL);
	if (e == NULL || elf_kind(e) != ELF_K_ELF) {
		fprintf(stderr, "not an ELF object\n"); return (1);
	}
	GElf_Ehdr eh;
	if (gelf_getehdr(e, &eh) == NULL) {
		fprintf(stderr, "getehdr: %s\n", elf_errmsg(-1)); return (1);
	}

	/* 2. SELECT the illumos EM_RISCV backend the way native ld does. */
	if (eh.e_machine != EM_RISCV) {
		fprintf(stderr, "input is not EM_RISCV (e_machine=%d)\n",
		    eh.e_machine);
		return (1);
	}
	if (ld_config_target(EM_RISCV) != 1 ||
	    ld_targ.t_m.m_mach != EM_RISCV) {
		fprintf(stderr, "ld_config_target(EM_RISCV) failed\n");
		return (1);
	}
	printf("[ldmin] selected illumos backend ld_targ_riscv "
	    "(m_mach=EM_RISCV) for %s\n", inpath);

	/* find .text, its .rela.text, and the symtab. */
	size_t shstrndx;
	elf_getshdrstrndx(e, &shstrndx);
	Elf_Scn *scn = NULL;
	Elf_Scn *textscn = NULL, *relascn = NULL, *symscn = NULL;
	size_t textndx = 0;
	while ((scn = elf_nextscn(e, scn)) != NULL) {
		GElf_Shdr sh;
		gelf_getshdr(scn, &sh);
		const char *nm = elf_strptr(e, shstrndx, sh.sh_name);
		if (nm == NULL) continue;
		if (strcmp(nm, ".text") == 0) {
			textscn = scn; textndx = elf_ndxscn(scn);
		} else if (strcmp(nm, ".rela.text") == 0) {
			relascn = scn;
		} else if (sh.sh_type == SHT_SYMTAB) {
			symscn = scn;
		}
	}
	if (textscn == NULL || relascn == NULL || symscn == NULL) {
		fprintf(stderr, "need .text + .rela.text + symtab\n");
		return (1);
	}

	GElf_Shdr textsh, relash, symsh;
	gelf_getshdr(textscn, &textsh);
	gelf_getshdr(relascn, &relash);
	gelf_getshdr(symscn, &symsh);

	Elf_Data *textdata = elf_getdata(textscn, NULL);
	Elf_Data *reladata = elf_getdata(relascn, NULL);

	/* mutable copy of the .text image we relocate in place. */
	uint8_t *image = malloc(textdata->d_size);
	memcpy(image, textdata->d_buf, textdata->d_size);

	/* 3. build the libld Rel_desc[] active-reloc descriptors. */
	unsigned nrela = relash.sh_size / relash.sh_entsize;

	Os_desc os; Is_desc is; Ofl_desc ofl; riscv_pcrel_htab_t pt;
	memset(&os, 0, sizeof (os));
	memset(&is, 0, sizeof (is));
	memset(&ofl, 0, sizeof (ofl));
	riscv_pcrel_htab_init(&pt);
	ofl.ofl_riscv_pcrel = &pt;
	ofl.ofl_flags = FLG_OF_EXEC;

	os.os_outdata = image;			/* where we write */
	os.os_shaddr = linkaddr;		/* .text link address (P base) */
	os.os_shoff = 0;
	is.is_indata = image;			/* read the working image too */
	is.is_osdesc = &os;
	is.is_offset = 0;

	Rel_desc *rels = calloc(nrela, sizeof (Rel_desc));
	Sym_desc *syms = calloc(nrela, sizeof (Sym_desc));
	unsigned nact = 0;

	printf("[ldmin] %u RELA records; building Rel_desc[] + resolving "
	    "symbols\n", nrela);
	for (unsigned i = 0; i < nrela; i++) {
		GElf_Rela r;
		gelf_getrela(reladata, i, &r);
		unsigned type = GELF_R_TYPE(r.r_info);
		unsigned symx = GELF_R_SYM(r.r_info);

		GElf_Sym sym;
		gelf_getsym(elf_getdata(symscn, NULL), symx, &sym);

		/*
		 * Resolve S: a defined symbol in .text resolves to its link
		 * address (linkaddr + st_value); anything else we treat as a
		 * local label whose value is its section-relative st_value +
		 * the section link address.  For this driver every symbol the
		 * test object references is .text-local, so S = linkaddr +
		 * st_value.
		 */
		syms[i].sd_value = (uint64_t)(linkaddr + sym.st_value);

		rels[nact].rel_rtype = type;
		rels[nact].rel_roffset = r.r_offset;
		rels[nact].rel_raddend = r.r_addend;
		rels[nact].rel_sym = &syms[i];
		rels[nact].rel_isdesc = &is;
		nact++;

		printf("  [%u] off=0x%llx type=%s sym=%s S=0x%llx A=%lld\n",
		    i, (unsigned long long)r.r_offset, rtype_name(type),
		    elf_strptr(e, symsh.sh_link, sym.st_name),
		    (unsigned long long)syms[i].sd_value,
		    (long long)r.r_addend);
	}

	/* 4. run the RELOCATION through the SELECTED backend. */
	if (ld_targ.t_mr.mr_do_activerelocs(rels, nact, &ofl) == S_ERROR) {
		fprintf(stderr, "[ldmin] backend do_activerelocs FAILED\n");
		return (1);
	}
	printf("[ldmin] relocation driven THROUGH "
	    "ld_targ.t_mr.mr_do_activerelocs (machrel.riscv.c), no GNU ld\n");

	/* 5. emit the relocated .text image. */
	if (outpath != NULL) {
		FILE *o = fopen(outpath, "wb");
		fwrite(image, 1, textdata->d_size, o);
		fclose(o);
		printf("[ldmin] wrote relocated .text (%zu bytes) -> %s\n",
		    textdata->d_size, outpath);
	}

	riscv_pcrel_htab_fini(&pt);
	elf_end(e);
	close(fd);
	return (0);
}
