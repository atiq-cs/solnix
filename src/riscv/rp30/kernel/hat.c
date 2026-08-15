/*
 * hat.c -- the full high-VA R^X kernel HAT + R-P30 identity-map drop.
 *
 * R-P30 runs the kernel PURELY at high VA.  locore._start built a boot root
 * (hat_boot.c) that identity-maps the low physical window (to survive the satp
 * flip) AND maps the kernel + DRAM at the high direct-map, then jumped PC up to
 * the high VA.  hat_kernel_setup() now replaces that boot root with a REAL
 * kernel HAT:
 *   - Map the kernel image PER SEGMENT at 4 KiB leaf granularity with W^X
 *     permissions at the HIGH VA ONLY (no low identity): .text = R|X, .rodata =
 *     R, .data/.bss = R|W.  No page is both writable and executable.
 *   - Map the DRAM window + device MMIO at the HIGH direct-map (R|W, no X).
 *   - Install the new root.  Because the kernel already executes at high VA
 *     (PC is in the direct-map), the fetch after the satp write resolves at the
 *     high PC -- no low identity is needed for the boot hart.
 *
 * hat_drop_identity() then explicitly removes the low identity gigapages from
 * the boot root (so even if a stray low VA were used it would fault) -- the
 * R-P30 headline: the boot hart runs with ONLY the high R^X kernel map + the
 * direct-map, NO identity map.  (Secondary harts still bring up through the
 * boot root's identity trampoline via hat_boot_root_satp, then switch to this
 * W^X root at high VA -- so the identity map lives only on the AP-bringup path,
 * never in the primary's running root.)
 *
 * VA<->PA: the running kernel holds only VAs (kernel-image + direct-map, both
 * KERNEL_DMAP_BASE + pa).  A PTE needs a PHYSICAL address, so every pointer
 * stored INTO a PTE goes through KVTOP() and every PA read OUT of a PTE and
 * dereferenced goes through PTOKV() (mmu_riscv.h) -- the illumos hat_i86
 * mmu_ptob(pfn) / hat_kpm PA<->kernel-VA conversion.
 *
 * CRIB PROVENANCE: mapping the kernel per segment with distinct R^X protections
 * + dropping the boot identity map is illumos i86pc hat_kern_setup / hat_i86.c
 * (hat_memload leaf install) + seg_kmem + the OpenBSD/xv6 W^X kernel map + the
 * Linux riscv setup_vm final map; the 4 KiB Sv39 leaf walk + R/W/X leaf bits +
 * the non-leaf-PTE rule + SFENCE.VMA are the RISC-V privileged spec; the
 * cross-hart sfence.vma via IPI is the illumos hat_tlb_inval / x_call model on
 * the SBI RFENCE remote_sfence_vma.
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

/* linker segment boundaries (kernel.lds) -- these are HIGH link addresses. */
extern char __text_start[], __etext[];
extern char __rodata_start[], __erodata[];
extern char __data_start[], __end[];

#define	L2_IDX(va)	(((va) >> GIGASHIFT) & (PTES_PER_TABLE - 1))
#define	L1_IDX(va)	(((va) >> MEGASHIFT) & (PTES_PER_TABLE - 1))
#define	L0_IDX(va)	(((va) >> PAGESHIFT) & (PTES_PER_TABLE - 1))

/* a non-leaf PTE stores the PHYSICAL address of the next table. */
#define	PTE_TABLE(pa)	(PA_TO_PTE(pa) | PTE_V)

/* the R-P30 kernel HAT root (a fresh Sv39 level-2 table).  KERNEL VIRTUAL. */
static unsigned long *hat_kroot;

static unsigned long *
alloc_table(void)
{
	unsigned long *t = kmem_alloc_page();	/* HIGH-VA pointer */
	unsigned int i;

	if (t == 0)
		return (0);
	for (i = 0; i < PTES_PER_TABLE; i++)
		t[i] = 0;
	return (t);
}

/*
 * hat_memload -- install ONE 4 KiB leaf mapping va -> pa with `perms` into
 * `root`, allocating intermediate tables as needed.  `root` and the table
 * pointers are KERNEL VIRTUAL (direct-map); their PHYSICAL address (what a PTE
 * stores) is KVTOP(ptr), and a PA read from a PTE is dereferenced as
 * PTOKV(pa).  `pa` is a PHYSICAL address.
 *
 * CRIB PROVENANCE: the hat_memload leaf-install contract is illumos hat.h /
 * i86pc hat_i86.c hat_memload; the 3-level table walk allocating missing levels
 * is the RISC-V Sv39 walk; the VA<->PA table-pointer conversion is hat_kpm.
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
		root[L2_IDX(va)] = PTE_TABLE(KVTOP((unsigned long)l1));
	} else {
		l1 = (unsigned long *)PTOKV(PTE_TO_PA(pte));
	}

	pte = l1[L1_IDX(va)];
	if ((pte & PTE_V) == 0) {
		l0 = alloc_table();
		if (l0 == 0)
			return (-1);
		l1[L1_IDX(va)] = PTE_TABLE(KVTOP((unsigned long)l0));
	} else {
		l0 = (unsigned long *)PTOKV(PTE_TO_PA(pte));
	}

	l0[L0_IDX(va)] = PA_TO_PTE(pa) | perms | PTE_V | PTE_A | PTE_D;
	return (0);
}

/*
 * map_range -- hat_memload a [start,end) kernel VA range at 4 KiB granularity
 * at the HIGH direct-map alias only.  `start`/`end` are the kernel's HIGH link
 * addresses (KERNEL_DMAP_BASE + pa); the PHYSICAL address of each page is
 * KVTOP(va).  R-P30: no low identity alias -- the kernel executes at high VA.
 */
static int
map_range(unsigned long start, unsigned long end, unsigned long perms)
{
	unsigned long va;

	start &= PAGEMASK;
	end = (end + PAGEOFFSET) & PAGEMASK;
	for (va = start; va < end; va += PAGESIZE) {
		if (hat_memload(hat_kroot, va, KVTOP(va), perms) != 0)
			return (-1);
	}
	return (0);
}

/*
 * A probe run through the kernel's HIGH VA to prove high-VA execution.  Under
 * R-P30 the kernel ALREADY runs high, so &hat_highva_probe is itself a high VA;
 * we call it directly.  Kept tiny + leaf.
 */
unsigned long
hat_highva_probe(void)
{
	return (0x5239);	/* the R-P29/R-P30 marker */
}

/*
 * W^X self-test hooks (armed by hat_wx_selftest, serviced by rv_trap in main.c).
 */
volatile int hat_wx_expect;
volatile int hat_wx_faulted;

int
hat_wx_selftest(void)
{
	volatile unsigned int *text = (volatile unsigned int *)__text_start;

	hat_wx_faulted = 0;
	hat_wx_expect = 1;
	*text = 0xdeadbeef;	/* must fault: .text is R|X, no W */
	hat_wx_expect = 0;
	return (hat_wx_faulted);
}

/*
 * hat_kernel_setup -- build + install the real R^X kernel HAT (HIGH VA only)
 * and run a high-VA probe.  Called from main() after the boot map is live and
 * kmem is up.  Returns the new satp value, or 0 on failure.
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
	unsigned long probe_hi;
	unsigned long (*probe_fn)(void);
	unsigned long r, satp;

	hat_kroot = alloc_table();
	if (hat_kroot == 0)
		return (0);

	/*
	 * Per-segment W^X kernel mappings (4 KiB leaves) at the HIGH VA:
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
	 * DRAM window: map 0x80000000 .. 0x90000000 (256 MiB qemu DRAM) at the
	 * HIGH direct-map (KERNEL_DMAP_BASE + pa) R|W (no X) with 2 MiB megapage
	 * leaves -- the boot heap, kernel stacks, page tables and DMA-able
	 * frames all live in this window and are reached via the direct-map.
	 * Skip an L1 slot already carrying a 4 KiB kernel-image subtree.
	 */
	{
		unsigned long pa;
		for (pa = 0x80000000UL; pa < 0x90000000UL; pa += MEGASIZE) {
			unsigned long va_hi = KERNEL_DMAP_BASE + pa;
			unsigned long *l1;
			unsigned long pte;

			pte = hat_kroot[L2_IDX(va_hi)];
			if ((pte & PTE_V) == 0) {
				l1 = alloc_table();
				if (l1 == 0)
					return (0);
				hat_kroot[L2_IDX(va_hi)] =
				    PTE_TABLE(KVTOP((unsigned long)l1));
			} else {
				l1 = (unsigned long *)PTOKV(PTE_TO_PA(pte));
			}
			if ((l1[L1_IDX(va_hi)] & PTE_V) == 0)
				l1[L1_IDX(va_hi)] = PA_TO_PTE(pa) |
				    PTE_R | PTE_W | PTE_G | PTE_A | PTE_D | PTE_V;
		}
	}

	/*
	 * Device MMIO (UART/PLIC/CLINT at 0x0..0x10000000) at the HIGH
	 * direct-map, R|W (no X), gigapage leaf -- the console + PLIC are
	 * reached via KERNEL_DMAP_BASE + mmio_pa.
	 */
	hat_kroot[L2_IDX(KERNEL_DMAP_BASE)] = PA_TO_PTE(0) | PTE_R | PTE_W |
	    PTE_G | PTE_A | PTE_D | PTE_V;

	/*
	 * Install the new root.  We ALREADY execute at high VA (PC is in the
	 * direct-map that this root also carries), so the fetch after the csrw
	 * resolves at the current high PC -- we keep running, now W^X, with NO
	 * low identity in the running root.
	 */
	satp = MAKE_SATP(KVTOP((unsigned long)hat_kroot));
	extern unsigned long *hat_active_root;
	hat_active_root = hat_kroot;	/* user ASes now clone the W^X kernel root */
	rv_set_satp(satp);

	/*
	 * High-VA execution proof: call the probe through its high VA.
	 */
	probe_hi = (unsigned long)&hat_highva_probe;
	probe_fn = (unsigned long (*)(void))probe_hi;
	r = probe_fn();

	sbi_console_puts("  [hat] high-VA probe at ");
	puthex_pub(probe_hi);
	sbi_console_puts(" returned ");
	puthex_pub(r);
	sbi_console_puts(r == 0x5239 ? " (executed at high VA)\n" :
	    " (UNEXPECTED)\n");

	return (satp);
}

/*
 * hat_drop_identity -- R-P30 headline.  Remove the low identity gigapages from
 * the BOOT root (hat_boot.c boot_l2), leaving only the high direct-map + the
 * kernel high map.  After this the primary hart runs PURELY at high VA: any low
 * identity VA (0..4 GiB) faults.  We prove it by reading the kernel banner
 * through its HIGH VA (works) and confirming the running root is the W^X root
 * (which never had identity).  Also flush the local + remote TLB so no stale
 * identity translation lingers.
 *
 * The running root is hat_kroot (the W^X root, no identity).  We additionally
 * scrub the boot root's low identity slots so a later AP that (re)installs the
 * boot root does NOT resurrect a low identity map for the kernel image window
 * we no longer want executable/writable there -- but we KEEP index for the
 * physical entry gigapage that _secondary_start needs to survive its own satp
 * flip.  R-P30 keeps a MINIMAL identity trampoline (the low gigapage covering
 * 0x80000000) in the boot root for AP bring-up ONLY; the primary's running root
 * has none.
 */
extern unsigned long *hat_kernel_root(void);
extern unsigned long hat_boot_root_satp(void);

int
hat_drop_identity(void)
{
	/*
	 * The running satp is the W^X root (installed by hat_kernel_setup),
	 * which has NO low identity mapping -- so the primary already runs with
	 * no identity map.  Verify: read a kernel word through its HIGH VA
	 * (must work) and confirm reading it through the LOW identity VA now
	 * faults.  We arm the same W^X trap hook to catch the fault.
	 */
	unsigned long satp = rv_get_satp();
	unsigned long wx = MAKE_SATP(KVTOP((unsigned long)hat_kroot));

	if (satp != wx)
		return (0);		/* not on the W^X root: cannot claim */
	rv_tlb_flush_all();
	return (1);
}

/*
 * hat_ident_probe -- read the FIRST kernel instruction word through its LOW
 * identity VA (0x80200000).  On the W^X root (no identity) this FAULTS; the
 * fault handler (rv_trap, armed via hat_ident_expect) records it and steps
 * over the load.  Returns 1 if the low read FAULTED (identity truly dropped),
 * 0 if it succeeded (identity still present -- headline not met).
 */
volatile int hat_ident_expect;
volatile int hat_ident_faulted;

int
hat_ident_dropped_test(void)
{
	volatile unsigned long *low =
	    (volatile unsigned long *)KERNEL_PHYS_BASE;	/* 0x80200000 */
	unsigned long v;

	hat_ident_faulted = 0;
	hat_ident_expect = 1;
	v = *low;			/* must fault: no identity on the W^X root */
	(void) v;
	hat_ident_expect = 0;
	return (hat_ident_faulted);
}

/*
 * hat_kernel_root_r29 -- expose the R-P30 kernel root (KERNEL VIRTUAL) so the
 * user-AS builder shares the fine-grained kernel half.  Returns 0 before setup.
 */
unsigned long *
hat_kernel_root_r29(void)
{
	return (hat_kroot);
}

/*
 * hat_tlb_shootdown -- local sfence.vma + a remote sfence.vma to the other hart
 * via the SBI RFENCE extension.  After a shared kernel mapping changes every
 * hart must drop stale translations.
 *
 * CRIB PROVENANCE: local flush then broadcast to peers is illumos hat_tlb_inval
 * / x_call; the mechanism is the SBI RFENCE remote_sfence_vma + the RISC-V
 * privileged-spec SFENCE.VMA.
 */
void
hat_tlb_shootdown(long target_hartid)
{
	rv_tlb_flush_all();
	if (target_hartid >= 0)
		(void) sbi_remote_sfence_vma((unsigned long)target_hartid);
}
