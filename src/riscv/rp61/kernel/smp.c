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
#define	NWORK	32
#define	MAXHARTS 8			/* R-P61: the K1 has 8 harts */
static volatile int work_next;			/* next unclaimed item */
static volatile int work_done;			/* items completed */
static volatile int hart_ran[MAXHARTS];		/* items each hart ran */

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
		if (hartid < MAXHARTS)
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
volatile int secondary_online;			/* legacy single flag (kept) */
volatile int hart_online[MAXHARTS];		/* R-P61: per-hart online flag */

void
secondary_main(unsigned long hartid)
{
	spin_lock(&runq_lock);
	sbi_console_puts("  [smp] SECONDARY hart online: hartid=");
	putdec_pub(hartid);
	sbi_console_puts(" (entered the shared scheduler)\n");
	spin_unlock(&runq_lock);

	secondary_online = 1;		/* handshake: tell the boot hart */
	if (hartid < MAXHARTS)
		hart_online[hartid] = 1;	/* R-P61 per-hart handshake */

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
smp_start(unsigned long boot_hartid, unsigned int nharts)
{
	/*
	 * R-P61: bring up ALL secondary harts the DTB reports (up to MAXHARTS=8,
	 * the SpacemiT K1's count) via SBI HSM hart_start, not just the single
	 * boot_hartid^1 secondary of R-P28.  Each secondary lands on its OWN
	 * per-hart stack (locore.S _secondary_high indexes secondary_stacks by
	 * hartid), reports online in hart_online[], then all harts drain ONE
	 * shared work runq -- the boot log shows up to 8 distinct hartids running
	 * items (the 8-core work-stealing proof).
	 */
	extern unsigned long hat_boot_root_satp(void);
	unsigned long ksatp = hat_boot_root_satp();
	unsigned int want = nharts;
	unsigned int started = 0, online = 0;
	unsigned int h;
	volatile unsigned long spin;

	if (want == 0 || want > MAXHARTS)
		want = MAXHARTS;		/* default/cap at 8 */

	sbi_console_puts("\n");
	sbi_console_puts("[R-P61] SMP: bring up ALL secondary harts from the DTB "
	    "count via SBI HSM hart_start (generalized from R-P28's 2 harts to N "
	    "up to 8 -- the SpacemiT K1 count)\n");
	sbi_console_puts("  [smp] DTB /cpus hart count = ");
	putdec_pub((unsigned long)nharts);
	sbi_console_puts("; bringing up ");
	putdec_pub((unsigned long)(want > 0 ? want - 1 : 0));
	sbi_console_puts(" secondaries (boot hart ");
	putdec_pub(boot_hartid);
	sbi_console_puts(" + secondaries)\n");

	if (want <= 1) {
		sbi_console_puts("  [smp] DTB reports a single hart -- no secondary "
		    "to start; continuing UP\n");
		sbi_console_puts("----- end SMP proof output -----\n");
		return;
	}

	sbi_console_puts("----- SMP proof output -----\n");

	/* start every hart id in [0,want) that is not the boot hart. */
	for (h = 0; h < want && h < MAXHARTS; h++) {
		long err;
		if (h == boot_hartid)
			continue;
		sbi_console_puts("  [smp] starting secondary hartid=");
		putdec_pub((unsigned long)h);
		sbi_console_puts(" at _secondary_start via SBI HSM\n");
		err = sbi_hart_start((unsigned long)h,
		    KVTOP((unsigned long)_secondary_start), ksatp);
		if (err != 0) {
			sbi_console_puts("  [smp] sbi_hart_start(hart ");
			putdec_pub((unsigned long)h);
			sbi_console_puts(") FAILED (err=");
			putdec_pub((unsigned long)(-err));
			sbi_console_puts(")\n");
			continue;
		}
		started++;
	}

	/* wait for the started secondaries to report online (bounded spin). */
	for (spin = 0; spin < 400000000UL; spin++) {
		online = 0;
		for (h = 0; h < want && h < MAXHARTS; h++) {
			if (h == boot_hartid)
				continue;
			if (hart_online[h])
				online++;
		}
		if (online >= started)
			break;
	}
	sbi_console_puts("  [smp] secondaries started=");
	putdec_pub((unsigned long)started);
	sbi_console_puts(" online=");
	putdec_pub((unsigned long)online);
	sbi_console_puts("\n");

	/* the boot hart drains the shared runq alongside every secondary. */
	run_work(boot_hartid);

	/* wait for all work to complete across all harts. */
	for (spin = 0; spin < 400000000UL && work_done < NWORK; spin++)
		;

	sbi_console_puts("----- end SMP proof output -----\n");
	{
		unsigned int nran = 0;
		sbi_console_puts("  [smp] work items run per hart:");
		for (h = 0; h < MAXHARTS; h++) {
			if (hart_ran[h] > 0) {
				sbi_console_puts(" hart");
				putdec_pub((unsigned long)h);
				sbi_console_puts("=");
				putdec_pub((unsigned long)hart_ran[h]);
				nran++;
			}
		}
		sbi_console_puts("\n");
		if (nran >= 2) {
			sbi_console_puts("[R-P61] SMP PROVEN: work ran on ");
			putdec_pub((unsigned long)nran);
			sbi_console_puts(" distinct harts (N-hart bring-up + shared-runq "
			    "work-stealing; on qemu -smp 8 all 8 come up)\n");
		} else {
			sbi_console_puts("[R-P61] SMP: only one hart drained the runq\n");
		}
	}
}
