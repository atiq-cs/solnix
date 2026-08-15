/*
 * exec_elf.c -- R-P25 sub-task 3: a reduced exec path for a single static
 * EM_RISCV ELF64.  exec_user() parses the embedded userland ELF, allocates a
 * fresh user address space (hat_user_new), maps each PT_LOAD segment + a user
 * stack into it (hat_user_map), copies the segment bytes, builds the initial
 * user stack (argc/argv/envp/auxv per the psABI), and returns the entry VA +
 * user sp so the caller can sret into U-mode.
 *
 * REDUCED (per the anti-wedge directive): one static ELF, no interpreter / no
 * ld.so.1, no copy-on-write / demand paging (segments are eagerly copied into
 * freshly kmem-allocated identity-mapped frames), a fixed-size user stack, a
 * minimal aux vector (AT_PAGESZ, AT_ENTRY, AT_NULL).  This is toward the
 * general gexec/elfexec, enough to run the R-P22 static hello as a process.
 *
 * CRIB PROVENANCE: the "walk the program headers, map+copy each PT_LOAD, zero
 * the .bss tail (p_memsz > p_filesz), set the entry, build the aux vector"
 * shape is the illumos exec elf mapelfexec / elfexec + BSD exec_elf64_imgact;
 * the initial-stack layout (argc, argv[], NULL, envp[], NULL, auxv[], AT_NULL)
 * is the RISC-V psABI program-startup + the illumos exec_args; ELF64 header /
 * phdr structs are the SysV gABI / <sys/elf.h>.
 */

#include "mmu_riscv.h"
#include "proc_riscv.h"
#include "sbi.h"

extern void *kmem_alloc(unsigned long);
extern void *kmem_alloc_page(void);
extern void putdec_pub(unsigned long);
extern void puthex_pub(unsigned long);

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
#define	PF_X		1
#define	PF_W		2
#define	PF_R		4
#define	EM_RISCV	243
#define	ET_EXEC		2

/* aux vector types (a_type) -- the few a static crt may consult. */
#define	AT_NULL		0
#define	AT_PAGESZ	6
#define	AT_ENTRY	9

/* user stack: one page just below the 0x40000000 line (still in L2 idx 0). */
#define	USTACK_TOP	0x40000000UL
#define	USTACK_PAGES	4			/* 16 KiB user stack */

/* kernel trap stack for the lwp (sscratch); in the identity-mapped boot heap. */
#define	KSTACK_SIZE	(16UL * 1024)

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
exec_user(struct uproc *up)
{
	const unsigned char *img = user_elf_start;
	const Elf64_Ehdr *eh = (const Elf64_Ehdr *)img;
	const Elf64_Phdr *ph;
	unsigned long *uroot;
	unsigned long *ustk_pa[USTACK_PAGES];
	unsigned char *kstack;
	unsigned int i;

	/* validate: ELF magic, 64-bit, EM_RISCV, ET_EXEC. */
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

	/* map + copy each PT_LOAD segment. */
	for (i = 0; i < eh->e_phnum; i++) {
		unsigned long seg_va, seg_end, va, perms;
		ph = (const Elf64_Phdr *)(img + eh->e_phoff +
		    (unsigned long)i * eh->e_phentsize);
		if (ph->p_type != PT_LOAD || ph->p_memsz == 0)
			continue;

		/* leaf perms from the phdr flags (+ PTE_U for user access). */
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
		 * Walk the segment page by page: allocate an identity-mapped
		 * frame (kmem), map it into the user AS, then copy the file
		 * bytes that fall in this page and zero the rest (bss tail).
		 */
		for (va = seg_va; va < seg_end; va += PAGESIZE) {
			unsigned char *frame = kmem_alloc_page();
			unsigned long off_in_seg, filebytes;

			if (frame == 0)
				return (-1);
			bzero_bytes(frame, PAGESIZE);

			/* how much of this page is inside [p_vaddr,+p_filesz)? */
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

	/* user stack: map USTACK_PAGES just below USTACK_TOP, RW|U. */
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

	/*
	 * Build the initial user stack in the TOP user-stack frame (which is
	 * identity-mapped as ustk_pa[USTACK_PAGES-1]).  We lay out, growing
	 * DOWN from the top:
	 *   [ argv strings ] ... then aligned:
	 *   argc, argv[0], NULL, envp NULL, auxv{AT_PAGESZ, AT_ENTRY, AT_NULL}
	 * The user VA of the top frame is USTACK_TOP; the identity (kernel)
	 * address of that same frame is ustk_pa[last].  We write through the
	 * kernel view and compute the matching user VA for the sp.
	 */
	{
		unsigned char *ktop = (unsigned char *)ustk_pa[USTACK_PAGES - 1]
		    + PAGESIZE;			/* kernel ptr to frame end */
		unsigned long utop = USTACK_TOP;	/* user VA of frame end */
		static const char arg0[] = "hello";
		unsigned char *kstr;
		unsigned long ustr;
		unsigned long *kw;
		unsigned long uw;
		unsigned long nwords, argv0_uva;

		/* place the arg0 string at the very top. */
		kstr = ktop - sizeof (arg0);
		ustr = utop - sizeof (arg0);
		bcopy_bytes((const unsigned char *)arg0, kstr, sizeof (arg0));
		argv0_uva = ustr;

		/*
		 * The startup word block (all 8-byte words), from low to high:
		 *   [0] argc = 1
		 *   [1] argv[0] = argv0_uva
		 *   [2] argv NULL
		 *   [3] envp NULL
		 *   [4] auxv AT_PAGESZ type
		 *   [5] auxv AT_PAGESZ val = PAGESIZE
		 *   [6] auxv AT_ENTRY type
		 *   [7] auxv AT_ENTRY val = e_entry
		 *   [8] auxv AT_NULL type
		 *   [9] auxv AT_NULL val = 0
		 * sp must point at argc (word 0) and be 16-byte aligned.
		 */
		nwords = 10;
		/* reserve, keeping the block 16-byte aligned below the string. */
		uw = (ustr & ~15UL) - nwords * 8;
		uw &= ~15UL;			/* 16-byte align the sp */
		kw = (unsigned long *)(ktop - (utop - uw));

		kw[0] = 1;			/* argc */
		kw[1] = argv0_uva;		/* argv[0] */
		kw[2] = 0;			/* argv NULL */
		kw[3] = 0;			/* envp NULL */
		kw[4] = AT_PAGESZ;
		kw[5] = PAGESIZE;
		kw[6] = AT_ENTRY;
		kw[7] = eh->e_entry;
		kw[8] = AT_NULL;
		kw[9] = 0;

		up->u_sp = uw;
	}

	/* a kernel trap stack for this lwp (sscratch on U-trap). */
	kstack = kmem_alloc(KSTACK_SIZE);
	if (kstack == 0)
		return (-1);
	up->u_kstack_top = ((unsigned long)kstack + KSTACK_SIZE) & ~15UL;

	up->u_satp = MAKE_SATP((unsigned long)uroot);
	up->u_entry = eh->e_entry;
	return (0);
}
