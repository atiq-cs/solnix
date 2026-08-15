/*
 * kmem_cache.c -- R-P29: a vmem arena + a slab-style kmem_cache over the R-P24
 * first-fit boot heap.
 *
 * R-P24's startup.c gives a first-fit kmem_alloc/kmem_free over a 16 MiB boot
 * heap -- fine for one-off allocations but not the illumos allocator shape.
 * R-P29 adds the two layers that sit above it:
 *
 *   vmem  -- a resource arena: a span of integers (here byte addresses of a
 *            dedicated slab region) handed out in aligned chunks and freed
 *            back, coalescing adjacent free segments.  This is the universal
 *            illumos back-end allocator (vmem.c): kmem_cache draws slab-sized
 *            spans from it.  Reduced to one arena, first-fit, segment list.
 *
 *   kmem_cache -- an object cache: a cache is created for a fixed object size;
 *            kmem_cache_alloc hands back one object, kmem_cache_free returns it.
 *            Objects are carved from SLABS (one vmem span == one slab, sliced
 *            into equal objects threaded on a free list).  A slab is grown on
 *            demand and its objects recycled -- the illumos slab allocator
 *            (kmem.c) reduced to a single free list per cache (no magazines, no
 *            per-CPU depot, no coloring).
 *
 * Boot proof: create a cache, alloc a batch of objects (forcing >1 slab),
 * free them, re-alloc and confirm freed objects are recycled (same addresses
 * come back) -- the slab allocator working.
 *
 * CRIB PROVENANCE: the vmem arena (span import, segment free list, first-fit
 * xalloc/xfree, coalescing) is illumos uts/common/os/vmem.c (Bonwick's vmem)
 * reduced to one arena; the kmem_cache (cache_create -> slab -> object free
 * list, alloc/free recycle) is illumos uts/common/os/kmem.c (Bonwick's slab
 * allocator) reduced to a single per-cache free list; the "kmem_cache draws
 * slabs from a vmem arena" layering is the illumos kmem/vmem split.
 */

#include "mmu_riscv.h"

extern void *kmem_alloc(unsigned long);
extern void sbi_console_puts(const char *);
extern void putdec_pub(unsigned long);
extern void puthex_pub(unsigned long);

/* ---- vmem: a one-arena resource allocator --------------------------- */

/*
 * The arena manages a linear region of `size` bytes carved from the boot heap
 * at init.  Free space is a list of [addr,len) segments; alloc first-fits +
 * splits, free coalesces with neighbors.  Addresses are real (usable) memory
 * so kmem_cache slabs are directly usable.
 */
#define	VMEM_MAXSEG	256

typedef struct vmseg {
	unsigned long	vs_addr;
	unsigned long	vs_len;
	int		vs_used;	/* 1 = this slot holds a live free segment */
} vmseg_t;

typedef struct vmem {
	vmseg_t		vm_seg[VMEM_MAXSEG];
	int		vm_nseg;
	unsigned long	vm_base;
	unsigned long	vm_size;
} vmem_t;

static vmem_t kernel_arena;

static void
vmem_init(vmem_t *vm, unsigned long base, unsigned long size)
{
	int i;
	for (i = 0; i < VMEM_MAXSEG; i++)
		vm->vm_seg[i].vs_used = 0;
	vm->vm_base = base;
	vm->vm_size = size;
	vm->vm_seg[0].vs_addr = base;
	vm->vm_seg[0].vs_len = size;
	vm->vm_seg[0].vs_used = 1;
	vm->vm_nseg = 1;
}

/* first-fit alloc of `len` bytes aligned to `align` (power of 2). */
static unsigned long
vmem_xalloc(vmem_t *vm, unsigned long len, unsigned long align)
{
	int i, j;

	if (align == 0)
		align = 1;
	for (i = 0; i < VMEM_MAXSEG; i++) {
		vmseg_t *s = &vm->vm_seg[i];
		unsigned long astart, aend, send;

		if (!s->vs_used)
			continue;
		astart = (s->vs_addr + align - 1) & ~(align - 1);
		aend = astart + len;
		send = s->vs_addr + s->vs_len;
		if (aend > send)
			continue;		/* does not fit */

		/* head remainder [vs_addr, astart) stays as its own segment. */
		if (astart > s->vs_addr) {
			/* shrink this segment to the head, add a new tail. */
			unsigned long tail_addr = aend;
			unsigned long tail_len = send - aend;
			s->vs_len = astart - s->vs_addr;
			/* find a free slot for the tail, if any. */
			if (tail_len > 0) {
				for (j = 0; j < VMEM_MAXSEG; j++) {
					if (!vm->vm_seg[j].vs_used) {
						vm->vm_seg[j].vs_addr = tail_addr;
						vm->vm_seg[j].vs_len = tail_len;
						vm->vm_seg[j].vs_used = 1;
						break;
					}
				}
			}
			return (astart);
		}
		/* no head remainder: carve from the front. */
		if (len == s->vs_len) {
			s->vs_used = 0;		/* fully consumed */
		} else {
			s->vs_addr = aend;
			s->vs_len = send - aend;
		}
		return (astart);
	}
	return (0);				/* arena exhausted */
}

/* return [addr,len) to the arena, coalescing with adjacent free segments. */
static void
vmem_xfree(vmem_t *vm, unsigned long addr, unsigned long len)
{
	int i, slot = -1;
	unsigned long end = addr + len;

	/* try to extend an adjacent free segment. */
	for (i = 0; i < VMEM_MAXSEG; i++) {
		vmseg_t *s = &vm->vm_seg[i];
		if (!s->vs_used)
			continue;
		if (s->vs_addr + s->vs_len == addr) {	/* s just before */
			s->vs_len += len;
			/* now maybe coalesce forward with a segment at `end`. */
			addr = s->vs_addr;
			end = s->vs_addr + s->vs_len;
			slot = i;
			break;
		}
		if (end == s->vs_addr) {		/* s just after */
			s->vs_addr = addr;
			s->vs_len += len;
			end = s->vs_addr + s->vs_len;
			slot = i;
			break;
		}
	}
	if (slot < 0) {
		/* no neighbor: take a fresh slot. */
		for (i = 0; i < VMEM_MAXSEG; i++) {
			if (!vm->vm_seg[i].vs_used) {
				vm->vm_seg[i].vs_addr = addr;
				vm->vm_seg[i].vs_len = len;
				vm->vm_seg[i].vs_used = 1;
				return;
			}
		}
		return;					/* seg table full: leak */
	}
	/* a coalesce happened; try one more merge with a segment abutting end. */
	for (i = 0; i < VMEM_MAXSEG; i++) {
		vmseg_t *s = &vm->vm_seg[i];
		if (!s->vs_used || i == slot)
			continue;
		if (vm->vm_seg[slot].vs_addr + vm->vm_seg[slot].vs_len ==
		    s->vs_addr) {
			vm->vm_seg[slot].vs_len += s->vs_len;
			s->vs_used = 0;
			break;
		}
		if (s->vs_addr + s->vs_len == vm->vm_seg[slot].vs_addr) {
			s->vs_len += vm->vm_seg[slot].vs_len;
			vm->vm_seg[slot].vs_used = 0;
			break;
		}
	}
}

/* ---- kmem_cache: slab-style object cache ---------------------------- */

#define	SLAB_SIZE	(4UL * 1024)	/* one slab == one page-sized span */

typedef struct kmem_bufctl {
	struct kmem_bufctl *bc_next;	/* free-list link (in the object itself) */
} kmem_bufctl_t;

typedef struct kmem_cache {
	const char	*cc_name;
	unsigned long	cc_objsize;	/* rounded-up object size */
	unsigned long	cc_align;
	kmem_bufctl_t	*cc_free;	/* free object list */
	unsigned long	cc_nslab;	/* slabs imported */
	unsigned long	cc_nobj;	/* total objects carved */
	unsigned long	cc_ninuse;	/* objects handed out */
} kmem_cache_t;

#define	NCACHE	16
static kmem_cache_t cache_tab[NCACHE];
static int ncache;

kmem_cache_t *
kmem_cache_create(const char *name, unsigned long objsize, unsigned long align)
{
	kmem_cache_t *c;

	if (ncache >= NCACHE)
		return (0);
	if (align == 0)
		align = 8;
	if (objsize < sizeof (kmem_bufctl_t))
		objsize = sizeof (kmem_bufctl_t);	/* fit the free link */
	objsize = (objsize + align - 1) & ~(align - 1);

	c = &cache_tab[ncache++];
	c->cc_name = name;
	c->cc_objsize = objsize;
	c->cc_align = align;
	c->cc_free = 0;
	c->cc_nslab = c->cc_nobj = c->cc_ninuse = 0;
	return (c);
}

/* grow a cache: import one slab from the arena, carve it into objects. */
static int
kmem_cache_grow(kmem_cache_t *c)
{
	unsigned long slab = vmem_xalloc(&kernel_arena, SLAB_SIZE, c->cc_align);
	unsigned long off;

	if (slab == 0)
		return (-1);
	c->cc_nslab++;
	for (off = 0; off + c->cc_objsize <= SLAB_SIZE; off += c->cc_objsize) {
		kmem_bufctl_t *bc = (kmem_bufctl_t *)(slab + off);
		bc->bc_next = c->cc_free;
		c->cc_free = bc;
		c->cc_nobj++;
	}
	return (0);
}

void *
kmem_cache_alloc(kmem_cache_t *c)
{
	kmem_bufctl_t *bc;

	if (c->cc_free == 0) {
		if (kmem_cache_grow(c) != 0)
			return (0);
	}
	bc = c->cc_free;
	c->cc_free = bc->bc_next;
	c->cc_ninuse++;
	return ((void *)bc);
}

void
kmem_cache_free(kmem_cache_t *c, void *obj)
{
	kmem_bufctl_t *bc = (kmem_bufctl_t *)obj;

	if (obj == 0)
		return;
	bc->bc_next = c->cc_free;
	c->cc_free = bc;
	c->cc_ninuse--;
}

unsigned long kmem_cache_inuse(kmem_cache_t *c) { return (c->cc_ninuse); }
unsigned long kmem_cache_nslab(kmem_cache_t *c) { return (c->cc_nslab); }
unsigned long kmem_cache_nobj(kmem_cache_t *c) { return (c->cc_nobj); }

/*
 * kmem_cache_init -- carve a dedicated slab region out of the boot heap and
 * seed the kernel vmem arena over it.  Called from startup after startup_kmem.
 */
#define	ARENA_BYTES	(4UL * 1024 * 1024)	/* 4 MiB for slabs */

void
kmem_cache_init(void)
{
	unsigned long region = (unsigned long)kmem_alloc(ARENA_BYTES);

	if (region == 0) {
		sbi_console_puts("  [kmem_cache] arena import FAILED\n");
		return;
	}
	/* page-align the arena base so slabs are page-aligned. */
	region = (region + PAGEOFFSET) & PAGEMASK;
	vmem_init(&kernel_arena, region, ARENA_BYTES - PAGESIZE);
}

/* expose the arena for a self-test (bytes free). */
unsigned long
vmem_arena_size(void)
{
	return (kernel_arena.vm_size);
}
