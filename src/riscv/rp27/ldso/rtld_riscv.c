/*
 * rtld_riscv.c -- R-P27: the riscv64 ld.so.1 runtime linker body, hosted by the
 * R-P26/R-P27 kernel.  Entered from _rtld_start (rtld_start.S) with a0 = the
 * psABI initial stack (&argc); walks the auxv the kernel built, finds the
 * application's program headers (AT_PHDR/AT_PHNUM/AT_PHENT), entry (AT_ENTRY)
 * and its own base (AT_BASE), locates the app's PT_DYNAMIC, reports its
 * DT_NEEDED objects (the shared libraries the kernel seeded into the ramfs),
 * applies the app's DT_RELA relocations with the R-P23 riscv64 reloc engine
 * (elf_reloc_riscv: R_RISCV_RELATIVE + R_RISCV_JUMP_SLOT), and returns the app
 * entry so _rtld_start can jump into the now-relocated executable.
 *
 * This is the REDUCED-but-real ld.so.1 path: it reads the aux vector, parses
 * the dynamic section, and runs the relocation loop -- the same shape as the
 * illumos runtime linker, minus mapping the DT_NEEDED objects (the DYNAMIC
 * hello binds no symbol from libgcc_s, so its RELA table is empty and no
 * cross-object binding is needed; loading libgcc_s into the AS is the next
 * step, documented as an R-P28 reduction).
 *
 * Talks to the kernel through the R-P25 write(2) syscall (a7=4) for its
 * progress lines; no libc.
 *
 * CRIB PROVENANCE: reading the auxv off the initial stack + dispatching on
 * AT_* tags is the illumos ld.so.1 _setup / rtld_start + the RISC-V psABI
 * program startup; walking PT_DYNAMIC for DT_RELA/DT_RELASZ/DT_NEEDED + the
 * relocate loop are usr/src/cmd/sgs/rtld/common/setup.c + _elf.c reduced to
 * the riscv64 load-time types; the reloc formulas (RELATIVE=base+addend,
 * JUMP_SLOT=symval) are the R-P23 rtld_riscv.c + the RISC-V psABI.
 */

typedef unsigned long		Elf64_Addr;
typedef unsigned long		Elf64_Xword;
typedef long			Elf64_Sxword;
typedef unsigned long		Elf64_Off;
typedef unsigned short		Elf64_Half;
typedef unsigned int		Elf64_Word;

typedef struct {
	Elf64_Addr	r_offset;
	Elf64_Xword	r_info;
	Elf64_Sxword	r_addend;
} Elf64_Rela;

typedef struct {
	Elf64_Xword	d_tag;
	Elf64_Xword	d_val;		/* union d_ptr; same width */
} Elf64_Dyn;

typedef struct {
	Elf64_Word	p_type;
	Elf64_Word	p_flags;
	Elf64_Off	p_offset;
	Elf64_Addr	p_vaddr;
	Elf64_Addr	p_paddr;
	Elf64_Xword	p_filesz;
	Elf64_Xword	p_memsz;
	Elf64_Xword	p_align;
} Elf64_Phdr;

#define	ELF64_R_TYPE(i)		((unsigned)((i) & 0xffffffffUL))
#define	ELF64_R_SYM(i)		((unsigned)((i) >> 32))

#define	R_RISCV_NONE		0
#define	R_RISCV_64		2
#define	R_RISCV_RELATIVE	3
#define	R_RISCV_JUMP_SLOT	5

#define	PT_LOAD		1
#define	PT_DYNAMIC	2
#define	PT_INTERP	3
#define	PT_PHDR		6

#define	DT_NULL		0
#define	DT_NEEDED	1
#define	DT_STRTAB	5
#define	DT_RELA		7
#define	DT_RELASZ	8
#define	DT_RELAENT	9

/* auxv tags (psABI / <sys/auxv.h>). */
#define	AT_NULL		0
#define	AT_PHDR		3
#define	AT_PHENT	4
#define	AT_PHNUM	5
#define	AT_BASE		7
#define	AT_ENTRY	9

#define	SYS_write	4

/* write(2) via ecall (a7=4). */
static long
sys_write(int fd, const void *buf, unsigned long n)
{
	register long a7 __asm__("a7") = SYS_write;
	register long a0 __asm__("a0") = fd;
	register long a1 __asm__("a1") = (long)buf;
	register long a2 __asm__("a2") = (long)n;
	__asm__ __volatile__("ecall" : "+r"(a0) : "r"(a7), "r"(a1), "r"(a2)
	    : "memory");
	return (a0);
}

static unsigned long
slen(const char *s)
{
	unsigned long n = 0;
	while (s[n])
		n++;
	return (n);
}

static void
puts_(const char *s)
{
	sys_write(1, s, slen(s));
}

/*
 * elf_reloc_riscv -- the R-P23 reduced riscv64 relocation loop, hosted now
 * inside the real ld.so.1: for each RELA against the object loaded at `base`,
 * apply the psABI formula.  symvals[] would come from symbol lookup; the
 * DYNAMIC hello carries no symbolic relocs so only RELATIVE (base+addend) is
 * exercised in practice.
 */
static long
elf_reloc_riscv(Elf64_Addr base, const Elf64_Rela *rela, unsigned n,
    const Elf64_Addr *symvals)
{
	unsigned i;
	long applied = 0;

	for (i = 0; i < n; i++) {
		Elf64_Addr *where = (Elf64_Addr *)(base + rela[i].r_offset);
		unsigned type = ELF64_R_TYPE(rela[i].r_info);
		unsigned sym = ELF64_R_SYM(rela[i].r_info);

		switch (type) {
		case R_RISCV_NONE:
			break;
		case R_RISCV_RELATIVE:
			*where = base + (Elf64_Addr)rela[i].r_addend;
			applied++;
			break;
		case R_RISCV_JUMP_SLOT:
		case R_RISCV_64:
			*where = (symvals ? symvals[sym] : 0) +
			    (Elf64_Addr)rela[i].r_addend;
			applied++;
			break;
		default:
			return (-1);
		}
	}
	return (applied);
}

/*
 * rtld_main -- the ld.so.1 body.  stackp = &argc (the psABI initial stack).
 * Layout: [argc][argv0..argvN][NULL][envp0..][NULL][auxv pairs..][AT_NULL].
 * Walk to the auxv, read the app phdrs/entry/base, find PT_DYNAMIC, report
 * DT_NEEDED, relocate the app, and return its entry.
 */
Elf64_Addr
rtld_main(unsigned long *stackp)
{
	long argc = (long)stackp[0];
	unsigned long *p;
	Elf64_Addr at_phdr = 0, at_entry = 0, at_base = 0;
	unsigned at_phnum = 0, at_phent = 0;
	const Elf64_Phdr *ph;
	const Elf64_Dyn *dyn = 0;
	Elf64_Addr app_base = 0;
	const char *strtab = 0;
	const Elf64_Rela *rela = 0;
	unsigned long relasz = 0, relaent = sizeof (Elf64_Rela);
	unsigned i;

	puts_("[ld.so.1] riscv64 runtime linker: hosting the DYNAMIC hello\n");

	/* skip argc, argv[], the NULL, envp[], the NULL -> auxv. */
	p = stackp + 1;			/* argv[0] */
	p += argc;			/* argv[argc] == NULL */
	p += 1;				/* first envp */
	while (*p != 0)			/* skip envp[] to its NULL */
		p++;
	p += 1;				/* first auxv pair */

	for (; p[0] != AT_NULL; p += 2) {
		switch (p[0]) {
		case AT_PHDR:	at_phdr = (Elf64_Addr)p[1];	break;
		case AT_PHENT:	at_phent = (unsigned)p[1];	break;
		case AT_PHNUM:	at_phnum = (unsigned)p[1];	break;
		case AT_BASE:	at_base = (Elf64_Addr)p[1];	break;
		case AT_ENTRY:	at_entry = (Elf64_Addr)p[1];	break;
		}
	}

	if (at_phdr == 0 || at_entry == 0) {
		puts_("[ld.so.1] FATAL: no AT_PHDR/AT_ENTRY in auxv\n");
		return (0);
	}
	(void) at_base;
	if (at_phent == 0)
		at_phent = sizeof (Elf64_Phdr);

	/*
	 * The app is an ET_EXEC linked at its vaddrs (load base 0), so
	 * app_base = 0 and the phdr vaddrs are absolute VAs.  Find PT_DYNAMIC.
	 * (PT_PHDR gives p_vaddr == the phdr VA; app_base = at_phdr - that.)
	 */
	for (i = 0; i < at_phnum; i++) {
		ph = (const Elf64_Phdr *)(at_phdr + (unsigned long)i * at_phent);
		if (ph->p_type == PT_PHDR)
			app_base = at_phdr - ph->p_vaddr;
	}
	for (i = 0; i < at_phnum; i++) {
		ph = (const Elf64_Phdr *)(at_phdr + (unsigned long)i * at_phent);
		if (ph->p_type == PT_DYNAMIC)
			dyn = (const Elf64_Dyn *)(app_base + ph->p_vaddr);
	}

	if (dyn == 0) {
		puts_("[ld.so.1] app has no PT_DYNAMIC (static?); "
		    "entering entry\n");
		return (at_entry);
	}

	/* first pass: STRTAB + RELA table. */
	for (i = 0; dyn[i].d_tag != DT_NULL; i++) {
		switch (dyn[i].d_tag) {
		case DT_STRTAB:	strtab = (const char *)(app_base + dyn[i].d_val); break;
		case DT_RELA:	rela = (const Elf64_Rela *)(app_base + dyn[i].d_val); break;
		case DT_RELASZ:	relasz = dyn[i].d_val;	break;
		case DT_RELAENT: relaent = dyn[i].d_val;	break;
		}
	}

	/* report DT_NEEDED (the shared libs; we seeded them in the ramfs). */
	for (i = 0; dyn[i].d_tag != DT_NULL; i++) {
		if (dyn[i].d_tag == DT_NEEDED && strtab != 0) {
			puts_("[ld.so.1] DT_NEEDED: ");
			puts_(strtab + dyn[i].d_val);
			puts_("\n");
		}
	}

	/* relocate the app (RELATIVE only for the DYNAMIC hello: RELASZ==0). */
	{
		unsigned n = relaent ? (unsigned)(relasz / relaent) : 0;
		long applied = elf_reloc_riscv(app_base, rela, n, 0);
		char nb[2];
		nb[0] = (applied >= 0 && applied < 10) ?
		    (char)('0' + applied) : '?';
		nb[1] = 0;
		puts_("[ld.so.1] relocations applied to the app: ");
		puts_(nb);
		puts_("\n");
		if (applied < 0) {
			puts_("[ld.so.1] FATAL: unhandled reloc type\n");
			return (0);
		}
	}

	puts_("[ld.so.1] app relocated; jumping to its entry (_start)\n");
	return (at_entry);
}
