/*
 * elf.c — illumos riscv64 static ELF64 loader (R-P7).
 *
 * Parse a static riscv64 ELF (EM_RISCV=243, ET_EXEC) image already in memory
 * (read off the rootfs / vioblk into a kernel buffer) and map its PT_LOAD
 * segments into a user address space (as.c), returning the entry PC. This is
 * the seed of uts/common/exec/elf/elf.c (elfexec), pared to what a static,
 * non-PIE, no-interpreter first process needs:
 *
 *   - validate e_ident (\x7fELF, 64-bit, little-endian), e_machine==EM_RISCV,
 *     e_type==ET_EXEC.
 *   - walk e_phnum program headers; for each PT_LOAD, as_map the segment at
 *     p_vaddr with p_memsz bytes, copying p_filesz bytes from the file image
 *     and zero-filling the rest (BSS). Permissions from p_flags (R/W/X).
 *   - return e_entry.
 *
 * NOTE: static ET_EXEC only \u2014 no PT_INTERP/dynamic linking, no PIE/ET_DYN
 * relocation, no PT_GNU_STACK/relro, no auxv beyond what proc.c stacks. The
 * loader trusts the image (it is our own hand-built /sbin/init); a real
 * elfexec validates far more and enforces NX. Upgrade path (R-P8): dynamic
 * linker + auxv + segment protection.
 */

#include "sbi.h"
#include "riscv_regs.h"

extern void kputhex(unsigned long v);
extern void kputdec(unsigned long v);

/* as.c address-space primitives. */
typedef struct as as_t;
extern int as_map(as_t *as, unsigned long va, unsigned long len,
    const void *data, unsigned long copylen, unsigned long perm);

/* ---------------------------------------------------------------------------
 * ELF64 on-disk structures (little-endian riscv64). From the ELF spec + the
 * RISC-V psABI; reimplemented (no copied headers).
 * ------------------------------------------------------------------------- */
typedef struct {
	unsigned char	e_ident[16];
	unsigned short	e_type;
	unsigned short	e_machine;
	unsigned int	e_version;
	unsigned long	e_entry;
	unsigned long	e_phoff;
	unsigned long	e_shoff;
	unsigned int	e_flags;
	unsigned short	e_ehsize;
	unsigned short	e_phentsize;
	unsigned short	e_phnum;
	unsigned short	e_shentsize;
	unsigned short	e_shnum;
	unsigned short	e_shstrndx;
} Elf64_Ehdr;

typedef struct {
	unsigned int	p_type;
	unsigned int	p_flags;
	unsigned long	p_offset;
	unsigned long	p_vaddr;
	unsigned long	p_paddr;
	unsigned long	p_filesz;
	unsigned long	p_memsz;
	unsigned long	p_align;
} Elf64_Phdr;

#define	PT_LOAD		1
#define	ET_EXEC		2
#define	EM_RISCV	243
#define	PF_X		0x1
#define	PF_W		0x2
#define	PF_R		0x4

/*
 * elf_load — parse the ELF image at `img` (length `len`) and map its PT_LOAD
 * segments into `as`. On success writes the entry PC to *entryp, the initial
 * program break (highest mapped vaddr+memsz, page-rounded) to *brkp (if
 * non-NULL — the exec/heap path uses it), and returns the number of PT_LOAD
 * segments mapped (>0). Returns -1 on a malformed or unsupported image.
 */
int
elf_load(as_t *as, const void *img, unsigned long len, unsigned long *entryp,
    unsigned long *brkp)
{
	const Elf64_Ehdr *eh = (const Elf64_Ehdr *)img;
	const unsigned char *base = (const unsigned char *)img;
	int i, nload = 0;
	unsigned long top = 0;

	if (len < sizeof (Elf64_Ehdr)) {
		sbi_console_puts("[elf] image too small\n");
		return (-1);
	}
	if (eh->e_ident[0] != 0x7f || eh->e_ident[1] != 'E' ||
	    eh->e_ident[2] != 'L' || eh->e_ident[3] != 'F') {
		sbi_console_puts("[elf] bad magic (not ELF)\n");
		return (-1);
	}
	if (eh->e_ident[4] != 2 /* ELFCLASS64 */ ||
	    eh->e_ident[5] != 1 /* ELFDATA2LSB */) {
		sbi_console_puts("[elf] not 64-bit little-endian\n");
		return (-1);
	}
	if (eh->e_machine != EM_RISCV) {
		sbi_console_puts("[elf] e_machine != EM_RISCV (243)\n");
		return (-1);
	}
	if (eh->e_type != ET_EXEC) {
		sbi_console_puts("[elf] e_type != ET_EXEC (static only)\n");
		return (-1);
	}
	if (eh->e_phoff == 0 || eh->e_phnum == 0 ||
	    eh->e_phentsize != sizeof (Elf64_Phdr)) {
		sbi_console_puts("[elf] no/invalid program headers\n");
		return (-1);
	}

	for (i = 0; i < eh->e_phnum; i++) {
		const Elf64_Phdr *ph = (const Elf64_Phdr *)
		    (base + eh->e_phoff + (unsigned long)i * eh->e_phentsize);
		unsigned long perm;

		if (ph->p_type != PT_LOAD)
			continue;
		if (ph->p_filesz > ph->p_memsz) {
			sbi_console_puts("[elf] filesz > memsz\n");
			return (-1);
		}
		if (ph->p_offset + ph->p_filesz > len) {
			sbi_console_puts("[elf] segment past image end\n");
			return (-1);
		}

		perm = 0;
		if (ph->p_flags & PF_R)
			perm |= PTE_R;
		if (ph->p_flags & PF_W)
			perm |= PTE_W;
		if (ph->p_flags & PF_X)
			perm |= PTE_X;
		/* A loadable segment is at least readable. */
		if (perm == 0)
			perm = PTE_R;

		if (!as_map(as, ph->p_vaddr, ph->p_memsz,
		    base + ph->p_offset, ph->p_filesz, perm)) {
			sbi_console_puts("[elf] as_map failed\n");
			return (-1);
		}

		sbi_console_puts("[elf]   PT_LOAD vaddr=");
		kputhex(ph->p_vaddr);
		sbi_console_puts(" filesz=");
		kputdec(ph->p_filesz);
		sbi_console_puts(" memsz=");
		kputdec(ph->p_memsz);
		sbi_console_puts(" perm=");
		sbi_console_putchar((perm & PTE_R) ? 'r' : '-');
		sbi_console_putchar((perm & PTE_W) ? 'w' : '-');
		sbi_console_putchar((perm & PTE_X) ? 'x' : '-');
		sbi_console_puts("\n");
		nload++;
		if (ph->p_vaddr + ph->p_memsz > top)
			top = ph->p_vaddr + ph->p_memsz;
	}

	if (nload == 0) {
		sbi_console_puts("[elf] no PT_LOAD segments\n");
		return (-1);
	}
	*entryp = eh->e_entry;
	if (brkp != 0)
		*brkp = (top + PAGESIZE - 1) & ~(PAGESIZE - 1);
	return (nload);
}
