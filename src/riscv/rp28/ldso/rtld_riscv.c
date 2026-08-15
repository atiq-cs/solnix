/*
 * rtld_riscv.c -- R-P28: the riscv64 ld.so.1 runtime linker, now with REAL
 * CROSS-OBJECT DYNAMIC LINKING.  Where R-P27's ld.so.1 only reported the
 * application's DT_NEEDED and relocated the app in isolation, R-P28 maps the
 * DT_NEEDED shared objects (libgcc_s.so.1) into the address space, processes
 * their own dynamic sections, and BINDS the application's cross-object symbol
 * references (R_RISCV_JUMP_SLOT into the app's GOT/PLT) to the addresses of the
 * symbols as defined in the loaded libraries.  A dynamic hello that CALLS a
 * libgcc_s routine (__multf3 / __fixtfsi) therefore runs correctly: ld.so.1
 * resolves those names in libgcc_s and writes the real function addresses into
 * the app's GOT slots, so the PLT stubs jump straight to them.
 *
 * ENTERED from _rtld_start (rtld_start.S) with a0 = the psABI initial stack
 * (&argc).  Walks the auxv, finds the app's program headers / entry, parses the
 * app's PT_DYNAMIC (STRTAB/SYMTAB/HASH/RELA/JMPREL/PLTRELSZ + DT_NEEDED), maps
 * + processes each NEEDED object, applies the app's own RELATIVE relocs, then
 * binds the app's PLT JUMP_SLOT relocs cross-object and returns the app entry.
 *
 * REDUCED (per the anti-wedge directive): eager PLT binding (no lazy stub / no
 * PLT0 resolver -- ld.so.1 writes every GOT slot up front); SysV .hash lookup
 * (no .gnu.hash); symbol versioning is IGNORED (the .dynstr name, e.g.
 * "__multf3", is matched regardless of its GCC_3.0 version -- correct here
 * because there is a single definition); no scope/breadth-first search beyond a
 * flat loaded-object list (app first, then each NEEDED in order); no recursive
 * DT_NEEDED-of-a-NEEDED (libgcc_s needs nothing further); the objects are
 * mapped by a kernel syscall (SYS_mapso) that maps an ET_DYN's PT_LOAD segments
 * at a chosen base and hands back the base -- ld.so.1 chooses the base, the
 * kernel does the page mapping (the real ld.so.1 mmaps the file itself; the
 * split is a reduction).
 *
 * Talks to the kernel through write(2) (a7=4) for progress lines and mapso
 * (a7=222, an mmap-family number) to map a NEEDED object; no libc.
 *
 * CRIB PROVENANCE: mapping the DT_NEEDED objects, processing each object's
 * dynamic section, and binding the caller's relocations against the loaded
 * objects' symbol tables is usr/src/cmd/sgs/rtld/common/setup.c (load the
 * primary + its dependencies) + analyze.c load_so()/analyze_lmc() (map + set up
 * each object) + _elf.c elf_bndr()/elf_reloc() (PLT/GOT binding + symbol
 * lookup) reduced to the riscv64 load-time types; the SysV .hash bucket/chain
 * lookup is the SysV gABI (hashval = elf_hash(name); walk bucket[hash % nbucket]
 * -> chain[]); the R_RISCV_JUMP_SLOT = S (+ A) formula + the "GOT slot at
 * r_offset gets the resolved symbol address, PLT stub jumps through it" model
 * are the RISC-V psABI + the R-P23 rtld_riscv.c reloc engine.
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

typedef struct {
	Elf64_Word	st_name;
	unsigned char	st_info;
	unsigned char	st_other;
	Elf64_Half	st_shndx;
	Elf64_Addr	st_value;
	Elf64_Xword	st_size;
} Elf64_Sym;

#define	ELF64_R_TYPE(i)		((unsigned)((i) & 0xffffffffUL))
#define	ELF64_R_SYM(i)		((unsigned)((i) >> 32))
#define	ELF64_ST_TYPE(i)	((i) & 0xf)
#define	STT_NOTYPE		0
#define	STT_FUNC		2
#define	SHN_UNDEF		0

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
#define	DT_PLTRELSZ	2
#define	DT_HASH		4
#define	DT_STRTAB	5
#define	DT_SYMTAB	6
#define	DT_RELA		7
#define	DT_RELASZ	8
#define	DT_RELAENT	9
#define	DT_SYMENT	11
#define	DT_JMPREL	23

/* auxv tags (psABI / <sys/auxv.h>). */
#define	AT_NULL		0
#define	AT_PHDR		3
#define	AT_PHENT	4
#define	AT_PHNUM	5
#define	AT_BASE		7
#define	AT_ENTRY	9

#define	SYS_write	4
#define	SYS_mapso	222		/* R-P28: map a NEEDED ET_DYN (mmap-family) */

/* ---- syscall stubs (illumos ABI: a7=nr, a0..=args, result in a0) ----- */
static long
sys3(long nr, long a0, long a1, long a2)
{
	register long r7 __asm__("a7") = nr;
	register long r0 __asm__("a0") = a0;
	register long r1 __asm__("a1") = a1;
	register long r2 __asm__("a2") = a2;
	__asm__ __volatile__("ecall" : "+r"(r0)
	    : "r"(r7), "r"(r1), "r"(r2) : "memory");
	return (r0);
}

static long
sys_write(int fd, const void *buf, unsigned long n)
{
	return (sys3(SYS_write, fd, (long)buf, (long)n));
}

/*
 * sys_mapso -- ask the kernel to map a NEEDED shared object (an ET_DYN found by
 * name in the ramfs) at `base` into the current address space (its PT_LOAD
 * segments relocated by `base`).  Returns 0 on success, -1 if the object is not
 * present / not mappable.  The kernel does the page mapping; ld.so.1 does the
 * dynamic-section processing + symbol binding.
 */
static long
sys_mapso(const char *path, Elf64_Addr base)
{
	return (sys3(SYS_mapso, (long)path, (long)base, 0));
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

static void
puthex_(unsigned long v)
{
	static const char hx[] = "0123456789abcdef";
	char b[19];
	int i;
	b[0] = '0'; b[1] = 'x';
	for (i = 0; i < 16; i++)
		b[2 + i] = hx[(v >> ((15 - i) * 4)) & 0xf];
	b[18] = 0;
	puts_(b);
}

/* ---- a loaded object: base + its dynamic symbol/hash tables ---------- */
struct lobj {
	Elf64_Addr		base;		/* load bias (0 for ET_EXEC) */
	const char		*strtab;
	const Elf64_Sym		*symtab;
	const Elf64_Word	*hash;		/* [nbucket][nchain][bucket][chain] */
	unsigned		nbucket;
	unsigned		nchain;
	const Elf64_Rela	*rela;		/* DT_RELA (RELATIVE etc.) */
	unsigned long		relasz;
	const Elf64_Rela	*jmprel;	/* DT_JMPREL (PLT relocs) */
	unsigned long		pltrelsz;
};

#define	MAXOBJ	8
static struct lobj objs[MAXOBJ];
static int nobj;

/* the SysV ELF hash (gABI): the canonical name hash. */
static unsigned long
elf_hash(const unsigned char *name)
{
	unsigned long h = 0, g;
	while (*name) {
		h = (h << 4) + *name++;
		if ((g = h & 0xf0000000UL) != 0)
			h ^= g >> 24;
		h &= ~g;
	}
	return (h);
}

static int
streq(const char *a, const char *b)
{
	while (*a && *a == *b) { a++; b++; }
	return (*a == *b);
}

/*
 * parse_dynamic -- fill `lo` from the object's PT_DYNAMIC (already located at
 * `dyn`, with load bias `base`).  Records strtab/symtab/hash + the two reloc
 * tables.  For the hash we read [nbucket][nchain] from the first two words.
 */
static void
parse_dynamic(struct lobj *lo, const Elf64_Dyn *dyn, Elf64_Addr base)
{
	unsigned i;

	lo->base = base;
	for (i = 0; dyn[i].d_tag != DT_NULL; i++) {
		Elf64_Addr v = base + dyn[i].d_val;
		switch (dyn[i].d_tag) {
		case DT_STRTAB:	lo->strtab = (const char *)v; break;
		case DT_SYMTAB:	lo->symtab = (const Elf64_Sym *)v; break;
		case DT_HASH:	lo->hash = (const Elf64_Word *)v; break;
		case DT_RELA:	lo->rela = (const Elf64_Rela *)v; break;
		case DT_RELASZ:	lo->relasz = dyn[i].d_val; break;
		case DT_JMPREL:	lo->jmprel = (const Elf64_Rela *)v; break;
		case DT_PLTRELSZ: lo->pltrelsz = dyn[i].d_val; break;
		}
	}
	if (lo->hash != 0) {
		lo->nbucket = lo->hash[0];
		lo->nchain = lo->hash[1];
	}
}

/*
 * sym_lookup -- find a DEFINED symbol named `name` in loaded object `lo` via
 * its SysV .hash chain.  Returns the symbol's absolute VA (base + st_value), or
 * 0 if not defined here (UNDEF or absent).
 */
static Elf64_Addr
sym_lookup(const struct lobj *lo, const char *name)
{
	unsigned long h;
	const Elf64_Word *bucket, *chain;
	unsigned idx;

	if (lo->hash == 0 || lo->symtab == 0 || lo->strtab == 0)
		return (0);
	bucket = lo->hash + 2;
	chain = bucket + lo->nbucket;
	h = elf_hash((const unsigned char *)name) % lo->nbucket;

	for (idx = bucket[h]; idx != 0; idx = chain[idx]) {
		const Elf64_Sym *s = &lo->symtab[idx];
		if (s->st_shndx == SHN_UNDEF)
			continue;		/* not a definition here */
		if (streq(lo->strtab + s->st_name, name))
			return (lo->base + s->st_value);
	}
	return (0);
}

/* resolve `name` across ALL loaded objects (flat scope, app first). */
static Elf64_Addr
sym_resolve(const char *name)
{
	int i;
	for (i = 0; i < nobj; i++) {
		Elf64_Addr v = sym_lookup(&objs[i], name);
		if (v != 0)
			return (v);
	}
	return (0);
}

/*
 * apply_relative -- apply an object's own R_RISCV_RELATIVE + R_RISCV_64 relocs
 * (its DT_RELA table): these fix the object's internal GOT/data pointers so it
 * runs at `base`.  Symbolic entries (JUMP_SLOT / R_RISCV_64 against a named
 * symbol) are resolved cross-object.  Returns applied count, or -1 on an
 * unhandled type.
 */
static long
apply_rela(const struct lobj *lo, const Elf64_Rela *rela, unsigned long sz)
{
	unsigned n = (unsigned)(sz / sizeof (Elf64_Rela));
	unsigned i;
	long applied = 0;

	if (rela == 0)
		return (0);
	for (i = 0; i < n; i++) {
		Elf64_Addr *where =
		    (Elf64_Addr *)(lo->base + rela[i].r_offset);
		unsigned type = ELF64_R_TYPE(rela[i].r_info);
		unsigned sym = ELF64_R_SYM(rela[i].r_info);

		switch (type) {
		case R_RISCV_NONE:
			break;
		case R_RISCV_RELATIVE:
			*where = lo->base + (Elf64_Addr)rela[i].r_addend;
			applied++;
			break;
		case R_RISCV_JUMP_SLOT:
		case R_RISCV_64: {
			const char *nm =
			    lo->strtab + lo->symtab[sym].st_name;
			Elf64_Addr s = sym_resolve(nm);
			if (s == 0)
				s = lo->base + lo->symtab[sym].st_value;
			*where = s + (Elf64_Addr)rela[i].r_addend;
			applied++;
			break;
		}
		default:
			return (-1);
		}
	}
	return (applied);
}

/*
 * bind_plt -- bind the app's PLT (DT_JMPREL) JUMP_SLOT relocs cross-object.
 * For each PLT reloc, look up the referenced symbol name across the loaded
 * objects and write its address into the GOT slot at r_offset.  This is EAGER
 * binding (every slot resolved up front); the PLT stub then jumps straight to
 * the real function.  Returns bound count, or -1 on an unresolved symbol.
 */
static long
bind_plt(const struct lobj *app)
{
	unsigned n = (unsigned)(app->pltrelsz / sizeof (Elf64_Rela));
	unsigned i;
	long bound = 0;

	if (app->jmprel == 0)
		return (0);
	for (i = 0; i < n; i++) {
		const Elf64_Rela *r = &app->jmprel[i];
		unsigned type = ELF64_R_TYPE(r->r_info);
		unsigned symn = ELF64_R_SYM(r->r_info);
		const char *nm = app->strtab + app->symtab[symn].st_name;
		Elf64_Addr *got = (Elf64_Addr *)(app->base + r->r_offset);
		Elf64_Addr val;

		if (type != R_RISCV_JUMP_SLOT) {
			puts_("[ld.so.1] FATAL: non-JUMP_SLOT in PLT\n");
			return (-1);
		}
		val = sym_resolve(nm);
		if (val == 0) {
			puts_("[ld.so.1] FATAL: unresolved cross-object symbol: ");
			puts_(nm);
			puts_("\n");
			return (-1);
		}
		*got = val + (Elf64_Addr)r->r_addend;
		puts_("[ld.so.1]   bound ");
		puts_(nm);
		puts_(" -> ");
		puthex_(*got);
		puts_("\n");
		bound++;
	}
	return (bound);
}

/*
 * load_needed -- map a DT_NEEDED shared object by name at `base`, locate its
 * PT_DYNAMIC (the .so is an ET_DYN loaded at bias `base`), parse it, and apply
 * its own RELATIVE + PLT relocs so it is self-consistent at `base`.  Records it
 * in the loaded-object list.  Returns 0 on success, -1 on failure.
 *
 * The kernel (SYS_mapso) has already mapped the .so's PT_LOAD segments at
 * `base`; we find PT_DYNAMIC by reading the ET_DYN's ELF header + phdrs at
 * `base` (the first LOAD segment maps the ELF header at offset 0 -> base).
 */
struct Elf64_Ehdr_min {
	unsigned char	e_ident[16];
	Elf64_Half	e_type;
	Elf64_Half	e_machine;
	Elf64_Word	e_version;
	Elf64_Addr	e_entry;
	Elf64_Off	e_phoff;
	Elf64_Off	e_shoff;
	Elf64_Word	e_flags;
	Elf64_Half	e_ehsize;
	Elf64_Half	e_phentsize;
	Elf64_Half	e_phnum;
	Elf64_Half	e_shentsize;
	Elf64_Half	e_shnum;
	Elf64_Half	e_shstrndx;
};

static int
load_needed(const char *name, Elf64_Addr base)
{
	const struct Elf64_Ehdr_min *eh;
	const Elf64_Phdr *ph;
	const Elf64_Dyn *dyn = 0;
	struct lobj *lo;
	unsigned i;

	if (nobj >= MAXOBJ)
		return (-1);
	if (sys_mapso(name, base) != 0) {
		puts_("[ld.so.1] FATAL: could not map NEEDED object: ");
		puts_(name);
		puts_("\n");
		return (-1);
	}
	/* the ELF header now lives at `base` (first LOAD maps offset 0). */
	eh = (const struct Elf64_Ehdr_min *)base;
	for (i = 0; i < eh->e_phnum; i++) {
		ph = (const Elf64_Phdr *)(base + eh->e_phoff +
		    (unsigned long)i * eh->e_phentsize);
		if (ph->p_type == PT_DYNAMIC)
			dyn = (const Elf64_Dyn *)(base + ph->p_vaddr);
	}
	if (dyn == 0) {
		puts_("[ld.so.1] FATAL: NEEDED object has no PT_DYNAMIC\n");
		return (-1);
	}
	lo = &objs[nobj++];
	parse_dynamic(lo, dyn, base);

	/* self-relocate the .so at its load base. */
	if (apply_rela(lo, lo->rela, lo->relasz) < 0 ||
	    apply_rela(lo, lo->jmprel, lo->pltrelsz) < 0) {
		puts_("[ld.so.1] FATAL: NEEDED self-reloc failed\n");
		return (-1);
	}
	return (0);
}

/*
 * rtld_main -- the ld.so.1 body.  stackp = &argc (the psABI initial stack).
 * Walk to the auxv, read the app phdrs/entry, find PT_DYNAMIC, parse it, map +
 * process each DT_NEEDED, apply the app's own RELATIVE relocs, bind its PLT
 * cross-object, and return the app entry.
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
	struct lobj *app;
	unsigned i;
	Elf64_Addr next_base = 0x38000000UL;	/* where NEEDED libs land */

	puts_("[ld.so.1] riscv64 runtime linker (R-P28: cross-object bind)\n");

	nobj = 0;

	/* skip argc, argv[], NULL, envp[], NULL -> auxv. */
	p = stackp + 1;
	p += argc;
	p += 1;
	while (*p != 0)
		p++;
	p += 1;

	for (; p[0] != AT_NULL; p += 2) {
		switch (p[0]) {
		case AT_PHDR:	at_phdr = (Elf64_Addr)p[1];	break;
		case AT_PHENT:	at_phent = (unsigned)p[1];	break;
		case AT_PHNUM:	at_phnum = (unsigned)p[1];	break;
		case AT_BASE:	at_base = (Elf64_Addr)p[1];	break;
		case AT_ENTRY:	at_entry = (Elf64_Addr)p[1];	break;
		}
	}
	(void) at_base;

	if (at_phdr == 0 || at_entry == 0) {
		puts_("[ld.so.1] FATAL: no AT_PHDR/AT_ENTRY in auxv\n");
		return (0);
	}
	if (at_phent == 0)
		at_phent = sizeof (Elf64_Phdr);

	/* app is ET_EXEC (load base 0); PT_PHDR gives the exact base. */
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
		puts_("[ld.so.1] app has no PT_DYNAMIC (static?); entering\n");
		return (at_entry);
	}

	/* object 0 = the application itself. */
	app = &objs[nobj++];
	parse_dynamic(app, dyn, app_base);

	/* map + process each DT_NEEDED (in link order). */
	for (i = 0; dyn[i].d_tag != DT_NULL; i++) {
		if (dyn[i].d_tag == DT_NEEDED && app->strtab != 0) {
			const char *nm = app->strtab + dyn[i].d_val;
			puts_("[ld.so.1] DT_NEEDED: ");
			puts_(nm);
			puts_(" -> mapping at ");
			puthex_(next_base);
			puts_("\n");
			if (load_needed(nm, next_base) != 0)
				return (0);
			next_base += 0x02000000UL;	/* next lib base */
		}
	}

	/* apply the app's own RELATIVE relocs (DT_RELA). */
	{
		long n = apply_rela(app, app->rela, app->relasz);
		if (n < 0) {
			puts_("[ld.so.1] FATAL: app RELATIVE reloc failed\n");
			return (0);
		}
	}

	/* BIND the app's PLT (cross-object JUMP_SLOT). */
	{
		long b = bind_plt(app);
		if (b < 0)
			return (0);
		puts_("[ld.so.1] cross-object PLT binds: ");
		{
			char nb[2];
			nb[0] = (b >= 0 && b < 10) ? (char)('0' + b) : '?';
			nb[1] = 0;
			puts_(nb);
		}
		puts_("\n");
	}

	puts_("[ld.so.1] app + libs relocated + bound; entering the app\n");
	return (at_entry);
}
