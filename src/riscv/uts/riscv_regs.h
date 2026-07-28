/*
 * riscv_regs.h — illumos riscv64 S-mode CSR + Sv39 definitions (R-P3).
 *
 * Machine-derived constants for the R-P3 trap vector, Sv39 HAT, and timer.
 * Values are from the RISC-V Privileged Specification (the authority); this
 * header is the illumos-idiom equivalent of NetBSD sys/arch/riscv/include/
 * {sysreg.h,pte.h} — reimplemented from the spec, not copied.
 *
 * All symbols here describe S-mode CSRs and the Sv39 address-translation
 * format. M-mode CSRs are OpenSBI's; we never touch them.
 */

#ifndef	_RISCV_REGS_H
#define	_RISCV_REGS_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * ---------------------------------------------------------------------------
 * sstatus (Supervisor Status) bits — Priv Spec, S-mode.
 * ---------------------------------------------------------------------------
 */
#define	SSTATUS_SIE	(1UL << 1)	/* S-mode interrupt enable */
#define	SSTATUS_SPIE	(1UL << 5)	/* prior SIE, saved on trap */
#define	SSTATUS_SPP	(1UL << 8)	/* prior privilege (0=U,1=S) */

/*
 * ---------------------------------------------------------------------------
 * sie / sip (Supervisor Interrupt Enable / Pending) bits — Priv Spec.
 * Bit numbers are the interrupt cause codes (scause low bits) for interrupts.
 * ---------------------------------------------------------------------------
 */
#define	SIE_SSIE	(1UL << 1)	/* S-mode software interrupt */
#define	SIE_STIE	(1UL << 5)	/* S-mode timer interrupt */
#define	SIE_SEIE	(1UL << 9)	/* S-mode external interrupt */

/*
 * ---------------------------------------------------------------------------
 * scause — trap cause. The high bit (bit 63 on RV64) distinguishes an
 * interrupt (1) from an exception (0); the low bits are the cause code.
 * ---------------------------------------------------------------------------
 */
#define	SCAUSE_INT	(1UL << 63)	/* set => interrupt, clear => exception */
#define	SCAUSE_CODE(c)	((c) & ~SCAUSE_INT)

/* Interrupt cause codes (scause with SCAUSE_INT set). */
#define	IRQ_S_SOFT	1UL		/* supervisor software */
#define	IRQ_S_TIMER	5UL		/* supervisor timer */
#define	IRQ_S_EXT	9UL		/* supervisor external */

/* Exception cause codes (scause with SCAUSE_INT clear). */
#define	EXC_INST_MISALIGNED	0UL
#define	EXC_INST_ACCESS		1UL
#define	EXC_ILLEGAL_INST	2UL
#define	EXC_BREAKPOINT		3UL
#define	EXC_LOAD_MISALIGNED	4UL
#define	EXC_LOAD_ACCESS		5UL
#define	EXC_STORE_MISALIGNED	6UL
#define	EXC_STORE_ACCESS	7UL
#define	EXC_ECALL_U		8UL
#define	EXC_ECALL_S		9UL
#define	EXC_INST_PAGE_FAULT	12UL	/* Sv39 page faults */
#define	EXC_LOAD_PAGE_FAULT	13UL
#define	EXC_STORE_PAGE_FAULT	15UL

/*
 * ---------------------------------------------------------------------------
 * satp — Supervisor Address Translation and Protection (Priv Spec).
 *   [63:60] MODE  (0 = Bare, 8 = Sv39, 9 = Sv48, 10 = Sv57)
 *   [59:44] ASID
 *   [43:0]  PPN   (physical page number of the root page table = PA >> 12)
 * ---------------------------------------------------------------------------
 */
#define	SATP_MODE_BARE	0UL
#define	SATP_MODE_SV39	8UL
#define	SATP_MODE_SHIFT	60
#define	SATP_ASID_SHIFT	44
#define	SATP_PPN_MASK	((1UL << 44) - 1)

#define	SATP_MAKE(mode, asid, ppn)					\
	(((unsigned long)(mode) << SATP_MODE_SHIFT) |			\
	((unsigned long)(asid) << SATP_ASID_SHIFT) |			\
	((unsigned long)(ppn) & SATP_PPN_MASK))

/*
 * ---------------------------------------------------------------------------
 * Sv39 page-table format (Priv Spec §Sv39).
 *
 * 39-bit virtual address, 3 levels. VA layout:
 *   [38:30] VPN[2]  (index into root / level-2 table)
 *   [29:21] VPN[1]  (index into level-1 table)
 *   [20:12] VPN[0]  (index into level-0 / leaf table)
 *   [11:0]  page offset
 *
 * A PTE is 64 bits:
 *   [63:54] reserved / PBMT / N (0 here)
 *   [53:10] PPN[2:0]  (physical page number; PPN = PTE[53:10])
 *   [9:8]   RSW (software)
 *   [7] D  dirty     [6] A accessed  [5] G global   [4] U user
 *   [3] X  execute   [2] W write     [1] R read     [0] V valid
 *
 * A PTE with V=1 and (R|W|X)=0 is a POINTER to the next-level table.
 * A PTE with V=1 and any of R/W/X set is a LEAF (a mapping). A leaf at
 * level 1 is a 2 MiB "megapage", at level 2 a 1 GiB "gigapage".
 *
 * PPN is bits [53:10] of the PTE, which equals (physaddr >> 12) << 10.
 * ---------------------------------------------------------------------------
 */
#define	PTE_V	(1UL << 0)	/* valid */
#define	PTE_R	(1UL << 1)	/* readable */
#define	PTE_W	(1UL << 2)	/* writable */
#define	PTE_X	(1UL << 3)	/* executable */
#define	PTE_U	(1UL << 4)	/* user-accessible */
#define	PTE_G	(1UL << 5)	/* global */
#define	PTE_A	(1UL << 6)	/* accessed */
#define	PTE_D	(1UL << 7)	/* dirty */

#define	PTE_RWX	(PTE_R | PTE_W | PTE_X)

/* Convert a physical address to the PPN field of a PTE (bits [53:10]). */
#define	PA_TO_PTE(pa)	((((unsigned long)(pa) >> 12) << 10))
/* Convert a PTE's PPN field back to the physical base address. */
#define	PTE_TO_PA(pte)	((((unsigned long)(pte) >> 10) << 12))

#define	PAGESHIFT	12
#define	PAGESIZE	(1UL << PAGESHIFT)	/* 4 KiB */
#define	MEGASHIFT	21
#define	MEGASIZE	(1UL << MEGASHIFT)	/* 2 MiB (level-1 leaf) */
#define	GIGASHIFT	30
#define	GIGASIZE	(1UL << GIGASHIFT)	/* 1 GiB (level-2 leaf) */

#define	PTES_PER_TABLE	512			/* 4KiB / 8 bytes */

/* Extract the level-L VPN index from a virtual address. */
#define	VPN(va, level)	(((unsigned long)(va) >> (PAGESHIFT + 9 * (level))) & 0x1ff)

/*
 * ---------------------------------------------------------------------------
 * Canonical Sv39 kernel VA split (R-P4).
 *
 * Sv39 gives a 39-bit VA space. The architectural rule is that bits [63:39]
 * must all equal bit 38 (sign-extension), so valid VAs are two disjoint
 * ranges: low  0x0000000000000000 .. 0x0000003fffffffff  (bit38=0)
 *          high 0xffffffc000000000 .. 0xffffffffffffffff  (bit38=1).
 *
 * illumos puts the kernel in the high range (like KERNELBASE on other arches).
 * We choose KERNELBASE at the base of the high canonical hole, 0xffffffc000...,
 * which is VPN[2]=256 (the first entry of the high half of the root table).
 * The R-P4 hat maps fresh physical pages here to prove a real high-VA regime,
 * distinct from the R-P3 identity boot map.
 * ---------------------------------------------------------------------------
 */
#define	KERNELBASE	0xffffffc000000000UL	/* high canonical, VPN2=256 */

/*
 * ---------------------------------------------------------------------------
 * qemu virt platform MMIO (from the qemu 'virt' machine + its devicetree).
 * These are physical addresses, identity-mapped by the R-P3 low-MMIO gigapage.
 * ---------------------------------------------------------------------------
 */
#define	CLINT_BASE	0x02000000UL	/* core-local interruptor */
#define	PLIC_BASE	0x0c000000UL	/* platform-level interrupt ctrl */
#define	UART0_BASE	0x10000000UL	/* NS16550A UART */
#define	UART0_IRQ	10UL		/* qemu virt: UART0 PLIC source = 10 */

#ifdef __cplusplus
}
#endif

#endif	/* _RISCV_REGS_H */
