/*
 * hat_boot.c -- R-P24 sub-task 1: riscv64 Sv39 boot paging.
 *
 * The R-P23 kernel runs bare (satp==0, VA==PA).  hat_boot_init() builds the
 * first Sv39 page table and turns paging ON, then the kernel keeps executing
 * in virtual address space.
 *
 * Strategy (the minimal correct boot map):
 *   - A single level-2 root table (512 gigapage slots covering the 512 GiB
 *     Sv39 space).
 *   - IDENTITY map the whole low 4 GiB with 1 GiB gigapage leaves (V|R|W|X).
 *     The kernel is linked + loaded at PA 0x80200000, so an identity map means
 *     the PC, sp, gp and every pointer stay valid the instant satp flips --
 *     execution continues at the same address, now translated.  This is the
 *     RISC-V analogue of the i86pc "boot identity map" that keeps the low
 *     addresses live across the mmu-enable so we do not fault on the very next
 *     fetch.
 *   - Also install a HIGH direct-map: KERNEL_DMAP_BASE + pa -> pa, again with
 *     gigapage leaves, so kernel code can address any physical page through a
 *     canonical high VA (the illumos kpm / direct-map window).  R-P25 moves the
 *     kernel text/data proper up here and drops the identity map.
 *
 * The root table lives in BSS (page-aligned), zeroed by locore, so its PA
 * equals its link address (identity, pre-paging) -- exactly what satp needs.
 *
 * CRIB PROVENANCE: hat_boot_init building a boot root, identity-mapping the
 * kernel, installing a direct-map, then writing satp+sfence.vma is the illumos
 * HAT riscv boot seam (R-P5 hat_riscv.c) + i86pc hat_kbootmmu/hat_kern_setup;
 * the Sv39 PTE encoding + the gigapage-leaf rule + satp MODE=8 are the RISC-V
 * privileged spec; the "keep the low identity map live across mmu-enable" trick
 * is the i86pc/aarch64 boot-map idiom.
 */

#include "mmu_riscv.h"
#include "sbi.h"

/*
 * The Sv39 root page table (level 2).  512 entries, one 4 KiB page, aligned so
 * its base PPN is exact.  In BSS => zero-filled by locore, PA == VA pre-paging.
 */
static unsigned long boot_l2[PTES_PER_TABLE]
    __attribute__((aligned(PAGESIZE)));

/* how many low gigabytes to identity-map (0 .. IDENTITY_GIB GiB). */
#define	IDENTITY_GIB	4

/*
 * Build the boot map and enable Sv39.  Returns the satp value written (so the
 * caller can report / stash it in the boot cpu).
 */
unsigned long
hat_boot_init(void)
{
	unsigned long pa;
	unsigned int idx;

	/*
	 * Identity gigapages for the low IDENTITY_GIB GiB.  VA==PA, leaf
	 * V|R|W|X.  A gigapage leaf sits directly in the level-2 table (no
	 * lower tables): PTE = PA_TO_PTE(pa) | perms.
	 */
	for (pa = 0; pa < ((unsigned long)IDENTITY_GIB << GIGASHIFT);
	    pa += GIGASIZE) {
		idx = (unsigned int)(pa >> GIGASHIFT);	/* VA[38:30], VA==PA */
		boot_l2[idx] = PA_TO_PTE(pa) | PTE_KRWX;
	}

	/*
	 * High direct-map: KERNEL_DMAP_BASE + pa -> pa, same gigapage leaves,
	 * for the low IDENTITY_GIB GiB of physical DRAM/IO.  The level-2 index
	 * of a canonical high VA is bits [38:30] of the VA.
	 */
	for (pa = 0; pa < ((unsigned long)IDENTITY_GIB << GIGASHIFT);
	    pa += GIGASIZE) {
		unsigned long va = KERNEL_DMAP_BASE + pa;
		idx = (unsigned int)((va >> GIGASHIFT) & (PTES_PER_TABLE - 1));
		boot_l2[idx] = PA_TO_PTE(pa) | PTE_KRWX;
	}

	/*
	 * Enable paging.  rv_set_satp writes satp (MODE=Sv39, root PPN) then
	 * sfence.vma.  Because the kernel is identity-mapped, the fetch of the
	 * instruction after the csrw still resolves to the same PA -- we keep
	 * running.
	 */
	{
		unsigned long satp = MAKE_SATP((unsigned long)boot_l2);
		rv_set_satp(satp);
		return (satp);
	}
}

/*
 * R-P25: expose the kernel boot root so the user-AS builder can share the
 * kernel high half (direct-map + kernel identity gigapages) into each user
 * page table -- the kernel mappings must stay live while a trap taken from
 * U-mode runs with the user satp still installed.
 *
 * R-P29: once hat_kernel_setup() installs the fine-grained W^X kernel root,
 * user address spaces must clone THAT root (so they share the per-segment R^X
 * kernel image + the RW low-RAM window), not the stale boot root.  hat.c sets
 * hat_active_root; hat_kernel_root() returns it if set, else the boot root.
 */
unsigned long *hat_active_root;

unsigned long *
hat_kernel_root(void)
{
	if (hat_active_root != 0)
		return (hat_active_root);
	return (boot_l2);
}
