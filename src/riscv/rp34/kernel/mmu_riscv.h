/*
 * mmu_riscv.h -- riscv64 Sv39 MMU constants + the R-P24 boot-paging seam.
 *
 * Sv39: 3-level page tables, 39-bit virtual address, 4 KiB base pages.
 *   VA[38:30] -> level-2 index (1 GiB gigapage step)
 *   VA[29:21] -> level-1 index (2 MiB megapage step)
 *   VA[20:12] -> level-0 index (4 KiB base page)
 *   VA[11:0]  -> page offset
 * Each table is 512 8-byte PTEs (one 4 KiB page).  A PTE holds
 * PPN[43:0]<<10 | flags; V marks it valid, R|W|X the leaf permissions, a leaf
 * at level 1/2 is a mega/giga superpage.  satp = MODE(8=Sv39)<<60 | ASID<<44 |
 * root_PPN.
 *
 * CRIB PROVENANCE: the Sv39 PTE bit layout, the 3-level index split, the
 * superpage-leaf rule, and the satp MODE=8 encoding are the RISC-V privileged
 * spec (Sv39 section); the "hat_boot_init builds a boot root, identity-maps the
 * kernel + a high direct-map, writes satp + sfence.vma" shape is the illumos
 * HAT riscv boot seam (R-P5 hat_riscv.c hat_boot_init / the i86pc hat_kbootmmu
 * bootstrap) + the RISC-V privileged spec SFENCE.VMA ordering.
 */

#ifndef	_RP24_MMU_RISCV_H
#define	_RP24_MMU_RISCV_H

#ifdef __cplusplus
extern "C" {
#endif

#define	PAGESHIFT	12
#define	PAGESIZE	(1UL << PAGESHIFT)	/* 4 KiB base page */
#define	PAGEOFFSET	(PAGESIZE - 1)
#define	PAGEMASK	(~PAGEOFFSET)

#define	MEGASHIFT	21
#define	MEGASIZE	(1UL << MEGASHIFT)	/* 2 MiB megapage */
#define	GIGASHIFT	30
#define	GIGASIZE	(1UL << GIGASHIFT)	/* 1 GiB gigapage */

#define	PTES_PER_TABLE	512			/* 4 KiB / 8 bytes */

/* Sv39 PTE flag bits (privileged spec). */
#define	PTE_V		(1UL << 0)		/* valid */
#define	PTE_R		(1UL << 1)		/* readable */
#define	PTE_W		(1UL << 2)		/* writable */
#define	PTE_X		(1UL << 3)		/* executable */
#define	PTE_U		(1UL << 4)		/* user-accessible */
#define	PTE_G		(1UL << 5)		/* global */
#define	PTE_A		(1UL << 6)		/* accessed */
#define	PTE_D		(1UL << 7)		/* dirty */

/*
 * R-P32: the two RSW (reserved-for-software) PTE bits [9:8] the privileged spec
 * leaves free for the OS.  We use them for copy-on-write + demand-paging state:
 *   PTE_COW  -- this leaf is a COW page: the frame is SHARED with another AS and
 *               mapped read-only; a store faults (scause 15) and the fault
 *               handler copies the frame + makes the copy writable.
 *   PTE_LAZY -- this leaf is DEMAND-PAGED: reserved but not yet backed; V is
 *               CLEAR so any access faults (scause 12/13/15) and the fault
 *               handler allocates + maps a zeroed frame on first touch.
 * The hardware ignores RSW, so a COW leaf still page-walks (V set, R set, W
 * clear); a LAZY leaf has V clear so the walk faults -- exactly the two
 * mechanisms illumos seg_vn (F_PROT COW) + anon demand-zero (F_INVAL) use.
 */
#define	PTE_COW		(1UL << 8)		/* RSW: copy-on-write leaf */
#define	PTE_LAZY	(1UL << 9)		/* RSW: demand-paged (V clear) */

#define	PTE_KDATA	(PTE_V | PTE_R | PTE_W | PTE_A | PTE_D | PTE_G)
#define	PTE_KCODE	(PTE_V | PTE_R | PTE_X | PTE_A | PTE_G)
#define	PTE_KRWX	(PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D | PTE_G)

/* PTE <-> PPN: PPN occupies bits [53:10]; PA = PPN << 12. */
#define	PA_TO_PTE(pa)	((((pa) >> PAGESHIFT) << 10))
#define	PTE_TO_PA(pte)	((((pte) >> 10) << PAGESHIFT))

/* satp: Sv39 mode. */
#define	SATP_MODE_SV39	(8UL << 60)
#define	MAKE_SATP(root_pa) \
	(SATP_MODE_SV39 | (((root_pa) >> PAGESHIFT) & ((1UL << 44) - 1)))

/*
 * The high kernel direct-map base.  We map all of physical DRAM starting here
 * so kernel code can reach any PA as (KERNEL_DMAP_BASE + pa) once paging is on
 * (the illumos "kpm" / direct-map window, on RISC-V a canonical Sv39 high VA
 * whose sign bits [63:39] are all 1).
 */
#define	KERNEL_DMAP_BASE	0xffffffc000000000UL

/*
 * R-P30: the kernel is now LINKED + EXECUTES at high VA.  Its physical load
 * address is 0x80200000 (where OpenSBI jumps the S-payload); its virtual link
 * address is KERNEL_VMA_BASE.  Because the whole kernel high half is the
 * direct-map (VA = KERNEL_DMAP_BASE + PA), a kernel VA and its physical address
 * differ by exactly KERNEL_DMAP_BASE -- both kernel-image symbols (linked at
 * KERNEL_DMAP_BASE + 0x80200000) and any direct-map pointer (KERNEL_DMAP_BASE +
 * pa) satisfy VA = DMAP + PA.  KVTOP/PTOKV convert between the two: a PTE needs
 * a PHYSICAL address, but the running kernel only ever holds VAs, so every
 * pointer stored INTO a PTE goes through KVTOP and every PA read OUT of a PTE
 * and dereferenced goes through PTOKV.  This is the illumos hat_i86 KERNELBASE
 * / mmu_ptob(pfn) + hat_kpm PA<->kernel-VA conversion.
 */
#define	KERNEL_PHYS_BASE	0x80200000UL
#define	KVTOP(va)	((unsigned long)(va) - KERNEL_DMAP_BASE)
#define	PTOKV(pa)	((unsigned long)(pa) + KERNEL_DMAP_BASE)

/* MD asm leaves (mach_mmu.S). */
extern void rv_set_satp(unsigned long satp);
extern unsigned long rv_get_satp(void);
extern void rv_tlb_flush_all(void);

/* R-P24 boot-paging: build the boot root + enable Sv39.  Returns satp value. */
extern unsigned long hat_boot_init(void);

#ifdef __cplusplus
}
#endif

#endif	/* _RP24_MMU_RISCV_H */
