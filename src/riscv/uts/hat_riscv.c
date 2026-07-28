/*
 * hat_riscv.c — illumos riscv64 Sv39 boot HAT / pmap (R-P3).
 *
 * The hardest R-P3 piece: build a Sv39 page table from scratch, switch satp
 * from Bare (0) to Sv39 (MODE=8), sfence.vma, and keep executing. This is the
 * seed of the riscv64 HAT (hardware address translation) layer — the analog of
 * uts/i86pc hat_i86 / richlowe arm64-gate hat_aarch64. The page-table walk and
 * PTE encoding are modeled on the RISC-V Privileged Spec (Sv39) and the design
 * of NetBSD sys/arch/riscv/riscv/pmap_machdep.c (studied, reimplemented — no
 * CDDL-incompatible source copied).
 *
 * ---------------------------------------------------------------------------
 * R-P3 boot map (what we install before turning paging on)
 * ---------------------------------------------------------------------------
 *  1. IDENTITY, gigapage (1 GiB level-2 leaf) at VA 0x00000000 -> PA 0x0:
 *     covers all qemu virt MMIO in the low GiB — CLINT 0x02000000,
 *     PLIC 0x0c000000, UART 0x10000000 — R/W, not executable.
 *  2. IDENTITY, gigapage at VA 0x80000000 -> PA 0x80000000: covers OpenSBI +
 *     the whole kernel RAM image (kernel loads at 0x80200000). R/W/X so the
 *     currently-executing kernel keeps running at the same addresses after the
 *     satp switch (VA==PA), and so the stack/data stay reachable.
 *  3. NON-IDENTITY 4 KiB alias at VA 0x40000000 (VPN2=1) -> PA of the kernel's
 *     first text page, built through a full 3-level walk with 4 KiB leaf PTEs.
 *     This proves the multi-level Sv39 walk really translates (it is NOT a
 *     satp=0 passthrough): after paging is on we read a known byte through the
 *     alias VA and compare it to the same byte at its physical/identity VA.
 *
 * Because the executing PC, sp, gp, and all data live in the 0x80000000
 * gigapage which is mapped VA==PA, enabling Sv39 does not move the kernel — it
 * just starts translating. That is the safe, provable way to "continue
 * executing in paged mode."
 * ---------------------------------------------------------------------------
 */

#include "sbi.h"
#include "riscv_regs.h"

/* Kernel image bounds from the linker script (riscv.ld). */
extern char _start[];
extern char __bss_end[];

/*
 * Static page-table pool. Each table is 4 KiB (512 * 8-byte PTEs), 4 KiB
 * aligned as Sv39 requires (a table's PA must be page-aligned; its PPN is
 * PA>>12). We need: 1 root (level 2) + 1 level-1 + 1 level-0 for the alias.
 * The two identity gigapages are leaves in the root, needing no sub-tables.
 * Pool of 4 tables is ample and leaves headroom.
 */
#define	NBOOT_TABLES	4
static unsigned long boot_pt[NBOOT_TABLES][PTES_PER_TABLE]
    __attribute__((aligned(PAGESIZE)));
static int boot_pt_next = 0;

/* The root table (set once alloc'd) and its PA, exported for satp. */
static unsigned long *root_pt;

static const char hex_al[] = "0123456789abcdef";
static void
puthex(unsigned long v)
{
	int i;
	sbi_console_puts("0x");
	for (i = 60; i >= 0; i -= 4)
		sbi_console_putchar(hex_al[(v >> i) & 0xf]);
}

/* Allocate a zeroed page table from the boot pool. Returns kernel/phys ptr
 * (identity: VA==PA in the 0x80000000 gigapage, so the pointer's address IS
 * the physical address usable in a PTE PPN). */
static unsigned long *
alloc_table(void)
{
	unsigned long *t;
	int i;

	if (boot_pt_next >= NBOOT_TABLES) {
		sbi_console_puts("[hat] PANIC: out of boot page tables\n");
		for (;;)
			__asm__ __volatile__("wfi");
	}
	t = boot_pt[boot_pt_next++];
	for (i = 0; i < PTES_PER_TABLE; i++)
		t[i] = 0;
	return (t);
}

/*
 * map_gigapage — install a 1 GiB identity leaf in the root table.
 * VA and PA must be 1 GiB aligned. perm = PTE_R/W/X bits (no V/A/D; we add).
 */
static void
map_gigapage(unsigned long va, unsigned long pa, unsigned long perm)
{
	unsigned long idx = VPN(va, 2);
	root_pt[idx] = PA_TO_PTE(pa) | perm | PTE_V | PTE_A | PTE_D;
}

/*
 * map_page — install a 4 KiB leaf mapping VA->PA through a full 3-level walk,
 * allocating intermediate tables as needed. This is the real Sv39 page-table
 * walk (levels 2 -> 1 -> 0), the core of any pmap.
 */
static void
map_page(unsigned long va, unsigned long pa, unsigned long perm)
{
	unsigned long *tbl = root_pt;
	int level;

	for (level = 2; level > 0; level--) {
		unsigned long idx = VPN(va, level);
		unsigned long pte = tbl[idx];

		if ((pte & PTE_V) == 0) {
			/* No next-level table yet: allocate one, install a
			 * non-leaf pointer PTE (V=1, R=W=X=0). */
			unsigned long *nt = alloc_table();
			tbl[idx] = PA_TO_PTE((unsigned long)nt) | PTE_V;
			tbl = nt;
		} else {
			/* Descend into the existing next-level table. */
			tbl = (unsigned long *)PTE_TO_PA(pte);
		}
	}
	/* Level 0: install the 4 KiB leaf. */
	tbl[VPN(va, 0)] = PA_TO_PTE(pa) | perm | PTE_V | PTE_A | PTE_D;
}

/* Alias VA used to prove non-identity translation (see file banner #3). */
#define	ALIAS_VA	0x40000000UL	/* VPN2=1, canonical (bit38=0) */

/*
 * hat_boot_init — build the boot page table and turn Sv39 on. Prints the
 * post-paging banner and the alias-readback proof. Returns the satp value
 * installed (for the caller's status line).
 */
unsigned long
hat_boot_init(void)
{
	unsigned long kbase = (unsigned long)_start & ~(GIGASIZE - 1);
	unsigned long kfirst = (unsigned long)_start & ~(PAGESIZE - 1);
	unsigned long satp, ppn;
	volatile unsigned char *alias, *ident;

	root_pt = alloc_table();

	/* 1. Identity gigapage for low MMIO (CLINT/PLIC/UART): R/W, no X. */
	map_gigapage(0x00000000UL, 0x00000000UL, PTE_R | PTE_W);

	/* 2. Identity gigapage for the kernel RAM/OpenSBI GiB: R/W/X. */
	map_gigapage(kbase, kbase, PTE_R | PTE_W | PTE_X);

	/* 3. Non-identity 4 KiB alias -> the kernel's first text page (R/X). */
	map_page(ALIAS_VA, kfirst, PTE_R | PTE_X);

	/* Compose satp: MODE=Sv39, ASID=0, PPN = root table PA >> 12. */
	ppn = (unsigned long)root_pt >> PAGESHIFT;
	satp = SATP_MAKE(SATP_MODE_SV39, 0, ppn);

	sbi_console_puts("[hat] Sv39 boot map built:\n");
	sbi_console_puts("      identity giga  VA=0x0000000000000000 -> PA 0x0 (MMIO, RW)\n");
	sbi_console_puts("      identity giga  VA=");
	puthex(kbase);
	sbi_console_puts(" -> PA (kernel, RWX)\n");
	sbi_console_puts("      alias 4KiB     VA=");
	puthex(ALIAS_VA);
	sbi_console_puts(" -> PA ");
	puthex(kfirst);
	sbi_console_puts(" (proof, RX)\n");
	sbi_console_puts("      root PT PA=");
	puthex((unsigned long)root_pt);
	sbi_console_puts(" satp=");
	puthex(satp);
	sbi_console_puts("\n");

	/*
	 * The switch. Write satp then sfence.vma to flush any stale TLB and
	 * make the new translation regime take effect. From this instruction
	 * on, every fetch/load/store is Sv39-translated. Because PC/sp/data
	 * are in the identity-mapped kernel gigapage, execution continues
	 * seamlessly at the same (now virtual) addresses.
	 */
	__asm__ __volatile__(
		"csrw satp, %0\n\t"
		"sfence.vma\n\t"
		:
		: "r"(satp)
		: "memory");

	/* We are now executing in paged (Sv39) mode. Announce it. */
	sbi_console_puts("[hat] PAGING ON: Sv39 live, executing translated. satp=");
	puthex(satp);
	sbi_console_puts("\n");

	/*
	 * Alias proof: read the kernel's first byte through BOTH the identity
	 * VA (== PA) and the non-identity alias VA. If Sv39 is really walking
	 * the tables (not a passthrough) the alias resolves to the same phys
	 * page and the bytes match. If satp were still 0 the alias VA would
	 * fault (nothing at 0x40000000 physically) — so a clean match is proof.
	 */
	ident = (volatile unsigned char *)kfirst;
	alias = (volatile unsigned char *)(ALIAS_VA | ((unsigned long)_start & (PAGESIZE - 1)));
	sbi_console_puts("[hat] alias readback: *(ident VA ");
	puthex((unsigned long)ident);
	sbi_console_puts(")=");
	puthex(ident[0]);
	sbi_console_puts(" *(alias VA ");
	puthex((unsigned long)alias);
	sbi_console_puts(")=");
	puthex(alias[0]);
	sbi_console_puts(alias[0] == ident[0] ?
	    "  MATCH -> Sv39 translation verified\n" :
	    "  MISMATCH -> translation BROKEN\n");

	return (satp);
}
