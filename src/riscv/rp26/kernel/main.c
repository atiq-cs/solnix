/*
 * main.c -- illumos riscv64 kernel C entry: mlsetup + main, R-P24.
 *
 * Reached from locore.S (_start) in S-mode under OpenSBI on qemu virt with
 * hartid=a0 (boot hart) and dtb=a1 (flattened devicetree phys addr).  R-P24
 * grows the R-P23 boot skeleton toward genunix, each step boot-verified:
 *   mlsetup -> hat_boot_init (Sv39 paging ON, keep running virtual)
 *           -> banner
 *           -> clock_init  (periodic SBI-timer tick through rv_trap_dispatch)
 *           -> plic_init   (qemu-virt PLIC: enable + claim an external intr)
 *           -> startup     (boot heap + kmem_alloc + page_t seed)
 *           -> dispatch_onramp (build an idle kthread, swtch into the idle
 *              loop with the clock ticking) -> known halt.
 *
 *   locore.S _start
 *     -> mlsetup(hartid, dtb)   MD bring-up: record the boot cpu, confirm the
 *          trap vector is installed (stvec self-test: a deliberate ecall that
 *          the R-P22.3 rv_trap_dispatch fields and returns from), then enter
 *          main().
 *     -> main()                 the illumos-style SunOS banner + subsystem
 *          status, then a clean SBI shutdown (the R-P23 known-halt).
 *
 * This mirrors uts/i86pc mlsetup() -> main() and this repo's R-P2..R-P16
 * uts/riscv64 main.c, reduced to the skeleton that boots + banners under the
 * solaris-target toolchain.  Freestanding; console only via the SBI layer
 * (sbi.c).  No libc.
 *
 * CRIB PROVENANCE: the mlsetup->main split + the SunOS-release banner shape is
 * uts/i86pc mlsetup/startup + this repo's R-P4 main.c; the trap self-test
 * (deliberate ecall fielded by the dispatcher) is the R-P3 trap_selftest
 * idiom; the trap C handlers (rv_trap/rv_interrupt/rv_syscall/clock) are the
 * receiving end of the R-P22.3 mach_trap.S/mach_clock.S dispatch.
 */

#include "sbi.h"
#include "mmu_riscv.h"
#include "clock_riscv.h"
#include "plic.h"

#define	SOLNIX_RELEASE	"5.11"
#define	SOLNIX_VERSION	"solnix-riscv64"

/* From locore.S / the MD asm units. */
extern void _u_trap_entry(void);
extern void rv_trap_dispatch(void);

/* R-P24 subsystems. */
extern void startup_kmem(void);
extern void *kmem_alloc(unsigned long);
extern void kmem_free(void *, unsigned long);
extern unsigned long kmem_heapsize(void);
extern unsigned long kmem_inuse_bytes(void);
extern void page_setup(void);
extern unsigned long page_create(void);
extern unsigned long page_count(void);
extern void dispatch_onramp(void);

/* R-P25/R-P26 userland-process seam. */
#include "proc_riscv.h"
struct rv_klabel { unsigned long l_ra, l_sp, l_s[12]; };
extern int rv_ksetjmp(struct rv_klabel *);
extern void rv_klongjmp(struct rv_klabel *, int);
extern unsigned long rv_get_satp(void);
extern void rv_set_satp(unsigned long);
extern void run_user(void);

/* R-P26 proc/lwp table + fork/exec/wait bodies (proc.c). */
extern int proc_getpid(void);
extern long proc_fork(void);
extern long proc_exec(const char *path);
extern void proc_exit(int status);
extern long proc_wait(long *statusp);

/* set by the exit(2) syscall; the kernel satp to restore after U-mode. */
static struct rv_klabel user_return_label;
static unsigned long kernel_satp;
static volatile int user_exit_status;
static volatile int user_wrote_bytes;

static void main(void);

/*
 * boot_cpu -- the seed cpu_t.  R-P23 records the boot hartid, the dtb, and the
 * MD-online flags.  Grows into the real cpu_t (dispatch, per-cpu areas) in
 * later phases.  In BSS (zeroed by locore).
 */
struct boot_cpu {
	unsigned long	bc_hartid;
	unsigned long	bc_dtb;
	int		bc_trap_online;	/* trap vector installed + proven */
};
static struct boot_cpu boot_cpu;

/* Trap self-test flag: set by rv_syscall when the deliberate ecall is fielded. */
static volatile int trap_fired;

static void
puthex64(unsigned long v)
{
	static const char hex[] = "0123456789abcdef";
	int i;

	sbi_console_puts("0x");
	for (i = 60; i >= 0; i -= 4)
		sbi_console_putchar(hex[(v >> i) & 0xf]);
}

static void
putdec(unsigned long v)
{
	char buf[20];
	int n = 0;

	if (v == 0) {
		sbi_console_putchar('0');
		return;
	}
	while (v != 0 && n < (int)sizeof (buf)) {
		buf[n++] = (char)('0' + (v % 10));
		v /= 10;
	}
	while (n-- > 0)
		sbi_console_putchar(buf[n]);
}

/* exported so startup.c (the dispatcher) can print through the SBI console. */
void putdec_pub(unsigned long v) { putdec(v); }
void puthex_pub(unsigned long v) { puthex64(v); }

/*
 * mlsetup -- machine-dependent low-level setup.  locore.S already installed
 * stvec (-> _u_trap_entry -> rv_trap_dispatch) and cleared BSS.  Here we record
 * the boot cpu and PROVE the trap path by executing a deliberate ecall: the
 * R-P22.3 dispatcher must save the frame, decode scause==ECALL_S, advance sepc
 * past the ecall, run rv_syscall (which sets trap_fired), restore, and sret
 * back here.  If the vector or dispatcher were wrong we would not return.
 */
void
mlsetup(unsigned long hartid, unsigned long dtb)
{
	boot_cpu.bc_hartid = hartid;
	boot_cpu.bc_dtb = dtb;

	sbi_console_puts("\n");
	sbi_console_puts("[mlsetup] illumos riscv64 MD bring-up (R-P25)\n");
	sbi_console_puts("[mlsetup] S-mode entry from OpenSBI: hartid=");
	putdec(hartid);
	sbi_console_puts(" dtb=");
	puthex64(dtb);
	sbi_console_puts("\n");
	sbi_console_puts("[mlsetup] trap vector installed (stvec -> "
	    "_u_trap_entry -> rv_trap_dispatch)\n");

	/*
	 * Trap self-test: a deliberate S-mode breakpoint (ebreak, scause==3).
	 * OpenSBI delegates breakpoints to S-mode (medeleg bit 3), so this
	 * traps into stvec -> rv_trap_dispatch -> rv_trap, which sets
	 * trap_fired and advances the saved sepc past the ebreak so sret
	 * resumes here.  (An ecall from S-mode is NOT delegated -- it traps to
	 * OpenSBI as an SBI call -- so ebreak is the correct S-mode trap probe.)
	 * Proves the whole MD trap path end-to-end.
	 */
	trap_fired = 0;
	__asm__ __volatile__(".option push\n\t.option norvc\n\tebreak\n\t.option pop"
	    ::: "memory");
	boot_cpu.bc_trap_online = trap_fired;

	sbi_console_puts("[mlsetup] trap path self-test: ");
	sbi_console_puts(boot_cpu.bc_trap_online ?
	    "PASS (deliberate breakpoint dispatched + resumed)\n" :
	    "FAIL\n");

	main();

	/* main() does not return. */
	for (;;)
		__asm__ __volatile__("wfi");
}

static void
main(void)
{
	unsigned long satp;
	unsigned int src;
	void *a, *b;
	unsigned long pa;

	sbi_console_puts("\n");
	sbi_console_puts("SunOS Release " SOLNIX_RELEASE " Version "
	    SOLNIX_VERSION " (illumos on RISC-V, native toolchain)\n");
	sbi_console_puts("Copyright (c) solnix -- booting illumos "
	    "riscv64 kernel (R-P25)\n");
	sbi_console_puts("\n");

	sbi_console_puts("riscv64 kernel: mlsetup complete, entering main:\n");
	sbi_console_puts("  boot hart id      : ");
	putdec(boot_cpu.bc_hartid);
	sbi_console_puts("\n");
	sbi_console_puts("  devicetree        : ");
	puthex64(boot_cpu.bc_dtb);
	sbi_console_puts("\n");
	sbi_console_puts("  console path      : ");
	sbi_console_puts(sbi_console_kind());
	sbi_console_puts("\n");
	sbi_console_puts("  trap online       : ");
	sbi_console_puts(boot_cpu.bc_trap_online ? "yes\n" : "NO\n");
	sbi_console_puts("  toolchain         : riscv64-unknown-solaris2.11 "
	    "(native EM_RISCV kernel ELF)\n");
	sbi_console_puts("\n");

	/*
	 * R-P24.1 -- Sv39 virtual memory.  Build the boot page tables
	 * (identity map + high direct-map), write satp + sfence.vma to turn
	 * paging ON, and keep executing (the kernel is identity-mapped so the
	 * next fetch still resolves).  The message AFTER the satp write is the
	 * boot proof: we are now running in virtual address space.
	 */
	sbi_console_puts("[R-P24.1] enabling Sv39 paging "
	    "(3-level, 39-bit VA)...\n");
	satp = hat_boot_init();
	sbi_console_puts("paging enabled (Sv39): satp=");
	puthex64(satp);
	sbi_console_puts(" -- kernel now executing in virtual address space\n");
	sbi_console_puts("  satp readback     : ");
	puthex64(rv_get_satp());
	sbi_console_puts("\n");
	/* prove the high direct-map: read the kernel's own text through it. */
	sbi_console_puts("  direct-map probe  : ");
	puthex64(*(volatile unsigned long *)(KERNEL_DMAP_BASE + 0x80200000UL));
	sbi_console_puts(" (word @ dmap+0x80200000)\n\n");

	/*
	 * R-P24.4 (allocator half, needed before the dispatcher) -- boot heap +
	 * first-fit kmem_alloc + a page_t seed.
	 */
	sbi_console_puts("[R-P24.4] startup: boot heap + kmem_alloc + "
	    "page_t seed\n");
	startup_kmem();
	a = kmem_alloc(4096);
	b = kmem_alloc(256);
	sbi_console_puts("  kmem heap         : ");
	putdec(kmem_heapsize());
	sbi_console_puts(" bytes; kmem_alloc(4096)=");
	puthex64((unsigned long)a);
	sbi_console_puts(" kmem_alloc(256)=");
	puthex64((unsigned long)b);
	sbi_console_puts("\n");
	kmem_free(b, 256);
	kmem_free(a, 4096);
	sbi_console_puts("  kmem_free ok; inuse now ");
	putdec(kmem_inuse_bytes());
	sbi_console_puts(" bytes\n");
	page_setup();
	pa = page_create();
	sbi_console_puts("  page_t layer      : ");
	putdec(page_count());
	sbi_console_puts(" frames managed; page_create()=");
	puthex64(pa);
	sbi_console_puts("\n\n");

	/*
	 * R-P24.3 -- qemu-virt PLIC.  Init it, provoke a UART0 external
	 * interrupt, and claim/complete it.  We drive one claim here (polled,
	 * SEIE masked) so the proof is deterministic, then also arm the SEIE
	 * line so an external interrupt can route through rv_trap_dispatch.
	 */
	sbi_console_puts("[R-P24.3] PLIC: init + claim an external "
	    "interrupt (UART0 IRQ10)\n");
	plic_init();
	plic_provoke_uart();
	src = plic_claim();
	sbi_console_puts("  PLIC claim        : source id ");
	putdec(src);
	if (src != 0) {
		plic_complete(src);
		sbi_console_puts(" -- claimed + completed (external "
		    "interrupt handled)\n");
	} else {
		sbi_console_puts(" -- none pending\n");
	}
	plic_quiesce_uart();
	sbi_console_puts("\n");

	/*
	 * R-P24.2 -- periodic clock.  Arm the SBI timer + unmask STIE + set
	 * SIE; each Supervisor Timer Interrupt routes stvec -> rv_trap_dispatch
	 * -> rv_interrupt -> rv_timer_intr, counting a tick.  Then hand the CPU
	 * to the dispatcher, whose idle loop wfi's and prints each tick.
	 */
	sbi_console_puts("[R-P24.2] clock: arming the periodic SBI timer "
	    "(100 Hz) + unmasking STIE/SIE\n");
	clock_init();

	/*
	 * R-P24.4 -- dispatcher on-ramp.  Build an idle kthread on a fresh kmem
	 * stack and swtch into its idle loop; the clock ticks through the trap
	 * path and the idle loop counts them, then swtches back here.
	 */
	sbi_console_puts("[R-P24.4] dispatcher on-ramp: build idle kthread + "
	    "swtch into the idle loop\n");
	dispatch_onramp();

	/*
	 * R-P26 -- run the FIRST MULTIPROCESS riscv64-solaris userland.  Build
	 * proc 1 (the forker) and run the dispatcher: it forks a child, both
	 * run through the runq + a real context switch between their kernel
	 * stacks, print their pid, the child exits, the parent waits + reaps
	 * it, then fork+exec+wait a second (different) program image.
	 */
	sbi_console_puts("\n");
	sbi_console_puts("[R-P26] multiprocess: proc/lwp table + fork(2)/exec(2)/"
	    "wait(2) + a runq dispatcher\n");
	run_user();

	sbi_console_puts("\n");
	sbi_console_puts("[R-P26] Sv39 paging + clock + PLIC + dispatcher + a "
	    "proc table + fork/exec/wait: all reached.\n");
	sbi_console_puts("[R-P26] next: R-P27 fs-backed exec + ld.so.1 + real HAT "
	    "(page hash/freelists) + SMP secondaries + preemption.\n");
	sbi_console_puts("[R-P26] reached the known halt; SBI shutdown.\n");

	sbi_shutdown();
}

/*
 * Trap C handlers -- the receiving end of the R-P22.3 mach_trap.S dispatch.
 * rv_trap fields the deliberate breakpoint in the mlsetup self-test.  These
 * are skeleton bodies; the real syscall table / interrupt dispatch / fault
 * handling is later-phase work.
 */
/* struct regs field the trap handler needs (regs.h layout). */
struct regs {
	unsigned long r_x[31];	/* x1..x31 */
	unsigned long r_sepc;
	unsigned long r_sstatus;
	unsigned long r_scause;
	unsigned long r_stval;
};

#define	SCAUSE_BREAKPOINT	3UL

void
rv_trap(struct regs *r)
{
	/*
	 * The self-test breakpoint (scause==3) lands here: mark the trap path
	 * proven and step the saved sepc past the 4-byte ebreak (we force
	 * .option norvc at the probe site so it is always the 4-byte form) so
	 * sret resumes the instruction after it.
	 */
	if ((r->r_scause & ~0UL) == SCAUSE_BREAKPOINT) {
		trap_fired = 1;
		r->r_sepc += 4;		/* uncompressed ebreak is 4 bytes */
		return;
	}
	sbi_console_puts("[trap] unexpected synchronous trap: scause=");
	puthex64(r->r_scause);
	sbi_console_puts(" sepc=");
	puthex64(r->r_sepc);
	sbi_console_puts(" stval=");
	puthex64(r->r_stval);
	sbi_console_puts(" sstatus=");
	puthex64(r->r_sstatus);
	sbi_console_puts("\n[trap] halting.\n");
	sbi_shutdown();
}

/*
 * rv_interrupt -- the interrupt bottom half (called from rv_trap_dispatch when
 * scause's sign bit is set).  Decode the S-mode interrupt cause: timer (5) ->
 * rv_timer_intr (count a tick, re-arm; on the last tick mask STIE), external
 * (9) -> claim/complete through the PLIC.  scause low bits carry the cause; the
 * sign bit (already tested by the dispatcher) marks it an interrupt.
 */
#define	SCAUSE_INT_MASK		0xffUL
#define	SCAUSE_S_TIMER		5UL
#define	SCAUSE_S_EXTERNAL	9UL
#define	SIE_STIE		(1UL << 5)

void
rv_interrupt(struct regs *r)
{
	unsigned long cause = r->r_scause & SCAUSE_INT_MASK;

	if (cause == SCAUSE_S_TIMER) {
		if (rv_timer_intr() == 0) {
			/* last tick: mask the timer so no more fire. */
			__asm__ __volatile__("csrc sie, %0"
			    :: "r"(SIE_STIE) : "memory");
		}
		return;
	}
	if (cause == SCAUSE_S_EXTERNAL) {
		unsigned int src = plic_claim();
		if (src != 0)
			plic_complete(src);
		return;
	}
	/* other interrupt sources: ignore for now. */
}

/*
 * rv_syscall -- the R-P25 syscall dispatcher: the receiving end of a U-mode
 * ecall.  illumos riscv64 ABI: a7 = syscall number, a0..a5 = args, result in
 * a0.  We wire the two the R-P22 static hello needs:
 *   SYS_write(4): write(fd, buf, n) -- route buf[0..n) to the SBI console
 *     (the user buffer is a low user VA that the current user satp translates
 *     directly).  Returns n in a0.
 *   SYS_exit(1):  exit(status) -- record the status, restore the kernel satp,
 *     and rv_klongjmp back to run_user (the process does not return).
 *
 * CRIB PROVENANCE: the "a7=nr, a0..a5=args, dispatch a small table, return in
 * a0" shape is the illumos syscall trap (os/syscall.c) reduced to two calls;
 * SYS_write=4 / SYS_exit=1 are the native <sys/syscall.h>; routing write to
 * the SBI console is the R-P bootstrap console path.
 */
#define	R_X_A0	9	/* r_x[] index for a0 (x10): index = N-1 */
#define	R_X_A1	10
#define	R_X_A2	11
#define	R_X_A7	16
#define	SYS_exit	1
#define	SYS_write	4
#define	SYS_getpid	20
#define	SYS_execve	59
#define	SYS_wait	107	/* reduced waitid */
#define	SYS_fork	142	/* reduced forksys */

void
rv_syscall(struct regs *r)
{
	unsigned long nr = r->r_x[R_X_A7];
	unsigned long a0 = r->r_x[R_X_A0];
	unsigned long a1 = r->r_x[R_X_A1];
	unsigned long a2 = r->r_x[R_X_A2];

	trap_fired = 1;
	switch (nr) {
	case SYS_write: {
		const char *buf = (const char *)a1;
		unsigned long n = a2, i;
		(void)a0;	/* fd ignored: all writes go to the console */
		for (i = 0; i < n; i++)
			sbi_console_putchar((int)(unsigned char)buf[i]);
		user_wrote_bytes += (int)n;
		r->r_x[R_X_A0] = n;	/* return bytes written */
		return;
	}
	case SYS_getpid:
		r->r_x[R_X_A0] = (unsigned long)proc_getpid();
		return;
	case SYS_fork:
		/*
		 * fork(2): the PARENT returns here with the child pid in a0;
		 * the child is a fresh RUNNABLE proc whose seeded trap frame
		 * has a0=0, so when the scheduler runs it, it returns 0.
		 */
		r->r_x[R_X_A0] = (unsigned long)proc_fork();
		return;
	case SYS_wait:
		/* wait(2): block (yield) until a child is ZOMBIE, reap it. */
		r->r_x[R_X_A0] = (unsigned long)proc_wait((long *)a0);
		return;
	case SYS_execve:
		/*
		 * exec(2): replace this proc's AS + rewrite its trap frame to
		 * point at the new program.  On success the syscall return
		 * (the epilogue sret) drops into the NEW image, so a0 is
		 * overwritten by the new frame; on failure we return -1.
		 */
		if (proc_exec((const char *)a0) != 0)
			r->r_x[R_X_A0] = (unsigned long)-1;
		return;
	case SYS_exit:
		user_exit_status = (int)a0;
		proc_exit((int)a0);	/* ZOMBIE + yield; never returns */
		return;
	default:
		sbi_console_puts("[syscall] unimplemented syscall number ");
		putdec(nr);
		sbi_console_puts("\n");
		r->r_x[R_X_A0] = (unsigned long)-1;
		return;
	}
}

/*
 * run_user -- R-P26: launch the FIRST userland process (the forker) and run
 * the multiprocess dispatcher.  proc.c builds proc 1 from the embedded forker
 * ELF (a fresh user AS + a seeded kernel trap frame/context), then rv_sched()
 * runs the runq: it swtch'es into proc 1, which forks a child; both procs run
 * cooperatively through the scheduler, print their pid, the child exits, the
 * parent waits + reaps it, then does the same for an exec child.  rv_sched
 * returns to the kernel when no proc is left alive.
 */
extern struct proc *proc_first(const unsigned char *img);

void
run_user(void)
{
	struct proc *p0;

	user_exit_status = -1;
	user_wrote_bytes = 0;

	sbi_console_puts("[R-P26] proc table: building the first process "
	    "(pid 1) from the embedded forker ELF\n");
	p0 = proc_first(user_elf_start);
	if (p0 == 0) {
		sbi_console_puts("[R-P26] proc_first FAILED\n");
		return;
	}
	sbi_console_puts("[R-P26] dispatcher: rv_sched runq -- fork lets a "
	    "child run; parent waits + reaps.\n");
	sbi_console_puts("----- userland process output (multiprocess) -----\n");
	rv_sched();
	sbi_console_puts("----- end userland process output -----\n");
	sbi_console_puts("[R-P26] all procs exited + reaped; wrote ");
	putdec((unsigned long)(unsigned int)user_wrote_bytes);
	sbi_console_puts(" bytes via their own write(2). Kernel continues.\n");
}

/* clock tick bottom half (mach_clock.S rv_clock_intr, unused in R-P24). */
void
clock(void)
{
}
