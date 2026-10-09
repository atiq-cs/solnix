/*
 * obsd_vm.h -- the OpenBSD UVM / pmap / km_alloc surface the drm core and
 * i915 reach, on illumos.
 *
 * This is the part of the compat layer with real design risk (x1-gpu-route.md
 * section 5.1, "VM: 30 functions"). What is here today:
 *   - the TYPES (vaddr_t, vm_page, uvm_object, ...) so the shared headers
 *     parse. REAL where a type is a plain scalar.
 *   - struct vm_page is a solnix-owned descriptor, not illumos page_t: the
 *     drm/i915 code only reads phys_addr and pg_flags from it, and it is
 *     handed out by uvm_pglistalloc / PHYS_TO_VM_PAGE. It is NOT allocated
 *     per physical page of RAM the way OpenBSD's vm_page array is; see
 *     PHYS_TO_VM_PAGE below.
 *   - km_alloc / uvm_pglistalloc / pmap_* / uao_* are DECLARED. Their bodies
 *     are PLANNED (obsd_vm.c, not written): the R1a target (modeset + dumb
 *     buffer) needs km_alloc(kv_any, kp_dirty) = kmem_alloc and the GTT
 *     writes, which go through BAR0, not pmap; GEM shmem objects (uao_*) and
 *     user mappings (uvm_map, pgo_fault) are R2.
 */
#ifndef _OBSD_VM_H
#define _OBSD_VM_H

/* ---- scalar VM types (REAL) ---- */
typedef uintptr_t	vaddr_t;
typedef size_t		vsize_t;
typedef uint64_t	psize_t;
typedef int64_t		voff_t;
typedef int		vm_prot_t;
typedef int		vm_fault_t;
typedef int		vm_inherit_t;
typedef struct vm_page	*vm_page_t;
typedef struct vm_map	*vm_map_t;
typedef struct pmap	*pmap_t;

#ifndef PAGE_SHIFT
#define PAGE_SHIFT	12
#endif
#ifndef PAGE_SIZE
#define PAGE_SIZE	(1 << PAGE_SHIFT)
#endif
#ifndef PAGE_MASK
#define PAGE_MASK	(PAGE_SIZE - 1)
#endif
#define atop(x)		((paddr_t)(x) >> PAGE_SHIFT)
#define ptoa(x)		((paddr_t)(x) << PAGE_SHIFT)
#define round_page(x)	(((x) + PAGE_MASK) & ~PAGE_MASK)
#define trunc_page(x)	((x) & ~PAGE_MASK)

/* illumos sys/mman.h already has PROT_READ/WRITE/EXEC/NONE with the same
 * values (1/2/4/0). */
#define PROT_MASK	(PROT_READ | PROT_WRITE | PROT_EXEC)
#define MAP_INHERIT_SHARE	0
#define MAP_INHERIT_NONE	2
#ifndef MADV_NORMAL
#define MADV_NORMAL	0
#endif
#define UVM_FLAG_FIXED	0x0010000
#define UVM_FLAG_WC	0x8000000
#define UVM_MAPFLAG(prot, maxprot, inh, advice, flags) \
	(((prot) << 8) | ((maxprot) << 12) | ((inh) << 16) | \
	((advice) << 20) | (flags))
#define UVM_PLA_WAITOK	0x0001
#define UVM_PLA_NOWAIT	0x0002
#define UVM_PLA_ZERO	0x0004
#define UVM_PLA_TRYCONTIG 0x0008
#define VM_MIN_ADDRESS		((vaddr_t)PAGE_SIZE)
#define VM_MAXUSER_ADDRESS	((vaddr_t)USERLIMIT)
#define VM_PROT_NONE	PROT_NONE
#define VM_PROT_READ	PROT_READ
#define VM_PROT_WRITE	PROT_WRITE

/* ---- struct vm_page (MAP, see the file header) ---- */
TAILQ_HEAD(pglist, vm_page);
struct vm_page {
	TAILQ_ENTRY(vm_page)	pageq;
	struct rb_entry		objt;		/* ttm_pool stashes a pointer
						   in objt.rbt_parent */
	struct uvm_object	*uobject;
	voff_t			offset;
	uint32_t		pg_flags;
	uint32_t		wire_count;
	paddr_t			phys_addr;
	ulong_t			pg_pfn;		/* illumos pfn */
	struct obsd_pgchunk	*pg_chunk;	/* RAM: the allocation it is
						   part of (obsd_vm.c) */
};
#define PG_BUSY		0x00000001
#define PG_WANTED	0x00000002
#define PG_TABLED	0x00000004
#define PG_CLEAN	0x00000008
#define PG_ZERO		0x00000100
#define PG_DEV		0x00000200
#define PG_PMAP0	0x02000000
#define PG_PMAP1	0x04000000
#define PG_PMAP2	0x08000000
#define PG_PMAP_WC	PG_PMAP2
#define VM_PAGE_TO_PHYS(pg)	((pg)->phys_addr)
/* DECL (obsd_vm.c): the vm_page of a physical address, for every page
 * uvm_pglistalloc/uao handed out and every uvm_page_physload range
 * (aperture, stolen); NULL for any other address. */
extern struct vm_page *PHYS_TO_VM_PAGE(paddr_t);
/* DECL: kernel VA -> its vm_page (virt_to_page); NULL if not one of ours. */
extern struct vm_page *uvm_atopg(vaddr_t);
extern int uvm_pglistalloc(psize_t, paddr_t, paddr_t, paddr_t, paddr_t,
    struct pglist *, int, int);
extern void uvm_pglistfree(struct pglist *);
extern void uvm_page_physload(paddr_t, paddr_t, paddr_t, paddr_t, int);
#define PHYSLOAD_DEVICE	0x01

struct uvm_constraint_range {
	paddr_t	ucr_low;
	paddr_t	ucr_high;
};
extern struct uvm_constraint_range no_constraint;
extern struct uvm_constraint_range dma_constraint;

/* uvmexp: drm reads free/npages/swpages/swpginuse for its shrinker sizing.
 * DECL: obsd_vm.c fills it from physmem/freemem at init. */
extern void obsd_vm_init(void);
struct uvmexp {
	int	pagesize;
	int	pagemask;
	int	pageshift;
	int	npages;
	int	free;
	int	swpages;
	int	swpginuse;
};
extern struct uvmexp uvmexp;

/* ---- uvm_object + pager ops (types: REAL shape; bodies PLANNED, R2) ---- */
struct uvm_faultinfo;
struct uvm_object;
struct uvm_pagerops {
	void	(*pgo_init)(void);
	void	(*pgo_reference)(struct uvm_object *);
	void	(*pgo_detach)(struct uvm_object *);
	int	(*pgo_fault)(struct uvm_faultinfo *, vaddr_t, vm_page_t *, int,
		    int, vm_fault_t, vm_prot_t, int);
	boolean_t (*pgo_flush)(struct uvm_object *, voff_t, voff_t, int);
	int	(*pgo_get)(struct uvm_object *, voff_t, vm_page_t *, int *, int,
		    vm_prot_t, int, int);
	int	(*pgo_put)(struct uvm_object *, vm_page_t *, int, boolean_t);
	void	(*pgo_cluster)(struct uvm_object *, voff_t, voff_t *, voff_t *);
	struct vm_page **(*pgo_mk_pcluster)(struct uvm_object *,
		    struct vm_page **, int *, struct vm_page *, int, voff_t,
		    voff_t);
};
struct uvm_object {
	struct rwlock			*vmobjlock;
	const struct uvm_pagerops	*pgops;
	int				uo_npages;
	int				uo_refs;
	void				*uo_priv;	/* solnix: backing */
};
#define UVM_OBJ_IS_DEVICE(uobj)	0
struct vm_amap;
struct vm_aref {
	int		ar_pageoff;
	struct vm_amap	*ar_amap;
};
struct vm_map_entry {
	vaddr_t		start;
	vaddr_t		end;
	union {
		struct uvm_object *uvm_obj;
		struct vm_map	*sub_map;
	} object;
	voff_t		offset;
	struct vm_aref	aref;
	int		etype;
	vm_prot_t	protection;
	vm_prot_t	max_protection;
};
#define UVM_ET_OBJ		0x0001
#define UVM_ET_SUBMAP		0x0002
#define UVM_ET_COPYONWRITE	0x0004
#define UVM_ET_NEEDSCOPY	0x0008
#define UVM_ET_WC		0x0080
#define UVM_ET_ISCOPYONWRITE(E)	(((E)->etype & UVM_ET_COPYONWRITE) != 0)
#define UVM_ET_ISNEEDSCOPY(E)	(((E)->etype & UVM_ET_NEEDSCOPY) != 0)
struct vm_map {
	struct pmap	*pmap;
	vaddr_t		min_offset;
	vaddr_t		max_offset;
};
struct vmspace {
	struct vm_map	vm_map;
	int		vm_refcnt;
};
#define vm_map_min(map)	((map)->min_offset)
#define vm_map_max(map)	((map)->max_offset)
extern struct vm_map *kernel_map;
extern struct vm_map *phys_map;
struct uvm_faultinfo {
	struct vm_map		*orig_map;
	vaddr_t			orig_rvaddr;
	vsize_t			orig_size;
	struct vm_map		*map;
	struct vm_map_entry	*entry;
};
#define PGO_ALLPAGES	0x001
#define PGO_CLEANIT	0x002
#define PGO_SYNCIO	0x004
#define PGO_DEACTIVATE	0x008
#define PGO_FREE	0x010
#define PGO_LOCKED	0x040
#define PGO_DONTCARE	((struct vm_page *)-1L)
#define VM_PAGER_OK	0
#define VM_PAGER_BAD	1
#define VM_PAGER_ERROR	4
#define VM_PAGER_REFAULT 7
extern void uvm_obj_init(struct uvm_object *, const struct uvm_pagerops *,
    int);
extern void uvm_obj_destroy(struct uvm_object *);
extern int uvm_obj_wire(struct uvm_object *, voff_t, voff_t, struct pglist *);
extern void uvm_obj_unwire(struct uvm_object *, voff_t, voff_t);
extern struct uvm_object *uao_create(vsize_t, int);
extern void uao_detach(struct uvm_object *);
extern void uao_reference(struct uvm_object *);
extern int uvm_map(vm_map_t, vaddr_t *, vsize_t, struct uvm_object *, voff_t,
    vsize_t, unsigned int);
extern int uvm_unmap(vm_map_t, vaddr_t, vaddr_t);
extern void uvmfault_unlockall(struct uvm_faultinfo *, void *,
    struct uvm_object *);
extern void uvm_wait(const char *);

/* ---- km_alloc (DECL: obsd_kern.c maps the kv_any/kv_page + kp_dirty/
 * kp_zero combinations onto kmem_alloc of page-aligned sizes; kp_none
 * (VA only) and kp_dma* are PLANNED) ---- */
struct kmem_va_mode {
	struct vm_map **kv_map;
	vsize_t	kv_align;
	char	kv_wait;
	char	kv_singlepage;
	char	kv_executable;
};
struct kmem_pa_mode {
	struct uvm_constraint_range *kp_constraint;
	struct uvm_object **kp_object;
	paddr_t	kp_align;
	paddr_t	kp_boundary;
	int	kp_nomem;
	char	kp_maxseg;
	char	kp_zero;
	char	kp_pageable;
};
struct kmem_dyn_mode {
	voff_t	kd_prefer;
	int	kd_slowdown;
	char	kd_waitok;
	char	kd_trylock;
};
extern const struct kmem_va_mode kv_any;
extern const struct kmem_va_mode kv_intrsafe;
extern const struct kmem_va_mode kv_page;
extern const struct kmem_pa_mode kp_dirty;
extern const struct kmem_pa_mode kp_zero;
extern const struct kmem_pa_mode kp_dma;
extern const struct kmem_pa_mode kp_dma_contig;
extern const struct kmem_pa_mode kp_dma_zero;
extern const struct kmem_pa_mode kp_pageable;
extern const struct kmem_pa_mode kp_none;
extern const struct kmem_dyn_mode kd_waitok;
extern const struct kmem_dyn_mode kd_nowait;
extern const struct kmem_dyn_mode kd_trylock;
extern void *km_alloc(size_t, const struct kmem_va_mode *,
    const struct kmem_pa_mode *, const struct kmem_dyn_mode *);
extern void km_free(void *, size_t, const struct kmem_va_mode *,
    const struct kmem_pa_mode *);

/* ---- pmap (PLANNED: hat_devload / hat_unload on kas.a_hat) ---- */
#define PMAP_NOCACHE	0x1
#define PMAP_WC		0x2
#define PMAP_DEVICE	0x4
#define PMAP_WIRED	0x00000010
#define PMAP_CANFAIL	0x00000020
#define PG_N		0x0000000000000010UL	/* x86 PCD */
#define PG_WT		0x0000000000000008UL	/* x86 PWT */
#define PG_PAT		0x0000000000000080UL
extern struct pmap *pmap_kernel(void);
extern void pmap_kenter_pa(vaddr_t, paddr_t, vm_prot_t);
extern void pmap_kremove(vaddr_t, vsize_t);
extern int pmap_enter(pmap_t, vaddr_t, paddr_t, vm_prot_t, int);
extern void pmap_remove(pmap_t, vaddr_t, vaddr_t);
extern int pmap_extract(pmap_t, vaddr_t, paddr_t *);
extern void pmap_page_protect(struct vm_page *, vm_prot_t);
extern void pmap_flush_cache(vaddr_t, vsize_t);
#define pmap_update(pm)	((void)(pm))
extern vaddr_t pmap_map_direct(struct vm_page *);
extern struct vm_page *pmap_unmap_direct(vaddr_t);
extern void wbinvd_on_all_cpus(void);
extern void pmap_zero_page(struct vm_page *);
extern void uvm_pagecopy(struct vm_page *, struct vm_page *);

/* ---- memory-range attributes (MTRR; PLANNED: illumos sets PAT per
 * mapping, so these become a no-op returning 0) ---- */
struct mem_range_desc {
	uint64_t	mr_base;
	uint64_t	mr_len;
	int		mr_flags;
	char		mr_owner[8];
};
#define MDF_WRITECOMBINE	0x00000008
#define MEMRANGE_SET_UPDATE	0
#define MEMRANGE_SET_REMOVE	1
extern int mem_range_attr_set(struct mem_range_desc *, int *);

/* ---- CPU feature words read by asm/cpufeature.h (DECL: from
 * is_x86_feature in obsd_kern.c) ---- */
extern uint32_t cpu_ecxfeature;
#define CPUIDECX_SSE41		0x00080000
#define CPUIDECX_HV		0x80000000
#define CPUID_PAT		0x00010000
#define CPUID_CFLUSH		0x00080000
#define SEFF0EBX_CLFLUSHOPT	0x00800000

#endif /* _OBSD_VM_H */
