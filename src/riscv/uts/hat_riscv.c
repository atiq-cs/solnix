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

/* Shared kernel satp, published for secondary harts (locore.S kernel_satp). */
extern unsigned long kernel_satp;

/*
 * Static page-table pool. Each table is 4 KiB (512 * 8-byte PTEs), 4 KiB
 * aligned as Sv39 requires (a table's PA must be page-aligned; its PPN is
 * PA>>12). We need: 1 root (level 2) + 1 level-1 + 1 level-0 for the alias +
 * 1 level-1 + 1 level-0 for the high-VA (KERNELBASE) kernel map (R-P4). The
 * identity gigapages are leaves in the root, needing no sub-tables. Pool of 6
 * tables covers both walks with headroom.
 */
#define	NBOOT_TABLES	6
static unsigned long boot_pt[NBOOT_TABLES][PTES_PER_TABLE]
    __attribute__((aligned(PAGESIZE)));
static int boot_pt_next = 0;

/*
 * ---------------------------------------------------------------------------
 * R-P4 physical page allocator (bump) + high-VA kernel map.
 * ---------------------------------------------------------------------------
 * A minimal watermark ('bump') allocator over the physical RAM that lies
 * above the loaded kernel image. This is the seed of the real illumos page
 * allocator (page_t / freelists) — enough to hand out fresh 4 KiB physical
 * pages for the high-VA hat and for allocating page-table pages once the
 * static boot pool is exhausted.
 *
 * RAM base/size: on qemu virt the DTB /memory node reports base 0x80000000
 * and size (default) 128 MiB. Full FDT parsing is R-P5 work; here we take the
 * conservative, provable path: start the bump watermark just above the kernel
 * BSS end (page-aligned) and cap it at a DTB-independent floor of RAM we know
 * qemu virt always has. Because the whole 0x80000000 GiB is identity-mapped
 * (VA==PA) by the R-P3 boot map, a bump-allocated physical address is directly
 * usable as a kernel pointer to zero/fill the page.
 */
#define	PHYS_RAM_BASE	0x80000000UL
/* Conservative: qemu virt default is 128 MiB; we only ever nibble a few pages. */
#define	PHYS_RAM_END	(PHYS_RAM_BASE + 0x08000000UL)	/* 128 MiB */

static unsigned long phys_bump;		/* next free physical address */
static unsigned long phys_bump_end;	/* one past the last usable byte */
static unsigned long phys_alloc_count;	/* pages handed out (diagnostics) */

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

/* From vm_page.c: real page allocator, available after page_init(). Weak-linked
 * via a global flag so early boot (before page_init) uses the static pool. */
extern unsigned long page_alloc(void);
extern void page_free(unsigned long pa);
extern void page_incref(unsigned long pa);
extern unsigned int page_refcount(unsigned long pa);
static int page_layer_up = 0;
void hat_page_layer_online(void) { page_layer_up = 1; }

/* Allocate a zeroed page table. Before the R-P5 page layer is up, draw from the
 * static boot pool; after, draw a real page from page_alloc (identity VA==PA,
 * already zeroed) so the KERNELBASE VA allocator can map many pages. */
static unsigned long *
alloc_table(void)
{
	unsigned long *t;
	int i;

	if (page_layer_up) {
		unsigned long pa = page_alloc();
		if (pa == 0) {
			sbi_console_puts("[hat] PANIC: page_alloc failed for PT\n");
			for (;;)
				__asm__ __volatile__("wfi");
		}
		return ((unsigned long *)pa);	/* page_alloc zeroes it */
	}

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
 * R-P15 K1 device window. The SpaceMiT K1 SoC places its high-address device
 * MMIO well above the R-P3 low-MMIO identity gigapage (0x0..0x40000000):
 *   dw-apb-uart 0xd4017000, sdhci/eMMC 0xd4281000  (both in the 0xd4xxxxxx run)
 *   APLIC 0xe0000000, IMSIC 0xe0008000
 * All four fall inside the single 1 GiB Sv39 gigapage at VA/PA 0xc0000000
 * (VPN2=3, spanning 0xc0000000..0x100000000). So ONE identity gigapage maps
 * every K1 device region. R/W, not executable (device memory).
 */
#define	K1_DEV_GIGA	0xc0000000UL	/* VPN2=3: covers 0xc0000000..0x100000000 */

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

	/* 4. R-P15: identity gigapage for the K1 high-address device window
	 * (dw-apb-uart/sdhci/aplic/imsic all live in 0xc0000000..0x100000000).
	 * R/W device memory, no X. Harmless on qemu-virt (nothing is there);
	 * on K1 silicon it makes the K1 uart/sdhci/aplic/imsic MMIO reachable. */
	map_gigapage(K1_DEV_GIGA, K1_DEV_GIGA, PTE_R | PTE_W);

	/* Compose satp: MODE=Sv39, ASID=0, PPN = root table PA >> 12. */
	ppn = (unsigned long)root_pt >> PAGESHIFT;
	satp = SATP_MAKE(SATP_MODE_SV39, 0, ppn);

	/*
	 * Publish the satp for secondary harts (R-P4 SMP). Every hart loads
	 * this same root table so the whole kernel shares one address space.
	 * Written before we start any secondary (main() starts them after
	 * hat_boot_init returns).
	 */
	kernel_satp = satp;

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
	sbi_console_puts("      K1 dev giga    VA=");
	puthex(K1_DEV_GIGA);
	sbi_console_puts(" -> PA 0xc0000000 (uart/sdhci/aplic/imsic, RW)\n");
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

/*
 * ---------------------------------------------------------------------------
 * R-P4: physical page allocator + high-VA kernel HAT (hat_memload-analog)
 * ---------------------------------------------------------------------------
 */

/*
 * hat_phys_init — initialize the bump allocator. The free pool starts one
 * page above the kernel BSS end (page-aligned up) and runs to the RAM cap.
 * Called from mlsetup after paging is on. Idempotent enough for R-P4.
 */
void
hat_phys_init(void)
{
	unsigned long kend = ((unsigned long)__bss_end + PAGESIZE - 1) &
	    ~(PAGESIZE - 1);

	phys_bump = kend;
	phys_bump_end = PHYS_RAM_END;
	phys_alloc_count = 0;

	sbi_console_puts("[hat] phys page allocator: free RAM ");
	puthex(phys_bump);
	sbi_console_puts(" .. ");
	puthex(phys_bump_end);
	sbi_console_puts(" (");
	puthex((phys_bump_end - phys_bump) >> PAGESHIFT);
	sbi_console_puts(" pages)\n");
}

/*
 * hat_palloc — hand out one zeroed 4 KiB physical page. Returns the physical
 * address (== a usable kernel pointer, since the kernel gigapage is identity
 * mapped VA==PA). Panics on exhaustion. This is the seed of page_get().
 */
unsigned long
hat_palloc(void)
{
	unsigned long pa;
	unsigned long *p;
	int i;

	if (phys_bump == 0 || phys_bump + PAGESIZE > phys_bump_end) {
		sbi_console_puts("[hat] PANIC: out of physical pages\n");
		for (;;)
			__asm__ __volatile__("wfi");
	}
	pa = phys_bump;
	phys_bump += PAGESIZE;
	phys_alloc_count++;

	/* Zero it (VA==PA identity map). */
	p = (unsigned long *)pa;
	for (i = 0; i < (int)(PAGESIZE / sizeof (unsigned long)); i++)
		p[i] = 0;
	return (pa);
}

/*
 * hat_phys_watermark — the first physical address ABOVE everything the boot
 * allocator has consumed (kernel image + any hat_palloc pages). R-P5's page
 * layer (vm_page.c) builds its page_t array + free list starting here, so the
 * bump region and the page-managed region never overlap. After page_init the
 * bump allocator is retired; hat page-table allocs route through page_alloc.
 */
unsigned long
hat_phys_watermark(void)
{
	return (phys_bump);
}

/*
 * hat_kmap_page — the hat_memload-analog: map one physical page PA at kernel
 * virtual address VA with the given RWX perm, through the shared root table's
 * full 3-level Sv39 walk (allocating intermediate tables from the boot pool as
 * needed). VA is expected to be a canonical high kernel VA (>= KERNELBASE).
 * sfence.vma the single VA so the new mapping is visible immediately.
 */
void
hat_kmap_page(unsigned long va, unsigned long pa, unsigned long perm)
{
	map_page(va, pa, perm);
	__asm__ __volatile__("sfence.vma %0, zero" :: "r"(va) : "memory");
}

/*
 * ---------------------------------------------------------------------------
 * R-P7 per-process address spaces (as.c support).
 * ---------------------------------------------------------------------------
 * A user address space is a FRESH Sv39 root page table whose kernel half (the
 * two identity gigapages the boot map installed: low MMIO + the kernel RAM
 * GiB) is copied in, so that after a trap from U-mode the kernel keeps running
 * at its identity VAs on the process satp. User mappings are installed with
 * PTE_U set through the same 3-level walk, allocating intermediate tables from
 * the page allocator.
 */

/* Allocate a fresh, zeroed root page table for a new address space and copy
 * the kernel gigapage entries from the shared boot root into it. Returns the
 * root's physical address (== kernel pointer, identity mapped). */
unsigned long
hat_as_newroot(void)
{
	unsigned long *nr = alloc_table();
	int i;

	/*
	 * Copy the KERNEL entries from the shared boot root so the kernel stays
	 * reachable on the new satp: slot 0 (low MMIO identity giga — the UART
	 * the syscall read path polls in S-mode), slot 2 (kernel RAM identity
	 * giga — kernel text/data/stack), and the high half (slots 256..511 —
	 * the KERNELBASE kmem tables). We deliberately DO NOT copy the low user
	 * slots (1 = the R-P3 alias, 3 = where userland lives): leaving them
	 * clear guarantees hat_as_map builds fresh user tables there and never
	 * collides with a kernel gigapage leaf. Kernel gigapage leaves lack
	 * PTE_U, so U-mode still cannot reach the kernel through the shared
	 * slots.
	 */
	for (i = 0; i < PTES_PER_TABLE; i++)
		nr[i] = 0;
	nr[0] = root_pt[0];			/* low MMIO giga (UART) */
	nr[2] = root_pt[2];			/* kernel RAM giga */
	/* NOT slot 3: on K1 the device giga lives at 0xc0000000 (VPN2=3), but
	 * userland ALSO lives in slot 3 (text @0xC0010000, stack @0xfffff000).
	 * The K1 device window is only touched on the KERNEL satp during boot
	 * (sdhci probe / aplic), never from a user process, so leave slot 3
	 * free for user mappings and avoid the kernel-leaf collision. */
	for (i = 256; i < PTES_PER_TABLE; i++)	/* KERNELBASE high half */
		nr[i] = root_pt[i];
	return ((unsigned long)nr);
}

/* Walk `root` (a physical/identity root PA) to install a 4 KiB user leaf
 * VA->PA with the given RWX perm + PTE_U. Allocates intermediate tables. */
void
hat_as_map(unsigned long root, unsigned long va, unsigned long pa,
    unsigned long perm)
{
	unsigned long *tbl = (unsigned long *)root;
	int level;

	for (level = 2; level > 0; level--) {
		unsigned long idx = VPN(va, level);
		unsigned long pte = tbl[idx];

		if ((pte & PTE_V) == 0) {
			unsigned long *nt = alloc_table();
			tbl[idx] = PA_TO_PTE((unsigned long)nt) | PTE_V;
			tbl = nt;
		} else if (pte & PTE_RWX) {
			/* A leaf where a table was expected: the caller is
			 * mapping a user VA into a slot that already holds a
			 * kernel gigapage/megapage. That is an address-layout
			 * bug (user space must avoid kernel slots). Panic loudly
			 * rather than dereference the leaf's PPN as a table. */
			sbi_console_puts("[hat] PANIC: hat_as_map into a kernel "
			    "leaf slot (va/kernel collision)\n");
			for (;;)
				__asm__ __volatile__("wfi");
		} else {
			tbl = (unsigned long *)PTE_TO_PA(pte);
		}
	}
	tbl[VPN(va, 0)] = PA_TO_PTE(pa) | perm | PTE_U | PTE_V | PTE_A | PTE_D;
}

/* Build the process satp value (Sv39) for a given root PA. */
unsigned long
hat_as_satp(unsigned long root)
{
	return (SATP_MAKE(SATP_MODE_SV39, 0, root >> PAGESHIFT));
}

/*
 * hat_as_va2pa — walk `root` (a physical/identity root PA) for the 4 KiB leaf
 * mapping page-aligned VA `va` and return its physical base, or 0 if unmapped.
 * Used by as_copyto to plant the exec argv/env/auxv image on the user stack
 * before the process satp is loaded (the pages are identity-mapped VA==PA in
 * the kernel, so the returned PA is directly writable).
 */
unsigned long
hat_as_va2pa(unsigned long root, unsigned long va)
{
	unsigned long *tbl = (unsigned long *)root;
	int level;

	for (level = 2; level > 0; level--) {
		unsigned long pte = tbl[VPN(va, level)];

		if ((pte & PTE_V) == 0)
			return (0);
		if (pte & PTE_RWX)
			return (0);	/* mega/gigapage: not a 4 KiB user leaf */
		tbl = (unsigned long *)PTE_TO_PA(pte);
	}
	{
		unsigned long pte = tbl[VPN(va, 0)];

		if ((pte & PTE_V) == 0)
			return (0);
		return (PTE_TO_PA(pte));
	}
}

/*
 * hat_as_walk_leaves — walk `root` and invoke cb(arg, va, pa, perm) for every
 * USER leaf (PTE_U set). Used by as_copy (fork) to duplicate a parent AS and by
 * as_free to reclaim its pages. `perm` passed back is the RWXU bits of the leaf
 * (so the copy re-maps with the same protection). Only the user slots (1..255)
 * are walked; the shared kernel slots (0,2,256..511) are never touched — they
 * are aliases of the boot root, not owned by this AS.
 */
void
hat_as_walk_leaves(unsigned long root,
    void (*cb)(void *arg, unsigned long va, unsigned long pa,
    unsigned long perm), void *arg)
{
	unsigned long *l2 = (unsigned long *)root;
	int i2;

	for (i2 = 0; i2 < PTES_PER_TABLE; i2++) {
		unsigned long *l1;
		int i1;

		/* Only user slots: skip kernel slot 0 (MMIO), 2 (RAM), 256+. */
		if (i2 == 0 || i2 == 2 || i2 >= 256)
			continue;
		if ((l2[i2] & PTE_V) == 0 || (l2[i2] & PTE_RWX))
			continue;	/* empty or (unexpected) megapage */
		l1 = (unsigned long *)PTE_TO_PA(l2[i2]);
		for (i1 = 0; i1 < PTES_PER_TABLE; i1++) {
			unsigned long *l0;
			int i0;

			if ((l1[i1] & PTE_V) == 0 || (l1[i1] & PTE_RWX))
				continue;
			l0 = (unsigned long *)PTE_TO_PA(l1[i1]);
			for (i0 = 0; i0 < PTES_PER_TABLE; i0++) {
				unsigned long pte = l0[i0];
				unsigned long va, pa, perm;

				if ((pte & PTE_V) == 0 || (pte & PTE_U) == 0)
					continue;
				va = ((unsigned long)i2 << 30) |
				    ((unsigned long)i1 << 21) |
				    ((unsigned long)i0 << 12);
				pa = PTE_TO_PA(pte);
				perm = pte & PTE_RWX;
				cb(arg, va, pa, perm);
			}
		}
	}
}

/*
 * hat_pte_ptr — walk `root` for the 4 KiB leaf PTE slot of VA `va` and return a
 * pointer to the PTE (or NULL if no leaf table exists on the path). Used by the
 * COW fault handler to flip a single leaf in place. va need not be page-aligned.
 */
static unsigned long *
hat_pte_ptr(unsigned long root, unsigned long va)
{
	unsigned long *tbl = (unsigned long *)root;
	int level;

	for (level = 2; level > 0; level--) {
		unsigned long pte = tbl[VPN(va, level)];

		if ((pte & PTE_V) == 0 || (pte & PTE_RWX))
			return (0);
		tbl = (unsigned long *)PTE_TO_PA(pte);
	}
	return (&tbl[VPN(va, 0)]);
}

/*
 * hat_as_cow_share — the COW fork primitive. For every USER leaf of `srcroot`
 * (the parent), map the SAME physical page into `dstroot` (the child) at the
 * same VA, and mark BOTH copies read-only + COW (clear PTE_W, set PTE_COW),
 * bumping the shared page's refcount. Read-only/execute-only leaves that were
 * never writable are shared verbatim (no COW needed — a read never faults).
 * Returns the number of leaves shared. The caller sfence's both AS TLBs.
 *
 * This is the RISC-V analog of illumos hat_dup with HAT_DUP_COW: pages are
 * shared read-only and split lazily on the first write fault.
 */
unsigned long
hat_as_cow_share(unsigned long dstroot, unsigned long srcroot)
{
	unsigned long *l2 = (unsigned long *)srcroot;
	unsigned long shared = 0;
	int i2;

	for (i2 = 0; i2 < PTES_PER_TABLE; i2++) {
		unsigned long *l1;
		int i1;

		if (i2 == 0 || i2 == 2 || i2 >= 256)
			continue;
		if ((l2[i2] & PTE_V) == 0 || (l2[i2] & PTE_RWX))
			continue;
		l1 = (unsigned long *)PTE_TO_PA(l2[i2]);
		for (i1 = 0; i1 < PTES_PER_TABLE; i1++) {
			unsigned long *l0;
			int i0;

			if ((l1[i1] & PTE_V) == 0 || (l1[i1] & PTE_RWX))
				continue;
			l0 = (unsigned long *)PTE_TO_PA(l1[i1]);
			for (i0 = 0; i0 < PTES_PER_TABLE; i0++) {
				unsigned long pte = l0[i0];
				unsigned long va, pa, perm;

				if ((pte & PTE_V) == 0 || (pte & PTE_U) == 0)
					continue;
				va = ((unsigned long)i2 << 30) |
				    ((unsigned long)i1 << 21) |
				    ((unsigned long)i0 << 12);
				pa = PTE_TO_PA(pte);
				perm = pte & PTE_RWX;

				if (perm & PTE_W) {
					/* Writable leaf: share read-only + COW
					 * in both AS. Drop W, keep R (and X),
					 * set the COW software bit. */
					unsigned long cowperm =
					    (perm & ~PTE_W);
					unsigned long newpte =
					    PA_TO_PTE(pa) | cowperm |
					    PTE_COW | PTE_U | PTE_V |
					    PTE_A | PTE_D;
					l0[i0] = newpte;	/* parent RO+COW */
					hat_as_map(dstroot, va, pa, cowperm);
					/* mark child COW too */
					{
						unsigned long *cp =
						    hat_pte_ptr(dstroot, va);
						if (cp != 0)
							*cp |= PTE_COW;
					}
					page_incref(pa);
				} else if (pte & PTE_COW) {
					/*
					 * ALREADY-COW leaf: this parent has been
					 * forked before, so an earlier fork already
					 * dropped W and set COW here. It is NOT a
					 * genuinely read-only page, so it must be
					 * shared COW again -- the new child needs
					 * PTE_COW too, or its first write store-faults
					 * on a leaf that hat_as_cow_fault refuses to
					 * split (V|U|!W|!COW) and the process dies.
					 *
					 * WHY THIS BRANCH IS SEPARATE: the test above
					 * asks "is it writable NOW", which cannot tell
					 * a never-writable page from one made RO by a
					 * previous fork. PTE_COW is exactly that
					 * distinction, so consult it rather than
					 * inferring writability from the perm bits.
					 * The parent's leaf is already RO+COW and stays
					 * as it is; only the child mapping is added.
					 */
					hat_as_map(dstroot, va, pa, perm);
					{
						unsigned long *cp =
						    hat_pte_ptr(dstroot, va);
						if (cp != 0)
							*cp |= PTE_COW;
					}
					page_incref(pa);
				} else {
					/* Never-writable leaf (text/rodata): share
					 * verbatim. A read never faults, and a write
					 * SHOULD fault -- there is nothing to split. */
					hat_as_map(dstroot, va, pa, perm);
					page_incref(pa);
				}
				shared++;
			}
		}
	}
	return (shared);
}

/*
 * hat_as_cow_fault — the store-page-fault COW handler. If VA `va` in `root`
 * maps a COW leaf, split it: allocate a fresh private page, copy the shared
 * page's bytes into it, remap `va` writable (clear COW, restore W) to the new
 * page, drop this AS's reference to the old shared page (page_free decrements),
 * and sfence the VA. Returns 1 if it handled a COW fault, 0 otherwise (the
 * caller then treats the store fault as a genuine fault).
 *
 * NOTE: the ceiling (a copy on every write fault, even if this AS is
 * the sole remaining owner) is documented; an owner-optimization (re-map in
 * place when refcount==1) is a cheap future win, noted in the design doc.
 */
int
hat_as_cow_fault(unsigned long root, unsigned long va)
{
	unsigned long *pte = hat_pte_ptr(root, va & ~(PAGESIZE - 1));
	unsigned long oldpa, newpa, perm;
	unsigned long i;
	const unsigned char *src;
	unsigned char *dst;

	if (pte == 0)
		return (0);
	if ((*pte & PTE_V) == 0 || (*pte & PTE_COW) == 0)
		return (0);		/* not a COW leaf */

	oldpa = PTE_TO_PA(*pte);
	perm = (*pte & PTE_RWX) | PTE_W;	/* restore writability */

	if (page_refcount(oldpa) <= 1) {
		/* Sole remaining owner: no copy needed, just re-map writable. */
		*pte = PA_TO_PTE(oldpa) | perm | PTE_U | PTE_V | PTE_A | PTE_D;
		__asm__ __volatile__("sfence.vma %0, zero" :: "r"(va) : "memory");
		return (1);
	}

	newpa = page_alloc();		/* zeroed private page */
	if (newpa == 0)
		return (0);		/* OOM: let it fault (honest) */

	src = (const unsigned char *)oldpa;
	dst = (unsigned char *)newpa;
	for (i = 0; i < PAGESIZE; i++)
		dst[i] = src[i];

	*pte = PA_TO_PTE(newpa) | perm | PTE_U | PTE_V | PTE_A | PTE_D;
	__asm__ __volatile__("sfence.vma %0, zero" :: "r"(va) : "memory");

	page_free(oldpa);		/* drop this AS's share of the old page */
	return (1);
}

/*
 * hat_as_freeuser — free every intermediate USER page table (slots 1..255) of
 * `root` back to the page allocator, then free the root table itself. The leaf
 * data pages are freed separately by as_free (via hat_as_walk_leaves) before
 * this is called; here we reclaim only the page-table pages + root. Kernel
 * slots are aliases and are NOT freed.
 */
void
hat_as_freeuser(unsigned long root)
{
	unsigned long *l2 = (unsigned long *)root;
	int i2;

	for (i2 = 1; i2 < 256; i2++) {
		unsigned long *l1;
		int i1;

		if (i2 == 2)
			continue;
		if ((l2[i2] & PTE_V) == 0 || (l2[i2] & PTE_RWX))
			continue;
		l1 = (unsigned long *)PTE_TO_PA(l2[i2]);
		for (i1 = 0; i1 < PTES_PER_TABLE; i1++) {
			if ((l1[i1] & PTE_V) == 0 || (l1[i1] & PTE_RWX))
				continue;
			page_free(PTE_TO_PA(l1[i1]));	/* level-0 table */
		}
		page_free((unsigned long)l1);			/* level-1 table */
	}
	page_free(root);					/* root table */
}

/*
 * hat_k1_devmap_prove — R-P15 gate-1 proof. Read back the root page-table
 * entry for the K1 device gigapage (VPN2 slot 3, VA 0xc0000000) and confirm it
 * is a VALID R/W leaf whose PPN points at PA 0xc0000000 — i.e. the four K1
 * device regions (dw-apb-uart 0xd4017000, sdhci 0xd4281000, aplic 0xe0000000,
 * imsic 0xe0008000) are all mapped and reachable by load/store. We PROVE the
 * translation by reading back the installed PTE (not by dereferencing the
 * address: on qemu-virt nothing is wired at 0xc0000000, so a live load would
 * fault — on K1 silicon the same PTE makes the real MMIO reachable). Prints
 * the readback so the boot log carries the proof.
 */
void
hat_k1_devmap_prove(void)
{
	unsigned long slot = VPN(K1_DEV_GIGA, 2);	/* == 3 */
	unsigned long pte = root_pt[slot];
	unsigned long pa = PTE_TO_PA(pte);
	int ok = (pte & PTE_V) && (pte & (PTE_R | PTE_W)) &&
	    !(pte & PTE_X) && pa == K1_DEV_GIGA;

	sbi_console_puts("[k1-mmio] device gigapage PTE[slot ");
	puthex(slot);
	sbi_console_puts("] = ");
	puthex(pte);
	sbi_console_puts(" -> PA ");
	puthex(pa);
	sbi_console_puts(ok ?
	    "  (V|R|W, !X) MAPPED\n" : "  BAD -> device map BROKEN\n");
	sbi_console_puts("k1-mmio: mapped dw-apb-uart/sdhci/aplic/imsic device "
	    "regions (0xd4017000/0xd4281000/0xe0000000/0xe0008000 in the "
	    "0xc0000000 giga); readback ");
	sbi_console_puts(ok ? "OK\n" : "FAILED\n");
}

/* Switch the current hart to address space `satp` and flush the TLB. */
void
hat_as_switch(unsigned long satp)
{
	__asm__ __volatile__(
	    "csrw satp, %0\n\t"
	    "sfence.vma\n\t"
	    :: "r"(satp) : "memory");
}

/* Return the shared kernel satp (to switch back to on process teardown). */
unsigned long
hat_kernel_satp(void)
{
	return (kernel_satp);
}

/*
 * hat_highva_prove — R-P4 milestone-4 proof. Allocate a fresh physical page,
 * map it at KERNELBASE in the high canonical VA range (R/W, kernel), write a
 * signature through the high VA, and read it back — both through the high VA
 * and through the page's identity (VA==PA) address — proving the high-VA
 * translation resolves to the intended physical page. This is the seed of the
 * kernel heap/VA regime that genunix (R-P5) will build on.
 */
void
hat_highva_prove(void)
{
	unsigned long pa;
	volatile unsigned long *hi, *ident;
	const unsigned long sig = 0x5041474544554d50UL;	/* "PAGEDUMP" */

	pa = hat_palloc();
	hat_kmap_page(KERNELBASE, pa, PTE_R | PTE_W);

	sbi_console_puts("[hat] high-VA map: KERNELBASE ");
	puthex(KERNELBASE);
	sbi_console_puts(" -> PA ");
	puthex(pa);
	sbi_console_puts(" (RW)\n");

	hi = (volatile unsigned long *)KERNELBASE;
	ident = (volatile unsigned long *)pa;

	*hi = sig;				/* write through the HIGH VA */
	__asm__ __volatile__("fence" ::: "memory");

	sbi_console_puts("[hat] wrote ");
	puthex(sig);
	sbi_console_puts(" via high VA; readback high=");
	puthex(*hi);
	sbi_console_puts(" ident=");
	puthex(*ident);
	sbi_console_puts((*hi == sig && *ident == sig) ?
	    "  MATCH -> high-VA translation verified\n" :
	    "  MISMATCH -> high-VA map BROKEN\n");
}
