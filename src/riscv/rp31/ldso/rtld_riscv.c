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
#define	PT_GNU_RELRO	0x6474e552

/* ELF version-table structures (gABI symbol versioning). */
typedef unsigned short	Elf64_Versym;
typedef struct {
	Elf64_Half	vn_version;
	Elf64_Half	vn_cnt;
	Elf64_Word	vn_file;
	Elf64_Word	vn_aux;
	Elf64_Word	vn_next;
} Elf64_Verneed;
typedef struct {
	Elf64_Word	vna_hash;
	Elf64_Half	vna_flags;
	Elf64_Half	vna_other;	/* the version index used in .gnu.version */
	Elf64_Word	vna_name;	/* strtab offset of the version string */
	Elf64_Word	vna_next;
} Elf64_Vernaux;
typedef struct {
	Elf64_Half	vd_version;
	Elf64_Half	vd_flags;
	Elf64_Half	vd_ndx;		/* version index this def provides */
	Elf64_Half	vd_cnt;
	Elf64_Word	vd_hash;
	Elf64_Word	vd_aux;
	Elf64_Word	vd_next;
} Elf64_Verdef;
typedef struct {
	Elf64_Word	vda_name;	/* strtab offset of the version string */
	Elf64_Word	vda_next;
} Elf64_Verdaux;

#define	VER_NDX_LOCAL	0
#define	VER_NDX_GLOBAL	1
#define	VERSYM_HIDDEN	0x8000

#define	DT_NULL		0
#define	DT_NEEDED	1
#define	DT_PLTRELSZ	2
#define	DT_PLTGOT	3
#define	DT_HASH		4
#define	DT_STRTAB	5
#define	DT_SYMTAB	6
#define	DT_RELA		7
#define	DT_RELASZ	8
#define	DT_RELAENT	9
#define	DT_SYMENT	11
#define	DT_JMPREL	23
#define	DT_GNU_HASH	0x6ffffef5
#define	DT_VERSYM	0x6ffffff0
#define	DT_VERDEF	0x6ffffffc
#define	DT_VERDEFNUM	0x6ffffffd
#define	DT_VERNEED	0x6ffffffe
#define	DT_VERNEEDNUM	0x6fffffff

/* auxv tags (psABI / <sys/auxv.h>). */
#define	AT_NULL		0
#define	AT_PHDR		3
#define	AT_PHENT	4
#define	AT_PHNUM	5
#define	AT_BASE		7
#define	AT_ENTRY	9

#define	SYS_write	4
#define	SYS_mprotect	74		/* R-P31.2: relro read-only */
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

/*
 * sys_mprotect -- R-P31.2: ask the kernel to change the leaf perms of the user
 * pages in [addr, addr+len).  Used to make the RELRO segment read-only after
 * relocation (prot = PROT_READ = 1).  Returns 0 or -1.
 */
static long
sys_mprotect(Elf64_Addr addr, unsigned long len, long prot)
{
	return (sys3(SYS_mprotect, (long)addr, (long)len, prot));
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
	const Elf64_Word	*hash;		/* SysV .hash [nbucket][nchain]... */
	unsigned		nbucket;
	unsigned		nchain;
	const Elf64_Word	*gnu_hash;	/* .gnu.hash (0 if absent) */
	const Elf64_Rela	*rela;		/* DT_RELA (RELATIVE etc.) */
	unsigned long		relasz;
	const Elf64_Rela	*jmprel;	/* DT_JMPREL (PLT relocs) */
	unsigned long		pltrelsz;
	Elf64_Addr		*pltgot;	/* DT_PLTGOT (.got.plt base) */
	const Elf64_Versym	*versym;	/* .gnu.version (per-dynsym idx) */
	const void		*verdef;	/* .gnu.version_d (this obj's defs) */
	const void		*verneed;	/* .gnu.version_r (this obj's needs) */
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
 * gnu_hash -- the .gnu.hash name hash (gABI / GNU): djb2-ish, distinct from the
 * SysV elf_hash.  h = 5381; for each byte c: h = h*33 + c.
 */
static unsigned int
gnu_hash(const unsigned char *name)
{
	unsigned int h = 5381;
	while (*name)
		h = (h << 5) + h + *name++;	/* h*33 + c */
	return (h);
}

/*
 * ver_string -- the version STRING selected for dynamic-symbol index `symn` in
 * object `lo` (via .gnu.version -> .gnu.version_r/_d), or 0 if the symbol is
 * unversioned (VER_NDX_LOCAL/GLOBAL) or the object has no version table.  Used
 * so a versioned reference (e.g. __multf3@GCC_3.0) binds to the definition
 * carrying the SAME version string.
 */
static const char *
ver_string(const struct lobj *lo, unsigned symn)
{
	unsigned short vndx;
	const unsigned char *p;

	if (lo->versym == 0 || lo->strtab == 0)
		return (0);
	vndx = lo->versym[symn] & ~VERSYM_HIDDEN;
	if (vndx == VER_NDX_LOCAL || vndx == VER_NDX_GLOBAL)
		return (0);		/* unversioned */

	/* search .gnu.version_r (needs): each Verneed has Vernaux entries whose
	   vna_other is the version index used in .gnu.version. */
	if (lo->verneed != 0) {
		p = (const unsigned char *)lo->verneed;
		for (;;) {
			const Elf64_Verneed *vn = (const Elf64_Verneed *)p;
			const unsigned char *a = p + vn->vn_aux;
			unsigned c;
			for (c = 0; c < vn->vn_cnt; c++) {
				const Elf64_Vernaux *va =
				    (const Elf64_Vernaux *)a;
				if ((va->vna_other & ~VERSYM_HIDDEN) == vndx)
					return (lo->strtab + va->vna_name);
				if (va->vna_next == 0)
					break;
				a += va->vna_next;
			}
			if (vn->vn_next == 0)
				break;
			p += vn->vn_next;
		}
	}
	/* search .gnu.version_d (defs): each Verdef's first Verdaux names the
	   version its vd_ndx provides. */
	if (lo->verdef != 0) {
		p = (const unsigned char *)lo->verdef;
		for (;;) {
			const Elf64_Verdef *vd = (const Elf64_Verdef *)p;
			if ((vd->vd_ndx & ~VERSYM_HIDDEN) == vndx) {
				const Elf64_Verdaux *vda =
				    (const Elf64_Verdaux *)(p + vd->vd_aux);
				return (lo->strtab + vda->vda_name);
			}
			if (vd->vd_next == 0)
				break;
			p += vd->vd_next;
		}
	}
	return (0);
}

/*
 * def_ver_ok -- does the DEFINITION at dynamic-symbol index `defn` in object
 * `lo` satisfy a reference asking for version `want` (0 = any)?  We accept a
 * definition whose version string equals `want`, or (when the reference is
 * unversioned) any global definition.  This is the reduced gABI version-match:
 * a versioned ref binds to the like-versioned def; an unversioned ref binds to
 * the default (non-hidden) def.
 */
static int
def_ver_ok(const struct lobj *lo, unsigned defn, const char *want)
{
	const char *have;

	if (want == 0)
		return (1);		/* unversioned ref: any global def */
	have = ver_string(lo, defn);
	if (have == 0)
		return (1);		/* def is base/global: acceptable */
	return (streq(have, want));
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
		case DT_GNU_HASH: lo->gnu_hash = (const Elf64_Word *)v; break;
		case DT_RELA:	lo->rela = (const Elf64_Rela *)v; break;
		case DT_RELASZ:	lo->relasz = dyn[i].d_val; break;
		case DT_JMPREL:	lo->jmprel = (const Elf64_Rela *)v; break;
		case DT_PLTRELSZ: lo->pltrelsz = dyn[i].d_val; break;
		case DT_PLTGOT:	lo->pltgot = (Elf64_Addr *)v; break;
		case DT_VERSYM:	lo->versym = (const Elf64_Versym *)v; break;
		case DT_VERDEF:	lo->verdef = (const void *)v; break;
		case DT_VERNEED: lo->verneed = (const void *)v; break;
		}
	}
	if (lo->hash != 0) {
		lo->nbucket = lo->hash[0];
		lo->nchain = lo->hash[1];
	}
}

/*
 * gnu_lookup -- find a DEFINED symbol `name` (satisfying version `want`) in
 * object `lo` via its .gnu.hash table.  Layout (gABI):
 *   [0] nbuckets  [1] symoffset  [2] bloom_size  [3] bloom_shift
 *   bloom[bloom_size] (Elf64 words)  buckets[nbuckets] (u32)  chain[] (u32)
 * A bucket gives the first dynsym index of its chain; the chain word per symbol
 * has bit0 as the "end of chain" marker and the top 31 bits as the symbol's
 * gnu-hash (compared to hash|1 masking bit0).  Returns the symbol VA or 0.
 */
static Elf64_Addr
gnu_lookup(const struct lobj *lo, const char *name, const char *want)
{
	const unsigned int *h32 = (const unsigned int *)lo->gnu_hash;
	unsigned int nbuckets = h32[0];
	unsigned int symoffset = h32[1];
	unsigned int bloom_size = h32[2];
	unsigned int bloom_shift = h32[3];
	const unsigned long *bloom =
	    (const unsigned long *)(lo->gnu_hash + 4);
	const unsigned int *buckets =
	    (const unsigned int *)(bloom + bloom_size);
	const unsigned int *chain = buckets + nbuckets;
	unsigned int hh = gnu_hash((const unsigned char *)name);
	unsigned long word, mask;
	unsigned int idx;

	if (nbuckets == 0)
		return (0);
	/* bloom filter: reject definitely-absent names fast (64-bit words). */
	word = bloom[(hh / 64) % bloom_size];
	mask = (1UL << (hh % 64)) |
	    (1UL << ((hh >> bloom_shift) % 64));
	if ((word & mask) != mask)
		return (0);		/* not present */

	idx = buckets[hh % nbuckets];
	if (idx < symoffset)
		return (0);
	for (;;) {
		unsigned int c = chain[idx - symoffset];
		if (((c ^ hh) >> 1) == 0) {
			const Elf64_Sym *s = &lo->symtab[idx];
			if (s->st_shndx != SHN_UNDEF &&
			    streq(lo->strtab + s->st_name, name) &&
			    def_ver_ok(lo, idx, want))
				return (lo->base + s->st_value);
		}
		if (c & 1)
			break;		/* end of chain */
		idx++;
	}
	return (0);
}

/*
 * sym_lookup -- find a DEFINED symbol named `name` (satisfying version `want`,
 * 0 = any) in loaded object `lo`.  Prefer .gnu.hash when present, else the
 * SysV .hash bucket/chain.  Returns the symbol's absolute VA (base + st_value),
 * or 0 if not defined here.
 */
static Elf64_Addr
sym_lookup(const struct lobj *lo, const char *name, const char *want)
{
	unsigned long h;
	const Elf64_Word *bucket, *chain;
	unsigned idx;

	if (lo->symtab == 0 || lo->strtab == 0)
		return (0);
	if (lo->gnu_hash != 0)
		return (gnu_lookup(lo, name, want));
	if (lo->hash == 0)
		return (0);
	bucket = lo->hash + 2;
	chain = bucket + lo->nbucket;
	h = elf_hash((const unsigned char *)name) % lo->nbucket;

	for (idx = bucket[h]; idx != 0; idx = chain[idx]) {
		const Elf64_Sym *s = &lo->symtab[idx];
		if (s->st_shndx == SHN_UNDEF)
			continue;		/* not a definition here */
		if (streq(lo->strtab + s->st_name, name) &&
		    def_ver_ok(lo, idx, want))
			return (lo->base + s->st_value);
	}
	return (0);
}

/* resolve `name`@`want` across ALL loaded objects (flat scope, app first). */
static Elf64_Addr
sym_resolve(const char *name, const char *want)
{
	int i;
	for (i = 0; i < nobj; i++) {
		Elf64_Addr v = sym_lookup(&objs[i], name, want);
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
apply_rela(const struct lobj *lo, const Elf64_Rela *rela, unsigned long sz,
    int skip_jumpslot)
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
			if (skip_jumpslot)
				break;		/* leave for lazy binding */
			/* FALLTHROUGH */
		case R_RISCV_64: {
			const char *nm =
			    lo->strtab + lo->symtab[sym].st_name;
			const char *want = ver_string(lo, sym);
			Elf64_Addr s = sym_resolve(nm, want);
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
 * plt_lazy_setup -- R-P31.2: LAZY PLT binding.  Instead of resolving every PLT
 * slot up front (eager), we arm the standard riscv lazy-binding contract and
 * let each slot resolve on its FIRST call:
 *   - .got.plt[0] <- the address of the _rtld_bind trampoline (rtld_start.S).
 *   - .got.plt[1] <- an identifier the trampoline hands the resolver (we use
 *     the app's struct lobj *).
 *   - each .got.plt[2+N] is LEFT pointing at the PLT0 header (its as-linked
 *     value), so the first call to PLT entry N jumps into PLT0, which loads the
 *     trampoline from GOT[0], the identifier from GOT[1], computes N*8 in t1,
 *     and jumps to the trampoline.  The trampoline calls rtld_bind(id, N*8),
 *     which resolves reloc N, patches .got.plt[2+N] with the real address, and
 *     returns it; the trampoline then tail-jumps to the function.  The SECOND
 *     call finds the patched slot and jumps straight through (no resolver).
 *
 * CRIB PROVENANCE: the .got.plt[0]=resolver / [1]=link-map reserved-slot
 * contract + the PLT0 header computing the reloc arg (ret-addr - PLT0 - 44,
 * >>1 = N*8) and jumping to the resolver is the RISC-V psABI PLT layout +
 * binutils bfd/elfnn-riscv.c riscv_make_plt0_entry / glibc sysdeps/riscv
 * dl-machine.h _dl_runtime_resolve + elf_machine_runtime_setup; the illumos
 * analogue is ld.so.1 elf_plt_init / elf_rtbndr (usr/src/cmd/sgs/rtld).
 */
extern void _rtld_bind(void);		/* the asm trampoline (rtld_start.S) */
static const struct lobj *lazy_app;	/* the app whose PLT we bind lazily */

static long
plt_lazy_setup(const struct lobj *app)
{
	unsigned n = (unsigned)(app->pltrelsz / sizeof (Elf64_Rela));

	if (app->jmprel == 0 || app->pltgot == 0)
		return (0);
	lazy_app = app;
	/* reserved GOT slots the PLT0 header consumes. */
	app->pltgot[0] = (Elf64_Addr)&_rtld_bind;	/* resolver */
	app->pltgot[1] = (Elf64_Addr)app;		/* link-map id */
	/* .got.plt[2+N] stay as-linked (-> PLT0) so N resolves on first call. */
	return ((long)n);
}

/*
 * rtld_bind -- the C half of the lazy resolver, called from _rtld_bind
 * (rtld_start.S) with (id = .got.plt[1] = the app lobj*, reloc_arg = N*8 from
 * the PLT0 header).  Resolve the Nth PLT reloc cross-object, patch the GOT
 * slot, and return the resolved function address for the trampoline to jump to.
 */
Elf64_Addr
rtld_bind(unsigned long id, unsigned long reloc_arg)
{
	const struct lobj *app = (const struct lobj *)id;
	unsigned n = (unsigned)(reloc_arg / 8);	/* PLT0 hands N*8 */
	const Elf64_Rela *r = &app->jmprel[n];
	unsigned symn = ELF64_R_SYM(r->r_info);
	const char *nm = app->strtab + app->symtab[symn].st_name;
	const char *want = ver_string(app, symn);
	Elf64_Addr *got = (Elf64_Addr *)(app->base + r->r_offset);
	Elf64_Addr val = sym_resolve(nm, want);

	if (val == 0) {
		puts_("[ld.so.1] FATAL: lazy bind unresolved: ");
		puts_(nm);
		puts_("\n");
		for (;;)
			;
	}
	val += (Elf64_Addr)r->r_addend;
	*got = val;			/* patch: next call jumps straight */
	puts_("[ld.so.1]   LAZY bind on first call: ");
	puts_(nm);
	if (want) { puts_("@"); puts_(want); }
	puts_(" -> ");
	puthex_(val);
	puts_("\n");
	return (val);
}

/*
 * bind_plt -- EAGER PLT binding (kept as a fallback / for objects where lazy is
 * not wanted).  Resolves every PLT slot up front.  Returns bound count or -1.
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
		const char *want = ver_string(app, symn);
		Elf64_Addr *got = (Elf64_Addr *)(app->base + r->r_offset);
		Elf64_Addr val;

		if (type != R_RISCV_JUMP_SLOT) {
			puts_("[ld.so.1] FATAL: non-JUMP_SLOT in PLT\n");
			return (-1);
		}
		val = sym_resolve(nm, want);
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
	if (apply_rela(lo, lo->rela, lo->relasz, 0) < 0 ||
	    apply_rela(lo, lo->jmprel, lo->pltrelsz, 0) < 0) {
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
		/*
		 * The app's DT_RELA + DT_JMPREL coincide (the JUMP_SLOT relocs
		 * are the whole RELA table here), so skip JUMP_SLOT: they are
		 * bound LAZILY (plt_lazy_setup below), not eagerly.  Only the
		 * app's RELATIVE / R_RISCV_64 relocs are applied now.
		 */
		long n = apply_rela(app, app->rela, app->relasz, 1);
		if (n < 0) {
			puts_("[ld.so.1] FATAL: app RELATIVE reloc failed\n");
			return (0);
		}
	}

	/*
	 * R-P31.2: LAZY PLT binding.  Arm the standard riscv lazy-binding
	 * contract (GOT[0]=resolver trampoline, GOT[1]=app id) and leave each
	 * PLT slot pointing at PLT0 -- it resolves on its FIRST call via
	 * _rtld_bind -> rtld_bind().  (The eager bind_plt path is kept as a
	 * fallback but not used here.)
	 */
	{
		long np = plt_lazy_setup(app);
		puts_("[ld.so.1] LAZY PLT armed (resolve-on-first-call); slots: ");
		{
			char nb[2];
			nb[0] = (np >= 0 && np < 10) ? (char)('0' + np) : '?';
			nb[1] = 0;
			puts_(nb);
		}
		puts_("\n");
		if (app->gnu_hash != 0)
			puts_("[ld.so.1] symbol lookup: .gnu.hash (with SysV .hash "
			    "fallback)\n");
		else
			puts_("[ld.so.1] symbol lookup: SysV .hash\n");
		if (app->versym != 0)
			puts_("[ld.so.1] symbol versioning: .gnu.version tables "
			    "active (GNU verneed/verdef)\n");
	}

	/*
	 * R-P31.2: RELRO -- after all relocation, make the PT_GNU_RELRO region
	 * READ-ONLY (mprotect PROT_READ) so the now-relocated GOT/.data.rel.ro
	 * cannot be overwritten.  (No-op if the app carries no PT_GNU_RELRO.)
	 */
	{
		int did = 0;
		for (i = 0; i < at_phnum; i++) {
			ph = (const Elf64_Phdr *)(at_phdr +
			    (unsigned long)i * at_phent);
			if (ph->p_type == PT_GNU_RELRO) {
				Elf64_Addr a = app_base + ph->p_vaddr;
				unsigned long len = ph->p_memsz;
				/* page-align the base down + length up. */
				Elf64_Addr ap = a & ~0xfffUL;
				unsigned long al = (a + len - ap + 0xfffUL) &
				    ~0xfffUL;
				if (sys_mprotect(ap, al, 1 /*PROT_READ*/) == 0) {
					puts_("[ld.so.1] RELRO: mprotect ");
					puthex_(ap);
					puts_(" read-only (");
					{
						char d[8]; int k = 0;
						unsigned long v = al >> 12;
						if (v == 0) d[k++] = '0';
						else { char t[8]; int j = 0;
						    while (v) { t[j++] = '0'+(v%10); v/=10; }
						    while (j) d[k++] = t[--j]; }
						d[k] = 0; puts_(d);
					}
					puts_(" page(s))\n");
					did = 1;
				}
			}
		}
		if (!did)
			puts_("[ld.so.1] RELRO: no PT_GNU_RELRO segment (nothing "
			    "to protect)\n");
	}

	puts_("[ld.so.1] app + libs relocated; LAZY PLT armed + RELRO set; "
	    "entering the app\n");
	return (at_entry);
}
