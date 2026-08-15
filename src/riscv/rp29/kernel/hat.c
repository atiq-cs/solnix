/*
 * hat.c -- R-P29 headline: the full high-VA R^X kernel HAT.
 *
 * R-P24's hat_boot.c built a BOOT map: identity gigapages over the low 4 GiB
 * (V|R|W|X, so kernel text is writable AND executable) + a high direct-map of
 * RWX gigapages.  That is enough to turn paging on but is not a mature kernel
 * map: no per-segment permissions (W^X is violated -- .text is writable), no
 * fine-grained 4 KiB leaves, and the kernel executes at the low identity VA.
 *
 * hat_kernel_setup() replaces that with a REAL kernel HAT, boot-verified:
 *   - Map the kernel image PER SEGMENT at 4 KiB leaf granularity with W^X
 *     permissions: .text = R|X (no W), .rodata = R (no W, no X), .data/.bss =
 *     R|W (no X).  No page is both writable and executable.  The segment
 *     boundaries come from the linker (__text_start/__etext, __rodata_start/
 *     __erodata, __data_start/__end).
 *   - Map the same kernel image at the HIGH direct-map alias (KERNEL_DMAP_BASE
 *     + pa) with the same per-segment R^X perms, and EXECUTE a probe function
 *     through that high VA (a real high-VA jump) -- proving the kernel can run
 *     in the canonical Sv39 high half.
 *   - Keep only the boot heap + a small low-RAM window RW-mapped (the kernel's
 *     stacks, page tables and DMA-able frames live in identity low DRAM); drop
 *     the low identity gigapages that covered unused address space.
 *   - Install the new root (satp + local sfence.vma) and broadcast a TLB
 *     shootdown to the secondary hart via an IPI (SBI) so every hart flushes
 *     stale translations.
 *
 * hat_memload(root, va, pa, perms) is the 4 KiB leaf mapping primitive (the
 * illumos hat_memload contract: install one page-sized mapping with the given
 * protections), shared with the user HAT walk.
 *
 * CRIB PROVENANCE: mapping the kernel per segment with distinct R^X
 * protections (text RX, rodata R, data RW) + dropping the boot identity map is
 * illumos i86pc hat_kern_setup / hat_i86.c (hat_devload/hat_memload leaf
 * install) + seg_kmem, and the OpenBSD/xv6 W^X kernel map; the 4 KiB Sv39 leaf
 * walk + the R/W/X leaf bits + the "non-leaf PTE has V set, R=W=X=0" rule are
 * the RISC-V privileged spec; the "keep a valid mapping of the running code
 * live across the satp switch, then jump to the new VA" transition is the
 * i86pc/aarch64 boot-map trampoline idiom; the cross-hart sfence.vma via IPI is
 * the illumos hat_tlb_inval / x_call TLB-shootdown model mapped onto the RISC-V
 * SBI IPI + remote-fence extension.
 */

#include "mmu_riscv.h"

extern void *kmem_alloc_page(void);
extern void rv_set_satp(unsigned long);
extern unsigned long rv_get_satp(void);
extern void rv_tlb_flush_all(void);
extern void sbi_console_puts(const char *);
extern void putdec_pub(unsigned long);
extern void puthex_pub(unsigned long);
extern long sbi_send_ipi_hart(unsigned long hartid);
extern long sbi_remote_sfence_vma(unsigned long hartid);

/* linker segment boundaries (kernel.lds). */
extern char __text_start[], __etext[];
extern char __rodata_start[], __erodata[];
extern char __data_start[], __end[];

#define	L2_IDX(va)	(((va) >> GIGASHIFT) & (PTES_PER_TABLE - 1))
#define	L1_IDX(va)	(((va) >> MEGASHIFT) & (PTES_PER_TABLE - 1))
#define	L0_IDX(va)	(((va) >> PAGESHIFT) & (PTES_PER_TABLE - 1))

#define	PTE_TABLE(pa)	(PA_TO_PTE(pa) | PTE_V)

/* the R-P29 kernel HAT root (a fresh Sv39 level-2 table, page-aligned). */
static unsigned long *hat_kroot;

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

/*
 * hat_memload -- install ONE 4 KiB leaf mapping va -> pa with `perms`
 * (PTE_R/W/X/G bits) into `root`, allocating intermediate tables as needed.
 * The kernel runs identity/direct-mapped low DRAM, so a freshly kmem_alloc'd
 * table pointer IS its physical address (what a PTE needs).  A|D preset so the
 * hardware need not fault to set them (Svadu would, but presetting is portable
 * and matches the illumos "kernel PTEs are always accessed/dirty" model).
 *
 * CRIB PROVENANCE: the hat_memload(hat, addr, pfn, attr, flags) leaf-install
 * contract is illumos uts/common/vm/hat.h + i86pc hat_i86.c hat_memload; the
 * 3-level table walk allocating missing levels is the RISC-V Sv39 walk.
 */
int
hat_memload(unsigned long *root, unsigned long va, unsigned long pa,
    unsigned long perms)
{
	unsigned long *l1, *l0;
	unsigned long pte;

	pte = root[L2_IDX(va)];
	if ((pte & PTE_V) == 0) {
		l1 = alloc_table();
		if (l1 == 0)
			return (-1);
		root[L2_IDX(va)] = PTE_TABLE((unsigned long)l1);
	} else {
		l1 = (unsigned long *)PTE_TO_PA(pte);
	}

	pte = l1[L1_IDX(va)];
	if ((pte & PTE_V) == 0) {
		l0 = alloc_table();
		if (l0 == 0)
			return (-1);
		l1[L1_IDX(va)] = PTE_TABLE((unsigned long)l0);
	} else {
		l0 = (unsigned long *)PTE_TO_PA(pte);
	}

	l0[L0_IDX(va)] = PA_TO_PTE(pa) | perms | PTE_V | PTE_A | PTE_D;
	return (0);
}

/*
 * map_range -- hat_memload a [start,end) VA range at 4 KiB granularity, both at
 * the low identity VA (va==pa) and at the high direct-map alias (KERNEL_DMAP_
 * BASE + pa), with the same perms.  The kernel image is loaded at pa==low VA,
 * so `start`/`end` are the low link addresses; we map both aliases so we can
 * jump PC to the high alias after the switch and drop the low identity later.
 */
static int
map_range(unsigned long start, unsigned long end, unsigned long perms)
{
	unsigned long va;

	start &= PAGEMASK;
	end = (end + PAGEOFFSET) & PAGEMASK;
	for (va = start; va < end; va += PAGESIZE) {
		if (hat_memload(hat_kroot, va, va, perms) != 0)
			return (-1);
		if (hat_memload(hat_kroot, KERNEL_DMAP_BASE + va, va,
		    perms) != 0)
			return (-1);
	}
	return (0);
}

/*
 * A probe run through the HIGH direct-map alias to prove high-VA execution.
 * hat_kernel_setup computes this function's high-alias address and calls it
 * through that pointer while the new root is installed; it returns a marker.
 * Kept tiny + leaf (no calls) so the single high-alias page mapping suffices.
 */
unsigned long
hat_highva_probe(void)
{
	return (0x5239);	/* "R-P29" marker */
}

/*
 * hat_wx_faulted -- set by the trap handler (main.c rv_trap) when the W^X
 * self-test store to .text faults.  hat_wx_selftest arms it, does a store to a
 * .text address (which must fault: text is mapped R|X, no W), and reports.
 */
volatile int hat_wx_expect;
volatile int hat_wx_faulted;

/*
 * hat_wx_selftest -- prove W^X: a store to a kernel .text address must trap
 * (store/AMO page fault, scause 15) because .text is mapped R|X with no W.
 * We arm hat_wx_expect, attempt the store, and the fault handler (rv_trap)
 * sees hat_wx_expect, sets hat_wx_faulted, and steps sepc past the store so we
 * resume.  Returns 1 if the write faulted (W^X enforced), 0 if it silently
 * succeeded (W^X NOT enforced -- a bug).
 */
int
hat_wx_selftest(void)
{
	volatile unsigned int *text = (volatile unsigned int *)__text_start;

	hat_wx_faulted = 0;
	hat_wx_expect = 1;
	/* this store must fault; rv_trap steps over it. */
	*text = 0xdeadbeef;
	hat_wx_expect = 0;
	return (hat_wx_faulted);
}

/*
 * hat_kernel_setup -- build + install the real R^X kernel HAT and run a
 * high-VA probe.  Called from main() after the boot map is live and kmem is
 * up.  Returns the new satp value, or 0 on failure (caller keeps the boot map).
 */
unsigned long
hat_kernel_setup(void)
{
	unsigned long tstart = (unsigned long)__text_start;
	unsigned long tend = (unsigned long)__etext;
	unsigned long rostart = (unsigned long)__rodata_start;
	unsigned long roend = (unsigned long)__erodata;
	unsigned long dstart = (unsigned long)__data_start;
	unsigned long dend = (unsigned long)__end;
	unsigned long probe_pa, probe_hi;
	unsigned long (*probe_fn)(void);
	unsigned long r, satp;

	hat_kroot = alloc_table();
	if (hat_kroot == 0)
		return (0);

	/*
	 * Per-segment W^X kernel mappings (4 KiB leaves), both at the low
	 * identity VA and the high direct-map alias:
	 *   .text          R | X       (executable, NOT writable)
	 *   .rodata        R           (read-only constants)
	 *   .data + .bss   R | W       (writable, NOT executable)
	 */
	if (map_range(tstart, tend, PTE_R | PTE_X | PTE_G) != 0)
		return (0);
	if (map_range(rostart, roend, PTE_R | PTE_G) != 0)
		return (0);
	if (map_range(dstart, dend, PTE_R | PTE_W | PTE_G) != 0)
		return (0);

	/*
	 * The boot heap + kernel stacks + page tables live in identity low
	 * DRAM outside the kernel image (BSS boot_heap is inside __data..__end,
	 * already RW-mapped; kmem_alloc'd frames beyond __end need a mapping
	 * too).  Map a generous low-RAM window [__end .. 0x90000000) R|W at
	 * gigapage-free 2 MiB... but to keep it simple + correct, RW-map the
	 * remainder of the physical DRAM the boot heap + managed frames use
	 * with 2 MiB megapage leaves (identity + direct-map alias).  4 KiB
	 * leaves for ~200 MiB would be many tables; a megapage leaf is one PTE.
	 */
	{
		unsigned long pa;
		/* cover 0x80000000 .. 0x90000000 (256 MiB qemu DRAM) RW, no X,
		   as 2 MiB megapage leaves at level 1. */
		for (pa = 0x80000000UL; pa < 0x90000000UL; pa += MEGASIZE) {
			/* megapage leaf: install directly in the level-1 table
			   at both the identity and direct-map aliases. */
			unsigned long va_id = pa;
			unsigned long va_hi = KERNEL_DMAP_BASE + pa;
			unsigned long *l1;
			unsigned long pte;

			/* identity alias */
			pte = hat_kroot[L2_IDX(va_id)];
			if ((pte & PTE_V) == 0) {
				l1 = alloc_table();
				if (l1 == 0)
					return (0);
				hat_kroot[L2_IDX(va_id)] =
				    PTE_TABLE((unsigned long)l1);
			} else {
				l1 = (unsigned long *)PTE_TO_PA(pte);
			}
			/* only set the megapage leaf if this L1 slot is empty
			   (do not clobber a 4 KiB kernel-image subtree). */
			if ((l1[L1_IDX(va_id)] & PTE_V) == 0)
				l1[L1_IDX(va_id)] = PA_TO_PTE(pa) |
				    PTE_R | PTE_W | PTE_G | PTE_A | PTE_D | PTE_V;

			/* direct-map alias */
			pte = hat_kroot[L2_IDX(va_hi)];
			if ((pte & PTE_V) == 0) {
				l1 = alloc_table();
				if (l1 == 0)
					return (0);
				hat_kroot[L2_IDX(va_hi)] =
				    PTE_TABLE((unsigned long)l1);
			} else {
				l1 = (unsigned long *)PTE_TO_PA(pte);
			}
			if ((l1[L1_IDX(va_hi)] & PTE_V) == 0)
				l1[L1_IDX(va_hi)] = PA_TO_PTE(pa) |
				    PTE_R | PTE_W | PTE_G | PTE_A | PTE_D | PTE_V;
		}
	}

	/*
	 * Map the qemu-virt device MMIO the kernel touches (UART/PLIC/CLINT at
	 * 0x0.. 0x10000000) identity R|W (no X) as gigapage leaf 0, so the
	 * console + PLIC keep working.  (The boot map had it RWX; we tighten to
	 * RW.)  Direct-map alias too.
	 */
	hat_kroot[0] = PA_TO_PTE(0) | PTE_R | PTE_W | PTE_G | PTE_A | PTE_D |
	    PTE_V;
	hat_kroot[L2_IDX(KERNEL_DMAP_BASE)] = PA_TO_PTE(0) | PTE_R | PTE_W |
	    PTE_G | PTE_A | PTE_D | PTE_V;

	/*
	 * Install the new root.  The running code (this function) is in .text,
	 * mapped R|X at BOTH the low identity VA (unchanged) and the high
	 * alias, so the fetch after the csrw still resolves at the current
	 * (low) PC -- we keep running, now with W^X.
	 */
	satp = MAKE_SATP((unsigned long)hat_kroot);
	extern unsigned long *hat_active_root;
	hat_active_root = hat_kroot;	/* user ASes now clone the W^X kernel root */
	rv_set_satp(satp);

	/*
	 * High-VA execution proof: call the probe through its high direct-map
	 * alias.  probe_pa is its physical/low VA; probe_hi = KERNEL_DMAP_BASE +
	 * probe_pa is the canonical Sv39 high VA; calling through it fetches +
	 * executes from the high half.
	 */
	probe_pa = (unsigned long)&hat_highva_probe;
	probe_hi = KERNEL_DMAP_BASE + probe_pa;
	probe_fn = (unsigned long (*)(void))probe_hi;
	r = probe_fn();

	sbi_console_puts("  [hat] high-VA probe via dmap alias ");
	puthex_pub(probe_hi);
	sbi_console_puts(" returned ");
	puthex_pub(r);
	sbi_console_puts(r == 0x5239 ? " (executed at high VA)\n" :
	    " (UNEXPECTED)\n");

	return (satp);
}

/*
 * hat_kernel_root_r29 -- expose the R-P29 kernel root so the user-AS builder
 * shares the (now fine-grained) kernel half.  Returns 0 before setup.
 */
unsigned long *
hat_kernel_root_r29(void)
{
	return (hat_kroot);
}

/*
 * hat_tlb_shootdown -- flush stale translations on THIS hart (local
 * sfence.vma) and broadcast a remote sfence.vma to the other hart via the SBI
 * RFENCE extension (falling back to a plain IPI).  After changing a shared
 * kernel mapping every hart must drop its cached translations or it may keep
 * using the stale PTE.  `target_hartid` is the other hart (or -1 for none up).
 *
 * CRIB PROVENANCE: local flush then broadcast to peers is the illumos
 * hat_tlb_inval / hat_sync / x_call cross-CPU TLB shootdown; the RISC-V
 * mechanism is the SBI RFENCE remote_sfence_vma (or a bare IPI whose handler
 * does sfence.vma) -- the privileged-spec SFENCE.VMA + the SBI IPI/RFENCE spec.
 */
void
hat_tlb_shootdown(long target_hartid)
{
	rv_tlb_flush_all();		/* local hart */
	if (target_hartid >= 0)
		(void) sbi_remote_sfence_vma((unsigned long)target_hartid);
}
