/*
 * rtld_riscv.c -- REDUCED illumos ld.so.1 runtime relocation engine for
 * riscv64 (R-P23 sub-task 2).
 *
 * The full illumos runtime linker (usr/src/cmd/sgs/rtld) maps the executable
 * + its DT_NEEDED objects, builds the link map, and relocates each object.
 * Standing up all of that requires a process model (a live kernel syscall
 * path + a userland loader), which is R-P24+ work.  Per the R-P23 anti-wedge
 * directive, this is the REDUCED milestone: the CORE riscv64 runtime reloc
 * engine -- the exact inner loop of rtld's elf_reloc() for the riscv64
 * relocation types -- proven end to end as a freestanding S-mode payload
 * under qemu-system-riscv64 (the same OpenSBI substrate as the R-P23 kernel
 * and the R-P22 hello), NOT a qemu-user process (this host has no user-mode
 * qemu and no OS to host a process yet).
 *
 * It resolves the two relocation types ld.so.1 must handle at load time for a
 * position-independent riscv64 object linked against libgcc_s:
 *
 *   R_RISCV_RELATIVE (3): *(uint64*)(base + r_offset) = base + r_addend
 *       -- fix up an absolute pointer for the object's actual load base
 *          (data pointers, the GOT's own entries).  B + A.
 *   R_RISCV_JUMP_SLOT (5): *(uint64*)(base + r_offset) = sym_value
 *       -- bind a PLT/GOT slot to the resolved symbol address.  This is the
 *          lazy/eager PLT binding ld.so.1 performs; here we do it eagerly
 *          (as ld.so.1 does under LD_BIND_NOW / for JUMP_SLOT with no lazy
 *          PLT stub), then CALL through the slot to prove the binding.
 *
 * A synthetic object image models what ld.so.1 sees after mmap: a .data.rel
 * pointer needing RELATIVE, and a GOT slot needing JUMP_SLOT bound to a
 * libgcc_s-style symbol (__riscv_save_0-shaped: here a local "target" fn that
 * returns a sentinel).  We relocate at a nonzero load base to prove the base
 * math, then dereference the RELATIVE pointer and call through the JUMP_SLOT
 * -- both must yield the relocated/bound values.
 *
 * CRIB PROVENANCE: the elf_reloc() inner switch (RELATIVE = base+addend,
 * JUMP_SLOT = symval into *where) is illumos usr/src/cmd/sgs/rtld/common/
 * _elf.c / the machine-specific rtld/<mach>/ reloc code (amd64/sparc shape,
 * riscv64 modeled on the psABI); the R_RISCV_* type numbers + formulas are
 * uts/common/sys/elf_riscv.h + the RISC-V psABI; the SBI console substrate is
 * the R-P23 kernel sbi.c.
 */

#include "sbi.h"

typedef unsigned long		Elf64_Addr;
typedef unsigned long		Elf64_Xword;
typedef long			Elf64_Sxword;

/* Elf64_Rela: the RELA entry ld.so.1 walks (elf.h). */
typedef struct {
	Elf64_Addr	r_offset;	/* location to fix (object-relative) */
	Elf64_Xword	r_info;		/* sym index << 32 | type */
	Elf64_Sxword	r_addend;	/* constant addend (A) */
} Elf64_Rela;

#define	ELF64_R_TYPE(i)		((unsigned)((i) & 0xffffffffUL))
#define	ELF64_R_SYM(i)		((unsigned)((i) >> 32))
#define	ELF64_R_INFO(s, t)	(((Elf64_Xword)(s) << 32) | (unsigned)(t))

/* riscv64 dynamic relocation types (uts/common/sys/elf_riscv.h). */
#define	R_RISCV_NONE		0
#define	R_RISCV_64		2
#define	R_RISCV_RELATIVE	3
#define	R_RISCV_JUMP_SLOT	5

/*
 * elf_reloc_riscv -- the REDUCED ld.so.1 riscv64 relocation loop.  Walks a
 * RELA table, applying each entry against an object mapped at load base
 * `base`.  `symvals[]` supplies resolved symbol addresses indexed by the RELA
 * symbol index (what rtld's symbol lookup + syminfo would produce).  Returns
 * the count applied, or -1 on an unhandled type (ld.so.1 would fatal there).
 *
 * This is exactly ld.so.1's per-object relocate loop, minus the mapping /
 * lookup plumbing: for each RELA, decode type, compute *where per the psABI
 * formula, store.  RELATIVE and JUMP_SLOT are the only load-time types a
 * riscv64 PIE/exe linked against a shared lib actually carries.
 */
long
elf_reloc_riscv(Elf64_Addr base, const Elf64_Rela *rela, unsigned n,
    const Elf64_Addr *symvals)
{
	unsigned i;
	long applied = 0;

	for (i = 0; i < n; i++) {
		Elf64_Addr *where =
		    (Elf64_Addr *)(base + rela[i].r_offset);
		unsigned type = ELF64_R_TYPE(rela[i].r_info);
		unsigned sym = ELF64_R_SYM(rela[i].r_info);

		switch (type) {
		case R_RISCV_NONE:
			break;
		case R_RISCV_RELATIVE:
			/* B + A: relocate an absolute pointer for the base. */
			*where = base + (Elf64_Addr)rela[i].r_addend;
			applied++;
			break;
		case R_RISCV_JUMP_SLOT:
			/* S: bind the PLT/GOT slot to the resolved symbol. */
			*where = symvals[sym] + (Elf64_Addr)rela[i].r_addend;
			applied++;
			break;
		case R_RISCV_64:
			/* S + A: absolute 64-bit (data). */
			*where = symvals[sym] + (Elf64_Addr)rela[i].r_addend;
			applied++;
			break;
		default:
			return (-1);	/* ld.so.1 would fatal on this */
		}
	}
	return (applied);
}

/* ---- synthetic object image (what ld.so.1 sees after mmap) ---- */

/*
 * target_fn -- stands in for a resolved libgcc_s symbol (e.g. __riscv_save_0).
 * ld.so.1 would find its address via the symbol hash; here it is a local fn
 * returning a sentinel so we can prove the JUMP_SLOT call reaches it.
 */
static unsigned long
target_fn(void)
{
	return (0x5eed);
}

/*
 * The object's mutable image: a GOT with a JUMP_SLOT slot [0] and a data
 * pointer needing RELATIVE [1].  Both are pre-relocation garbage until the
 * engine fixes them.  `image_base` models the object's actual mmap load base
 * so the RELATIVE math is exercised with a nonzero base.
 */
static Elf64_Addr got[2];

/* the datum a RELATIVE reloc should point at, object-relative offset. */
static const char reloc_msg[] = "relocated pointer OK";

void
kmain(unsigned long hartid, void *fdt)
{
	(void)hartid;
	(void)fdt;

	sbi_console_puts("\n[ld.so.1] REDUCED riscv64 runtime relocation engine "
	    "(R-P23)\n");

	/*
	 * Model an object loaded at a nonzero base.  In real ld.so.1 this is
	 * the mmap address; the RELATIVE addend is the object-relative VA of
	 * the target datum, and *where lands at base + r_offset.  We use the
	 * running payload's own address space: base = &got[0] adjusted so the
	 * addend + base reconstructs &reloc_msg.  To keep the math honest we
	 * express addend as (target_va - base) and check base + addend ==
	 * target_va after the reloc.
	 */
	Elf64_Addr base = (Elf64_Addr)&got[0];
	Elf64_Addr msg_va = (Elf64_Addr)reloc_msg;

	Elf64_Addr symvals[1];
	symvals[0] = (Elf64_Addr)&target_fn;	/* resolved "libgcc_s" symbol */

	/*
	 * RELA table: [0] JUMP_SLOT binds got[0] to target_fn; [1] RELATIVE
	 * fixes got[1] to point at reloc_msg.  r_offset is the slot's byte
	 * offset from base.
	 */
	Elf64_Rela rela[2];
	rela[0].r_offset = 0;				/* got[0] */
	rela[0].r_info = ELF64_R_INFO(0, R_RISCV_JUMP_SLOT);
	rela[0].r_addend = 0;
	rela[1].r_offset = sizeof (Elf64_Addr);		/* got[1] */
	rela[1].r_info = ELF64_R_INFO(0, R_RISCV_RELATIVE);
	rela[1].r_addend = (Elf64_Sxword)(msg_va - base);

	got[0] = 0;	/* unbound PLT slot */
	got[1] = 0;	/* unrelocated pointer */

	long applied = elf_reloc_riscv(base, rela, 2, symvals);

	sbi_console_puts("[ld.so.1] relocs applied: ");
	sbi_console_putchar(applied == 2 ? '2' : '?');
	sbi_console_puts("\n");

	/* Verify JUMP_SLOT: got[0] must be target_fn; call through it. */
	int jump_ok = 0;
	if (got[0] == (Elf64_Addr)&target_fn) {
		unsigned long (*fp)(void) = (unsigned long (*)(void))got[0];
		jump_ok = (fp() == 0x5eed);
	}
	sbi_console_puts("[ld.so.1] R_RISCV_JUMP_SLOT: ");
	sbi_console_puts(jump_ok ?
	    "PASS (GOT slot bound + called through -> sentinel)\n" :
	    "FAIL\n");

	/* Verify RELATIVE: got[1] must equal &reloc_msg; deref it. */
	int rel_ok = 0;
	if (got[1] == msg_va) {
		const char *p = (const char *)got[1];
		rel_ok = (p[0] == 'r' && p[1] == 'e');
	}
	sbi_console_puts("[ld.so.1] R_RISCV_RELATIVE: ");
	sbi_console_puts(rel_ok ?
	    "PASS (base+addend pointer relocated + dereferenced)\n" :
	    "FAIL\n");

	if (jump_ok && rel_ok)
		sbi_console_puts("[ld.so.1] R-P23 REDUCED ld.so.1 reloc engine "
		    "PASS: riscv64 JUMP_SLOT + RELATIVE resolved at runtime.\n");
	else
		sbi_console_puts("[ld.so.1] R-P23 reloc engine FAIL\n");

	sbi_shutdown();
}
