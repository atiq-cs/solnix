/*
 * smp_wxroot.c -- R-P31.1 (the headline): SECONDARIES ON THE W^X ROOT.  Bring
 * up a secondary hart so it enables paging and then SWITCHES onto the primary's
 * identity-FREE W^X kernel root -- so that after boot NO identity map exists on
 * ANY running root, on ANY hart.  This completes the true-high-half kernel for
 * SMP: R-P30 dropped the identity map on the PRIMARY, but a secondary still
 * ran the shared kernel mappings from the identity-bearing BOOT root; R-P31
 * switches the secondary onto the W^X root (the primary's running root) and
 * then scrubs the boot root's identity window entirely.
 *
 * The bring-up (locore.S wx_ap_entry -> wx_ap_high):
 *   1. The secondary starts at its PHYSICAL entry (paging off).  It installs
 *      the BOOT root (a1) so its first post-satp fetch resolves -- this is the
 *      transient identity trampoline, used ONLY for the initial flip.
 *   2. It jumps to the HIGH VA continuation (wx_ap_high).  PC is now high.
 *   3. It calls hat_wxroot_satp() (a high-VA C call on the direct-map) and
 *      switches to the identity-FREE W^X root: csrw satp; sfence.vma.  The W^X
 *      root maps the kernel image (high) + the direct-map, so the fetch after
 *      the satp write resolves -- and from here the secondary runs with NO
 *      identity map, exactly like the primary.
 *   4. wx_secondary_main() PROVES it: the running satp equals the W^X root satp,
 *      and a read of the first kernel word through its LOW identity VA
 *      (0x80200000) FAULTS (no identity on the W^X root).  Then both harts drain
 *      the shared runq (SMP work still splits across harts).
 *
 * After both harts are on the W^X root, the boot root's low identity window is
 * scrubbed (hat_boot_drop_identity) so no identity map survives anywhere.
 *
 * CRIB PROVENANCE: an AP enabling its MMU to the SHARED kernel hat (not a
 * private/identity root) is illumos mp_startup (uts/i86pc/os/mp_startup.c: the
 * secondary CPU switches to the kernel's hat page table before entering the
 * dispatcher); switching from a transient trampoline root to the final
 * identity-free root after the high jump is Linux arch/riscv/kernel/head.S
 * secondary_start_sbi + relocate_enable_mmu (trampoline_pg_dir -> swapper_pg_dir);
 * the shared runq drained by two harts + the amoswap.w spinlock is the R-P28
 * smp.c model + the RISC-V A extension; the low-identity-read-faults proof is
 * the R-P30 hat_ident_dropped_test applied on the secondary.
 */

#include "sbi.h"
#include "mmu_riscv.h"

extern void putdec_pub(unsigned long v);
extern void puthex_pub(unsigned long v);
extern void wx_ap_entry(void);
extern long sbi_hart_start(unsigned long, unsigned long, unsigned long);
extern unsigned long hat_boot_root_satp(void);
extern unsigned long hat_wxroot_satp(void);
extern unsigned long rv_get_satp(void);
extern void hat_boot_drop_identity(void);

/* AP-only identity-drop self-test hooks, serviced by rv_trap (main.c). */
extern volatile int hat_ap_ident_expect;
extern volatile int hat_ap_ident_faulted;

/* ---- a raw spinlock (amoswap.w test-and-set) ------------------------ */
static volatile int wq_lock;

static void
spin_lock(volatile int *l)
{
	int prev;
	do {
		__asm__ __volatile__("amoswap.w.aq %0, %2, %1"
		    : "=r"(prev), "+A"(*l) : "r"(1) : "memory");
	} while (prev != 0);
}
static void
spin_unlock(volatile int *l)
{
	__asm__ __volatile__("amoswap.w.rl zero, zero, %0"
	    : "+A"(*l) :: "memory");
}

/* ---- the shared work runq (SMP-split proof, like R-P28 smp.c) -------- */
#define	NWORK	8
static volatile int wq_next;
static volatile int wq_done;
static volatile int wq_hart_ran[2];

static int
take_work(void)
{
	int id;
	spin_lock(&wq_lock);
	id = (wq_next < NWORK) ? wq_next++ : -1;
	spin_unlock(&wq_lock);
	return (id);
}

static void
run_work(unsigned long hartid)
{
	int id;
	while ((id = take_work()) >= 0) {
		volatile unsigned long d;
		spin_lock(&wq_lock);
		sbi_console_puts("    [hart ");
		putdec_pub(hartid);
		sbi_console_puts("] ran work item ");
		putdec_pub((unsigned long)id);
		sbi_console_puts("\n");
		if (hartid < 2)
			wq_hart_ran[hartid]++;
		wq_done++;
		spin_unlock(&wq_lock);
		for (d = 0; d < 200000; d++)
			;
	}
}

/*
 * ap_ident_faults -- on the SECONDARY hart: read the first kernel word through
 * its LOW identity VA (0x80200000).  On the W^X root (no identity) this FAULTS;
 * rv_trap (armed via hat_ap_ident_expect) records it + steps sepc past the load.
 * Returns 1 if the low read FAULTED (identity truly gone on this hart's running
 * root), 0 if it succeeded.
 */
static int
ap_ident_faults(void)
{
	volatile unsigned long *low =
	    (volatile unsigned long *)KERNEL_PHYS_BASE;	/* 0x80200000 */
	unsigned long v;

	hat_ap_ident_faulted = 0;
	hat_ap_ident_expect = 1;
	v = *low;			/* must fault: no identity on the W^X root */
	(void) v;
	hat_ap_ident_expect = 0;
	return (hat_ap_ident_faulted);
}

/* set by the secondary: 1 iff it verified it runs on the W^X root, no identity. */
volatile int wx_secondary_online;
volatile int wx_secondary_on_wxroot;
volatile int wx_secondary_ident_faulted;
static volatile unsigned long wx_secondary_satp;

/*
 * wx_secondary_main -- the C entry the secondary reaches from wx_ap_high after
 * it has switched onto the identity-FREE W^X root.  Prove it, then drain the
 * shared runq alongside the primary.
 */
void
wx_secondary_main(unsigned long hartid)
{
	unsigned long satp = rv_get_satp();
	unsigned long wx = hat_wxroot_satp();
	int faulted;

	wx_secondary_satp = satp;
	wx_secondary_on_wxroot = (satp == wx);
	faulted = ap_ident_faults();
	wx_secondary_ident_faulted = faulted;

	spin_lock(&wq_lock);
	sbi_console_puts("  [R-P31.1] SECONDARY hart online: hartid=");
	putdec_pub(hartid);
	sbi_console_puts("\n    running satp=");
	puthex_pub(satp);
	sbi_console_puts(satp == wx ?
	    " == W^X root satp (identity-FREE root)\n" :
	    " != W^X root satp (STILL on the boot/identity root!)\n");
	sbi_console_puts(faulted ?
	    "    read of _start via LOW identity VA 0x80200000: FAULTED "
	    "-- secondary runs purely high-VA (no identity)\n" :
	    "    read of _start via LOW identity VA 0x80200000: SUCCEEDED "
	    "-- identity still present on the secondary!\n");
	spin_unlock(&wq_lock);

	wx_secondary_online = 1;		/* handshake to the boot hart */

	run_work(hartid);

	/* park STARTED (not STOP) so later cross-hart fences still reach us. */
	for (;;)
		__asm__ __volatile__("wfi");
}

/*
 * run_secondaries_wxroot -- R-P31.1 driver (boot hart).  Start the secondary at
 * wx_ap_entry with the BOOT root as the transient flip trampoline; wait for it
 * to switch onto the W^X root + report; both harts drain the shared runq; then
 * scrub the boot root's identity window so NO identity map survives anywhere.
 */
void
run_secondaries_wxroot(unsigned long boot_hartid)
{
	unsigned long sec = boot_hartid ^ 1;
	unsigned long bootsatp = hat_boot_root_satp();	/* transient flip root */
	unsigned long wxsatp = hat_wxroot_satp();
	long err;
	volatile unsigned long spin;

	sbi_console_puts("\n");
	sbi_console_puts("[R-P31.1] secondaries on the W^X root: bring up a "
	    "secondary hart + switch it onto the identity-FREE W^X kernel root\n");
	sbi_console_puts("----- R-P31.1 secondary-on-W^X-root proof output -----\n");
	sbi_console_puts("  [smp] boot hart ");
	putdec_pub(boot_hartid);
	sbi_console_puts(" runs on the W^X root satp=");
	puthex_pub(rv_get_satp());
	sbi_console_puts("\n  [smp] W^X root satp=");
	puthex_pub(wxsatp);
	sbi_console_puts("; starting secondary ");
	putdec_pub(sec);
	sbi_console_puts(" at wx_ap_entry (boot root = transient flip trampoline)\n");

	err = sbi_hart_start(sec, KVTOP((unsigned long)wx_ap_entry), bootsatp);
	if (err != 0) {
		sbi_console_puts("  [smp] sbi_hart_start FAILED (err=");
		putdec_pub((unsigned long)(-err));
		sbi_console_puts("); continuing UP\n");
		sbi_console_puts("----- end R-P31.1 proof output -----\n");
		return;
	}

	for (spin = 0; spin < 200000000UL && wx_secondary_online == 0; spin++)
		;
	if (wx_secondary_online == 0) {
		sbi_console_puts("  [smp] secondary did not come online "
		    "(timeout) -- continuing UP\n");
		sbi_console_puts("----- end R-P31.1 proof output -----\n");
		return;
	}

	/* both harts drain the shared runq -- SMP work still splits. */
	run_work(boot_hartid);
	for (spin = 0; spin < 200000000UL && wq_done < NWORK; spin++)
		;

	sbi_console_puts("----- end R-P31.1 proof output -----\n");
	sbi_console_puts("  [smp] work items run: hart0=");
	putdec_pub((unsigned long)wq_hart_ran[0]);
	sbi_console_puts(" hart1=");
	putdec_pub((unsigned long)wq_hart_ran[1]);
	sbi_console_puts("\n");

	/*
	 * Both harts are on the W^X root now.  Scrub the boot root's low
	 * identity window entirely: no identity map survives on ANY root.
	 */
	hat_boot_drop_identity();
	sbi_console_puts("  [smp] boot-root identity window scrubbed "
	    "(hat_boot_drop_identity) -- no identity map anywhere\n");

	if (wx_secondary_on_wxroot && wx_secondary_ident_faulted &&
	    wq_hart_ran[0] > 0 && wq_hart_ran[1] > 0)
		sbi_console_puts("[R-P31.1] SECONDARY-ON-W^X-ROOT PROVEN: the "
		    "secondary runs the identity-FREE W^X root (low identity "
		    "read faults), no identity map anywhere, SMP work on 2 "
		    "harts.\n");
	else
		sbi_console_puts("[R-P31.1] secondary-on-W^X-root INCOMPLETE.\n");
}
