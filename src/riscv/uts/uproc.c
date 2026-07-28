/*
 * uproc.c — illumos riscv64 userland process exec + exit (R-P7).
 *
 * The R-P7 milestone glue: turn an in-memory static riscv64 ELF into a running
 * U-mode process. This is the seam between the kernel-thread world (proc.c) and
 * userland: it builds a fresh address space (as.c), loads the ELF (elf.c), maps
 * a user stack, and drops to U-mode via usermode_entry (trap.S). When the
 * process calls the exit syscall, proc_exit switches back to the kernel address
 * space and resumes the exec caller's kernel context (a cooperative
 * return-to-kernel via rv_swtch), so the calling kernel thread continues.
 *
 * This is the seed of the illumos exec/proc model (exec_common -> exec_args ->
 * elfexec -> setregs -> lwp_rtt to U-mode; proc_exit/exit). Scope for R-P7: a
 * single live user process, no fork, one hardcoded /sbin/init image, a fixed
 * user stack, no argv/envp/auxv beyond a null-terminated stack.
 *
 * NOTE: exactly one user process at a time; no p_t/proc table, no signals, no
 * fork/wait, no argv/env passed (argc=0). Upgrade path (R-P8): a real proc_t,
 * fork()/exec() syscalls, argv/env/auxv on the user stack, and multiple LWPs.
 */

#include "sbi.h"
#include "riscv_regs.h"
#include "regs.h"

extern void kputhex(unsigned long v);
extern void kputdec(unsigned long v);

/* as.c */
typedef struct as as_t;
extern as_t *as_alloc(void);
extern int as_map(as_t *as, unsigned long va, unsigned long len,
    const void *data, unsigned long copylen, unsigned long perm);
extern void as_switch(as_t *as);
extern unsigned long as_satp(as_t *as);
extern unsigned long as_npages(as_t *as);

/* elf.c */
extern int elf_load(as_t *as, const void *img, unsigned long len,
    unsigned long *entryp);

/* proc.c: kernel stack top of the current thread (for sscratch) + the context
 * switch primitive used to return to the exec caller on proc_exit. */
extern unsigned long curthread_kstacktop(void);
struct rv_context;
extern void rv_swtch(struct rv_context *old, struct rv_context *new);

/* hat: switch back to the kernel address space on exit. */
extern unsigned long hat_kernel_satp(void);
extern void hat_as_switch(unsigned long satp);

/* kmem.c: dedicated kernel trap stack for the user process (so a trap from
 * U-mode never lands on the exec caller's stack, which must survive the run). */
extern void *kmem_alloc(unsigned long size);

/*
 * The user address-space layout for the first process. The ELF's own segments
 * sit at their p_vaddr (our hand-built init links low, e.g. 0x10000). The user
 * stack is a fixed region just below 1 GiB (well clear of the ELF and of the
 * kernel identity gigapages at 0x0 / 0x80000000, which stay kernel-only \u2014 they
 * lack PTE_U so U-mode can't touch them).
 */
#define	USTACK_TOP	0xfffff000UL	/* top of VPN2 slot 3, page-aligned */
#define	USTACK_PAGES	4UL		/* 16 KiB user stack */
#define	USTACK_SIZE	(USTACK_PAGES * PAGESIZE)

/* Saved kernel context to resume on proc_exit (the exec caller's context). */
static struct {
	unsigned long c_ra, c_sp, c_tp, c_s[12];
} exec_return_ctx;
static struct {
	unsigned long c_ra, c_sp, c_tp, c_s[12];
} exec_user_ctx;	/* scratch: rv_swtch needs an `old` to save into */

volatile int userland_active = 0;
static volatile int userland_exited = 0;
static int userland_exit_status = 0;

/*
 * proc_exec_user — exec the static ELF image [img,img+len) as the first user
 * process. Builds the address space, loads the ELF, maps a user stack, sets up
 * the user trap frame (entry PC, user sp), switches to the process satp, and
 * enters U-mode. Returns to the caller (via proc_exit's rv_swtch) once the
 * process exits; returns the process exit status, or -1 on a load failure.
 */
int
proc_exec_user(const char *path, const void *img, unsigned long len)
{
	as_t *as;
	unsigned long entry;
	int nseg;
	struct regs uframe;
	unsigned long kstacktop;
	int i;

	sbi_console_puts("\n[exec] exec ");
	sbi_console_puts(path);
	sbi_console_puts(" (");
	kputdec(len);
	sbi_console_puts(" bytes)\n");

	as = as_alloc();
	if (as == 0) {
		sbi_console_puts("[exec] as_alloc failed\n");
		return (-1);
	}

	nseg = elf_load(as, img, len, &entry);
	if (nseg < 0)
		return (-1);

	/* Map the user stack (RW, no exec). */
	if (!as_map(as, USTACK_TOP - USTACK_SIZE, USTACK_SIZE, 0, 0,
	    PTE_R | PTE_W)) {
		sbi_console_puts("[exec] user stack map failed\n");
		return (-1);
	}

	sbi_console_puts("exec: loaded ");
	sbi_console_puts(path);
	sbi_console_puts(" (");
	kputdec((unsigned long)nseg);
	sbi_console_puts(" segments, entry ");
	kputhex(entry);
	sbi_console_puts(")\n");

	/* Build the initial user register frame. */
	{
		unsigned char *fp = (unsigned char *)&uframe;
		for (i = 0; i < (int)sizeof (uframe); i++)
			fp[i] = 0;
	}
	uframe.r_sepc = entry;
	/*
	 * User sp: top of the stack region, 16-byte aligned, with a zeroed
	 * argc slot (argc=0) so a crt0 that reads argc off the stack sees 0.
	 */
	uframe.r_sp = (USTACK_TOP - 16) & ~15UL;
	uframe.r_a0 = 0;		/* argc */
	uframe.r_a1 = 0;		/* argv */

	kstacktop = curthread_kstacktop();
	if (kstacktop == 0) {
		sbi_console_puts("[exec] no kernel stack (must exec from a "
		    "kmem-stacked thread)\n");
		return (-1);
	}

	sbi_console_puts("[exec] switching to process address space (satp=");
	kputhex(as_satp(as));
	sbi_console_puts("), ");
	kputdec(as_npages(as));
	sbi_console_puts(" user pages mapped; entering U-mode\n");

	userland_active = 1;
	userland_exited = 0;

	/*
	 * Save the current (kernel) context so proc_exit can rv_swtch back here
	 * after the process exits. Then switch satp to the process AS and drop
	 * to U-mode. usermode_entry does not return; control comes back at the
	 * rv_swtch below only when proc_exit switches into exec_return_ctx.
	 */
	as_switch(as);

	/*
	 * rv_swtch(save-here=exec_user_ctx, resume=exec_return_ctx) would loop;
	 * instead we hand-roll: save our context into exec_return_ctx via a
	 * dummy swtch that immediately continues into usermode_entry, and let
	 * proc_exit swtch back into it. We use rv_swtch's ability to save `old`
	 * and load `new`: set exec_return_ctx = a context whose ra resumes just
	 * past the entry, by saving into it and loading a fresh scratch that
	 * lands in usermode_entry.
	 *
	 * Simpler + correct: usermode_entry never returns, and proc_exit does
	 * the rv_swtch(&scratch, &exec_return_ctx). So here we just need
	 * exec_return_ctx populated with THIS point. We capture it by calling
	 * rv_swtch(&exec_return_ctx, &go) where `go` is a context that jumps to
	 * enter_user() below. On proc_exit, rv_swtch(&scratch, &exec_return_ctx)
	 * resumes right after this call, and we fall through to the return.
	 */
	{
		extern void uproc_enter_trampoline(void);
		struct rvctx {
			unsigned long c_ra, c_sp, c_tp, c_s[12];
		} go;
		unsigned long uktrapstack;
		void *s;
		int k;

		/*
		 * Give the user process a DEDICATED kernel trap stack. On a trap
		 * from U-mode _trap_entry lands on the sscratch value; if that
		 * were the exec caller's stack, the U-mode trap frames would
		 * overwrite proc_exec_user's OWN frame (its saved locals + the
		 * exec_return_ctx sp target), corrupting the return-to-kernel. A
		 * separate 16 KiB trap stack keeps the caller's frame intact.
		 */
		s = kmem_alloc(16384UL);
		if (s == 0) {
			sbi_console_puts("[exec] trap-stack alloc failed\n");
			return (-1);
		}
		uktrapstack = ((unsigned long)s + 16384UL) & ~15UL;
		(void) kstacktop;	/* superseded by the dedicated trap stack */

		for (k = 0; k < 12; k++)
			go.c_s[k] = 0;
		go.c_ra = (unsigned long)uproc_enter_trampoline;
		go.c_sp = uktrapstack;
		go.c_tp = 0;
		/* pass uframe + trap stack to the trampoline via s0/s1. */
		go.c_s[0] = (unsigned long)&uframe;
		go.c_s[1] = uktrapstack;

		rv_swtch((struct rv_context *)&exec_return_ctx,
		    (struct rv_context *)&go);
		/* Resumed here by proc_exit after the process exited. */
	}

	(void) exec_user_ctx;
	hat_as_switch(hat_kernel_satp());	/* back on the kernel AS */
	userland_active = 0;

	sbi_console_puts("[exec] process exited, status ");
	kputdec((unsigned long)userland_exit_status);
	sbi_console_puts("; back in kernel\n");
	return (userland_exit_status);
}

/*
 * proc_exit — called from the exit syscall (S-mode, on the process satp, on
 * the kernel trap stack). Record the status, switch back to the kernel address
 * space, and rv_swtch into the saved exec caller context (exec_return_ctx),
 * which resumes proc_exec_user right after it launched us. Does not return.
 */
void
proc_exit(int status)
{
	userland_exit_status = status;
	userland_exited = 1;

	sbi_console_puts("\n[R-P7] userland process called exit(");
	kputdec((unsigned long)status);
	sbi_console_puts(")\n");

	/* Back to the kernel address space before touching kernel-thread state. */
	hat_as_switch(hat_kernel_satp());

	/*
	 * Clear sscratch. We entered here via a trap FROM U-mode, which left the
	 * user sp in sscratch; because proc_exit never returns through the trap
	 * exit path (it rv_swtch's back to the kernel below), that stale nonzero
	 * value would fool the next trap-from-S (e.g. a timer tick) into taking
	 * the from-U stack-swap branch. In S-mode sscratch must be 0.
	 */
	__asm__ __volatile__("csrw sscratch, zero" ::: "memory");

	/* Resume the exec caller's kernel context. Never returns. */
	rv_swtch((struct rv_context *)&exec_user_ctx,
	    (struct rv_context *)&exec_return_ctx);

	for (;;)
		__asm__ __volatile__("wfi");	/* NOTREACHED */
}
