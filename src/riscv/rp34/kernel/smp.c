/*
 * smp.c -- R-P28 sub-task 3: SMP secondary-hart bring-up via the SBI HSM
 * extension + a shared, lock-protected work runq that BOTH harts drain.
 *
 * On qemu-virt with -smp 2 OpenSBI hands the S-mode kernel payload to the boot
 * hart (hart 0); the other hart sits in the SBI HSM STOPPED state.  smp_start()
 * (called on the boot hart) uses the SBI HSM hart_start ecall to launch the
 * secondary at _secondary_start (locore.S) with the shared kernel satp as the
 * opaque argument; the secondary sets up its stack + trap vector + address
 * space and calls secondary_main(hartid), which -- like the boot hart's
 * smp_run_shared_runq() -- pulls work items off ONE shared queue guarded by a
 * spinlock.  Because both harts drain the same queue concurrently, the work
 * items are executed across BOTH harts; each item prints the hartid that ran
 * it, so the boot log shows two DISTINCT hartids executing -- the SMP proof.
 *
 * The spinlock is a test-and-set over an amoswap.w (RISC-V A extension); the
 * per-hart online counter + the barrier the boot hart spins on until the
 * secondary reports in are the AP-start handshake.
 *
 * CRIB PROVENANCE: the HSM hart_start AP bring-up is the SBI spec (HSM) mapped
 * onto the illumos mp_startup / i86pc mach_cpu_start + BSD riscv cpu_hatch
 * secondary-CPU-start sequence (set stack/pagetable/trap-vector, then enter the
 * dispatcher); the shared runq + a dispatch lock is the illumos disp_lock /
 * cpu_t shared dispatch-queue model reduced to one global runq + one spinlock;
 * the amoswap.w test-and-set spinlock is the RISC-V A-extension + the illumos
 * mutex/lock_set spin primitive reduced to a raw byte lock.
 */

#include "sbi.h"
#include "mmu_riscv.h"	/* KVTOP: hart_start entry needs a PHYSICAL address */

extern void putdec_pub(unsigned long v);
extern void _secondary_start(void);
extern unsigned long rv_get_satp(void);

/* ---- a raw spinlock (amoswap.w test-and-set) ------------------------ */
static volatile int runq_lock;

static void
spin_lock(volatile int *l)
{
	int prev;
	do {
		__asm__ __volatile__("amoswap.w.aq %0, %2, %1"
		    : "=r"(prev), "+A"(*l)
		    : "r"(1)
		    : "memory");
	} while (prev != 0);
}

static void
spin_unlock(volatile int *l)
{
	__asm__ __volatile__("amoswap.w.rl zero, zero, %0"
	    : "+A"(*l) :: "memory");
}

/* ---- the shared work runq ------------------------------------------- */
/*
 * A work item is just an id; "running" it prints which hart drained it.  This
 * stands in for a shared dispatch queue of runnable threads -- the point is
 * that BOTH harts pull from ONE queue under ONE lock, so the items are split
 * across the two CPUs.
 */
#define	NWORK	12
static volatile int work_next;			/* next unclaimed item */
static volatile int work_done;			/* items completed */
static volatile int hart_ran[2];		/* items each hart ran */

/*
 * take_work -- pull the next work item off the shared queue under the lock.
 * Returns the item id, or -1 when the queue is empty.
 */
static int
take_work(void)
{
	int id;
	spin_lock(&runq_lock);
	if (work_next < NWORK)
		id = work_next++;
	else
		id = -1;
	spin_unlock(&runq_lock);
	return (id);
}

/*
 * run_work -- drain the shared queue on the calling hart.  Each item prints the
 * hartid running it; a short delay spreads the work so both harts get some.
 */
static void
run_work(unsigned long hartid)
{
	int id;

	while ((id = take_work()) >= 0) {
		volatile unsigned long d;

		spin_lock(&runq_lock);
		sbi_console_puts("    [hart ");
		putdec_pub(hartid);
		sbi_console_puts("] ran work item ");
		putdec_pub((unsigned long)id);
		sbi_console_puts("\n");
		if (hartid < 2)
			hart_ran[hartid]++;
		work_done++;
		spin_unlock(&runq_lock);

		/* spin a little so the other hart also claims items. */
		for (d = 0; d < 200000; d++)
			;
	}
}

/*
 * secondary_main -- the C entry the secondary hart reaches from
 * _secondary_start (locore.S) after it has its stack + trap vector + the
 * shared kernel address space.  Report the hartid (proving a DISTINCT hart is
 * executing), then drain the shared runq alongside the boot hart.
 */
volatile int secondary_online;

void
secondary_main(unsigned long hartid)
{
	spin_lock(&runq_lock);
	sbi_console_puts("  [smp] SECONDARY hart online: hartid=");
	putdec_pub(hartid);
	sbi_console_puts(" (entered the shared scheduler)\n");
	spin_unlock(&runq_lock);

	secondary_online = 1;		/* handshake: tell the boot hart */

	run_work(hartid);

	/*
	 * R-P30: STOP this hart (return to the HSM STOPPED state) so a later
	 * phase (the R-P30.2 TS/RT scheduler) can restart it via sbi_hart_start.
	 */
	sbi_hart_stop();
	for (;;)
		__asm__ __volatile__("wfi");
}

/*
 * smp_start -- R-P28 sub-task 3 driver (boot hart).  Start the secondary hart
 * via SBI HSM hart_start, wait for it to report online, then BOTH harts drain
 * the shared work runq.  The boot log shows two distinct hartids executing
 * items -- procs running on BOTH harts.
 */
void
smp_start(unsigned long boot_hartid)
{
	unsigned long sec = boot_hartid ^ 1;	/* the other hart (0<->1) */
	/*
	 * R-P30: the boot hart now runs on the identity-FREE W^X kernel root, so
	 * we CANNOT hand rv_get_satp() to the secondary -- it starts at its
	 * PHYSICAL entry (paging off) and its first post-satp fetch is at the
	 * physical PC, which the W^X root does not map.  Hand it the
	 * identity-bearing BOOT root (hat_boot_root_satp): the secondary survives
	 * its satp flip, jumps to the high continuation, and runs the shared
	 * kernel mappings from the boot root.
	 */
	extern unsigned long hat_boot_root_satp(void);
	unsigned long ksatp = hat_boot_root_satp();
	long err;
	volatile unsigned long spin;

	sbi_console_puts("\n");
	sbi_console_puts("[R-P28.3] SMP: bring up a secondary hart via SBI HSM "
	    "hart_start; shared runq on 2 harts\n");
	sbi_console_puts("----- SMP proof output -----\n");
	sbi_console_puts("  [smp] boot hartid=");
	putdec_pub(boot_hartid);
	sbi_console_puts("; starting secondary hartid=");
	putdec_pub(sec);
	sbi_console_puts(" at _secondary_start via SBI HSM\n");

	err = sbi_hart_start(sec, KVTOP((unsigned long)_secondary_start), ksatp);
	if (err != 0) {
		sbi_console_puts("  [smp] sbi_hart_start FAILED (err=");
		putdec_pub((unsigned long)(-err));
		sbi_console_puts("); SMP not available -- continuing UP\n");
		sbi_console_puts("----- end SMP proof output -----\n");
		return;
	}

	/* wait for the secondary to report online (bounded spin). */
	for (spin = 0; spin < 200000000UL && secondary_online == 0; spin++)
		;
	if (secondary_online == 0) {
		sbi_console_puts("  [smp] secondary did not come online "
		    "(timeout) -- continuing UP\n");
		sbi_console_puts("----- end SMP proof output -----\n");
		return;
	}

	/* both harts now drain the shared runq. */
	run_work(boot_hartid);

	/* wait for all work to complete on both harts. */
	for (spin = 0; spin < 200000000UL && work_done < NWORK; spin++)
		;

	sbi_console_puts("----- end SMP proof output -----\n");
	sbi_console_puts("  [smp] work items run: hart0=");
	putdec_pub((unsigned long)hart_ran[0]);
	sbi_console_puts(" hart1=");
	putdec_pub((unsigned long)hart_ran[1]);
	sbi_console_puts("\n");
	if (hart_ran[0] > 0 && hart_ran[1] > 0)
		sbi_console_puts("[R-P28.3] SMP PROVEN: work ran on BOTH harts "
		    "(two distinct hartids executed).\n");
	else
		sbi_console_puts("[R-P28.3] SMP: only one hart drained the runq "
		    "(secondary started but did not share work).\n");
}
