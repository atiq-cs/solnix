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
 * hat_user_protect -- R-P31.2: change the leaf permissions of the user pages in
 * [va, va+len) in `root`.  Used by SYS_mprotect so ld.so.1 can make the RELRO
 * segment READ-ONLY after relocation (clear PTE_W).  `perms` is the new R/W/X
 * leaf permission set (PTE_U is re-added).  Missing pages are skipped.  Returns
 * 0 (a best-effort protect; a partial range still protects what is mapped).
 *
 * CRIB PROVENANCE: mprotect walking the mapped range + rewriting each leaf's
 * protection bits is illumos as_setprot / hat_chgprot (i86pc hat_i86.c
 * hat_updateattr) reduced to a Sv39 leaf walk that ANDs/ORs the R/W/X bits;
 * making PT_GNU_RELRO read-only after startup relocation is the gABI relro
 * contract + illumos ld.so.1 setup.c (LM_SET_RELRO / mprotect the relro).
 */
int
hat_user_protect(unsigned long *root, unsigned long va, unsigned long len,
    unsigned long perms)
{
	unsigned long a, end = va + len;

	for (a = va & PAGEMASK; a < end; a += PAGESIZE) {
		unsigned long *l1, *l2t;
		unsigned long pte;

		pte = root[L2_IDX(a)];
		if ((pte & PTE_V) == 0)
			continue;
		l1 = (unsigned long *)PTOKV(PTE_TO_PA(pte));
		pte = l1[L1_IDX(a)];
		if ((pte & PTE_V) == 0)
			continue;
		l2t = (unsigned long *)PTOKV(PTE_TO_PA(pte));
		pte = l2t[L0_IDX(a)];
		if ((pte & PTE_V) == 0)
			continue;
		/* keep the frame + A/D/V; replace the R/W/X/U perm bits. */
		l2t[L0_IDX(a)] = (pte & ~(PTE_R | PTE_W | PTE_X | PTE_U)) |
		    perms | PTE_U | PTE_V | PTE_A | PTE_D;
	}
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
 * hat_user_cow_share -- R-P32 COPY-ON-WRITE fork.  Instead of hat_user_copy's
 * eager per-leaf frame copy, SHARE every 4 KiB user leaf between parent and
 * child: map the SAME physical frame into the child at the same VA, and in BOTH
 * ASes clear PTE_W + set PTE_COW so a write to a formerly-writable page FAULTS
 * (store page fault, scause 15) into hat_cow_fault, which copies the frame.  A
 * read-only leaf (never writable) is shared as-is (no COW mark needed, but we
 * still bump the refcount so it is freed once).  A per-frame refcount
 * (page_ref_inc) tracks the extra sharer so the frame is freed only when the
 * last AS lets go.
 *
 * dst_root must already share the kernel high half (hat_user_new).  Only walks
 * level-2 index 0 (the private user half).  Returns 0, or -1 on OOM.
 *
 * CRIB PROVENANCE: marking both parent + child mappings read-only + shared at
 * fork and copying on the write fault is illumos hat_dup(HAT_DUP) / seg_vn
 * SEGVN_COW (uts/common/vm/seg_vn.c segvn_dup + the anon_dup / F_PROT copy) +
 * the BSD pmap_copy_on_write; the per-frame refcount is page_t p_cowcnt; the
 * xv6-riscv uvmcopy-turned-COW (map parent+child RO, PTE_COW, refcount, copy in
 * the trap) is the reduced skeleton this follows.
 */
int
hat_user_cow_share(unsigned long *dst_root, unsigned long *src_root)
{
	unsigned long l2pte = src_root[0];
	unsigned long *sl1;
	unsigned int i1;
	extern void page_ref_inc(void *);

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

			if ((l0pte & PTE_V) == 0)
				continue;
			va = ((unsigned long)i1 << MEGASHIFT) |
			    ((unsigned long)i0 << PAGESHIFT);
			perms = PTE_PERMS(l0pte);
			src_pa = PTE_TO_PA(l0pte);

			/* bump the shared frame's sharer count (this child). */
			page_ref_inc((void *)PTOKV(src_pa));

			if ((perms & PTE_W) || (l0pte & PTE_COW)) {
				/*
				 * A writable leaf (or one that is ALREADY COW from
				 * a prior fork): make it COW in BOTH ASes -- drop W,
				 * keep R (+X/U), set PTE_COW.  Re-sharing an already-
				 * COW page must KEEP the COW mark (PTE_PERMS strips
				 * it), else the new child would get a plain read-only
				 * page and its write would fault unhandled.
				 */
				unsigned long cowperms =
				    (perms & ~PTE_W) | PTE_COW;
				sl0[i0] = PA_TO_PTE(src_pa) | cowperms |
				    PTE_V | PTE_A | PTE_D;
				if (hat_user_map(dst_root, va, PTOKV(src_pa),
				    cowperms) != 0)
					return (-1);
			} else {
				/* genuinely read-only leaf: share as-is (no COW). */
				if (hat_user_map(dst_root, va, PTOKV(src_pa),
				    perms) != 0)
					return (-1);
			}
		}
	}
	return (0);
}

/*
 * hat_cow_fault -- R-P32: service a store page fault against a COW leaf.  Walk
 * to the faulting leaf in `root`; if it is a live COW page (V set, W clear,
 * PTE_COW set), allocate a FRESH frame, copy the shared frame's bytes into it,
 * remap the VA to the private copy WRITABLE with PTE_COW cleared, and drop one
 * reference on the old shared frame (freed if this was the last sharer).
 * Returns 1 if it handled a COW fault (the store may be retried), 0 if the leaf
 * was not a COW page (a genuine protection violation -- the caller kills the
 * proc).
 *
 * CRIB PROVENANCE: the copy-on-write fault (locate the leaf, allocate a new
 * page, copy, remap writable, drop the shared page's cow refcount) is illumos
 * segvn_faultpage F_PROT + anon_private (uts/common/vm/seg_vn.c) + the BSD
 * pmap COW fault + xv6-riscv cowfault.
 */
int
hat_cow_fault(unsigned long *root, unsigned long va)
{
	unsigned long *l1, *l2t;
	unsigned long pte, old_pa, perms;
	unsigned char *newf;
	const unsigned char *oldf;
	unsigned int b;

	if (root == 0)
		return (0);
	pte = root[L2_IDX(va)];
	if ((pte & PTE_V) == 0 || PTE_IS_LEAF(pte))
		return (0);
	l1 = (unsigned long *)PTOKV(PTE_TO_PA(pte));
	pte = l1[L1_IDX(va)];
	if ((pte & PTE_V) == 0 || PTE_IS_LEAF(pte))
		return (0);
	l2t = (unsigned long *)PTOKV(PTE_TO_PA(pte));
	pte = l2t[L0_IDX(va)];
	if ((pte & PTE_V) == 0 || (pte & PTE_COW) == 0)
		return (0);			/* not a COW leaf */

	old_pa = PTE_TO_PA(pte);
	perms = (PTE_PERMS(pte) & ~PTE_COW) | PTE_W;	/* private + writable */

	newf = kmem_alloc_page();
	if (newf == 0)
		return (0);			/* OOM: treat as unhandled */
	oldf = (const unsigned char *)PTOKV(old_pa);
	for (b = 0; b < PAGESIZE; b++)
		newf[b] = oldf[b];

	/* remap this VA to the private writable copy. */
	l2t[L0_IDX(va)] = PA_TO_PTE(KVTOP((unsigned long)newf)) | perms |
	    PTE_V | PTE_A | PTE_D;

	/* drop our reference to the old shared frame (free if last). */
	kmem_free_page((void *)PTOKV(old_pa));
	return (1);
}

/*
 * hat_user_lazy -- R-P32 DEMAND PAGING: reserve `va` in `root` as a demand-
 * paged leaf -- allocate the intermediate page tables but leave the leaf INVALID
 * (V clear) with PTE_LAZY + the intended perms recorded in the leaf's perm bits.
 * The first access FAULTS (scause 12/13/15) into hat_demand_fault, which backs
 * it with a fresh zeroed frame.  Returns 0 or -1.
 *
 * CRIB PROVENANCE: reserving an anonymous demand-zero segment (as_map of a
 * seg_vn with no pages, faulted in on first touch) is illumos as_map + segvn
 * F_INVAL anon_zero; the "invalid PTE carrying the intended perms in RSW,
 * filled on the fault" is the reduced skeleton.
 */
int
hat_user_lazy(unsigned long *root, unsigned long va, unsigned long perms)
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
	/* leaf: V CLEAR (so any access faults) + PTE_LAZY + the wanted perms. */
	l2t[L0_IDX(va)] = PTE_LAZY | (perms & (PTE_R | PTE_W | PTE_X | PTE_U));
	return (0);
}

/*
 * hat_demand_fault -- R-P32: service a page fault against a demand-paged (LAZY)
 * leaf.  Walk to the leaf; if it is INVALID with PTE_LAZY set, allocate a fresh
 * ZEROED frame and map it with the perms recorded in the leaf.  Returns 1 if it
 * faulted in a lazy page, 0 if the leaf was not lazy (a genuine fault).
 */
int
hat_demand_fault(unsigned long *root, unsigned long va)
{
	unsigned long *l1, *l2t;
	unsigned long pte, perms;
	unsigned char *frame;
	unsigned int b;

	if (root == 0)
		return (0);
	pte = root[L2_IDX(va)];
	if ((pte & PTE_V) == 0 || PTE_IS_LEAF(pte))
		return (0);
	l1 = (unsigned long *)PTOKV(PTE_TO_PA(pte));
	pte = l1[L1_IDX(va)];
	if ((pte & PTE_V) == 0 || PTE_IS_LEAF(pte))
		return (0);
	l2t = (unsigned long *)PTOKV(PTE_TO_PA(pte));
	pte = l2t[L0_IDX(va)];
	if ((pte & PTE_V) != 0 || (pte & PTE_LAZY) == 0)
		return (0);			/* not a lazy leaf */

	perms = pte & (PTE_R | PTE_W | PTE_X | PTE_U);
	frame = kmem_alloc_page();
	if (frame == 0)
		return (0);
	for (b = 0; b < PAGESIZE; b++)
		frame[b] = 0;
	l2t[L0_IDX(va)] = PA_TO_PTE(KVTOP((unsigned long)frame)) | perms |
	    PTE_V | PTE_A | PTE_D;
	return (1);
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
