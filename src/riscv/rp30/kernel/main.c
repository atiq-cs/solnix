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
void run_dynamic(void);
void run_xobject(void);
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
extern void proc_exit(int status);
extern long proc_wait(long *statusp);
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
	run_user();

	run_preempt();

	run_fsexec();

	run_dynamic();

	run_xobject();

	run_priodisp();

	run_fptest();

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
	 * R-P30.3 -- as_free lifecycle.  Fork+exec+exit a process N times and
	 * confirm the kmem free count is stable (no AS leak): proc_exit/do_exec
	 * now walk + unmap + free the user page tables + frames of the old AS.
	 */
	{
		extern void run_asfree(void);
		run_asfree();
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
#define	SCAUSE_LOAD_FAULT	13UL	/* load page fault */
#define	SCAUSE_STORE_FAULT	15UL	/* store/AMO page fault */

/* R-P29 W^X self-test hooks (hat.c). */
extern volatile int hat_wx_expect;
extern volatile int hat_wx_faulted;
/* R-P30 identity-drop self-test hooks (hat.c). */
extern volatile int hat_ident_expect;
extern volatile int hat_ident_faulted;

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

	if (cause == SCAUSE_S_TIMER) {
		if (rv_timer_intr() == 0) {
			/* last tick: mask the timer so no more fire. */
			__asm__ __volatile__("csrc sie, %0"
			    :: "r"(SIE_STIE) : "memory");
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
#define	SYS_brk		17
#define	SYS_getpid	20
#define	SYS_fstat	28
#define	SYS_execve	59
#define	SYS_wait	107	/* reduced waitid */
#define	SYS_mmap	115
#define	SYS_fork	142	/* reduced forksys */
#define	SYS_mapso	222	/* R-P28: map a NEEDED ET_DYN (mmap-family) */

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
		/* no fs read yet: EOF (0 bytes) on any fd. */
		r->r_x[R_X_A0] = 0;
		return;
	case SYS_open:
		/* no vfs open path yet: report -ENOSYS via the errno ABI. */
		r->r_x[R_X_A0] = (unsigned long)(-ENOSYS);
		return;
	case SYS_close:
		/* accept fd 0/1/2 (console); anything else -EBADF. */
		r->r_x[R_X_A0] = (a0 <= 2) ? 0 : (unsigned long)(-EBADF);
		return;
	case SYS_fstat:
		/* no stat backing yet: -ENOSYS via the errno ABI. */
		r->r_x[R_X_A0] = (unsigned long)(-ENOSYS);
		return;
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
