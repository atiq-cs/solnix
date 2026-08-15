/*
 * hat_boot.c -- R-P30 Sv39 EARLY boot paging for a HIGH-HALF kernel.
 *
 * The R-P30 kernel is LINKED + EXECUTES at high VA (KERNEL_DMAP_BASE +
 * 0x80200000) but LOADS + starts at physical 0x80200000.  hat_earlyboot() runs
 * from locore._start at the PHYSICAL address (paging OFF), so it must use only
 * physical addresses: medany PC-relative addressing gives it the PHYSICAL
 * address of every high-linked symbol (boot_l2 lives in BSS, high-linked at
 * KERNEL_DMAP_BASE + pa; `&boot_l2` computed PC-relative while PC is physical
 * yields its physical address, which is what a satp/PTE needs).
 *
 * It builds the boot page table:
 *   - IDENTITY-map the low 4 GiB with 1 GiB gigapage leaves (V|R|W|X).  This
 *     keeps the PHYSICAL PC/sp/gp valid the instant satp flips so the very next
 *     fetch (still at the physical PC) resolves -- the Linux setup_vm / i86pc
 *     boot-identity idiom.  locore then jumps PC UP to the high VA.
 *   - Map the kernel + all DRAM at the HIGH direct-map (KERNEL_DMAP_BASE + pa,
 *     gigapage leaves) so the kernel can execute + address any physical page
 *     through its canonical high VA (the illumos kpm window).  The kernel's
 *     high link addresses (KERNEL_DMAP_BASE + 0x80200000 ...) live inside this
 *     window, so jumping PC to the high _start_high lands on mapped memory.
 *
 * This boot root is ALSO the permanent AP-bringup / trampoline root: a
 * secondary hart starts at its PHYSICAL entry with paging off, installs THIS
 * root (which still carries the low identity map), so its first post-satp fetch
 * resolves; the secondary then jumps high and switches to the real W^X kernel
 * root (hat.c).  The BOOT hart, by contrast, switches to the identity-FREE W^X
 * root and hat_drop_identity() proves the primary runs with NO identity map.
 *
 * CRIB PROVENANCE: hat_earlyboot building a boot root, identity-mapping the low
 * window to survive mmu-enable + installing a high direct-map, then locore
 * jumping PC to the high half is Linux arch/riscv setup_vm + relocate_enable_mmu
 * + the i86pc hat_kbootmmu bootstrap; the Sv39 PTE encoding + gigapage-leaf rule
 * + satp MODE=8 are the RISC-V privileged spec.
 */

#include "mmu_riscv.h"

/*
 * The Sv39 boot root (level 2).  512 entries, one 4 KiB page, page-aligned.
 * In BSS => zeroed by locore before hat_earlyboot runs; its PHYSICAL address
 * (what satp needs) is KVTOP(&boot_l2), computed here PC-relative as physical.
 */
static unsigned long boot_l2[PTES_PER_TABLE]
    __attribute__((aligned(PAGESIZE)));

/* how many low gigabytes to identity-map (0 .. IDENTITY_GIB GiB). */
#define	IDENTITY_GIB	4

/*
 * hat_earlyboot -- build the boot map and return the satp value to install.
 * Runs at PHYSICAL addresses (paging off).  Does NOT write satp itself (locore
 * does, so the satp write + the immediate high jump are adjacent).
 */
unsigned long
hat_earlyboot(void)
{
	unsigned long pa;
	unsigned int idx;
	/*
	 * &boot_l2 computed while PC is physical is boot_l2's PHYSICAL address
	 * (a high-linked symbol reached PC-relative pre-paging).  Equivalent to
	 * KVTOP(&boot_l2); we take the raw pointer value directly here since we
	 * are pre-paging and it already IS physical.
	 */
	unsigned long root_pa = (unsigned long)boot_l2;

	/* Identity gigapages for the low IDENTITY_GIB GiB (VA==PA, V|R|W|X). */
	for (pa = 0; pa < ((unsigned long)IDENTITY_GIB << GIGASHIFT);
	    pa += GIGASIZE) {
		idx = (unsigned int)(pa >> GIGASHIFT);
		boot_l2[idx] = PA_TO_PTE(pa) | PTE_KRWX;
	}

	/* High direct-map: KERNEL_DMAP_BASE + pa -> pa, gigapage leaves. */
	for (pa = 0; pa < ((unsigned long)IDENTITY_GIB << GIGASHIFT);
	    pa += GIGASIZE) {
		unsigned long va = KERNEL_DMAP_BASE + pa;
		idx = (unsigned int)((va >> GIGASHIFT) & (PTES_PER_TABLE - 1));
		boot_l2[idx] = PA_TO_PTE(pa) | PTE_KRWX;
	}

	return (MAKE_SATP(root_pa));
}

/*
 * hat_boot_root_satp -- the satp value of the identity-bearing boot root, used
 * to bring up secondary harts (they start at their physical entry with paging
 * off, install this root so the first post-satp fetch resolves, jump high, then
 * switch to the real W^X kernel root).  Runs at HIGH VA: KVTOP(&boot_l2) gives
 * the physical root address.
 */
unsigned long
hat_boot_root_satp(void)
{
	return (MAKE_SATP(KVTOP((unsigned long)boot_l2)));
}

/*
 * R-P29/R-P30: expose the active kernel root so the user-AS builder clones the
 * (fine-grained W^X) kernel half.  hat.c sets hat_active_root to the W^X root
 * once hat_kernel_setup runs; before that, fall back to the boot root.  Note:
 * these are KERNEL VIRTUAL pointers (the running kernel dereferences them);
 * PTE storage converts via KVTOP in hat.c / hat_user.c.
 */
unsigned long *hat_active_root;

unsigned long *
hat_kernel_root(void)
{
	if (hat_active_root != 0)
		return (hat_active_root);
	return (boot_l2);	/* HIGH-VA pointer once paging is on */
}
