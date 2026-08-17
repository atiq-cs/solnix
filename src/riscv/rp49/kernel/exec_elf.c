/*
 * exec_elf.c -- R-P25/R-P26 reduced exec: load a static EM_RISCV ELF64 image
 * into a fresh user address space.  exec_image() parses the ELF at img[0..),
 * allocates a fresh user AS (hat_user_new), maps+copies each PT_LOAD segment +
 * a user stack (hat_user_map), builds the psABI initial stack, and returns the
 * user satp/root/entry/sp so the caller can enter U-mode.  R-P26 parametrizes
 * the image so the same loader serves the first process, fork's children (via
 * the AS copy), and exec's new program.
 *
 * REDUCED: static ELF (no interpreter / ld.so.1), no COW/demand paging (eager
 * copy into kmem frames), a fixed-size user stack, a minimal aux vector
 * (AT_PAGESZ, AT_ENTRY, AT_NULL).  Toward the general gexec/elfexec.
 *
 * CRIB PROVENANCE: the "walk the program headers, map+copy each PT_LOAD, zero
 * the .bss tail, set the entry, build the aux vector" shape is the illumos
 * exec elf mapelfexec / elfexec + BSD exec_elf64_imgact; the initial-stack
 * layout (argc, argv[], NULL, envp[], NULL, auxv[], AT_NULL) is the RISC-V
 * psABI program-startup + the illumos exec_args; ELF64 header / phdr structs
 * are the SysV gABI / <sys/elf.h>.
 */

#include "mmu_riscv.h"
#include "proc_riscv.h"
#include "sbi.h"

extern void *kmem_alloc(unsigned long);
extern void *kmem_alloc_page(void);

/* ---- minimal ELF64 (SysV gABI) -------------------------------------- */
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
#define	PT_INTERP	3
#define	PT_PHDR		6
#define	PF_X		1
#define	PF_W		2
#define	PF_R		4
#define	EM_RISCV	243
#define	ET_EXEC		2
#define	ET_DYN		3

#define	AT_NULL		0
#define	AT_PHDR		3
#define	AT_PHENT	4
#define	AT_PHNUM	5
#define	AT_BASE		7
#define	AT_ENTRY	9
#define	AT_PAGESZ	6

#define	USTACK_TOP	0x40000000UL
#define	USTACK_PAGES	16			/* R-P41: 64 KiB user stack (a real
						   coreutils util like wc uses 16 KiB
						   stack buffers) */
#define	KSTACK_SIZE	(16UL * 1024)

/*
 * R-P35.2/.3: argv passthrough across exec(2).  do_exec copies the caller's
 * argv strings out of the OLD user AS (before the AS switch) into this kernel
 * staging area, then exec_image lays them onto the NEW program's initial stack
 * (argc, argv[0..n], NULL) per the RISC-V psABI.  Without this the shell could
 * fork+exec a command but never PASS it arguments (echo hello, cat /path).
 *
 * CRIB PROVENANCE: exec copying the argv/envp vectors into a kernel buffer
 * (exec_args) then relocating them onto the new user stack is illumos
 * uts/common/os/exec.c exec_args()/stk_copyin + BSD exec_copyout_strings; the
 * argc/argv[]/NULL/envp[]/NULL/auxv initial-stack layout is the RISC-V psABI.
 */
#define	EXEC_MAXARG	8		/* argv slots (argv[0..7]) */
#define	EXEC_ARGLEN	64		/* max bytes per arg incl NUL */
static char exec_argv_buf[EXEC_MAXARG][EXEC_ARGLEN];
static int exec_argv_n;			/* staged arg count (0 = default "prog") */

/* do_exec calls these to stage the caller's argv before the AS switch. */
void
exec_argv_reset(void)
{
	exec_argv_n = 0;
}
int
exec_argv_push(const char *s)
{
	int i = 0;
	if (exec_argv_n >= EXEC_MAXARG)
		return (-1);
	while (s[i] != 0 && i < EXEC_ARGLEN - 1) {
		exec_argv_buf[exec_argv_n][i] = s[i];
		i++;
	}
	exec_argv_buf[exec_argv_n][i] = 0;
	exec_argv_n++;
	return (0);
}

static void
bcopy_bytes(const unsigned char *src, unsigned char *dst, unsigned long n)
{
	unsigned long i;
	for (i = 0; i < n; i++)
		dst[i] = src[i];
}

static void
bzero_bytes(unsigned char *dst, unsigned long n)
{
	unsigned long i;
	for (i = 0; i < n; i++)
		dst[i] = 0;
}

int
exec_image(struct uproc *up, const unsigned char *img)
{
	const Elf64_Ehdr *eh = (const Elf64_Ehdr *)img;
	const Elf64_Phdr *ph;
	unsigned long *uroot;
	unsigned long *ustk_pa[USTACK_PAGES];
	unsigned char *kstack;
	unsigned int i;

	if (!(eh->e_ident[0] == 0x7f && eh->e_ident[1] == 0x45 &&
	    eh->e_ident[2] == 0x4c && eh->e_ident[3] == 0x46) ||
	    eh->e_ident[4] != 2 || eh->e_machine != EM_RISCV ||
	    eh->e_type != ET_EXEC) {
		sbi_console_puts("[exec] not a static EM_RISCV ELF64 exec\n");
		return (-1);
	}

	uroot = hat_user_new();
	if (uroot == 0)
		return (-1);

	for (i = 0; i < eh->e_phnum; i++) {
		unsigned long seg_va, seg_end, va, perms;
		ph = (const Elf64_Phdr *)(img + eh->e_phoff +
		    (unsigned long)i * eh->e_phentsize);
		if (ph->p_type != PT_LOAD || ph->p_memsz == 0)
			continue;

		perms = PTE_U;
		if (ph->p_flags & PF_R)
			perms |= PTE_R;
		if (ph->p_flags & PF_W)
			perms |= PTE_W;
		if (ph->p_flags & PF_X)
			perms |= PTE_X;

		seg_va = ph->p_vaddr & PAGEMASK;
		seg_end = ph->p_vaddr + ph->p_memsz;

		for (va = seg_va; va < seg_end; va += PAGESIZE) {
			unsigned char *frame = kmem_alloc_page();
			unsigned long off_in_seg, filebytes;

			if (frame == 0)
				return (-1);
			bzero_bytes(frame, PAGESIZE);

			if (va + PAGESIZE > ph->p_vaddr &&
			    va < ph->p_vaddr + ph->p_filesz) {
				unsigned long cstart = va;
				unsigned long cend = va + PAGESIZE;
				unsigned long fstart = ph->p_vaddr;
				unsigned long fend = ph->p_vaddr + ph->p_filesz;
				unsigned long cs = cstart > fstart ?
				    cstart : fstart;
				unsigned long ce = cend < fend ? cend : fend;
				off_in_seg = cs - ph->p_vaddr;
				filebytes = ce - cs;
				bcopy_bytes(img + ph->p_offset + off_in_seg,
				    frame + (cs - va), filebytes);
			}

			if (hat_user_map(uroot, va, (unsigned long)frame,
			    perms) != 0)
				return (-1);
		}
	}

	for (i = 0; i < USTACK_PAGES; i++) {
		ustk_pa[i] = kmem_alloc_page();
		if (ustk_pa[i] == 0)
			return (-1);
		bzero_bytes((unsigned char *)ustk_pa[i], PAGESIZE);
		if (hat_user_map(uroot,
		    USTACK_TOP - (unsigned long)(USTACK_PAGES - i) * PAGESIZE,
		    (unsigned long)ustk_pa[i], PTE_R | PTE_W | PTE_U) != 0)
			return (-1);
	}

	{
		unsigned char *ktop = (unsigned char *)ustk_pa[USTACK_PAGES - 1]
		    + PAGESIZE;
		unsigned long utop = USTACK_TOP;
		static const char arg0_default[] = "prog";
		unsigned long argv_uva[EXEC_MAXARG];
		unsigned long env_uva[EXEC_MAXARG];
		unsigned long ustr, uw, nwords;
		unsigned long *kw;
		int nargs, ai, nenv = 0;

		/*
		 * R-P35.2/.3: lay the staged argv strings (or the default
		 * "prog") at the top of the user stack, high-to-low, recording
		 * each string's user VA; then build argc, argv[0..n-1], NULL,
		 * envp NULL, and the auxv below them.  Writes go through the
		 * direct-map kernel alias (ktop) of the freshly-allocated stack
		 * frames; the user VAs (argv_uva/uw) are what U-mode will read.
		 */
		nargs = exec_argv_n;
		if (nargs <= 0)
			nargs = 1;		/* default argv[0]="prog" */
		ustr = utop;
		for (ai = nargs - 1; ai >= 0; ai--) {
			const char *s = (exec_argv_n > 0) ?
			    exec_argv_buf[ai] : arg0_default;
			unsigned long len = 0;
			while (s[len] != 0)
				len++;
			len++;			/* include the NUL */
			ustr -= len;
			bcopy_bytes((const unsigned char *)s,
			    ktop - (utop - ustr), len);
			argv_uva[ai] = ustr;
		}

		/* words: argc + (nargs argv ptrs) + NULL + envpNULL + 6 auxv */
		nwords = 1 + (unsigned long)nargs + 1 + 1 + 6;
		uw = (ustr & ~15UL) - nwords * 8;
		uw &= ~15UL;
		kw = (unsigned long *)(ktop - (utop - uw));

		kw[0] = (unsigned long)nargs;		/* argc */
		for (ai = 0; ai < nargs; ai++)
			kw[1 + ai] = argv_uva[ai];	/* argv[ai] */
		kw[1 + nargs] = 0;			/* argv NULL */
		kw[2 + nargs] = 0;			/* envp NULL */
		kw[3 + nargs] = AT_PAGESZ; kw[4 + nargs] = PAGESIZE;
		kw[5 + nargs] = AT_ENTRY;  kw[6 + nargs] = eh->e_entry;
		kw[7 + nargs] = AT_NULL;   kw[8 + nargs] = 0;

		up->u_sp = uw;
	}

	kstack = kmem_alloc(KSTACK_SIZE);
	if (kstack == 0)
		return (-1);
	up->u_kstack_top = ((unsigned long)kstack + KSTACK_SIZE) & ~15UL;

	up->u_root = (unsigned long)uroot;
	up->u_satp = MAKE_SATP(KVTOP((unsigned long)uroot));
	up->u_entry = eh->e_entry;
	up->ud_img = 0;			/* R-P33.3: no file-backed segment */
	return (0);
}

/*
 * exec_image_demand -- R-P33.3: file-backed demand-exec.  Load the ELF like
 * exec_image, EXCEPT the executable (text) PT_LOAD segment is mapped LAZY
 * (hat_user_lazy: V clear, PTE_LAZY + the intended perms) instead of eager-
 * copied, and the segment's file backing is recorded in up->ud_* so the page-
 * fault handler (proc_pagefault -> exec_demand_fault) copies each text page from
 * the ELF image on the FIRST fetch fault.  Non-executable segments (data/bss)
 * are still eager (they need per-page zero-fill / relocation, handled at load).
 *
 * CRIB PROVENANCE: mmap'ing a file-backed PT_LOAD segment (seg_vn with a vnode
 * + offset) and faulting each page in from the file on first touch is illumos
 * exec mapelfexec (VOP_MAP the text) + segvn_fault (F_INVAL -> VOP_GETPAGE from
 * the file) + the BSD vnode-backed exec image; here reduced to the embedded ELF
 * bytes as the "file" + the R-P32 lazy-leaf demand-paging machinery.
 */
extern int hat_user_lazy(unsigned long *root, unsigned long va,
    unsigned long perms);

int
exec_image_demand(struct uproc *up, const unsigned char *img)
{
	const Elf64_Ehdr *eh = (const Elf64_Ehdr *)img;
	const Elf64_Phdr *ph;
	unsigned long *uroot;
	unsigned long *ustk_pa[USTACK_PAGES];
	unsigned char *kstack;
	unsigned int i;
	int text_seg = -1;

	if (!(eh->e_ident[0] == 0x7f && eh->e_ident[1] == 0x45 &&
	    eh->e_ident[2] == 0x4c && eh->e_ident[3] == 0x46) ||
	    eh->e_ident[4] != 2 || eh->e_machine != EM_RISCV ||
	    eh->e_type != ET_EXEC) {
		sbi_console_puts("[exec-demand] not a static EM_RISCV ELF64 exec\n");
		return (-1);
	}

	uroot = hat_user_new();
	if (uroot == 0)
		return (-1);

	up->ud_img = 0;
	for (i = 0; i < eh->e_phnum; i++) {
		unsigned long seg_va, seg_end, va, perms;
		int is_text;
		ph = (const Elf64_Phdr *)(img + eh->e_phoff +
		    (unsigned long)i * eh->e_phentsize);
		if (ph->p_type != PT_LOAD || ph->p_memsz == 0)
			continue;

		perms = PTE_U;
		if (ph->p_flags & PF_R)
			perms |= PTE_R;
		if (ph->p_flags & PF_W)
			perms |= PTE_W;
		if (ph->p_flags & PF_X)
			perms |= PTE_X;

		seg_va = ph->p_vaddr & PAGEMASK;
		seg_end = ph->p_vaddr + ph->p_memsz;

		/*
		 * The FIRST executable, non-writable, fully-file-backed segment
		 * (the text) is demand-paged file-backed: map its pages LAZY +
		 * record the file region; the fetch fault fills them.
		 */
		is_text = (text_seg < 0) && (ph->p_flags & PF_X) &&
		    !(ph->p_flags & PF_W) && ph->p_filesz == ph->p_memsz;
		if (is_text) {
			text_seg = (int)i;
			up->ud_img = img;
			up->ud_va = seg_va;
			/* file offset that backs ud_va (== seg_va): p_offset adjusted
			   back by how far p_vaddr sits past the page boundary. */
			up->ud_off = ph->p_offset - (ph->p_vaddr - seg_va);
			up->ud_filesz = (ph->p_vaddr - seg_va) + ph->p_filesz;
			up->ud_memsz = seg_end - seg_va;
			for (va = seg_va; va < seg_end; va += PAGESIZE) {
				if (hat_user_lazy(uroot, va, perms) != 0)
					return (-1);
			}
			continue;
		}

		/* every other segment: eager copy (as exec_image). */
		for (va = seg_va; va < seg_end; va += PAGESIZE) {
			unsigned char *frame = kmem_alloc_page();
			unsigned long off_in_seg, filebytes;
			if (frame == 0)
				return (-1);
			bzero_bytes(frame, PAGESIZE);
			if (va + PAGESIZE > ph->p_vaddr &&
			    va < ph->p_vaddr + ph->p_filesz) {
				unsigned long cstart = va, cend = va + PAGESIZE;
				unsigned long fstart = ph->p_vaddr;
				unsigned long fend = ph->p_vaddr + ph->p_filesz;
				unsigned long cs = cstart > fstart ? cstart : fstart;
				unsigned long ce = cend < fend ? cend : fend;
				off_in_seg = cs - ph->p_vaddr;
				filebytes = ce - cs;
				bcopy_bytes(img + ph->p_offset + off_in_seg,
				    frame + (cs - va), filebytes);
			}
			if (hat_user_map(uroot, va, (unsigned long)frame,
			    perms) != 0)
				return (-1);
		}
	}

	for (i = 0; i < USTACK_PAGES; i++) {
		ustk_pa[i] = kmem_alloc_page();
		if (ustk_pa[i] == 0)
			return (-1);
		bzero_bytes((unsigned char *)ustk_pa[i], PAGESIZE);
		if (hat_user_map(uroot,
		    USTACK_TOP - (unsigned long)(USTACK_PAGES - i) * PAGESIZE,
		    (unsigned long)ustk_pa[i], PTE_R | PTE_W | PTE_U) != 0)
			return (-1);
	}
	{
		unsigned char *ktop = (unsigned char *)ustk_pa[USTACK_PAGES - 1]
		    + PAGESIZE;
		unsigned long utop = USTACK_TOP;
		static const char arg0[] = "prog";
		unsigned char *kstr;
		unsigned long ustr, uw, nwords, argv0_uva;
		unsigned long *kw;
		kstr = ktop - sizeof (arg0);
		ustr = utop - sizeof (arg0);
		bcopy_bytes((const unsigned char *)arg0, kstr, sizeof (arg0));
		argv0_uva = ustr;
		nwords = 10;
		uw = (ustr & ~15UL) - nwords * 8;
		uw &= ~15UL;
		kw = (unsigned long *)(ktop - (utop - uw));
		kw[0] = 1; kw[1] = argv0_uva; kw[2] = 0; kw[3] = 0;
		kw[4] = AT_PAGESZ; kw[5] = PAGESIZE;
		kw[6] = AT_ENTRY; kw[7] = eh->e_entry;
		kw[8] = AT_NULL; kw[9] = 0;
		up->u_sp = uw;
	}

	kstack = kmem_alloc(KSTACK_SIZE);
	if (kstack == 0)
		return (-1);
	up->u_kstack_top = ((unsigned long)kstack + KSTACK_SIZE) & ~15UL;
	up->u_root = (unsigned long)uroot;
	up->u_satp = MAKE_SATP(KVTOP((unsigned long)uroot));
	up->u_entry = eh->e_entry;
	return (0);
}

/* R-P25 back-compat: exec the forker image. */
int
exec_user(struct uproc *up)
{
	return (exec_image(up, user_elf_start));
}

/*
 * exec_demand_fault -- R-P33.3: fill a faulting file-backed text page.  `va` is
 * the page-aligned faulting VA inside the text segment [seg_va, seg_va+memsz);
 * copy the corresponding file bytes from img+file_off (zero-filling any tail
 * past filesz) into a fresh frame and map it R|X|U.  Returns 1 if it mapped a
 * page, 0 if `va` is outside the file-backed range.
 *
 * CRIB PROVENANCE: VOP_GETPAGE filling a seg_vn page from the backing vnode at
 * (segment base + offset) on an F_INVAL fault is illumos segvn_faultpage /
 * fop_getpage; here the "vnode" is the embedded ELF image bytes.
 */
extern int hat_user_map(unsigned long *root, unsigned long va,
    unsigned long pa, unsigned long perms);

int
exec_demand_fault(unsigned long *root, unsigned long va,
    const unsigned char *img, unsigned long seg_va, unsigned long file_off,
    unsigned long filesz)
{
	unsigned char *frame;
	unsigned long delta, fcopy;

	if (va < seg_va)
		return (0);
	frame = kmem_alloc_page();
	if (frame == 0)
		return (0);
	bzero_bytes(frame, PAGESIZE);

	delta = va - seg_va;			/* page offset within the segment */
	if (delta < filesz) {
		fcopy = filesz - delta;
		if (fcopy > PAGESIZE)
			fcopy = PAGESIZE;
		bcopy_bytes(img + file_off + delta, frame, fcopy);
	}
	/* text is read+execute+user (the lazy leaf carried these perms). */
	if (hat_user_map(root, va, (unsigned long)frame,
	    PTE_R | PTE_X | PTE_U) != 0)
		return (0);
	return (1);
}

/* ---- R-P27: dynamic exec via ld.so.1 -------------------------------- */

extern int ramfs_lookup(const char *path, const unsigned char **out,
    unsigned long *outlen);

/*
 * elf_has_interp -- return the PT_INTERP path (a pointer into img) if the ELF
 * requests an interpreter, else 0.  The kernel uses this to decide between the
 * static exec_image path and the dynamic ld.so.1 path.
 */
const char *
elf_has_interp(const unsigned char *img)
{
	const Elf64_Ehdr *eh = (const Elf64_Ehdr *)img;
	unsigned int i;

	for (i = 0; i < eh->e_phnum; i++) {
		const Elf64_Phdr *ph = (const Elf64_Phdr *)(img + eh->e_phoff +
		    (unsigned long)i * eh->e_phentsize);
		if (ph->p_type == PT_INTERP)
			return ((const char *)(img + ph->p_offset));
	}
	return (0);
}

/* map every PT_LOAD segment of `img` (an ET_EXEC, load base 0) into uroot. */
static int
map_load_segments(unsigned long *uroot, const unsigned char *img)
{
	const Elf64_Ehdr *eh = (const Elf64_Ehdr *)img;
	unsigned int i;

	for (i = 0; i < eh->e_phnum; i++) {
		const Elf64_Phdr *ph = (const Elf64_Phdr *)(img + eh->e_phoff +
		    (unsigned long)i * eh->e_phentsize);
		unsigned long seg_va, seg_end, va, perms;

		if (ph->p_type != PT_LOAD || ph->p_memsz == 0)
			continue;
		perms = PTE_U;
		if (ph->p_flags & PF_R) perms |= PTE_R;
		if (ph->p_flags & PF_W) perms |= PTE_W;
		if (ph->p_flags & PF_X) perms |= PTE_X;
		/* ld.so.1 writes the app's GOT/relocs, so any segment it must
		   patch needs W; the DYNAMIC hello has no relocs, but keep the
		   phdr/dynamic reachable read/write-safe by adding W to the RW
		   seg only (as the phdrs already say). */
		seg_va = ph->p_vaddr & PAGEMASK;
		seg_end = ph->p_vaddr + ph->p_memsz;
		for (va = seg_va; va < seg_end; va += PAGESIZE) {
			unsigned char *frame = kmem_alloc_page();
			if (frame == 0)
				return (-1);
			bzero_bytes(frame, PAGESIZE);
			if (va + PAGESIZE > ph->p_vaddr &&
			    va < ph->p_vaddr + ph->p_filesz) {
				unsigned long cs = va > ph->p_vaddr ?
				    va : ph->p_vaddr;
				unsigned long fend = ph->p_vaddr + ph->p_filesz;
				unsigned long ce = (va + PAGESIZE) < fend ?
				    (va + PAGESIZE) : fend;
				bcopy_bytes(img + ph->p_offset +
				    (cs - ph->p_vaddr), frame + (cs - va),
				    ce - cs);
			}
			if (hat_user_map(uroot, va, (unsigned long)frame,
			    perms) != 0)
				return (-1);
		}
	}
	return (0);
}

/*
 * exec_dynamic -- R-P27: load a DYNAMIC ET_EXEC (has PT_INTERP) plus its
 * interpreter (ld.so.1, resolved from the ramfs) into a fresh user AS, build
 * an auxv carrying the app's program headers + entry + the interp base, and
 * set the entry to the INTERPRETER's entry (_rtld_start).  ld.so.1 then reads
 * the auxv, relocates the app, and jumps to the app entry.
 *
 * Both the app (linked at 0x10000) and ld.so.1 (linked at 0x30000000) are
 * ET_EXEC, so we map each at its own vaddrs with load base 0 -- they do not
 * collide.  The app's phdrs are inside its first LOAD segment (PT_PHDR), so
 * they are mapped automatically; AT_PHDR points at their VA.
 *
 * CRIB PROVENANCE: exec detecting PT_INTERP, mapping the interpreter, building
 * the auxv (AT_PHDR/AT_PHNUM/AT_PHENT/AT_ENTRY/AT_BASE) and entering the
 * interpreter is the illumos exec elfexec / mapexec_interp + BSD
 * exec_elf_imgact interp handling; the auxv contents are the RISC-V psABI +
 * <sys/auxv.h>.
 */
int
exec_dynamic(struct uproc *up, const unsigned char *img)
{
	const Elf64_Ehdr *aeh = (const Elf64_Ehdr *)img;
	const char *interp = elf_has_interp(img);
	const unsigned char *iimg;
	unsigned long ilen;
	const Elf64_Ehdr *ieh;
	unsigned long *uroot;
	unsigned long *ustk_pa[USTACK_PAGES];
	unsigned char *kstack;
	unsigned long app_phdr_va;
	unsigned int i;

	if (interp == 0)
		return (exec_image(up, img));	/* not dynamic */
	if (ramfs_lookup(interp, &iimg, &ilen) != 0) {
		sbi_console_puts("[exec] interpreter not in ramfs: ");
		sbi_console_puts(interp);
		sbi_console_puts("\n");
		return (-1);
	}
	ieh = (const Elf64_Ehdr *)iimg;
	if (aeh->e_machine != EM_RISCV || ieh->e_machine != EM_RISCV)
		return (-1);

	uroot = hat_user_new();
	if (uroot == 0)
		return (-1);

	/* map the app and the interpreter (both ET_EXEC, own vaddrs). */
	if (map_load_segments(uroot, img) != 0)
		return (-1);
	if (map_load_segments(uroot, iimg) != 0)
		return (-1);

	/* the app's phdrs sit at (e_phoff) inside its first LOAD segment,
	   whose vaddr for the DYNAMIC hello is the file base -> phdr VA. */
	app_phdr_va = 0;
	for (i = 0; i < aeh->e_phnum; i++) {
		const Elf64_Phdr *ph = (const Elf64_Phdr *)(img + aeh->e_phoff +
		    (unsigned long)i * aeh->e_phentsize);
		if (ph->p_type == PT_PHDR)
			app_phdr_va = ph->p_vaddr;
	}
	if (app_phdr_va == 0) {
		/* no PT_PHDR: derive from the first LOAD seg vaddr + phoff. */
		for (i = 0; i < aeh->e_phnum; i++) {
			const Elf64_Phdr *ph = (const Elf64_Phdr *)(img +
			    aeh->e_phoff + (unsigned long)i * aeh->e_phentsize);
			if (ph->p_type == PT_LOAD) {
				app_phdr_va = ph->p_vaddr + aeh->e_phoff -
				    ph->p_offset;
				break;
			}
		}
	}

	/* user stack + the psABI initial stack with a full auxv. */
	for (i = 0; i < USTACK_PAGES; i++) {
		ustk_pa[i] = kmem_alloc_page();
		if (ustk_pa[i] == 0)
			return (-1);
		bzero_bytes((unsigned char *)ustk_pa[i], PAGESIZE);
		if (hat_user_map(uroot,
		    USTACK_TOP - (unsigned long)(USTACK_PAGES - i) * PAGESIZE,
		    (unsigned long)ustk_pa[i], PTE_R | PTE_W | PTE_U) != 0)
			return (-1);
	}
	{
		unsigned char *ktop =
		    (unsigned char *)ustk_pa[USTACK_PAGES - 1] + PAGESIZE;
		unsigned long utop = USTACK_TOP;
		static const char arg0_default[] = "prog";
		unsigned long argv_uva[EXEC_MAXARG];
		unsigned long env_uva[EXEC_MAXARG];
		unsigned long ustr, uw, nwords;
		unsigned long *kw;
		int nargs, ai, nenv = 0;

		/*
		 * R-P38.1: lay the staged argv strings (the shell's argv, e.g.
		 * "/bin/coreecho R-P38 ...") at the top of the user stack just
		 * like the static exec_image path -- the R-P27 code hardcoded
		 * argc=1/"hello", which starved a REAL program (the coreutils
		 * echo) of its arguments.  Then build argc/argv[]/NULL, an empty
		 * envp, and the DYNAMIC auxv (AT_PHDR/PHENT/PHNUM/ENTRY/BASE/
		 * PAGESZ) that ld.so.1 reads.
		 */
		nargs = exec_argv_n;
		if (nargs <= 0)
			nargs = 1;		/* default argv[0]="prog" */
		ustr = utop;
		for (ai = nargs - 1; ai >= 0; ai--) {
			const char *s = (exec_argv_n > 0) ?
			    exec_argv_buf[ai] : arg0_default;
			unsigned long len = 0;
			while (s[len] != 0)
				len++;
			len++;			/* include the NUL */
			ustr -= len;
			bcopy_bytes((const unsigned char *)s,
			    ktop - (utop - ustr), len);
			argv_uva[ai] = ustr;
		}

		/*
		 * R-P43: a small DEFAULT ENVIRONMENT for the new image so a real
		 * `env` prints something (envp was NULL before -- an empty env).
		 * Lay the env strings on the stack (like argv), record their VAs,
		 * and thread them through the envp[] vector below.  The reduced
		 * kernel does not yet propagate a caller's environ across
		 * execve(2) (SYS_execve carries only path+argv), so this is the
		 * process's default env, matching a login shell's minimal set.
		 */
		{
			static const char *const env_default[] = {
			    "PATH=/bin", "PWD=/", "HOME=/", "SHELL=/bin/sh"
			};
			int ei;
			for (ei = (int)(sizeof (env_default) /
			    sizeof (env_default[0])) - 1; ei >= 0; ei--) {
				const char *s = env_default[ei];
				unsigned long len = 0;
				while (s[len] != 0)
					len++;
				len++;
				ustr -= len;
				bcopy_bytes((const unsigned char *)s,
				    ktop - (utop - ustr), len);
				env_uva[ei] = ustr;
			}
			nenv = (int)(sizeof (env_default) /
			    sizeof (env_default[0]));
		}

		/* argc + nargs argv ptrs + NULL + nenv env ptrs + NULL +
		   7 auxv pairs (AT_PHDR/PHENT/PHNUM/ENTRY/BASE/PAGESZ/NULL). */
		nwords = 1 + (unsigned long)nargs + 1 +
		    (unsigned long)nenv + 1 + 14;
		uw = (ustr & ~15UL) - nwords * 8;
		uw &= ~15UL;
		kw = (unsigned long *)(ktop - (utop - uw));

		kw[0] = (unsigned long)nargs;		/* argc */
		for (ai = 0; ai < nargs; ai++)
			kw[1 + ai] = argv_uva[ai];	/* argv[ai] */
		kw[1 + nargs] = 0;			/* argv NULL */
		for (ai = 0; ai < nenv; ai++)
			kw[2 + nargs + ai] = env_uva[ai];  /* envp[ai] */
		kw[2 + nargs + nenv] = 0;		/* envp NULL */
		{
			unsigned long b = 3 + (unsigned long)nargs +
			    (unsigned long)nenv;
			kw[b + 0]  = AT_PHDR;   kw[b + 1]  = app_phdr_va;
			kw[b + 2]  = AT_PHENT;  kw[b + 3]  = aeh->e_phentsize;
			kw[b + 4]  = AT_PHNUM;  kw[b + 5]  = aeh->e_phnum;
			kw[b + 6]  = AT_ENTRY;  kw[b + 7]  = aeh->e_entry;
			kw[b + 8]  = AT_BASE;   kw[b + 9]  = 0; /* interp ET_EXEC */
			kw[b + 10] = AT_PAGESZ; kw[b + 11] = PAGESIZE;
			kw[b + 12] = AT_NULL;   kw[b + 13] = 0;
		}

		up->u_sp = uw;
	}

	kstack = kmem_alloc(KSTACK_SIZE);
	if (kstack == 0)
		return (-1);
	up->u_kstack_top = ((unsigned long)kstack + KSTACK_SIZE) & ~15UL;
	up->u_root = (unsigned long)uroot;
	up->u_satp = MAKE_SATP(KVTOP((unsigned long)uroot));
	up->u_entry = ieh->e_entry;	/* ENTER THE INTERPRETER (ld.so.1) */
	return (0);
}

/* ---- R-P28: map a DT_NEEDED shared object (ET_DYN) for ld.so.1 ------- */

extern unsigned long *proc_curroot(void);

/*
 * map_dyn_segments -- map every PT_LOAD segment of an ET_DYN `img` into uroot,
 * biased by `base` (the load address ld.so.1 chose): each segment lands at
 * base + p_vaddr.  Unlike the ET_EXEC path (map_load_segments, load base 0),
 * this adds `base` to the vaddr and FORCES write on every segment so ld.so.1
 * can patch the object's GOT / the app's cross-object slots.  (Reduced: no R^X
 * hardening -- the whole object is mapped RWX-user for the load-time linker;
 * a real ld.so.1 mprotects after relocating.)
 */
static int
map_dyn_segments(unsigned long *uroot, const unsigned char *img,
    unsigned long base)
{
	const Elf64_Ehdr *eh = (const Elf64_Ehdr *)img;
	unsigned int i;

	for (i = 0; i < eh->e_phnum; i++) {
		const Elf64_Phdr *ph = (const Elf64_Phdr *)(img + eh->e_phoff +
		    (unsigned long)i * eh->e_phentsize);
		unsigned long seg_va, seg_end, va, perms;

		if (ph->p_type != PT_LOAD || ph->p_memsz == 0)
			continue;
		/* map user + all of R/W/X: the runtime linker writes the GOT
		   (RELATIVE/JUMP_SLOT) which lands in a nominally-RO segment, so
		   grant W here (reduced; mprotect-after-reloc is later work). */
		perms = PTE_U | PTE_R | PTE_W | PTE_X;

		seg_va = (base + ph->p_vaddr) & PAGEMASK;
		seg_end = base + ph->p_vaddr + ph->p_memsz;
		for (va = seg_va; va < seg_end; va += PAGESIZE) {
			unsigned char *frame = kmem_alloc_page();
			unsigned long fbase = base + ph->p_vaddr;
			if (frame == 0)
				return (-1);
			bzero_bytes(frame, PAGESIZE);
			if (va + PAGESIZE > fbase &&
			    va < fbase + ph->p_filesz) {
				unsigned long cs = va > fbase ? va : fbase;
				unsigned long fend = fbase + ph->p_filesz;
				unsigned long ce = (va + PAGESIZE) < fend ?
				    (va + PAGESIZE) : fend;
				bcopy_bytes(img + ph->p_offset +
				    (cs - fbase), frame + (cs - va), ce - cs);
			}
			if (hat_user_map(uroot, va, (unsigned long)frame,
			    perms) != 0)
				return (-1);
		}
	}
	return (0);
}

/*
 * exec_map_so -- the SYS_mapso syscall body.  ld.so.1 asks the kernel to map a
 * DT_NEEDED shared object (found by `path` in the ramfs) at load address `base`
 * into the CALLING process's address space.  The kernel resolves the bytes,
 * checks it is an EM_RISCV ET_DYN, and maps its PT_LOAD segments biased by
 * `base` into the current user root.  ld.so.1 then processes the object's own
 * dynamic section + binds the app's cross-object references.  Returns 0 on
 * success, -1 on failure.
 *
 * CRIB PROVENANCE: mapping a shared object's PT_LOAD segments at a chosen base
 * into the address space is the illumos ld.so.1 analyze.c load_so / elf_map_it
 * (mmap the ELF file's LOAD segments at the load base) reduced to an eager
 * copy-into-frames map over the ramfs image; the ET_DYN bias (base + p_vaddr)
 * is the SysV gABI position-independent load model.
 */
int
exec_map_so(const char *path, unsigned long base)
{
	const unsigned char *img;
	unsigned long len;
	const Elf64_Ehdr *eh;
	unsigned long *uroot;

	if (path == 0)
		return (-1);
	if (ramfs_lookup(path, &img, &len) != 0) {
		/*
		 * A bare DT_NEEDED soname (no '/') is searched along the
		 * reduced default library path: /lib then /usr/lib.  (The real
		 * ld.so.1 walks DT_RPATH/LD_LIBRARY_PATH/the default trusted
		 * dirs; this is that search reduced to two fixed prefixes.)
		 */
		static const char *const libdirs[] = { "/lib/", "/usr/lib/" };
		char buf[128];
		unsigned d, i, k;
		int found = 0;

		for (d = 0; d < 2 && !found; d++) {
			k = 0;
			for (i = 0; libdirs[d][i] && k < sizeof (buf) - 1; i++)
				buf[k++] = libdirs[d][i];
			for (i = 0; path[i] && k < sizeof (buf) - 1; i++)
				buf[k++] = path[i];
			buf[k] = 0;
			if (ramfs_lookup(buf, &img, &len) == 0)
				found = 1;
		}
		if (!found)
			return (-1);
	}
	eh = (const Elf64_Ehdr *)img;
	if (!(eh->e_ident[0] == 0x7f && eh->e_ident[1] == 0x45 &&
	    eh->e_ident[2] == 0x4c && eh->e_ident[3] == 0x46) ||
	    eh->e_machine != EM_RISCV || eh->e_type != ET_DYN)
		return (-1);
	uroot = proc_curroot();
	if (uroot == 0)
		return (-1);
	if (map_dyn_segments(uroot, img, base) != 0)
		return (-1);
	/* the new mappings must be visible to the running (user-satp) proc. */
	__asm__ __volatile__("sfence.vma" ::: "memory");
	/*
	 * R-P49 (SMP bind race): the .so we just mapped carries CODE pages
	 * written with plain data stores.  ld.so.1 returns from this syscall on
	 * the SAME hart and (without an intervening context switch) tail-jumps
	 * into the app, which calls a routine (__multf3) that now lives in those
	 * freshly-written .so pages.  Flush this hart's I-cache so it does not
	 * fetch stale instructions for them, AND broadcast a remote fence.i to
	 * the OTHER harts (the proc may be scheduled onto one whose I-cache is
	 * stale for these pages) -- otherwise the cross-object call executes
	 * garbage and the app exits with a bogus status (the R-P28.1 -smp 2
	 * flake).  (rv_set_satp also fence.i's on a root switch as a backstop.)
	 */
	__asm__ __volatile__("fence.i" ::: "memory");
	{
		extern long sbi_remote_fence_i(unsigned long hart_mask);
		(void) sbi_remote_fence_i(~0UL);  /* all harts */
	}
	return (0);
}
