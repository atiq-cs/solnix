/*
 * hat_user.c -- R-P25/R-P26 riscv64 user address space.
 *
 * A user process needs its own Sv39 page table (its own satp) that (a) maps
 * the user text/data/stack with PTE_U so U-mode may touch them, and (b) still
 * maps the kernel -- the trap vector, kernel text, the direct-map and the
 * current kernel stack -- because a trap taken from U-mode does NOT change
 * satp: the kernel trap handler runs with the USER page table installed.  So
 * every user AS shares the kernel high half.
 *
 * The kernel boot map (hat_boot.c) uses 1 GiB gigapage LEAVES at level-2:
 *   index 0 : VA 0..1GiB     (identity, but the kernel executes nothing here)
 *   index 1 : VA 1..2GiB     (identity)
 *   index 2 : VA 2..3GiB     (identity -- KERNEL TEXT @ 0x80200000 lives here)
 *   index 3 : VA 3..4GiB     (identity)
 *   the KERNEL_DMAP_BASE high entries (direct-map window)
 * The user process (static ELF) links at VA 0x10000, i.e. inside level-2
 * index 0.  We CANNOT keep index 0 as a gigapage leaf AND put 4 KiB user
 * leaves there, so in the USER root we replace index 0 with a pointer to a
 * fresh level-1 -> level-0 subtree carrying 4 KiB user leaves; indices 1..511
 * are copied verbatim from the kernel root so kernel text/direct-map/stack
 * stay mapped.  (Nothing in the kernel executes in VA 0..1GiB, so dropping the
 * index-0 identity gigapage in the user AS is safe.)
 *
 * Leaf tables come from kmem_alloc (page-aligned by the 4 KiB request); with
 * the kernel running identity/direct-mapped their PA == the address kmem
 * returns (boot heap is in the identity-mapped low DRAM), so a table pointer
 * is also its PA -- exactly what a PTE needs.
 *
 * R-P26 adds hat_user_copy: a DEEP COPY of the private user half (the index-0
 * subtree) -- fork copies every 4 KiB user leaf frame into the child so the
 * two processes have independent memory (copy, not COW; COW is a later
 * optimization).  The shared kernel high half is already installed by
 * hat_user_new, so hat_user_copy only walks index 0.
 *
 * CRIB PROVENANCE: the "user AS = kernel high half shared + private user leaf
 * tables" split is the illumos hat as_t / i86pc kernel-vs-user hat separation;
 * the 3-level Sv39 walk + PTE encoding + the "non-leaf PTE has V set, R=W=X=0,
 * points at the next table PPN" rule are the RISC-V privileged spec; the fork
 * AS deep-copy (walk the source page tables, dup each user leaf) is illumos
 * hat_dup / as_dup + BSD pmap_copy reduced to an eager leaf copy.
 */

#include "mmu_riscv.h"
#include "proc_riscv.h"

extern void *kmem_alloc_page(void);
extern void kmem_free_page(void *);
extern unsigned long *hat_kernel_root(void);

#define	L2_IDX(va)	(((va) >> GIGASHIFT) & (PTES_PER_TABLE - 1))
#define	L1_IDX(va)	(((va) >> MEGASHIFT) & (PTES_PER_TABLE - 1))
#define	L0_IDX(va)	(((va) >> PAGESHIFT) & (PTES_PER_TABLE - 1))

/* a non-leaf PTE: V set, R=W=X=0, PHYSICAL PPN of the next-level table. */
#define	PTE_TABLE(pa)	(PA_TO_PTE(pa) | PTE_V)
/* leaf test: a PTE is a leaf if any of R/W/X is set. */
#define	PTE_IS_LEAF(pte)	(((pte) & (PTE_R | PTE_W | PTE_X)) != 0)
/* the leaf perm bits (R/W/X/U) to carry into the copy. */
#define	PTE_PERMS(pte)		((pte) & (PTE_R | PTE_W | PTE_X | PTE_U))

static unsigned long *
alloc_table(void)
{
	unsigned long *t = kmem_alloc_page();
	unsigned int i;

	if (t == 0)
		return (0);
	for (i = 0; i < PTES_PER_TABLE; i++)
		t[i] = 0;
	return (t);
}

unsigned long *
hat_user_new(void)
{
	unsigned long *kroot = hat_kernel_root();	/* HIGH-VA pointer */
	unsigned long *uroot = alloc_table();		/* HIGH-VA pointer */
	unsigned int i;

	if (uroot == 0)
		return (0);
	/* copy PTEs verbatim (PTEs hold PHYSICAL addresses -- no conversion). */
	for (i = 1; i < PTES_PER_TABLE; i++)
		uroot[i] = kroot[i];
	uroot[0] = 0;
	return (uroot);
}

int
hat_user_map(unsigned long *root, unsigned long va, unsigned long pa,
    unsigned long perms)
{
	unsigned long *l1, *l2t;
	unsigned long pte;

	pte = root[L2_IDX(va)];
	if ((pte & PTE_V) == 0) {
		l1 = alloc_table();
		if (l1 == 0)
			return (-1);
		root[L2_IDX(va)] = PTE_TABLE(KVTOP((unsigned long)l1));
	} else {
		l1 = (unsigned long *)PTOKV(PTE_TO_PA(pte));
	}

	pte = l1[L1_IDX(va)];
	if ((pte & PTE_V) == 0) {
		l2t = alloc_table();
		if (l2t == 0)
			return (-1);
		l1[L1_IDX(va)] = PTE_TABLE(KVTOP((unsigned long)l2t));
	} else {
		l2t = (unsigned long *)PTOKV(PTE_TO_PA(pte));
	}

	l2t[L0_IDX(va)] = PA_TO_PTE(KVTOP(pa)) | perms | PTE_V | PTE_A | PTE_D;
	return (0);
}

/*
 * hat_user_copy -- deep-copy the private user half (level-2 index 0) of
 * src_root into dst_root: for every 4 KiB user leaf, allocate a fresh frame,
 * copy its bytes, and map it into dst at the same VA with the same perms.
 * dst_root must already share the kernel high half (from hat_user_new).
 * Returns 0 on success, -1 on OOM.  Only walks index 0 (the user segments +
 * stack all link below 1 GiB).
 */
int
hat_user_copy(unsigned long *dst_root, unsigned long *src_root)
{
	unsigned long l2pte = src_root[0];
	unsigned long *sl1;
	unsigned int i1;

	if ((l2pte & PTE_V) == 0)
		return (0);			/* nothing private mapped */
	if (PTE_IS_LEAF(l2pte))
		return (-1);			/* a gigapage user leaf: unsupported */
	sl1 = (unsigned long *)PTOKV(PTE_TO_PA(l2pte));

	for (i1 = 0; i1 < PTES_PER_TABLE; i1++) {
		unsigned long l1pte = sl1[i1];
		unsigned long *sl0;
		unsigned int i0;

		if ((l1pte & PTE_V) == 0 || PTE_IS_LEAF(l1pte))
			continue;
		sl0 = (unsigned long *)PTOKV(PTE_TO_PA(l1pte));

		for (i0 = 0; i0 < PTES_PER_TABLE; i0++) {
			unsigned long l0pte = sl0[i0];
			unsigned long va, perms, src_pa;
			unsigned char *dst_frame;
			const unsigned char *src_frame;
			unsigned int b;

			if ((l0pte & PTE_V) == 0)
				continue;
			/* reconstruct the VA from the three indices. */
			va = ((unsigned long)0 << GIGASHIFT) |
			    ((unsigned long)i1 << MEGASHIFT) |
			    ((unsigned long)i0 << PAGESHIFT);
			perms = PTE_PERMS(l0pte);
			src_pa = PTE_TO_PA(l0pte);

			dst_frame = kmem_alloc_page();	/* HIGH-VA pointer */
			if (dst_frame == 0)
				return (-1);
			/* the source frame's PA -> its direct-map kernel VA. */
			src_frame = (const unsigned char *)PTOKV(src_pa);
			for (b = 0; b < PAGESIZE; b++)
				dst_frame[b] = src_frame[b];

			if (hat_user_map(dst_root, va,
			    (unsigned long)dst_frame, perms) != 0)
				return (-1);
		}
	}
	return (0);
}

/*
 * hat_as_free -- R-P30: free a user address space.  Walk the PRIVATE user half
 * (level-2 index 0 only -- indices 1..511 are the SHARED kernel half and must
 * NOT be freed) and reclaim, in order: every 4 KiB leaf FRAME, then the level-0
 * page tables, then the level-1 page table, then the level-2 subtree table,
 * then the root itself.  This is what fork/exec/exit needed so the AS does not
 * leak (R-P26 noted the leak).  The root + tables + frames are KERNEL VIRTUAL
 * pointers (kmem_alloc_page); a PA read from a PTE is turned back into its
 * direct-map kernel VA (PTOKV) before freeing.
 *
 * CRIB PROVENANCE: as_free walking the address space + hat_free / hat_unload
 * tearing down the page tables + freeing the backing frames is illumos
 * uts/common/vm/as.c as_free + i86pc hat_free_end / htable_release +
 * seg_vn free, reduced to an eager walk of the single private user subtree;
 * the BSD analogue is pmap_remove + pmap_release.
 */
void
hat_as_free(unsigned long *root)
{
	unsigned long l2pte;
	unsigned long *l1;
	unsigned int i1;

	if (root == 0)
		return;
	l2pte = root[0];			/* the private user subtree */
	if ((l2pte & PTE_V) != 0 && !PTE_IS_LEAF(l2pte)) {
		l1 = (unsigned long *)PTOKV(PTE_TO_PA(l2pte));
		for (i1 = 0; i1 < PTES_PER_TABLE; i1++) {
			unsigned long l1pte = l1[i1];
			unsigned long *l0;
			unsigned int i0;

			if ((l1pte & PTE_V) == 0 || PTE_IS_LEAF(l1pte))
				continue;
			l0 = (unsigned long *)PTOKV(PTE_TO_PA(l1pte));
			for (i0 = 0; i0 < PTES_PER_TABLE; i0++) {
				unsigned long l0pte = l0[i0];
				if ((l0pte & PTE_V) == 0)
					continue;
				/* free the backing 4 KiB user frame. */
				kmem_free_page((void *)
				    PTOKV(PTE_TO_PA(l0pte)));
			}
			kmem_free_page(l0);	/* free the L0 table */
		}
		kmem_free_page(l1);		/* free the L1 table */
	}
	kmem_free_page(root);			/* free the root L2 table */
}
