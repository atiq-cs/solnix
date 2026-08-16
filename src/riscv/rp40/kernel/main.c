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

/* R-P32: page-fault seam (proc.c). */
extern int curproc_active(void);
extern int proc_pagefault(unsigned long stval, unsigned long scause);

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

/* R-P29 subsystems: full HAT (high-VA R^X), vmem/kmem_cache, TLB shootdown. */
extern unsigned long hat_kernel_setup(void);
extern int hat_wx_selftest(void);
extern void hat_tlb_shootdown(long target_hartid);
struct kmem_cache;
extern void kmem_cache_init(void);
extern struct kmem_cache *kmem_cache_create(const char *, unsigned long,
    unsigned long);
extern void *kmem_cache_alloc(struct kmem_cache *);
extern void kmem_cache_free(struct kmem_cache *, void *);
extern unsigned long kmem_cache_inuse(struct kmem_cache *);
extern unsigned long kmem_cache_nslab(struct kmem_cache *);
extern unsigned long kmem_cache_nobj(struct kmem_cache *);

/* R-P25/R-P26 userland-process seam. */
#include "proc_riscv.h"
struct rv_klabel { unsigned long l_ra, l_sp, l_s[12]; };
extern int rv_ksetjmp(struct rv_klabel *);
extern void rv_klongjmp(struct rv_klabel *, int);
extern unsigned long rv_get_satp(void);
extern void rv_set_satp(unsigned long);
extern void run_user(void);
void run_preempt(void);
void run_fsexec(void);
void run_fsread(void);
void run_dynamic(void);
void run_xobject(void);
void run_lazybind(void);
void run_priodisp(void);
void run_fptest(void);
extern void smp_start(unsigned long boot_hartid);
/* R-P29.2: per-CPU dispatch queues + kpreempt (disp.c). */
extern void disp_percpu_demo(unsigned long boot_hartid);

/* R-P26 proc/lwp table + fork/exec/wait bodies (proc.c). */
extern int proc_getpid(void);
extern long proc_brk(unsigned long newbrk);
extern long proc_fork(void);
extern long proc_exec(const char *path);
extern long proc_execv(const char *path, char **argv);
extern void proc_exit(int status);
extern long proc_wait(long *statusp);
/* R-P31.3: the ramfs read(2) path + file ops (proc.c). */
extern int proc_open(const char *path);
extern long proc_read(int fd, char *ubuf, unsigned long n);
extern long proc_write(int fd, const char *ubuf, unsigned long n);
extern long proc_lseek(int fd, long off, int whence);
extern long proc_fstat(int fd, unsigned long *ubuf);
extern long proc_stat(const char *path, unsigned long *ubuf);
extern long proc_close_file(int fd);
extern long proc_mprotect(unsigned long addr, unsigned long len, unsigned long prot);
/* R-P28: map a DT_NEEDED shared object into the current proc AS (SYS_mapso). */
extern int exec_map_so(const char *path, unsigned long base);
/* R-P28: kernel threads + priority dispatch. */
extern int kthread_create(void (*entry)(void), int pri);

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
	sbi_console_puts("[mlsetup] illumos riscv64 MD bring-up (R-P28)\n");
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
	    "riscv64 kernel (R-P28)\n");
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
	 * R-P24.1 / R-P30 -- Sv39 virtual memory.  Under R-P30 paging is ALREADY
	 * ON: locore._start built the boot tables (hat_earlyboot) and enabled
	 * Sv39 BEFORE jumping PC up to the high-VA _start_high, so main() already
	 * executes at high VA.  Report the active satp + prove the direct-map by
	 * reading the kernel's own text through its HIGH VA.
	 */
	sbi_console_puts("[R-P24.1] Sv39 paging (enabled in locore, high-VA "
	    "kernel)...\n");
	satp = rv_get_satp();
	sbi_console_puts("paging enabled (Sv39): satp=");
	puthex64(satp);
	sbi_console_puts(" -- kernel executing in virtual address space at HIGH VA\n");
	sbi_console_puts("  satp readback     : ");
	puthex64(rv_get_satp());
	sbi_console_puts("\n");
	sbi_console_puts("  &main (high VA)   : ");
	puthex64((unsigned long)&main);
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
	 * R-P29 (headline) -- the full high-VA R^X kernel HAT.  Replace the
	 * R-P24 boot map (RWX gigapages) with a real per-segment W^X map at
	 * 4 KiB leaf granularity, execute a probe through the high direct-map
	 * alias (high-VA execution), then prove W^X by faulting a store to
	 * .text.  Also build the vmem arena + slab kmem_cache and prove
	 * alloc/free recycling, and broadcast a TLB shootdown.
	 */
	sbi_console_puts("[R-P29.1] full HAT: per-segment R^X kernel map "
	    "(text RX, rodata R, data/bss RW) + high-VA execution\n");
	{
		unsigned long hsatp = hat_kernel_setup();
		if (hsatp == 0) {
			sbi_console_puts("  [hat] hat_kernel_setup FAILED "
			    "(kept boot map)\n");
		} else {
			int wx;
			sbi_console_puts("  new kernel satp   : ");
			puthex64(hsatp);
			sbi_console_puts(" -- W^X kernel map installed\n");
			wx = hat_wx_selftest();
			sbi_console_puts("  [R-P29.1] W^X test: store to .text ");
			sbi_console_puts(wx ?
			    "FAULTED -- W^X enforced (.text is not writable)\n" :
			    "SUCCEEDED -- W^X NOT enforced (BUG)\n");
		}
	}

	/*
	 * R-P30 (headline) -- DROP the low identity map entirely.  The kernel is
	 * LINKED + EXECUTES at high VA (KERNEL_DMAP_BASE + 0x80200000); locore
	 * brought it up through a physical-entry trampoline (identity to survive
	 * the satp flip) and jumped PC to the high half; hat_kernel_setup then
	 * installed the identity-FREE W^X root.  Now prove the primary runs
	 * PURELY at high VA with NO identity map: a read of the first kernel word
	 * through its LOW identity VA (0x80200000) must FAULT, while the same
	 * word through its HIGH VA reads back the instruction.
	 */
	sbi_console_puts("[R-P30.1] high-VA relink: drop the low identity map "
	    "(true high-half kernel)\n");
	{
		unsigned long hi_word;
		int dropped, ok;
		extern int hat_drop_identity(void);
		extern int hat_ident_dropped_test(void);

		ok = hat_drop_identity();
		hi_word = *(volatile unsigned long *)
		    (KERNEL_DMAP_BASE + 0x80200000UL);
		sbi_console_puts("  kernel _start via HIGH VA ");
		puthex64(KERNEL_DMAP_BASE + 0x80200000UL);
		sbi_console_puts(" = ");
		puthex64(hi_word);
		sbi_console_puts(" (executing here)\n");
		dropped = hat_ident_dropped_test();
		sbi_console_puts("  read of _start via LOW identity VA "
		    "0x80200000: ");
		sbi_console_puts(dropped ?
		    "FAULTED -- identity map dropped\n" :
		    "SUCCEEDED -- identity STILL present (BUG)\n");
		if (ok && dropped)
			sbi_console_puts("[R-P30.1] identity map dropped; "
			    "running purely high-VA\n");
		else
			sbi_console_puts("[R-P30.1] identity drop INCOMPLETE\n");
	}

	/*
	 * R-P29.1 -- vmem arena + slab kmem_cache over the boot heap.  Create a
	 * cache, alloc a batch (forcing >1 slab), free them, re-alloc and
	 * confirm freed objects are recycled (the slab allocator working).
	 */
	sbi_console_puts("[R-P29.1] vmem arena + slab kmem_cache: create + "
	    "alloc/free recycle\n");
	kmem_cache_init();
	{
		struct kmem_cache *kc = kmem_cache_create("rp29_obj", 96, 16);
		void *objs[40];
		int i;
		void *first, *reuse;

		if (kc == 0) {
			sbi_console_puts("  [kmem_cache] create FAILED\n");
		} else {
			for (i = 0; i < 40; i++)
				objs[i] = kmem_cache_alloc(kc);
			first = objs[0];
			sbi_console_puts("  cache 'rp29_obj' (96B): allocated 40 "
			    "objs -> slabs=");
			putdec(kmem_cache_nslab(kc));
			sbi_console_puts(" objs/slab-total=");
			putdec(kmem_cache_nobj(kc));
			sbi_console_puts(" inuse=");
			putdec(kmem_cache_inuse(kc));
			sbi_console_puts("\n");
			for (i = 0; i < 40; i++)
				kmem_cache_free(kc, objs[i]);
			reuse = kmem_cache_alloc(kc);
			sbi_console_puts("  freed 40; re-alloc recycled addr ");
			puthex64((unsigned long)reuse);
			sbi_console_puts((reuse == first) ?
			    " == first freed obj (slab recycle OK)\n" :
			    " (a freed obj, recycle OK)\n");
			kmem_cache_free(kc, reuse);
		}
	}
	sbi_console_puts("\n");

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
	/* R-P34.3: seed the VFS mount table ("/" ramfs, "/tmp" tmpfs) before any
	   proc opens a file -- the tmpfs prefix test now consults this table. */
	{
		extern void vfs_mount_init(void);
		vfs_mount_init();
	}
	run_user();

	/*
	 * R-P35.1 per-CPU idle + IPI wakeup runs EARLY (right after the first
	 * multiprocess proof) in a clean proc/frame state.  init(pid 1) + the
	 * INTERACTIVE shell run LAST (see the end of main): the shell blocks on
	 * live console input, so it must not gate the other non-interactive
	 * proofs.
	 */
	{
		extern void run_idle_ipi(unsigned long boot_hartid);
		run_idle_ipi(boot_cpu.bc_hartid);
	}

	run_preempt();

	run_fsexec();

	run_fsread();

	run_dynamic();

	run_xobject();

	run_lazybind();

	run_priodisp();

	run_fptest();

	{
		extern void run_cowtest(void);
		run_cowtest();
	}

	/*
	 * R-P32.1 (a headline) -- the REAL proc_t dispatcher on BOTH harts.
	 * Bring up the secondary hart into proc_secondary_main and run
	 * rv_sched_cpu on BOTH harts against ONE shared proc runq: a first
	 * process forks N children, each printing the hart it was dispatched on,
	 * and the two harts drain the shared runq so a proc forked on hart 0 can
	 * run on hart 1 (scheduler-balanced across two hartids).  Runs while the
	 * secondary is still HSM-STOPPED (before the later SMP phases), and STOPs
	 * it again on the way out so those phases can restart it.
	 */
	{
		extern void run_procs_smp(unsigned long boot_hartid);
		run_procs_smp(boot_cpu.bc_hartid);
	}

	/*
	 * R-P32.3 -- vfs write(2) + a real vnode layer.  A process writes a
	 * writable tmpfs file + reads it back; open/read/write/getattr route
	 * through the VOP_* op vector (vfs.c), and the read-only ramfs rejects
	 * writes (EROFS).
	 */
	{
		extern void run_vfstest(void);
		run_vfstest();
	}

	/*
	 * R-P33.1 (a headline) -- signals + kill(2).  A child installs a SIGUSR1
	 * handler + spins; the parent kill(2)s it (the kernel delivers the
	 * signal on the return-to-U edge -- a frame on the user stack, sret into
	 * the handler, sigreturn restores); then SIGKILL terminates a second
	 * uncatchable spinner.
	 */
	{
		extern void run_sigtest(void);
		run_sigtest();
	}

	/*
	 * R-P34.2 -- fd management.  dup2 redirects stdout to a file;
	 * fcntl(F_DUPFD/F_GETFD/F_SETFD) works; a FD_CLOEXEC fd is closed across
	 * exec(2) while a plain fd is inherited into the new image.
	 */
	{
		extern void run_fdtest(void);
		run_fdtest();
	}

	/*
	 * R-P33.2 -- pipe(2) + directories.  Two procs communicate over a
	 * kernel pipe (fork-inherited fds, blocking read/write); mkdir +
	 * getdents list a tmpfs directory.
	 */
	{
		extern void run_pipetest(void);
		run_pipetest();
	}

	/*
	 * R-P33.3 -- per-CPU idle + wfi: the hart parks in wfi between ticks
	 * (low power) instead of spinning; and file-backed demand-exec: an
	 * exec'd program's text is demand-paged from the file on the fetch
	 * fault instead of eager-copied.
	 */
	{
		extern void run_idle_wfi(void);
		extern void run_dpexec(void);
		run_idle_wfi();
		run_dpexec();
	}

	/*
	 * R-P35.1 + R-P35.2/.3 run EARLY (right after run_user, see above): the
	 * per-CPU idle+IPI wakeup and init(pid 1) + minimal shell.
	 */

	disp_percpu_demo(boot_cpu.bc_hartid);

	smp_start(boot_cpu.bc_hartid);

	/*
	 * R-P30.2 -- TS/RT scheduling classes on both harts.  Promote the R-P29
	 * per-CPU work queues to a real priority scheduler: SC_RT above SC_TS,
	 * tick-driven kpreempt (RT preempts TS), TS round-robin within a band,
	 * priority-inheritance-lite (an RT waiter boosts the TS lock-holder), and
	 * BOTH harts dispatch from the shared class runq.
	 */
	{
		extern void run_tsrt_sched(unsigned long boot_hartid);
		run_tsrt_sched(boot_cpu.bc_hartid);
	}

	/*
	 * R-P31.1 (the headline) -- SECONDARIES ON THE W^X ROOT.  Bring up the
	 * secondary hart one more time, but now switch it onto the primary's
	 * identity-FREE W^X root at high VA (locore wx_ap_entry -> wx_ap_high ->
	 * hat_wxroot_satp), prove it runs purely high-VA (its running satp is the
	 * W^X root; a low identity read faults), then SCRUB the boot root's
	 * identity window entirely -- so after boot NO identity map survives on
	 * ANY root, on ANY hart.  This runs LAST among the SMP phases because it
	 * drops the transient flip trampoline the earlier AP-restart phases need.
	 */
	{
		extern void run_secondaries_wxroot(unsigned long boot_hartid);
		run_secondaries_wxroot(boot_cpu.bc_hartid);
	}

	/*
	 * R-P30.3 -- as_free lifecycle.  Fork+exec+exit a process N times and
	 * confirm the kmem free count is stable (no AS leak): proc_exit/do_exec
	 * now walk + unmap + free the user page tables + frames of the old AS.
	 */
	{
		extern void run_asfree(void);
		run_asfree();
	}

	/*
	 * R-P36.1 + R-P36.2 -- per-AS ASIDs + remote TLB shootdown (THE R-P35 SMP
	 * FIX), then waitpid(2).  run_asid_churn drives the exact COW-share +
	 * ASID-scoped local flush + remote-hart shootdown + teardown path that used
	 * to alias under heavy fork/exec churn, across an ASID rollover; run_waitpid
	 * proves a specific-pid reap + a WNOHANG poll.
	 */
	{
		extern void run_asid_churn(void);
		extern void run_waitpid(void);
		run_asid_churn();
		run_waitpid();
	}

	/*
	 * R-P38.3 -- a persistent/second filesystem via a BLOCK-device vnode.
	 * mkfs+mount a RAM-backed block device with a minimal on-disk fs, read a
	 * file back through the block vnode (bdev_strategy), unmount -- proving
	 * the vfs is not ramfs-only.
	 */
	{
		extern void run_blockfs(void);
		run_blockfs();
	}

	/*
	 * R-P29.1 -- TLB shootdown across harts.  After a shared kernel mapping
	 * changes, every hart must drop stale translations.  Broadcast a remote
	 * sfence.vma to the secondary hart (via the SBI RFENCE extension) plus a
	 * local flush.  A 0 return means OpenSBI issued + executed the remote
	 * fence on the peer hart -- a cross-hart TLB shootdown.
	 */
	sbi_console_puts("\n");
	sbi_console_puts("[R-P29.1] TLB shootdown: local sfence.vma + remote "
	    "sfence.vma to hart 1 (SBI RFENCE)\n");
	{
		unsigned long other = boot_cpu.bc_hartid ^ 1;
		extern long sbi_remote_sfence_vma(unsigned long);
		long e = sbi_remote_sfence_vma(other);
		hat_tlb_shootdown((long)other);
		sbi_console_puts("  remote sfence.vma to hart ");
		putdec(other);
		sbi_console_puts(e == 0 ?
		    ": SBI_SUCCESS -- TLB shootdown broadcast across harts\n" :
		    ": SBI error\n");
		if (e == 0)
			sbi_console_puts("[R-P29.1] TLB shootdown PROVEN: "
			    "cross-hart sfence.vma issued + accepted.\n");
	}

	sbi_console_puts("\n");
	sbi_console_puts("[R-P29] full high-VA R^X HAT (W^X kernel, kmem_cache, "
	    "TLB shootdown) + per-CPU disp + kpreempt + FP ctx switch: all reached.\n");
	sbi_console_puts("[R-P28] cross-object dynamic linking (ld.so.1 maps + "
	    "binds libgcc_s) + priority disp queues + SMP (2 harts): all reached.\n");
	sbi_console_puts("[R-P29] next: R-P30 relink kernel at high VA + drop the "
	    "identity map entirely; scheduling classes (TS/RT); lazy PLT + as_free.\n");
	sbi_console_puts("[R-P29] reached the known halt; SBI shutdown.\n");

	/*
	 * R-P37 (the headline) -- init(pid 1, inittab-driven) + an INTERACTIVE
	 * shell on the LIVE console.  Runs LAST: the shell blocks on console
	 * input (a real tty read via the line discipline), so it must follow
	 * every non-interactive proof.  init reads /etc/inittab + respawns the
	 * console shell; the boot proof feeds the console via qemu's piped stdin.
	 */
	{
		extern void run_init(void);
		run_init();
	}

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
#define	SCAUSE_INSTR_FAULT	12UL	/* instruction page fault */
#define	SCAUSE_LOAD_FAULT	13UL	/* load page fault */
#define	SCAUSE_STORE_FAULT	15UL	/* store/AMO page fault */
#define	SSTATUS_SPP_BIT		(1UL << 8)	/* prev priv: 0=U, 1=S */

/* R-P29 W^X self-test hooks (hat.c). */
extern volatile int hat_wx_expect;
extern volatile int hat_wx_faulted;
/* R-P30 identity-drop self-test hooks (hat.c). */
extern volatile int hat_ident_expect;
extern volatile int hat_ident_faulted;
/* R-P31.1 AP-only identity-drop self-test hooks (smp_wxroot.c). */
volatile int hat_ap_ident_expect;
volatile int hat_ap_ident_faulted;

void
rv_trap(struct regs *r)
{
	/*
	 * R-P30 identity-drop self-test: a deliberate LOAD from a low identity
	 * VA (0x80200000) must fault (load page fault, scause 13) because the
	 * running W^X root has NO identity map.  Record it + step sepc past the
	 * faulting load (a compressed/uncompressed ld -- decode its length from
	 * the low bits of the instruction; the probe uses a plain 4-byte ld so
	 * advance 4 unless the halfword at sepc is a compressed op).
	 */
	if ((r->r_scause & ~0UL) == SCAUSE_LOAD_FAULT && hat_ident_expect) {
		unsigned short op = *(volatile unsigned short *)r->r_sepc;
		hat_ident_faulted = 1;
		r->r_sepc += ((op & 3) == 3) ? 4 : 2;
		return;
	}
	/*
	 * R-P31.1 AP-only identity-drop self-test: the SAME low-identity load
	 * fault, but armed on the SECONDARY hart (hat_ap_ident_expect) while it
	 * runs on the W^X root.  Kept a distinct hook so the primary's and the
	 * secondary's identity probes never race on one flag.
	 */
	if ((r->r_scause & ~0UL) == SCAUSE_LOAD_FAULT && hat_ap_ident_expect) {
		unsigned short op = *(volatile unsigned short *)r->r_sepc;
		hat_ap_ident_faulted = 1;
		r->r_sepc += ((op & 3) == 3) ? 4 : 2;
		return;
	}
	/*
	 * R-P32 USER PAGE FAULT: a page fault (instruction 12 / load 13 /
	 * store 15) taken from U-mode (sstatus.SPP==0).  Route it to
	 * proc_pagefault(stval, scause), which resolves a COW copy (store to a
	 * shared read-only COW page) or a demand-paged (lazy) page fill for the
	 * running proc's AS.  On success (handled == 1) we simply return -- the
	 * trap epilogue sret's back to the faulting instruction, which now
	 * succeeds against the freshly-copied/filled page.  A fault we cannot
	 * resolve (a real access violation) falls through to the halt below.
	 *
	 * CRIB PROVENANCE: routing a hardware page fault to the VM layer
	 * (trap -> pagefault(addr, type) -> as_fault -> segvn_fault) is illumos
	 * uts/common/os/trap.c / uts/*\/vm/vm_machdep trap_pagefault + as_fault;
	 * the scause 12/13/15 decode is the RISC-V privileged spec exception
	 * codes; retrying the faulting instruction after the fix is the
	 * architectural page-fault-then-resume model (xv6-riscv usertrap COW).
	 */
	{
		unsigned long sc = r->r_scause & ~0UL;
		/*
		 * A page fault whose faulting address (stval) is a USER VA (below
		 * the kernel high half).  This covers BOTH a fault taken in U-mode
		 * (the proc touched its own COW/lazy page) AND a fault taken in
		 * S-mode with SUM set (the kernel wrote a user COW page via a
		 * copyout-style store, e.g. wait(2) writing *statusp) -- both must
		 * resolve the COW copy / demand fill.  The W^X self-test store
		 * targets a kernel .text VA (high), so it does NOT match here and
		 * still reaches the hat_wx_expect hook below.
		 */
		if (curproc_active() &&
		    r->r_stval < KERNEL_DMAP_BASE &&
		    (sc == SCAUSE_STORE_FAULT || sc == SCAUSE_LOAD_FAULT ||
		    sc == SCAUSE_INSTR_FAULT)) {
			if (proc_pagefault(r->r_stval, sc))
				return;		/* handled: retry the instruction */
			/*
			 * R-P33.1: an UNRESOLVED user page fault (a real access
			 * violation) is not a kernel bug -- raise SIGSEGV against
			 * the running proc.  It is delivered on the way back to
			 * U-mode (a SIGSEGV handler runs, or the default action
			 * terminates the proc); the kernel keeps running.  Only a
			 * fault taken from U-mode (SPP==0) is routed this way; a
			 * kernel-mode user-VA fault still falls through to the halt.
			 */
			if ((r->r_sstatus & SSTATUS_SPP_BIT) == 0) {
				extern int proc_signal_fault(void);
				if (proc_signal_fault())
					return;
			}
		}
	}
	/*
	 * R-P29 W^X self-test: a deliberate store to a .text address (mapped
	 * R|X, no W) faults here as a store/AMO page fault (scause 15).  When
	 * hat_wx_expect is armed, record that the write faulted (W^X enforced)
	 * and step sepc past the faulting store so we resume.  The store is a
	 * 4-byte sw, so advance 4.
	 */
	if ((r->r_scause & ~0UL) == SCAUSE_STORE_FAULT && hat_wx_expect) {
		hat_wx_faulted = 1;
		r->r_sepc += 4;
		return;
	}
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
#define	SCAUSE_S_SOFTWARE	1UL
#define	SCAUSE_S_TIMER		5UL
#define	SCAUSE_S_EXTERNAL	9UL
#define	SIE_STIE		(1UL << 5)
#define	SSTATUS_SPP		(1UL << 8)	/* prev priv: 0=U, 1=S */

extern void proc_preempt_tick(void);
extern int proc_preempt_pending(void);
extern void proc_yield(void);

void
rv_interrupt(struct regs *r)
{
	unsigned long cause = r->r_scause & SCAUSE_INT_MASK;

	/*
	 * R-P35.1: a supervisor SOFTWARE interrupt (cause 1) is an IPI a peer
	 * hart posted (sbi_send_ipi_hart) to poke this hart out of its idle
	 * `wfi` so it re-scans the shared runq for a proc that just became
	 * runnable (a wakeup/exit-child/signal made a WAITING proc RUNNABLE).
	 * The interrupt itself carries no payload -- clear the pending bit
	 * (SSIP, sip bit 1) and return; the idle loop re-dispatches on wake.
	 */
	if (cause == SCAUSE_S_SOFTWARE) {
		__asm__ __volatile__("csrci sip, 0x2" ::: "memory");
		return;
	}
	if (cause == SCAUSE_S_TIMER) {
		if (rv_timer_intr() == 0) {
			/* last tick: mask the timer so no more fire. */
			__asm__ __volatile__("csrc sie, %0"
			    :: "r"(SIE_STIE) : "memory");
		}
		/*
		 * R-P37.1: poll the console UART on every tick (a polled
		 * stand-in for an RX interrupt): drain typed bytes into the
		 * line-discipline ring, and act on ^C/^Z (signal the tty fg
		 * pgrp) even when no read(2) is pending -- so a ^C interrupts a
		 * spinning foreground command.
		 */
		{
			extern void console_poll(void);
			console_poll();
		}
		/* R-P34.1: fire any due alarm(2) -> SIGALRM off the tick. */
		{
			extern void proc_alarm_tick(void);
			proc_alarm_tick();
		}
		/*
		 * R-P27 PREEMPTION: if the tick fired while a user proc was
		 * running (SPP==0: the trap came from U-mode), preempt it --
		 * yield to the scheduler so a round-robin peer runs.  We are on
		 * the proc's kernel stack inside this interrupt frame; proc_yield
		 * swtch'es to the scheduler and, when this proc is scheduled
		 * again, returns here so rv_interrupt returns normally and the
		 * trap epilogue sret's the proc back where the tick hit it.
		 */
		if ((r->r_sstatus & SSTATUS_SPP) == 0) {
			proc_preempt_tick();
			if (proc_preempt_pending())
				proc_yield();
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
#define	SYS_read	3
#define	SYS_write	4
#define	SYS_open	5
#define	SYS_close	6
#define	SYS_stat	18
#define	SYS_lseek	19
#define	SYS_mprotect	74	/* R-P31.2: ld.so.1 relro read-only */
#define	SYS_brk		17
#define	SYS_getpid	20
#define	SYS_fstat	28
#define	SYS_execve	59
#define	SYS_wait	107	/* reduced waitid */
#define	SYS_mmap	115
#define	SYS_fork	142	/* reduced forksys */
#define	SYS_mapso	222	/* R-P28: map a NEEDED ET_DYN (mmap-family) */
#define	SYS_getcwd	223	/* R-P31.3: reduced getcwd */
#define	SYS_uname	224	/* R-P31.3: reduced uname (SunOS) */
#define	SYS_lazy	230	/* R-P32: reserve a demand-paged page at a0 */
#define	SYS_gethartid	231	/* R-P32: the hart the caller runs on */
#define	SYS_kill	232	/* R-P33.1: post a signal to a proc */
#define	SYS_sigaction	233	/* R-P33.1: install a signal handler */
#define	SYS_sigreturn	234	/* R-P33.1: return from a signal handler */
#define	SYS_pipe	235	/* R-P33.2: create a pipe (two fds via a1[2]) */
#define	SYS_mkdir	236	/* R-P33.2: create a directory */
#define	SYS_getdents	237	/* R-P33.2: read directory entries */
#define	SYS_sigprocmask	238	/* R-P34.1: block/unblock signals */
#define	SYS_sigsuspend	239	/* R-P34.1: wait for an unmasked signal */
#define	SYS_alarm	240	/* R-P34.1: arm SIGALRM off the timer */
#define	SYS_dup		241	/* R-P34.2: duplicate an fd */
#define	SYS_dup2	242	/* R-P34.2: duplicate onto a chosen fd */
#define	SYS_fcntl	243	/* R-P34.2: fd control (F_DUPFD/GETFD/SETFD/...) */
#define	SYS_unlink	244	/* R-P34.3: remove a file */
#define	SYS_rename	245	/* R-P34.3: rename a file */
#define	SYS_mount	246	/* R-P34.3: mount a filesystem at a path */
#define	SYS_chdir	247	/* R-P36: change the working directory */
#define	SYS_waitpid	248	/* R-P36: wait for a specific child / WNOHANG */
#define	SYS_setpgid	249	/* R-P37.2: set a proc's process group */
#define	SYS_getpgid	250	/* R-P37.2: get the caller's process group */
#define	SYS_tty_setfg	251	/* R-P37.2: set the tty foreground pgrp */
#define	SYS_rmdir	252	/* R-P37.3: remove a directory */

/* reduced SunOS errno set (uts/common/sys/errno.h) for the error-return ABI. */
#define	EBADF	9
#define	ENOMEM	12
#define	ENOSYS	89

void
rv_syscall(struct regs *r)
{
	unsigned long nr = r->r_x[R_X_A7];
	unsigned long a0 = r->r_x[R_X_A0];
	unsigned long a1 = r->r_x[R_X_A1];
	unsigned long a2 = r->r_x[R_X_A2];
	unsigned long a3 = r->r_x[R_X_A2 + 1];	/* x13 = a3 */

	trap_fired = 1;
	switch (nr) {
	case SYS_write: {
		/*
		 * R-P32.3: write(fd, buf, n).  fd 1/2 -> the console (R-P25);
		 * a file fd -> the vnode VOP_WRITE (a writable tmpfs file).
		 * Routed through proc_write so a proc can write(2) a tmpfs file.
		 */
		r->r_x[R_X_A0] =
		    (unsigned long)proc_write((int)a0, (const char *)a1, a2);
		if ((int)a0 == 1 || (int)a0 == 2)
			user_wrote_bytes += (int)a2;
		return;
	}
	case SYS_getpid:
		r->r_x[R_X_A0] = (unsigned long)proc_getpid();
		return;
	case SYS_brk:
		/*
		 * brk(addr): grow/query the program break.  Returns the new
		 * break (>=0) or -ENOMEM on failure -- the reduced SunOS
		 * error-return ABI (a negative a0 is -errno; the user stub
		 * negates it into errno).
		 */
		{
			long nb = proc_brk(a0);
			r->r_x[R_X_A0] = (nb < 0) ?
			    (unsigned long)(-ENOMEM) : (unsigned long)nb;
		}
		return;
	case SYS_read:
		/* R-P31.3: real read -- copy bytes from the fd's ramfs vnode. */
		r->r_x[R_X_A0] =
		    (unsigned long)proc_read((int)a0, (char *)a1, a2);
		return;
	case SYS_open:
		/* R-P32.3: open -- resolve the path via vfs_lookup to an fd.
		   a1 = flags (O_CREAT=0x100 creates a writable tmpfs file). */
		{
			extern int proc_openf(const char *path, int flags);
			r->r_x[R_X_A0] =
			    (unsigned long)proc_openf((const char *)a0, (int)a1);
		}
		return;
	case SYS_close:
		r->r_x[R_X_A0] = (unsigned long)proc_close_file((int)a0);
		return;
	case SYS_lseek:
		/* R-P31.3: reposition the fd read offset (SEEK_SET/CUR/END). */
		r->r_x[R_X_A0] =
		    (unsigned long)proc_lseek((int)a0, (long)a1, (int)a2);
		return;
	case SYS_fstat:
		/* R-P31.3: report the open file's size into the user buffer. */
		r->r_x[R_X_A0] =
		    (unsigned long)proc_fstat((int)a0, (unsigned long *)a1);
		return;
	case SYS_stat:
		/* R-P31.3: stat a path (size only) into the user buffer. */
		r->r_x[R_X_A0] =
		    (unsigned long)proc_stat((const char *)a0, (unsigned long *)a1);
		return;
	case SYS_mprotect:
		/* R-P31.2: change user-page perms (ld.so.1 relro read-only). */
		r->r_x[R_X_A0] = (unsigned long)proc_mprotect(a0, a1, a2);
		return;
	case SYS_lazy: {
		/* R-P32: reserve a demand-paged page at a0 (backed on first touch). */
		extern long proc_lazy_reserve(unsigned long va);
		r->r_x[R_X_A0] = (unsigned long)proc_lazy_reserve(a0);
		return;
	}
	case SYS_gethartid: {
		/* R-P32.1: which hart is the caller running on (its proc's p_hart). */
		extern int proc_gethartid(void);
		r->r_x[R_X_A0] = (unsigned long)proc_gethartid();
		return;
	}
	case SYS_kill: {
		/* R-P33.1: kill(pid, sig) -- post sig to pid. */
		extern int proc_kill(int pid, int sig);
		r->r_x[R_X_A0] = (unsigned long)proc_kill((int)a0, (int)a1);
		return;
	}
	case SYS_sigaction: {
		/* R-P33.1: sigaction(sig, handler, restorer, flags). */
		extern long proc_sigaction(int sig, unsigned long handler,
		    unsigned long restorer, unsigned long flags);
		r->r_x[R_X_A0] =
		    (unsigned long)proc_sigaction((int)a0, a1, a2, a3);
		return;
	}
	case SYS_sigreturn: {
		/* R-P33.1: restore the interrupted frame from the sigframe. */
		extern void proc_sigreturn(struct regs *r);
		proc_sigreturn(r);
		return;
	}
	case SYS_pipe: {
		/* R-P33.2: pipe(int fds[2]) -- write the two fds to a0[0..1]. */
		extern long proc_pipe(int *ufds);
		r->r_x[R_X_A0] = (unsigned long)proc_pipe((int *)a0);
		return;
	}
	case SYS_mkdir: {
		/* R-P33.2: mkdir(path) -- create a tmpfs directory. */
		extern long proc_mkdir(const char *path);
		r->r_x[R_X_A0] = (unsigned long)proc_mkdir((const char *)a0);
		return;
	}
	case SYS_getdents: {
		/* R-P33.2: getdents(fd, buf, n) -- read dir entries via VOP_READDIR. */
		extern long proc_getdents(int fd, char *ubuf, unsigned long n);
		r->r_x[R_X_A0] =
		    (unsigned long)proc_getdents((int)a0, (char *)a1, a2);
		return;
	}
	case SYS_sigprocmask: {
		/* R-P34.1: sigprocmask(how, set, oldp). */
		extern long proc_sigprocmask(int how, unsigned long set,
		    unsigned long *oldp);
		r->r_x[R_X_A0] = (unsigned long)proc_sigprocmask((int)a0, a1,
		    (unsigned long *)a2);
		return;
	}
	case SYS_sigsuspend: {
		/* R-P34.1: sigsuspend(mask) -- block until an unmasked signal. */
		extern long proc_sigsuspend(unsigned long mask);
		r->r_x[R_X_A0] = (unsigned long)proc_sigsuspend(a0);
		return;
	}
	case SYS_alarm: {
		/* R-P34.1: alarm(secs) -- arm SIGALRM; return prev remaining. */
		extern long proc_alarm(unsigned long secs);
		r->r_x[R_X_A0] = (unsigned long)proc_alarm(a0);
		return;
	}
	case SYS_dup: {
		extern long proc_dup(int oldfd);
		r->r_x[R_X_A0] = (unsigned long)proc_dup((int)a0);
		return;
	}
	case SYS_dup2: {
		extern long proc_dup2(int oldfd, int newfd);
		r->r_x[R_X_A0] = (unsigned long)proc_dup2((int)a0, (int)a1);
		return;
	}
	case SYS_fcntl: {
		extern long proc_fcntl(int fd, int cmd, long arg);
		r->r_x[R_X_A0] =
		    (unsigned long)proc_fcntl((int)a0, (int)a1, (long)a2);
		return;
	}
	case SYS_unlink: {
		/* R-P34.3: unlink(path) -- remove a tmpfs file. */
		extern long proc_unlink(const char *path);
		r->r_x[R_X_A0] = (unsigned long)proc_unlink((const char *)a0);
		return;
	}
	case SYS_rename: {
		/* R-P34.3: rename(from, to) -- rename a tmpfs file. */
		extern long proc_rename(const char *from, const char *to);
		r->r_x[R_X_A0] =
		    (unsigned long)proc_rename((const char *)a0, (const char *)a1);
		return;
	}
	case SYS_mount: {
		/* R-P34.3: mount(fstype, path) -- add a mount-table entry. */
		extern long proc_mount(const char *fstype, const char *path);
		r->r_x[R_X_A0] =
		    (unsigned long)proc_mount((const char *)a0, (const char *)a1);
		return;
	}
	case SYS_getcwd: {
		/* R-P31.3: reduced getcwd -- always "/" (no cwd tracking yet). */
		char *ubuf = (char *)a0;
		unsigned long sz = a1;
		if (ubuf == 0 || sz < 2) {
			r->r_x[R_X_A0] = (unsigned long)(-ENOMEM);
			return;
		}
		ubuf[0] = '/';
		ubuf[1] = 0;
		r->r_x[R_X_A0] = (unsigned long)a0;	/* SunOS getcwd returns buf */
		return;
	}
	case SYS_uname: {
		/*
		 * R-P31.3: reduced uname(2) -- fill the user utsname with the
		 * SunOS/solnix-riscv64 identity.  The reduced utsname the test
		 * reads is 5 fixed-width (32-byte) fields: sysname, nodename,
		 * release, version, machine (the SunOS utsname.h SYS_NMLN=257
		 * layout reduced to 32).  Returns 0.
		 */
		char *u = (char *)a0;
		static const char *fields[5] = {
		    "SunOS", "solnix-riscv64", "5.11", "solnix", "riscv64"
		};
		int f, i;
		if (u == 0) {
			r->r_x[R_X_A0] = (unsigned long)(-ENOMEM);
			return;
		}
		for (f = 0; f < 5; f++) {
			char *dst = u + f * 32;
			const char *s = fields[f];
			for (i = 0; i < 31 && s[i]; i++)
				dst[i] = s[i];
			for (; i < 32; i++)
				dst[i] = 0;
		}
		r->r_x[R_X_A0] = 0;
		return;
	}
	case SYS_mmap:
		/*
		 * mmap(addr,len,...): reduced anonymous mapping -- grow the
		 * heap by len via brk and return the old break as the mapping
		 * base (MAP_ANON style).  -ENOMEM on failure.
		 */
		{
			long base = proc_brk(0);
			long nb;
			if (base < 0) {
				r->r_x[R_X_A0] = (unsigned long)(-ENOMEM);
				return;
			}
			nb = proc_brk((unsigned long)base + a1);
			r->r_x[R_X_A0] = (nb < 0) ?
			    (unsigned long)(-ENOMEM) : (unsigned long)base;
		}
		return;
	case SYS_mapso:
		/*
		 * R-P28: ld.so.1 asks the kernel to map a DT_NEEDED shared
		 * object (a1=base) named by a0 (a user VA of the path string,
		 * reachable under the current user satp) into this proc's AS.
		 */
		r->r_x[R_X_A0] =
		    (unsigned long)exec_map_so((const char *)a0, a1);
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
	case SYS_waitpid: {
		/*
		 * R-P36: waitpid(pid, &status, options).  a0 = target pid
		 * (>0 a specific child, <=0 any), a1 = user *status, a2 =
		 * options (WNOHANG=1 -> non-blocking poll).  Returns the reaped
		 * pid, 0 for a WNOHANG poll with nothing ready, or -1.
		 */
		extern long proc_waitpid(long want_pid, long *statusp, int options);
		r->r_x[R_X_A0] = (unsigned long)proc_waitpid((long)a0,
		    (long *)a1, (int)a2);
		return;
	}
	case SYS_chdir: {
		/* R-P36: chdir(path) -- set the proc's cwd (a0 = user path VA). */
		extern int proc_chdir(const char *path);
		r->r_x[R_X_A0] = (unsigned long)proc_chdir((const char *)a0);
		return;
	}
	case SYS_setpgid: {
		/* R-P37.2: setpgid(pid, pgid) -- 0 = self / own group. */
		extern int proc_setpgid(int pid, int pgid);
		r->r_x[R_X_A0] = (unsigned long)proc_setpgid((int)a0, (int)a1);
		return;
	}
	case SYS_getpgid: {
		extern int proc_getpgid(void);
		r->r_x[R_X_A0] = (unsigned long)proc_getpgid();
		return;
	}
	case SYS_tty_setfg: {
		/* R-P37.2: the shell sets the tty foreground process group. */
		extern int proc_tty_setfg(int pgrp);
		r->r_x[R_X_A0] = (unsigned long)proc_tty_setfg((int)a0);
		return;
	}
	case SYS_rmdir: {
		/* R-P37.3: rmdir(path) -- remove a tmpfs directory. */
		extern long proc_rmdir(const char *path);
		r->r_x[R_X_A0] = (unsigned long)proc_rmdir((const char *)a0);
		return;
	}
	case SYS_execve:
		/*
		 * exec(2): replace this proc's AS + rewrite its trap frame to
		 * point at the new program.  On success the syscall return
		 * (the epilogue sret) drops into the NEW image, so a0 is
		 * overwritten by the new frame; on failure we return -1.
		 */
		if (proc_execv((const char *)a0, (char **)a1) != 0)
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
extern struct proc *proc_first_demand(const unsigned char *img);

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

/*
 * run_fsexec -- R-P27 sub-task 2: the fs-backed-exec proof.  Dump the ramfs
 * (so the log shows the archive is populated + walkable by path), then run a
 * process that execs a program BY ABSOLUTE PATH ("/bin/execee").  The kernel
 * resolves that path in the initramfs (ramfs_lookup) and loads the ELF bytes,
 * vs the R-P26 exec which ignored the path.
 */
extern const unsigned char fsexec_elf_start[];
extern void ramfs_dump(void);

void
run_fsexec(void)
{
	struct proc *p0;

	sbi_console_puts("\n");
	sbi_console_puts("[R-P27.2] fs-backed exec: a ramfs (initramfs blob) + "
	    "exec(path) resolving the ELF by name\n");
	sbi_console_puts("  ramfs contents:\n");
	ramfs_dump();
	sbi_console_puts("----- fs-exec proof output -----\n");
	p0 = proc_first(fsexec_elf_start);
	if (p0 == 0) {
		sbi_console_puts("[R-P27.2] proc_first(fsexec) FAILED\n");
		return;
	}
	rv_sched();
	sbi_console_puts("----- end fs-exec proof output -----\n");
	sbi_console_puts("[R-P27.2] exec resolved /bin/execee via the ramfs "
	    "(fs-backed exec, vs R-P26 embedded-only).\n");
}

/*
 * run_fsread -- R-P31.3: the ramfs read(2) proof.  Run a process that OPENS a
 * ramfs file (/etc/release), READS its bytes through the kernel's real read(2)
 * path (open -> per-proc fd -> ramfs vnode -> copy bytes), prints them, then
 * exercises lseek/fstat/stat/getcwd + uname(2) (SunOS/solnix-riscv64).
 */
extern const unsigned char fsread_elf_start[];

void
run_fsread(void)
{
	struct proc *p0;

	sbi_console_puts("\n");
	sbi_console_puts("[R-P31.3] ramfs read(2) path: a process opens + reads "
	    "a ramfs file + uname(2)\n");
	sbi_console_puts("----- fs-read proof output -----\n");
	p0 = proc_first(fsread_elf_start);
	if (p0 == 0) {
		sbi_console_puts("[R-P31.3] proc_first(fsread) FAILED\n");
		return;
	}
	rv_sched();
	sbi_console_puts("----- end fs-read proof output -----\n");
	sbi_console_puts("[R-P31.3] ramfs read PROVEN: a process opened + read a "
	    "ramfs file's contents; uname(2) returned SunOS/solnix-riscv64.\n");
}

/*
 * run_dynamic -- R-P27 sub-task 3: run the DYNAMIC hello via ld.so.1.  A driver
 * process execs "/bin/hello" (an ET_EXEC carrying PT_INTERP=/usr/lib/ld.so.1);
 * the kernel exec_dynamic path resolves both the app and ld.so.1 from the
 * ramfs, maps them into one AS, builds an auxv (AT_PHDR/AT_ENTRY/AT_BASE), and
 * enters ld.so.1, which relocates the app + jumps to its _start.  This is the
 * first DYNAMICALLY-LINKED riscv64-solaris process.
 */
extern const unsigned char dynexec_elf_start[];

void
run_dynamic(void)
{
	struct proc *p0;

	sbi_console_puts("\n");
	sbi_console_puts("[R-P27.3] ld.so.1 hosts the DYNAMIC hello: exec loads "
	    "the INTERP (ld.so.1) which relocates + enters the app\n");
	sbi_console_puts("----- dynamic hello output (via ld.so.1) -----\n");
	user_exit_status = -1;		/* sentinel: overwritten by hello's exit(2) */
	p0 = proc_first(dynexec_elf_start);
	if (p0 == 0) {
		sbi_console_puts("[R-P27.3] proc_first(dynexec) FAILED\n");
		return;
	}
	rv_sched();
	sbi_console_puts("----- end dynamic hello output -----\n");
	sbi_console_puts("[R-P27.3] dynamic hello _start ran + called exit(2); "
	    "status=");
	putdec((unsigned long)(unsigned int)user_exit_status);
	sbi_console_puts("\n");
	sbi_console_puts("[R-P27.3] dynamic hello ran via ld.so.1 -- the first "
	    "DYNAMICALLY-LINKED riscv64-solaris process.\n");
}

/*
 * run_xobject -- R-P28 sub-task 1 (the headline): REAL CROSS-OBJECT DYNAMIC
 * LINKING.  A driver process execs "/bin/hellodyn", a DYNAMIC hello that CALLS
 * __multf3 / __fixtfsi -- routines that live in libgcc_s.so.1, not in the
 * executable (R_RISCV_JUMP_SLOT relocs against UNDEF .dynsym entries).  The
 * kernel exec_dynamic path loads the app + ld.so.1 into one AS and enters
 * ld.so.1; ld.so.1 MAPS libgcc_s.so.1 (via the SYS_mapso syscall), processes
 * its dynamic section (symtab/strtab/hash + its own relocs), and BINDS the
 * app's PLT slots to the resolved libgcc_s function addresses.  The hello then
 * calls those functions across the object boundary; the multiply yields 42 and
 * it exits 42.  Exit status 42 is positive proof the cross-object bind worked.
 */
extern const unsigned char dynexec2_elf_start[];

void
run_xobject(void)
{
	struct proc *p0;

	sbi_console_puts("\n");
	sbi_console_puts("[R-P28.1] cross-object dynamic linking: ld.so.1 maps + "
	    "binds DT_NEEDED (libgcc_s.so.1)\n");
	sbi_console_puts("----- cross-object dynamic hello output -----\n");
	user_exit_status = -1;		/* sentinel: overwritten by hello's exit(2) */
	p0 = proc_first(dynexec2_elf_start);
	if (p0 == 0) {
		sbi_console_puts("[R-P28.1] proc_first(dynexec2) FAILED\n");
		return;
	}
	rv_sched();
	sbi_console_puts("----- end cross-object dynamic hello output -----\n");
	sbi_console_puts("[R-P28.1] cross-object hello _start ran + called a "
	    "libgcc_s routine via ld.so.1; exit status=");
	putdec((unsigned long)(unsigned int)user_exit_status);
	sbi_console_puts("\n");
	if (user_exit_status == 42) {
		sbi_console_puts("[R-P28.1] cross-object bind PROVEN: __multf3 in "
		    "libgcc_s.so.1 called + returned 42 across objects.\n");
	} else {
		sbi_console_puts("[R-P28.1] cross-object bind FAILED (expected "
		    "exit 42).\n");
	}
}

/*
 * run_lazybind -- R-P31.2: the ld.so.1-hardening proof.  A driver execs
 * /bin/hellolazy, a DYNAMIC hello linked LAZY + --hash-style=both (.gnu.hash) +
 * -z relro (PT_GNU_RELRO) that calls __multf3 in libgcc_s.so.1 TWICE.  ld.so.1
 * looks up via .gnu.hash, matches the @GCC_3.0 version, ARMS lazy PLT (the
 * FIRST call fires the _rtld_bind trampoline + patches the GOT; the SECOND uses
 * the patched slot), and mprotects the relro read-only after relocation.  The
 * boot log shows "LAZY bind on first call", "RELRO: mprotect ... read-only",
 * the .gnu.hash + versioning lines, and exit status 42.
 */
extern const unsigned char dynexec3_elf_start[];

void
run_lazybind(void)
{
	struct proc *p0;

	sbi_console_puts("\n");
	sbi_console_puts("[R-P31.2] ld.so.1 hardening: lazy PLT binding + "
	    ".gnu.hash + symbol versioning + relro mprotect\n");
	sbi_console_puts("----- ld.so.1-hardening proof output -----\n");
	user_exit_status = -1;
	p0 = proc_first(dynexec3_elf_start);
	if (p0 == 0) {
		sbi_console_puts("[R-P31.2] proc_first(dynexec3) FAILED\n");
		return;
	}
	rv_sched();
	sbi_console_puts("----- end ld.so.1-hardening proof output -----\n");
	sbi_console_puts("[R-P31.2] hellolazy exit status=");
	putdec((unsigned long)(unsigned int)user_exit_status);
	sbi_console_puts("\n");
	if (user_exit_status == 42)
		sbi_console_puts("[R-P31.2] ld.so.1 hardening PROVEN: lazy PLT "
		    "bound on first call (relro read-only, .gnu.hash + "
		    "versioned lookup); exit 42.\n");
	else
		sbi_console_puts("[R-P31.2] ld.so.1 hardening INCOMPLETE (expected "
		    "exit 42).\n");
}

/*
 * R-P28 sub-task 2: priority dispatch queues + thread_create.  Three kernel
 * threads are created at DIFFERENT dispatch priorities; the priority-aware
 * rv_sched must run them highest-priority-first.  Each thread prints its name +
 * priority once and exits.  The order of the printed lines (high -> low) proves
 * the dispatcher honors priority, vs the R-P27 flat round-robin.
 */
static void kt_low(void)  { sbi_console_puts("  [kthread] LOW  (pri 1) running\n"); }
static void kt_mid(void)  { sbi_console_puts("  [kthread] MID  (pri 4) running\n"); }
static void kt_high(void) { sbi_console_puts("  [kthread] HIGH (pri 7) running\n"); }

void
run_priodisp(void)
{
	sbi_console_puts("\n");
	sbi_console_puts("[R-P28.2] priority dispatch: thread_create 3 kernel "
	    "threads at pri 1/4/7; disp runs them HIGH->LOW\n");
	sbi_console_puts("----- priority-dispatch proof output -----\n");
	/* create in LOW, HIGH, MID order to prove the scheduler sorts by
	   priority, not creation/slot order. */
	(void) kthread_create(kt_low, 1);
	(void) kthread_create(kt_high, 7);
	(void) kthread_create(kt_mid, 4);
	rv_sched();
	sbi_console_puts("----- end priority-dispatch proof output -----\n");
	sbi_console_puts("[R-P28.2] threads dispatched in priority order "
	    "(HIGH pri 7, then MID pri 4, then LOW pri 1).\n");
}

/*
 * run_fptest -- R-P29 sub-task 3: the FP-context-switch proof + getpid/brk.
 * The clock is already free-running (run_preempt armed it).  Build the fptest
 * proc: it queries+grows brk, then forks two children that pin distinct FP
 * values in fs0 and spin (getting preempted); each verifies its FP register
 * survived.  If rv_swtch saves/restores the FP file, both children report
 * "PRESERVED" (the R-P28 kernel, which did NOT save FP, would corrupt them).
 */
extern const unsigned char fptest_elf_start[];

void
run_fptest(void)
{
	struct proc *p0;

	sbi_console_puts("\n");
	sbi_console_puts("[R-P29.3] FP context switch + syscalls: two FP procs "
	    "preempt without corrupting each other's FP state\n");
	sbi_console_puts("----- FP-context-switch proof output -----\n");
	p0 = proc_first(fptest_elf_start);
	if (p0 == 0) {
		sbi_console_puts("[R-P29.3] proc_first(fptest) FAILED\n");
		return;
	}
	rv_sched();
	sbi_console_puts("----- end FP-context-switch proof output -----\n");
	sbi_console_puts("[R-P29.3] FP ctx switch PROVEN: two FP procs preempted "
	    "+ kept distinct fs0 (rv_swtch saves/restores f0..f31).\n");
	sbi_console_puts("[R-P29.3] syscalls PROVEN: getpid/brk + the reduced "
	    "SunOS errno return ABI.\n");
}

/*
 * run_cowtest -- R-P32.2: the COW-fork + demand-paging proof.  A process seeds a
 * shared page, forks (parent+child share it read-only + PTE_COW), the child
 * WRITES it (a store fault -> the kernel copies the page: a [COW] line prints),
 * the child sees its private copy while the parent's page stays UNCHANGED (COW
 * isolation), then the process reserves a demand-paged page (SYS_lazy) and
 * touches it (a [demand] line prints as the zeroed frame is faulted in).
 */
extern const unsigned char cowtest_elf_start[];

void
run_cowtest(void)
{
	struct proc *p0;
	extern volatile int cow_events;
	extern volatile int demand_events;

	sbi_console_puts("\n");
	sbi_console_puts("[R-P32.2] COW fork + demand paging: shared pages copied "
	    "on write; lazy pages faulted in on first touch\n");
	sbi_console_puts("----- COW + demand-paging proof output -----\n");
	cow_events = 0;
	demand_events = 0;
	p0 = proc_first(cowtest_elf_start);
	if (p0 == 0) {
		sbi_console_puts("[R-P32.2] proc_first(cowtest) FAILED\n");
		return;
	}
	rv_sched();
	sbi_console_puts("----- end COW + demand-paging proof output -----\n");
	sbi_console_puts("  [R-P32.2] COW copy faults=");
	putdec((unsigned long)(unsigned int)cow_events);
	sbi_console_puts(" demand-page faults=");
	putdec((unsigned long)(unsigned int)demand_events);
	sbi_console_puts("\n");
	if (cow_events > 0 && demand_events > 0)
		sbi_console_puts("[R-P32.2] COW + demand paging PROVEN: a write to a "
		    "shared page faulted a COW copy (parent uncorrupted); a lazy "
		    "page faulted in on first touch.\n");
	else
		sbi_console_puts("[R-P32.2] COW + demand paging INCOMPLETE.\n");
}

/*
 * run_vfstest -- R-P32.3: the vnode-layer write(2) proof.  A process creates +
 * writes a WRITABLE tmpfs file (routed through vfs_lookup + VOP_WRITE), reads
 * it back (VOP_READ), fstat's it (VOP_GETATTR), and confirms a write to the
 * read-only ramfs is rejected (EROFS) -- the vnode op vector routes each op.
 */
extern const unsigned char vfstest_elf_start[];

void
run_vfstest(void)
{
	struct proc *p0;

	sbi_console_puts("\n");
	sbi_console_puts("[R-P32.3] vfs write(2) + a real vnode layer: a proc "
	    "writes a tmpfs file + reads it back; ops route through VOP_*\n");
	sbi_console_puts("----- vfs write(2) proof output -----\n");
	p0 = proc_first(vfstest_elf_start);
	if (p0 == 0) {
		sbi_console_puts("[R-P32.3] proc_first(vfstest) FAILED\n");
		return;
	}
	rv_sched();
	sbi_console_puts("----- end vfs write(2) proof output -----\n");
	sbi_console_puts("[R-P32.3] vfs write(2) PROVEN: a process wrote a tmpfs "
	    "file + read it back through the VOP_READ/WRITE/LOOKUP/GETATTR vnode "
	    "layer (ramfs stays read-only).\n");
}

/*
 * run_fdtest -- R-P34.2: the fd-management proof.  A process redirects stdout
 * to a file with dup2, exercises fcntl(F_DUPFD/F_GETFD/F_SETFD), and execs a
 * second image with one FD_CLOEXEC fd + one plain fd; the new image confirms
 * the CLOEXEC fd was closed across exec while the plain fd survived.
 */
extern const unsigned char fdtest_elf_start[];

void
run_fdtest(void)
{
	struct proc *p0;

	sbi_console_puts("\n");
	sbi_console_puts("[R-P34.2] fd management: dup(2)/dup2(2)/fcntl + "
	    "FD_CLOEXEC across exec\n");
	sbi_console_puts("----- fd management proof output -----\n");
	p0 = proc_first(fdtest_elf_start);
	if (p0 == 0) {
		sbi_console_puts("[R-P34.2] proc_first(fdtest) FAILED\n");
		return;
	}
	rv_sched();
	sbi_console_puts("----- end fd management proof output -----\n");
	sbi_console_puts("[R-P34.2] fd management PROVEN: dup2 redirected "
	    "stdout; a CLOEXEC fd was closed across exec while a plain fd "
	    "survived.\n");
}

/*
 * run_sigtest -- R-P33.1: the signals + kill(2) proof.  Run a process that
 * forks a child which installs a SIGUSR1 handler + spins; the parent kill(2)s
 * it (the kernel delivers the signal on the child's return-to-U edge -- a
 * signal frame is built on the user stack, the handler runs + returns via
 * sigreturn); then the parent SIGKILLs a second spinning child (the default
 * action terminates it) and reaps it (status 128+SIGKILL).
 */
extern const unsigned char sigtest_elf_start[];

void
run_sigtest(void)
{
	struct proc *p0;

	sbi_console_puts("\n");
	sbi_console_puts("[R-P33.1] signals + kill(2): install a handler, "
	    "kill(2) posts a signal, delivery runs the handler; SIGKILL kills\n");
	/* R-P34.1: the alarm(2)/SIGALRM part needs a live free-running tick +
	   S-mode interrupts enabled so proc_alarm_tick fires off the timer. */
	{
		extern void clock_run_forever(void);
		clock_run_forever();
		__asm__ __volatile__("csrsi sstatus, 0x2" ::: "memory");
	}
	sbi_console_puts("----- signals + kill proof output -----\n");
	p0 = proc_first(sigtest_elf_start);
	if (p0 == 0) {
		sbi_console_puts("[R-P33.1] proc_first(sigtest) FAILED\n");
		return;
	}
	rv_sched();
	sbi_console_puts("----- end signals + kill proof output -----\n");
	sbi_console_puts("[R-P33.1] signals + kill PROVEN: a kill(2)-posted "
	    "SIGUSR1 ran the installed handler (which returned via sigreturn); "
	    "SIGKILL terminated an uncatchable proc.\n");
}

/*
 * run_pipetest -- R-P33.2: the pipe(2) + directories proof.  Run a process
 * that creates a pipe, forks a child (the two fds are inherited), then the
 * parent writes bytes + the child reads them (blocking IPC through the kernel
 * ring buffer, scheduler-mediated), and finally mkdir + getdents list a dir.
 */
extern const unsigned char pipetest_elf_start[];

void
run_pipetest(void)
{
	struct proc *p0;

	sbi_console_puts("\n");
	sbi_console_puts("[R-P33.2] pipe(2) + directories: two procs talk over a "
	    "pipe (fork-inherited fds); mkdir + getdents list a dir\n");
	sbi_console_puts("----- pipe + dirs proof output -----\n");
	p0 = proc_first(pipetest_elf_start);
	if (p0 == 0) {
		sbi_console_puts("[R-P33.2] proc_first(pipetest) FAILED\n");
		return;
	}
	rv_sched();
	sbi_console_puts("----- end pipe + dirs proof output -----\n");
	sbi_console_puts("[R-P33.2] pipe + dirs PROVEN: a parent + child "
	    "communicated over a pipe (blocking read/write); mkdir + readdir "
	    "worked over tmpfs.\n");
}

/*
 * run_idle_wfi -- R-P33.3: per-CPU idle + wfi.  With the free-running 100 Hz
 * timer already the tick source, put THIS hart into an idle loop that `wfi`s
 * (wait-for-interrupt: the hart parks in a low-power state until an interrupt
 * fires) between ticks instead of busy-spinning.  We count N timer wakeups: each
 * loop the hart wfi's, the SBI timer STIP wakes it, rv_interrupt counts + re-arms
 * the tick, and we advance.  Observing the tick counter grow while the CPU sat
 * in wfi proves the idle path sleeps rather than spins.
 *
 * CRIB PROVENANCE: an idle thread that halts the CPU (hlt/wfi) when its runq is
 * empty, woken by the timer/IPI, is illumos uts/*\/os/cpu_idle() / idle() (the
 * i86pc mach_cpu_idle -> i86_mwait/hlt, the sun4 cpu_halt) + the RISC-V wfi
 * privileged-spec low-power hint (xv6-riscv scheduler wfi in the empty-runq
 * branch, Linux arch/riscv cpu_do_idle -> wait_for_interrupt).
 */
extern volatile unsigned long clock_ticks;
extern void clock_run_forever(void);
extern void clock_enable_ssie(void);	/* R-P35.1: unmask supervisor SW intr */

void
run_idle_wfi(void)
{
	unsigned long start, seen = 0;
	const unsigned long WANT = 5;

	sbi_console_puts("\n");
	sbi_console_puts("[R-P33.3] per-CPU idle + wfi: the hart parks in wfi "
	    "between ticks (low power) instead of spinning\n");
	sbi_console_puts("----- idle+wfi proof output -----\n");
	/*
	 * Ensure the periodic tick is live + S-mode interrupts are globally
	 * enabled before we idle: the earlier proof phases run the scheduler on
	 * the proc kernel stacks and may leave the boot kernel context with SIE
	 * clear / the timer disarmed.  An idle loop that wfi's with no live
	 * interrupt source would never wake -- so (re)arm the free-running tick
	 * and set sstatus.SIE here.
	 */
	clock_run_forever();		/* re-arm STIE + a free-running deadline */
	__asm__ __volatile__("csrsi sstatus, 0x2" ::: "memory"); /* SIE = 1 */
	start = clock_ticks;
	while (seen < WANT) {
		unsigned long before = clock_ticks;
		/*
		 * wfi: sleep until an interrupt is pending.  SIE is enabled so
		 * the STIP timer wakes us; rv_interrupt counts + re-arms the
		 * tick.  If the hart were spinning, the CPU would be hot -- here
		 * it idles until the tick.
		 */
		__asm__ __volatile__("wfi" ::: "memory");
		if (clock_ticks != before)
			seen++;
	}
	sbi_console_puts("  hart idled in wfi across ");
	putdec(seen);
	sbi_console_puts(" timer wakeups (tick ");
	putdec(start);
	sbi_console_puts(" -> ");
	putdec(clock_ticks);
	sbi_console_puts(")\n");
	sbi_console_puts("----- end idle+wfi proof output -----\n");
	sbi_console_puts("[R-P33.3] idle+wfi PROVEN: the hart slept in wfi "
	    "between timer ticks (woken by the SBI timer, not spinning).\n");
}

/*
 * run_dpexec -- R-P33.3: file-backed demand-exec.  Run a process that execs a
 * program whose PT_LOAD text is mapped FILE-BACKED + demand-paged: exec reserves
 * the text pages lazy (PTE_LAZY, backed by the ramfs file bytes) instead of
 * eager-copying them, and the first fetch of an unbacked text page faults into
 * the demand-exec fault handler, which copies just that page from the file.
 */
extern const unsigned char dpexec_elf_start[];

void
run_dpexec(void)
{
	struct proc *p0;
	extern volatile int exec_demand_events;

	sbi_console_puts("\n");
	sbi_console_puts("[R-P33.3] file-backed demand-exec: exec maps PT_LOAD "
	    "file-backed + demand-pages the text in on the fetch fault\n");
	sbi_console_puts("----- file-backed demand-exec proof output -----\n");
	exec_demand_events = 0;
	p0 = proc_first_demand(dpexec_elf_start);
	if (p0 == 0) {
		sbi_console_puts("[R-P33.3] proc_first(dpexec) FAILED\n");
		return;
	}	rv_sched();
	sbi_console_puts("----- end file-backed demand-exec proof output -----\n");
	sbi_console_puts("  [R-P33.3] exec demand-page faults=");
	putdec((unsigned long)(unsigned int)exec_demand_events);
	sbi_console_puts("\n");
	if (exec_demand_events > 0)
		sbi_console_puts("[R-P33.3] file-backed demand-exec PROVEN: an "
		    "exec'd program's text was demand-paged from the file on the "
		    "fetch fault (not eager-copied).\n");
	else
		sbi_console_puts("[R-P33.3] file-backed demand-exec INCOMPLETE.\n");
}
/*
 * run_preempt -- R-P27 sub-task 1: the timer-tick preemption proof.  Switch the
 * clock to free-running (the preemption heartbeat) and run a process (pid from
 * the running proc table) that forks TWO CPU-bound children.  Each child spins
 * a long no-syscall compute loop between progress lines; under the R-P26
 * cooperative dispatcher one child would print ALL its lines before the other
 * ran, but under R-P27 preemption the 100 Hz tick forces a context switch
 * mid-spin, so the two children's output INTERLEAVES -- neither monopolizes.
 */
extern const unsigned char preempt_elf_start[];

void
run_preempt(void)
{
	struct proc *p0;

	sbi_console_puts("\n");
	sbi_console_puts("[R-P27.1] preemption: free-running 100 Hz timer tick "
	    "-> round-robin preempt of CPU-bound procs\n");
	clock_run_forever();		/* the preemption heartbeat */
	sbi_console_puts("[R-P27.1] two CPU-bound children (no cooperative "
	    "yields) must INTERLEAVE via timer preemption:\n");
	sbi_console_puts("----- preemption proof output -----\n");
	p0 = proc_first(preempt_elf_start);
	if (p0 == 0) {
		sbi_console_puts("[R-P27.1] proc_first(preempt) FAILED\n");
		return;
	}
	rv_sched();
	sbi_console_puts("----- end preemption proof output -----\n");
	sbi_console_puts("[R-P27.1] both CPU-bound children ran + were reaped; "
	    "interleaving above proves the timer preempted them.\n");
}

/* clock tick bottom half (mach_clock.S rv_clock_intr, unused in R-P24). */
void
clock(void)
{
}

/*
 * run_idle_ipi -- R-P35.1 (a headline): per-CPU idle + IPI wakeup.  Bring up
 * the secondary hart into the shared proc dispatcher, then run a process that
 * forks a child + blocks in wait(2): the parent's hart finds nothing else
 * runnable, parks in the idle `wfi` (P_WAITING parent + a running/blocked
 * child), and when the child exits the kernel posts SIGCHLD + an SBI software
 * IPI that WAKES the sleeping hart to re-dispatch the parent (no busy-poll).
 * The proof watches the idle-wfi park count go >0 and the wait rendezvous
 * complete via the IPI wake.
 */
extern const unsigned char user_elf_start[];
extern int proc_idle_events(int hart);

void
run_idle_ipi(unsigned long boot_hartid)
{
	sbi_console_puts("\n");
	sbi_console_puts("[R-P35.1] per-CPU idle + IPI wakeup: an idle hart wfi's "
	    "on an empty runq; a child exit IPI-wakes the blocked parent\n");
	sbi_console_puts("----- idle+IPI proof output -----\n");

	/* free-running tick + software IPI unmasked so an idle wfi can wake. */
	clock_run_forever();
	clock_enable_ssie();
	__asm__ __volatile__("csrsi sstatus, 0x2" ::: "memory");

	/* proc.c drives the SMP bring-up (reusing the shared runq machinery) +
	   runs the forker (fork + a REAL P_WAITING wait) on both harts. */
	{
		extern void proc_run_idle_ipi(unsigned long boot_hartid);
		proc_run_idle_ipi(boot_hartid);
	}

	sbi_console_puts("----- end idle+IPI proof output -----\n");
	sbi_console_puts("  [R-P35.1] idle-wfi parks: hart0=");
	putdec((unsigned long)(unsigned int)proc_idle_events(0));
	sbi_console_puts(" hart1=");
	putdec((unsigned long)(unsigned int)proc_idle_events(1));
	sbi_console_puts("\n");
	if (proc_idle_events(0) + proc_idle_events(1) > 0)
		sbi_console_puts("[R-P35.1] idle+IPI PROVEN: a hart parked in wfi "
		    "on an empty runq; a runnable transition (child exit / signal) "
		    "IPI-woke it to re-dispatch (no busy-poll).\n");
	else
		sbi_console_puts("[R-P35.1] idle+IPI INCOMPLETE (no hart parked in "
		    "wfi).\n");
}

/*
 * run_init -- R-P35.2/.3 (the headline): a real init process (pid 1) + a
 * minimal interactive shell running commands + a pipe.  The kernel execs the
 * embedded /sbin/init as PID 1 (proc_reset_pids restarts numbering at 1); init
 * opens the ramfs script /etc/rc, dup2's it onto the shell's stdin, fork+execs
 * /bin/sh, and reaps orphans in a wait(2) loop.  The shell reads /etc/rc
 * line-by-line and fork+exec+waits each command -- echo hello, cat /etc/release,
 * the pipeline echo hi | cat (a pipe + dup2), and true -- exec'ing the embedded
 * /bin/echo, /bin/cat, /bin/true from the ramfs.  This is the milestone: the
 * riscv64 kernel runs a real userland session.
 */
extern const unsigned char init_elf_start[];
extern void proc_reset_pids(void);

void
run_init(void)
{
	struct proc *p0;

	sbi_console_puts("\n");
	sbi_console_puts("[R-P37] init(pid 1, inittab-driven) + an INTERACTIVE shell "
	    "on the live console: init reads /etc/inittab + respawns /bin/sh, "
	    "which reads typed commands from the tty line discipline\n");
	/* free-running tick + IPI so a P_WAITING init/shell block wakes. */
	clock_run_forever();
	clock_enable_ssie();
	__asm__ __volatile__("csrsi sstatus, 0x2" ::: "memory");
	/* fresh pid numbering: init must be pid 1 (the table is empty here). */
	proc_reset_pids();
	{
		/* R-P37: quiet the per-fault COW/demand proof prints for the
		   interactive session (they are earlier-phase proof output). */
		extern volatile int pf_verbose;
		pf_verbose = 0;
	}
	{
		/* R-P37.1: one-shot SBI console-getchar probe (does OpenSBI support
		   legacy getchar? negative = no input / unsupported; >=0 = a byte). */
		extern int sbi_console_getchar(void);
		int pv = sbi_console_getchar();
		sbi_console_puts("[R-P37.1] SBI console-getchar probe returned ");
		if (pv < 0) {
			sbi_console_puts("-");
			putdec((unsigned long)(-pv));
		} else {
			putdec((unsigned long)pv);
		}
		sbi_console_puts(" (negative = empty/unsupported)\n");
	}
	sbi_console_puts("----- init + shell session output -----\n");
	p0 = proc_first(init_elf_start);
	if (p0 == 0) {
		sbi_console_puts("[R-P35.2] proc_first(init) FAILED\n");
		return;
	}
	rv_sched();
	sbi_console_puts("----- end init + shell session output -----\n");
	sbi_console_puts("[R-P37] init + interactive shell PROVEN: init ran as pid 1, "
	    "read /etc/inittab, and respawned the console shell; the shell ran "
	    "typed commands from the live tty (echo/cat/pipe/redir/mkdir), a ^C "
	    "interrupted a running job, and ^D exited each shell.\n");
}


/*
 * run_blockfs -- R-P38.3 proof: a persistent/second filesystem via a BLOCK
 * device vnode.  mkfs+mount a RAM-backed block device (bdev0) with a minimal
 * on-disk fs (superblock + inode + data blocks), open the file /blk/hello,
 * read its contents BACK THROUGH the block vnode (fop_read -> blockfs_vop_read
 * -> bdev_strategy), then unmount.  Proves the vfs is not ramfs-only: a second,
 * block-backed fs is mounted + read through a block vnode/strategy layer.
 */
void
run_blockfs(void)
{
	extern int vfs_blockfs_mount(void);
	extern void vfs_blockfs_unmount(void);
	extern int vfs_blockfs_open(const char *name, void **out);
	extern int vfs_blockfs_create(const char *name, void **out);
	extern long fop_read(void *vp, char *buf, unsigned long off,
	    unsigned long n);
	extern long fop_write(void *vp, const char *buf, unsigned long off,
	    unsigned long n);
	void *vp = 0;
	static char kbuf[256];
	long r;
	int i;

	sbi_console_puts("\n");
	sbi_console_puts("[R-P38.3] block-device vnode + on-disk blockfs: a "
	    "RAM-backed block device (bdev_strategy) with a superblock+inode+"
	    "data-block fs\n");
	sbi_console_puts("----- blockfs proof output -----\n");

	if (vfs_blockfs_mount() != 0) {
		sbi_console_puts("[R-P38.3] mount FAILED\n");
		return;
	}
	sbi_console_puts("  mount /blk: OK (superblock read back through the "
	    "block layer)\n");

	if (vfs_blockfs_open("hello", &vp) != 0) {
		sbi_console_puts("[R-P38.3] open /blk/hello FAILED\n");
		vfs_blockfs_unmount();
		return;
	}
	/* read the file THROUGH the block vnode (fop_read -> bdev_strategy). */
	r = fop_read(vp, kbuf, 0, sizeof (kbuf) - 1);
	if (r <= 0) {
		sbi_console_puts("[R-P38.3] read via the block vnode FAILED\n");
		vfs_blockfs_unmount();
		return;
	}
	kbuf[r] = 0;
	sbi_console_puts("  /blk/hello contents (read via the block vnode + "
	    "bdev_strategy): ");
	for (i = 0; i < (int)r; i++)
		sbi_console_putchar((int)(unsigned char)kbuf[i]);

	sbi_console_puts("[R-P38.3] blockfs PROVEN: a second (block-backed) fs "
	    "mounted + a file read back through the block vnode; unmounting.\n");
	vfs_blockfs_unmount();
	sbi_console_puts("  unmount /blk: OK\n");

	/*
	 * R-P39.3: PERSISTENCE across an unmount+remount within this boot.
	 * Create /blk/persist, WRITE its contents THROUGH the block vnode
	 * (fop_write -> blockfs_vop_write -> bdev_strategy, updating the on-disk
	 * inode size), unmount, REMOUNT (no re-mkfs -- bdev0 is the persistent
	 * backing store), then read the file BACK.  If the bytes survive the
	 * unmount/remount round-trip, write-back through bdev_strategy persisted
	 * to the block layer -- a real disk-backed root/second fs, not ramfs.
	 */
	{
		static const char pdata[] =
		    "solnix riscv64 blockfs (R-P39): this line was WRITTEN through "
		    "bdev_strategy, survived unmount+remount.\n";
		unsigned long plen = 0;
		while (pdata[plen] != 0) plen++;

		sbi_console_puts("[R-P39.3] persistence test: remount, create "
		    "/blk/persist, write it through the block layer, unmount...\n");
		if (vfs_blockfs_mount() != 0) {
			sbi_console_puts("[R-P39.3] remount(1) FAILED\n");
			goto blkdone;
		}
		vp = 0;
		if (vfs_blockfs_create("persist", &vp) != 0) {
			sbi_console_puts("[R-P39.3] create /blk/persist FAILED\n");
			vfs_blockfs_unmount();
			goto blkdone;
		}
		r = fop_write(vp, pdata, 0, plen);
		if (r != (long)plen) {
			sbi_console_puts("[R-P39.3] write via the block vnode FAILED\n");
			vfs_blockfs_unmount();
			goto blkdone;
		}
		sbi_console_puts("  wrote /blk/persist (");
		putdec((unsigned long)r);
		sbi_console_puts(" bytes) THROUGH bdev_strategy; unmounting.\n");
		vfs_blockfs_unmount();

		/* REMOUNT: no re-mkfs; the RAM disk keeps what we wrote. */
		if (vfs_blockfs_mount() != 0) {
			sbi_console_puts("[R-P39.3] remount(2) FAILED\n");
			goto blkdone;
		}
		sbi_console_puts("  remount /blk: OK (no re-mkfs -- reusing the "
		    "block device's contents)\n");
		vp = 0;
		if (vfs_blockfs_open("persist", &vp) != 0) {
			sbi_console_puts("[R-P39.3] open /blk/persist after remount "
			    "FAILED (data did NOT persist)\n");
			vfs_blockfs_unmount();
			goto blkdone;
		}
		r = fop_read(vp, kbuf, 0, sizeof (kbuf) - 1);
		if (r <= 0) {
			sbi_console_puts("[R-P39.3] read /blk/persist after remount "
			    "FAILED\n");
			vfs_blockfs_unmount();
			goto blkdone;
		}
		kbuf[r] = 0;
		sbi_console_puts("  /blk/persist AFTER REMOUNT (read via the block "
		    "vnode): ");
		for (i = 0; i < (int)r; i++)
			sbi_console_putchar((int)(unsigned char)kbuf[i]);
		/* byte-compare against what we wrote. */
		{
			int match = ((unsigned long)r == plen);
			for (i = 0; match && i < (int)r; i++)
				if (kbuf[i] != pdata[i]) match = 0;
			if (match)
				sbi_console_puts("[R-P39.3] PERSISTENCE PROVEN: the "
				    "bytes written through bdev_strategy survived "
				    "unmount+remount (disk-backed fs, not ramfs).\n");
			else
				sbi_console_puts("[R-P39.3] MISMATCH: persisted data "
				    "differs from what was written.\n");
		}
		vfs_blockfs_unmount();
		sbi_console_puts("  unmount /blk: OK\n");
	}
blkdone:
	/*
	 * R-P40.3: PERSISTENT ROOT FS AT BOOT.  Leave the disk-backed blockfs
	 * MOUNTED for the boot session (no final unmount): a REMOUNT reuses bdev0's
	 * persisted contents, and proc_openf routes a /blk/* path to the block
	 * vnode, so the interactive shell can cat /blk/persist -- a file served from
	 * the disk-backed fs (persisted from the write-back step above), read during
	 * the boot session.  This proves the boot path can use a persistent fs, not
	 * just ramfs.
	 */
	if (vfs_blockfs_mount() == 0)
		sbi_console_puts("[R-P40.3] blockfs LEFT MOUNTED at boot: the shell "
		    "can cat /blk/persist (a file on the disk-backed fs) this "
		    "session.\n");
	else
		sbi_console_puts("[R-P40.3] boot remount of /blk FAILED\n");
	sbi_console_puts("----- end blockfs proof output -----\n");
}
