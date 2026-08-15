/*
 * hat_user.c -- R-P25 sub-task 1: the riscv64 user address space.
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
 * CRIB PROVENANCE: the "user AS = kernel high half shared + private user leaf
 * tables" split is the illumos hat as_t / i86pc kernel-vs-user hat separation;
 * the 3-level Sv39 walk + PTE encoding + the "non-leaf PTE has V set, R=W=X=0,
 * points at the next table PPN" rule are the RISC-V privileged spec; using
 * kmem-allocated identity-mapped pages as page tables is the R-P5 hat_memload
 * table-alloc idiom reduced to the boot heap.
 */

#include "mmu_riscv.h"
#include "proc_riscv.h"

extern void *kmem_alloc_page(void);
extern unsigned long *hat_kernel_root(void);

#define	L2_IDX(va)	(((va) >> GIGASHIFT) & (PTES_PER_TABLE - 1))
#define	L1_IDX(va)	(((va) >> MEGASHIFT) & (PTES_PER_TABLE - 1))
#define	L0_IDX(va)	(((va) >> PAGESHIFT) & (PTES_PER_TABLE - 1))

/* a non-leaf PTE: V set, R=W=X=0, PPN of the next-level table. */
#define	PTE_TABLE(pa)	(PA_TO_PTE(pa) | PTE_V)

static unsigned long *
alloc_table(void)
{
	/* 4 KiB, PAGE-ALIGNED; boot heap is identity-mapped so ptr == PA. */
	unsigned long *t = kmem_alloc_page();
	unsigned int i;

	if (t == 0)
		return (0);
	for (i = 0; i < PTES_PER_TABLE; i++)
		t[i] = 0;
	return (t);
}

/*
 * hat_user_new -- allocate a fresh user root (level-2) table and copy the
 * kernel high half (indices 1..511, which carry the kernel identity gigapages
 * for VA >=1GiB and the direct-map) into it.  Index 0 is left zero for the
 * private user leaf subtree that hat_user_map fills.  Returns the root pointer
 * (== its PA under the identity map), suitable for MAKE_SATP().
 */
unsigned long *
hat_user_new(void)
{
	unsigned long *kroot = hat_kernel_root();
	unsigned long *uroot = alloc_table();
	unsigned int i;

	if (uroot == 0)
		return (0);
	/* share the kernel high half; keep index 0 private to the user. */
	for (i = 1; i < PTES_PER_TABLE; i++)
		uroot[i] = kroot[i];
	uroot[0] = 0;
	return (uroot);
}

/*
 * hat_user_map -- map one 4 KiB page va -> pa with the given leaf perms
 * (caller ORs in PTE_U for user access) into the user root, walking/creating
 * the level-1 and level-0 tables.  Returns 0 on success, -1 on OOM.
 */
int
hat_user_map(unsigned long *root, unsigned long va, unsigned long pa,
    unsigned long perms)
{
	unsigned long *l1, *l2t;
	unsigned long pte;

	/* level 2 -> level 1 */
	pte = root[L2_IDX(va)];
	if ((pte & PTE_V) == 0) {
		l1 = alloc_table();
		if (l1 == 0)
			return (-1);
		root[L2_IDX(va)] = PTE_TABLE((unsigned long)l1);
	} else {
		l1 = (unsigned long *)PTE_TO_PA(pte);
	}

	/* level 1 -> level 0 */
	pte = l1[L1_IDX(va)];
	if ((pte & PTE_V) == 0) {
		l2t = alloc_table();
		if (l2t == 0)
			return (-1);
		l1[L1_IDX(va)] = PTE_TABLE((unsigned long)l2t);
	} else {
		l2t = (unsigned long *)PTE_TO_PA(pte);
	}

	/* level 0 leaf */
	l2t[L0_IDX(va)] = PA_TO_PTE(pa) | perms | PTE_V | PTE_A | PTE_D;
	return (0);
}
