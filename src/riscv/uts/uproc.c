/*
 * uproc.c — illumos riscv64 userland process model: exec + fork + wait + exit
 * (R-P8).
 *
 * R-P7 ran exactly one user process, "inline" on the single-user kernel thread
 * (a hand-rolled rv_swtch back to the exec caller on exit). R-P8 turns that
 * into a real, multi-process model: a small proc_t table, each user process
 * running on its OWN kernel thread (proc.c dispatcher), and the fork/exec/
 * wait/exit syscalls that make the process model genuinely interactive.
 *
 * The model (seed of uts/common/os fork.c/exec.c/exit.c/wait, pared to what a
 * shell + a couple utils need):
 *
 *   proc_t          pid/ppid, state (RUN/ZOMBIE/FREE), exit status, its as_t,
 *                   its kernel thread, and a saved user trap frame (p_uframe)
 *                   used to (re)enter U-mode on the process's own kthread.
 *
 *   proc_first()    exec the first process (/sbin/init) on a fresh kthread and
 *                   return its pid; the caller (rootfs single_user) then waits.
 *   proc_fork(tf)   duplicate the caller: copy the AS (full copy), clone the
 *                   caller's user frame with a0=0 into the child, spawn a child
 *                   kthread that enters U-mode with that frame. Parent gets the
 *                   child pid; child gets 0. (SYS_fork.)
 *   proc_exec(...)  replace the caller's AS with a new ELF and re-enter U-mode
 *                   at its entry (does not return to the caller's U context).
 *   proc_exit(st)   mark the caller ZOMBIE, record status, tear the process off
 *                   the cpu (thread_exit); the parent reaps in wait.
 *   proc_waitpid()  block (cooperative yield) until a child is ZOMBIE, reap it
 *                   (free AS + kthread), return its pid and status.
 *
 * The per-process kthread is the key R-P8 change: because each user process is
 * a real dispatched kernel thread, two processes (parent + forked child) are
 * two runnable contexts, and the cooperative dispatcher time-shares them across
 * their yields/syscalls — genuine multi-process.
 *
 * NOTE: full-copy fork (no COW), cooperative spin-yield wait (no real sleep/
 * wakeup channel), a fixed 16-slot proc table, no signals, no session/pgrp.
 * Upgrade path (R-P9): COW fork off the store fault, sleepq-based wait, a real
 * proc_t/lwp_t, signals.
 */

#include "sbi.h"
#include "riscv_regs.h"
#include "regs.h"

extern void kputhex(unsigned long v);
extern void kputdec(unsigned long v);

/* as.c */
typedef struct as as_t;
extern as_t *as_alloc(void);
extern as_t *as_copy(as_t *src);
extern void as_free(as_t *as);
extern int as_map(as_t *as, unsigned long va, unsigned long len,
    const void *data, unsigned long copylen, unsigned long perm);
extern void as_switch(as_t *as);
extern unsigned long as_satp(as_t *as);
extern unsigned long as_npages(as_t *as);
extern void as_setbrk(as_t *as, unsigned long brk);
extern unsigned long as_getbrk(as_t *as);
extern unsigned long as_grow(as_t *as, unsigned long newbrk);

/* elf.c */
extern int elf_load(as_t *as, const void *img, unsigned long len,
    unsigned long *entryp, unsigned long *brkp);

/* proc.c: kernel-thread dispatcher primitives. */
struct kthread;
extern struct kthread *thread_create(void (*entry)(void *), void *arg);
extern void thread_yield(void);
extern void thread_exit(void) __attribute__((noreturn));
extern unsigned long curthread_kstacktop(void);
extern int curthread_id(void);
extern void thread_reap(struct kthread *t);

/* hat: switch back to the kernel address space. */
extern unsigned long hat_kernel_satp(void);
extern void hat_as_switch(unsigned long satp);

/* kmem.c */
extern void *kmem_alloc(unsigned long size);
extern void kmem_free(void *buf, unsigned long size);

/* trap.S: sret into U-mode with the given frame. Does not return. */
extern void usermode_entry(struct regs *tf, unsigned long kstacktop);

/* rootfs.c: resolve a path to file bytes (regular files + exec images). */
extern int vfs_lookup(const char *path, const void **datap, unsigned long *lenp);

/*
 * User address-space layout. The ELF's segments sit at their p_vaddr (our
 * hand-built userland links at 0xC0010000, VPN2 slot 3). The user stack sits
 * just below 4 GiB. The heap grows up from just past the image (a_brk).
 */
#define	USTACK_TOP	0xfffff000UL
#define	USTACK_PAGES	16UL		/* 64 KiB user stack */
#define	USTACK_SIZE	(USTACK_PAGES * PAGESIZE)

typedef enum {
	PS_FREE = 0,
	PS_RUN,
	PS_ZOMBIE
} pstate_t;

typedef struct proc {
	int		p_pid;
	int		p_ppid;
	pstate_t	p_state;
	int		p_status;	/* exit status when ZOMBIE */
	as_t		*p_as;
	struct kthread	*p_thread;
	struct regs	p_uframe;	/* frame to (re)enter U-mode with */
	int		p_inuse;
	/* Tiny per-process fd table: fd 0/1/2 are the console (stdin/out/err);
	 * fd 3.. are open files (a vfs image + a read cursor). */
	struct {
		int		fd_used;
		const unsigned char *fd_data;
		unsigned long	fd_len;
		unsigned long	fd_pos;
	} p_fd[8];
} proc_t;

#define	NPROC	16
static proc_t proctab[NPROC];
static int next_pid = 1;

/* Per-cpu current user process (boot-cpu dispatch only in R-P8). */
static proc_t *curproc;

volatile int userland_active = 0;

/* ------------------------------------------------------------------------- */

static proc_t *
proc_alloc(void)
{
	int i;

	for (i = 0; i < NPROC; i++) {
		if (!proctab[i].p_inuse) {
			proc_t *p = &proctab[i];
			int k;
			unsigned char *fp = (unsigned char *)&p->p_uframe;

			for (k = 0; k < (int)sizeof (p->p_uframe); k++)
				fp[k] = 0;
			p->p_inuse = 1;
			p->p_pid = next_pid++;
			p->p_ppid = 0;
			p->p_state = PS_RUN;
			p->p_status = 0;
			p->p_as = 0;
			p->p_thread = 0;
			for (k = 0; k < 8; k++)
				p->p_fd[k].fd_used = 0;
			return (p);
		}
	}
	return (0);
}

proc_t *
proc_current(void)
{
	return (curproc);
}

int
proc_getpid(void)
{
	return (curproc != 0 ? curproc->p_pid : 0);
}

/*
 * proc_open — open a regular file by path in the current process. Resolves the
 * path via the vfs, grabs a free fd (>= 3), and records the file image + a read
 * cursor. Returns the fd, or -1 on lookup failure / no free fd. (open of an
 * exec image works too — it just reads the ELF bytes.)
 */
long
proc_open(const char *path)
{
	proc_t *p = curproc;
	const void *data;
	unsigned long len;
	int fd;

	if (p == 0 || path == 0)
		return (-1);
	if (!vfs_lookup(path, &data, &len))
		return (-1);
	for (fd = 3; fd < 8; fd++) {
		if (!p->p_fd[fd].fd_used) {
			p->p_fd[fd].fd_used = 1;
			p->p_fd[fd].fd_data = (const unsigned char *)data;
			p->p_fd[fd].fd_len = len;
			p->p_fd[fd].fd_pos = 0;
			return (fd);
		}
	}
	return (-1);			/* fd table full */
}

/*
 * proc_fread — read from an open regular-file fd (>= 3) into the user buffer
 * `ubuf`. Returns bytes read (0 at EOF), or -1 for a bad/closed fd. Console fds
 * (0/1/2) are handled by the syscall layer (uart), not here.
 */
long
proc_fread(int fd, char *ubuf, unsigned long n)
{
	proc_t *p = curproc;
	unsigned long avail, i;

	if (p == 0 || fd < 3 || fd >= 8 || !p->p_fd[fd].fd_used)
		return (-1);
	avail = p->p_fd[fd].fd_len - p->p_fd[fd].fd_pos;
	if (n > avail)
		n = avail;
	for (i = 0; i < n; i++)
		ubuf[i] = (char)p->p_fd[fd].fd_data[p->p_fd[fd].fd_pos + i];
	p->p_fd[fd].fd_pos += n;
	return ((long)n);
}

/* proc_close — close a regular-file fd. Console fds 0/1/2 always "succeed". */
long
proc_close(int fd)
{
	proc_t *p = curproc;

	if (fd >= 0 && fd <= 2)
		return (0);
	if (p == 0 || fd < 3 || fd >= 8 || !p->p_fd[fd].fd_used)
		return (-1);
	p->p_fd[fd].fd_used = 0;
	return (0);
}

/*
 * load_elf_into — build/replace `p`'s address space from the ELF image, map a
 * fresh user stack, set the initial break, and fill p->p_uframe (entry PC + a
 * clean argc=0 user stack). Shared by proc_first/proc_fork(child-exec)/exec.
 * Returns 1 on success, 0 on failure (p->p_as is left NULL on failure).
 */
static int
load_elf_into(proc_t *p, const char *path, const void *img, unsigned long len)
{
	as_t *as;
	unsigned long entry, brk = 0;
	int nseg, i;

	sbi_console_puts("[exec] ");
	sbi_console_puts(path);
	sbi_console_puts(" (");
	kputdec(len);
	sbi_console_puts(" bytes) pid ");
	kputdec((unsigned long)p->p_pid);
	sbi_console_puts("\n");

	as = as_alloc();
	if (as == 0)
		return (0);

	nseg = elf_load(as, img, len, &entry, &brk);
	if (nseg < 0) {
		as_free(as);
		return (0);
	}

	if (!as_map(as, USTACK_TOP - USTACK_SIZE, USTACK_SIZE, 0, 0,
	    PTE_R | PTE_W)) {
		as_free(as);
		return (0);
	}
	as_setbrk(as, brk);

	p->p_as = as;

	/* Fresh user frame: entry PC, top-of-stack sp with argc=0. */
	{
		unsigned char *fp = (unsigned char *)&p->p_uframe;
		for (i = 0; i < (int)sizeof (p->p_uframe); i++)
			fp[i] = 0;
	}
	p->p_uframe.r_sepc = entry;
	p->p_uframe.r_sp = (USTACK_TOP - 16) & ~15UL;
	p->p_uframe.r_a0 = 0;		/* argc */
	p->p_uframe.r_a1 = 0;		/* argv */

	/* exec starts with a clean fd table (only console fds 0/1/2 implicit). */
	for (i = 0; i < 8; i++)
		p->p_fd[i].fd_used = 0;
	return (1);
}

/*
 * user_thread_body — the kernel-thread entry for a user process. Runs on the
 * process's own kthread stack (thread_create allocated it). We are curthread;
 * install curproc, switch to the process satp, then usermode_entry drops to
 * U-mode. usermode_entry does not return; the process runs until it exits (or
 * execs, which re-enters U-mode from the syscall path). When the process exits,
 * proc_exit calls thread_exit, which switches away for good — control never
 * returns here.
 */
static void
user_thread_body(void *arg)
{
	proc_t *p = (proc_t *)arg;
	unsigned long kstacktop = curthread_kstacktop();

	curproc = p;
	userland_active = 1;

	as_switch(p->p_as);
	usermode_entry(&p->p_uframe, kstacktop);
	/* NOTREACHED */
	for (;;)
		thread_yield();
}

/*
 * proc_spawn_thread — give proc `p` a kernel thread that will enter U-mode.
 * The thread is enqueued runnable; the dispatcher runs it on the next yield.
 */
static int
proc_spawn_thread(proc_t *p)
{
	p->p_thread = thread_create(user_thread_body, p);
	return (p->p_thread != 0);
}

/*
 * proc_first — exec the first user process (/sbin/init) on its own kthread.
 * Returns its pid, or -1 on failure. The caller (rootfs single_user) then
 * waits for it. This replaces R-P7's inline proc_exec_user.
 */
int
proc_first(const char *path, const void *img, unsigned long len)
{
	proc_t *p = proc_alloc();

	if (p == 0)
		return (-1);
	p->p_ppid = 0;			/* init has no user parent */
	if (!load_elf_into(p, path, img, len)) {
		p->p_inuse = 0;
		return (-1);
	}
	if (!proc_spawn_thread(p)) {
		as_free(p->p_as);
		p->p_inuse = 0;
		return (-1);
	}
	sbi_console_puts("[proc] first process pid ");
	kputdec((unsigned long)p->p_pid);
	sbi_console_puts(" (");
	sbi_console_puts(path);
	sbi_console_puts(") spawned; satp=");
	kputhex(as_satp(p->p_as));
	sbi_console_puts("\n");
	return (p->p_pid);
}

/*
 * child_thread_body — the kthread entry for a forked child. Identical to
 * user_thread_body except the frame is already fully populated (a copy of the
 * parent's syscall frame with a0=0), so we do NOT rebuild it.
 */
static void
child_thread_body(void *arg)
{
	proc_t *p = (proc_t *)arg;
	unsigned long kstacktop = curthread_kstacktop();

	curproc = p;
	userland_active = 1;
	as_switch(p->p_as);
	usermode_entry(&p->p_uframe, kstacktop);
	for (;;)
		thread_yield();
}

/*
 * proc_fork — fork the current process. tf is the parent's syscall trap frame
 * (on the parent's kthread kernel stack). We copy the parent AS, clone tf into
 * the child's p_uframe with a0=0 (the child's fork() returns 0) and sepc
 * advanced past the ecall, spawn a child kthread, and return the child pid to
 * the parent (a0 in the parent's frame, set by the syscall dispatcher).
 * Returns the child pid (>0) to the parent, or -1 on failure.
 */
int
proc_fork(struct regs *tf)
{
	proc_t *parent = curproc;
	proc_t *child;
	int i;

	if (parent == 0)
		return (-1);
	child = proc_alloc();
	if (child == 0)
		return (-1);
	child->p_ppid = parent->p_pid;

	child->p_as = as_copy(parent->p_as);
	if (child->p_as == 0) {
		child->p_inuse = 0;
		return (-1);
	}

	/* Clone the parent's user frame; child returns 0 from fork. */
	{
		const unsigned char *sp = (const unsigned char *)tf;
		unsigned char *dp = (unsigned char *)&child->p_uframe;
		for (i = 0; i < (int)sizeof (child->p_uframe); i++)
			dp[i] = sp[i];
	}
	child->p_uframe.r_a0 = 0;		/* child fork() -> 0 */
	child->p_uframe.r_sepc = tf->r_sepc + 4;	/* skip the ecall */

	child->p_thread = thread_create(child_thread_body, child);
	if (child->p_thread == 0) {
		as_free(child->p_as);
		child->p_inuse = 0;
		return (-1);
	}

	sbi_console_puts("[fork] pid ");
	kputdec((unsigned long)parent->p_pid);
	sbi_console_puts(" -> child pid ");
	kputdec((unsigned long)child->p_pid);
	sbi_console_puts("\n");
	return (child->p_pid);
}

/*
 * proc_exec — replace the current process's address space with a new ELF and
 * re-enter U-mode at its entry. Called from the exec syscall; does not return
 * to the caller's U-mode context (the old AS is torn down). Returns -1 (into
 * the caller's a0) only on failure, in which case the caller's original AS is
 * still live and it continues.
 */
int
proc_exec(const char *path, const void *img, unsigned long len)
{
	proc_t *p = curproc;
	as_t *oldas;
	unsigned long kstacktop;

	if (p == 0)
		return (-1);
	oldas = p->p_as;

	/* Build the new AS into the process (load_elf_into sets p->p_as). */
	if (!load_elf_into(p, path, img, len)) {
		p->p_as = oldas;	/* restore; new load failed */
		return (-1);
	}

	/* New AS is live in p->p_as; free the old one (we're on the kernel
	 * trap stack, but currently the OLD satp is loaded — switch first). */
	hat_as_switch(hat_kernel_satp());
	as_free(oldas);

	kstacktop = curthread_kstacktop();
	as_switch(p->p_as);
	usermode_entry(&p->p_uframe, kstacktop);	/* does not return */
	/* NOTREACHED */
	return (0);
}

/*
 * proc_execve — the execve(path) syscall backing: resolve `path` to an ELF
 * image via the vfs, then proc_exec it (replace the current AS + re-enter
 * U-mode). Returns -1 (into a0) only on failure; on success it does not return
 * to the caller's U context (the new image runs). argv/envp are accepted but
 * not yet plumbed onto the user stack (R-P9).
 */
int
proc_execve(const char *path)
{
	const void *img;
	unsigned long len;

	if (path == 0 || !vfs_lookup(path, &img, &len))
		return (-1);
	return (proc_exec(path, img, len));
}

/*
 * proc_exit — terminate the current process. Record the status, mark ZOMBIE,
 * switch back to the kernel AS, and thread_exit (switch away for good). The
 * parent reaps the AS + kthread in proc_waitpid. Does not return.
 */
void
proc_exit(int status)
{
	proc_t *p = curproc;

	sbi_console_puts("\n[exit] pid ");
	kputdec((unsigned long)(p != 0 ? p->p_pid : 0));
	sbi_console_puts(" exit(");
	kputdec((unsigned long)status);
	sbi_console_puts(")\n");

	/* Back on the kernel AS before touching kernel-thread state. */
	hat_as_switch(hat_kernel_satp());
	__asm__ __volatile__("csrw sscratch, zero" ::: "memory");

	if (p != 0) {
		p->p_status = status;
		p->p_state = PS_ZOMBIE;
	}
	curproc = 0;
	userland_active = 0;

	thread_exit();		/* off the cpu for good; parent reaps */
	for (;;)
		__asm__ __volatile__("wfi");	/* NOTREACHED */
}

/*
 * proc_waitpid — block (cooperative yield) until a child of the current process
 * becomes ZOMBIE, reap it (free its AS + kthread, free the proc slot), and
 * return its pid; write the exit status through *statusp (if non-NULL). If the
 * caller has no children, returns -1. pid == -1 waits for any child.
 *
 * NOTE: cooperative spin-yield, not a sleepq. Correct because the child runs on
 * its own dispatched thread and WILL reach exit on a yield; a real sleep/wakeup
 * channel is R-P9. Bounded only by "a child eventually exits" \u2014 unbounded by
 * design (like real wait), but every iteration yields the cpu so the child runs.
 */
int
proc_waitpid(int pid, int *statusp)
{
	proc_t *self = curproc;
	int mypid = (self != 0) ? self->p_pid : 0;

	for (;;) {
		int i, haskid = 0;

		for (i = 0; i < NPROC; i++) {
			proc_t *c = &proctab[i];

			if (!c->p_inuse || c->p_ppid != mypid)
				continue;
			if (pid > 0 && c->p_pid != pid)
				continue;
			haskid = 1;
			if (c->p_state == PS_ZOMBIE) {
				int rpid = c->p_pid;
				int rst = c->p_status;

				if (statusp != 0)
					*statusp = rst;
				/* Reap: free AS + the (now-dead) kthread + slot. */
				as_free(c->p_as);
				thread_reap(c->p_thread);
				c->p_inuse = 0;
				c->p_state = PS_FREE;
				curproc = self;	/* restore (a child clobbered it) */
				return (rpid);
			}
		}
		if (!haskid) {
			curproc = self;
			return (-1);		/* no matching child */
		}
		thread_yield();			/* let the child run */
		/*
		 * A child (or any other user thread) that ran while we were
		 * yielded clobbered the global curproc; restore ours before the
		 * next iteration touches proctab / self.
		 */
		curproc = self;
	}
}

/*
 * proc_brk / proc_sbrk — the heap syscall. brk(newbrk) sets the break to an
 * absolute address; sbrk(incr) grows/shrinks by incr and returns the OLD break.
 * Both route through as_grow on the current process AS.
 */
long
proc_brk(unsigned long newbrk)
{
	as_t *as = (curproc != 0) ? curproc->p_as : 0;

	if (as == 0)
		return (-1);
	if (newbrk == 0)
		return ((long)as_getbrk(as));	/* query current break */
	if (as_grow(as, newbrk) == 0)
		return (-1);
	return (0);
}

long
proc_sbrk(long incr)
{
	as_t *as = (curproc != 0) ? curproc->p_as : 0;
	unsigned long old;

	if (as == 0)
		return (-1);
	old = as_getbrk(as);
	if (incr == 0)
		return ((long)old);
	if (as_grow(as, old + incr) == 0)
		return (-1);
	return ((long)old);
}
