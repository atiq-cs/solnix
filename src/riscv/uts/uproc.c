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
 * NOTE (R-P9): fork is now COW (as_cow_copy); wait is now a real sleepq
 * (sleep_on/wakeup, not spin-yield); execve delivers argv/env/auxv on the user
 * stack; copyin/copyout are fault-safe. Still a fixed 16-slot proc table, no
 * signals, no session/pgrp. Upgrade path: a real proc_t/lwp_t, signals,
 * per-thread curproc (partly done: t_curproc follows the thread).
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
extern as_t *as_cow_copy(as_t *src);
extern int as_cow_fault(as_t *as, unsigned long va);
extern void as_free(as_t *as);
extern int as_map(as_t *as, unsigned long va, unsigned long len,
    const void *data, unsigned long copylen, unsigned long perm);
extern void as_switch(as_t *as);
extern unsigned long as_satp(as_t *as);
extern unsigned long as_npages(as_t *as);
extern void as_setbrk(as_t *as, unsigned long brk);
extern unsigned long as_getbrk(as_t *as);
extern unsigned long as_grow(as_t *as, unsigned long newbrk);
extern int as_copyto(as_t *as, unsigned long va, const void *src,
    unsigned long n);

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
extern void sleep_on(void *chan);
extern void wakeup(void *chan);

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

/* blkfs.c: on-disk writable SNFS over the block cache (R-P12). */
extern int snfs_open(const char *name, int create, unsigned long *lenp);
extern long snfs_read(int slot, unsigned long off, unsigned char *kbuf,
    unsigned long n);
extern long snfs_write(int slot, unsigned long off, const unsigned char *kbuf,
    unsigned long n);
extern unsigned long snfs_len(int slot);
extern int snfs_sync(void);
extern int snfs_remount(void);
extern int snfs_ready_p(void);

/* R-P12 pipe pool (defined below); forward-declared for proc_close/proc_fork. */
static void pipe_close(int pi, int is_write);
static void pipe_ref(int pi, int is_write);
static long pipe_read(int pi, char *ubuf, unsigned long n);
static long pipe_write(int pi, const char *ubuf, unsigned long n);

/* copy.S: fault-safe user-memory access (R-P9). */
extern long copyin(const void *uaddr, void *kaddr, unsigned long n);
extern long copyout(const void *kaddr, void *uaddr, unsigned long n);

/*
 * ELF auxiliary-vector entries (a_type) the RISC-V ELF ABI puts on the initial
 * stack. We supply the small useful subset a static freestanding _start reads;
 * a full auxv (AT_PHDR/AT_BASE/AT_RANDOM ...) is the dynamic-linker upgrade.
 */
#define	AT_NULL		0
#define	AT_PAGESZ	6
#define	AT_ENTRY	9
#define	AT_UID		11
#define	AT_EUID		12
#define	AT_GID		13
#define	AT_EGID		14

/*
 * Bounded snapshot of an exec argv/envp: at most ARG_MAX_N pointers and
 * ARG_STRBUF bytes of string data. Big enough for a shell command line; a
 * larger/unbounded ARG_MAX is the upgrade. Copied out of the CALLER's user AS
 * (via copyin, which is fault-safe) BEFORE the new AS is built, then planted
 * onto the new user stack by build_user_stack.
 */
#define	ARG_MAX_N	32
#define	ARG_STRBUF	1024

struct argsnap {
	int		argc;
	int		envc;
	char		str[ARG_STRBUF];	/* packed NUL-terminated strings */
	unsigned long	aoff[ARG_MAX_N];	/* byte offset of argv[i] in str */
	unsigned long	eoff[ARG_MAX_N];	/* byte offset of envp[i] in str */
};

/* Kernel-side strlen over an already-copied string block. */
static unsigned long
ustrlen_k(const char *s)
{
	unsigned long n = 0;
	while (s[n] != 0)
		n++;
	return (n);
}

/* Kernel-side string compare (ramfs path lookup, R-P11). */
static int
str_eq_uproc(const char *a, const char *b)
{
	while (*a && *a == *b) { a++; b++; }
	return (*a == *b);
}

/*
 * argsnap_copy — snapshot a user argv[]/envp[] (NULL-terminated arrays of user
 * char* pointers) into `snap`, using fault-safe copyin so a bad pointer yields
 * a truncated/empty snapshot rather than a panic. envp may be NULL. Returns 1
 * always (best-effort; a faulting entry just stops that vector).
 */
static int
argsnap_copy(struct argsnap *snap, char *const uargv[], char *const uenvp[])
{
	unsigned long pos = 0;
	int i;

	snap->argc = 0;
	snap->envc = 0;

	for (i = 0; uargv != 0 && i < ARG_MAX_N; i++) {
		unsigned long uptr = 0;
		unsigned long j;

		if (copyin(&uargv[i], &uptr, sizeof (uptr)) != 0)
			break;			/* bad argv array page */
		if (uptr == 0)
			break;			/* NULL terminator */
		snap->aoff[i] = pos;
		/* Copy the string byte-by-byte (fault-safe) up to NUL. */
		for (j = 0; pos < ARG_STRBUF - 1; j++, pos++) {
			char ch = 0;
			if (copyin((const char *)uptr + j, &ch, 1) != 0) {
				ch = 0;		/* fault: terminate here */
			}
			snap->str[pos] = ch;
			if (ch == 0) {
				pos++;
				break;
			}
		}
		snap->argc++;
	}

	for (i = 0; uenvp != 0 && i < ARG_MAX_N; i++) {
		unsigned long uptr = 0;
		unsigned long j;

		if (copyin(&uenvp[i], &uptr, sizeof (uptr)) != 0)
			break;
		if (uptr == 0)
			break;
		snap->eoff[i] = pos;
		for (j = 0; pos < ARG_STRBUF - 1; j++, pos++) {
			char ch = 0;
			if (copyin((const char *)uptr + j, &ch, 1) != 0)
				ch = 0;
			snap->str[pos] = ch;
			if (ch == 0) {
				pos++;
				break;
			}
		}
		snap->envc++;
	}
	return (1);
}

/*
 * build_user_stack — lay out the initial process stack per the RISC-V ELF ABI
 * in the freshly-built AS `as` and return the sp value the process must enter
 * with (a0 also = argc, a1 = argv per the psABI hint). Layout, growing DOWN
 * from ustack_top (all pushed onto the stack, low-to-high in memory):
 *
 *   [strings]                (argv + envp string bytes, copied from snap)
 *   ... alignment pad ...
 *   argc                     <- sp (lowest)
 *   argv[0..argc-1], NULL
 *   envp[0..envc-1], NULL
 *   auxv pairs .. AT_NULL
 *
 * The string block is placed at the top; the pointer array + argc go at the
 * bottom (== sp) so `_start` reads argc at 0(sp), argv at 8(sp). Everything is
 * planted with as_copyto (writes into the AS's physical pages without loading
 * its satp). Returns the final sp (16-byte aligned), or 0 on layout overflow.
 */
static unsigned long
build_user_stack(as_t *as, unsigned long ustack_top, unsigned long entry,
    const struct argsnap *snap)
{
	unsigned long sp;
	unsigned long strbase;
	unsigned long uargv[ARG_MAX_N];
	unsigned long uenvp[ARG_MAX_N];
	unsigned long aux[16];
	int naux = 0;
	int i;
	unsigned long strbytes;
	unsigned long nptrs;
	unsigned long words;

	/* String block sits just below the top of stack. */
	strbytes = 0;
	{
		/* total packed string bytes = sum of both vectors (already NUL-
		 * terminated in snap->str, contiguous from offset 0). */
		int lasti;
		unsigned long endoff = 0;
		lasti = snap->argc + snap->envc;
		if (lasti == 0) {
			endoff = 0;
		} else if (snap->envc > 0) {
			endoff = snap->eoff[snap->envc - 1];
			endoff += ustrlen_k(&snap->str[endoff]) + 1;
		} else {
			endoff = snap->aoff[snap->argc - 1];
			endoff += ustrlen_k(&snap->str[endoff]) + 1;
		}
		strbytes = endoff;
	}

	sp = ustack_top;
	sp -= strbytes;
	sp &= ~15UL;			/* keep 16-byte alignment */
	strbase = sp;
	if (strbytes > 0) {
		if (!as_copyto(as, strbase, snap->str, strbytes))
			return (0);
	}

	/* Resolve each argv/envp pointer to its planted user address. */
	for (i = 0; i < snap->argc; i++)
		uargv[i] = strbase + snap->aoff[i];
	for (i = 0; i < snap->envc; i++)
		uenvp[i] = strbase + snap->eoff[i];

	/* Auxiliary vector (type,value pairs), AT_NULL-terminated. */
	aux[naux++] = AT_PAGESZ; aux[naux++] = PAGESIZE;
	aux[naux++] = AT_ENTRY;  aux[naux++] = entry;
	aux[naux++] = AT_UID;    aux[naux++] = 0;
	aux[naux++] = AT_EUID;   aux[naux++] = 0;
	aux[naux++] = AT_GID;    aux[naux++] = 0;
	aux[naux++] = AT_EGID;   aux[naux++] = 0;
	aux[naux++] = AT_NULL;   aux[naux++] = 0;

	/*
	 * Compute the size of the pointer block so we can align sp such that the
	 * FINAL sp (pointing at argc) is 16-byte aligned. Block words (8 bytes):
	 *   1 (argc) + (argc+1) (argv+NULL) + (envc+1) (envp+NULL) + naux (auxv).
	 */
	nptrs = 1 + (unsigned long)(snap->argc + 1) +
	    (unsigned long)(snap->envc + 1) + (unsigned long)naux;
	words = nptrs;
	sp -= words * 8;
	sp &= ~15UL;

	{
		unsigned long block[1 + 2 * (ARG_MAX_N + 1) + 16];
		unsigned long w = 0;

		block[w++] = (unsigned long)snap->argc;		/* argc */
		for (i = 0; i < snap->argc; i++)
			block[w++] = uargv[i];
		block[w++] = 0;					/* argv NULL */
		for (i = 0; i < snap->envc; i++)
			block[w++] = uenvp[i];
		block[w++] = 0;					/* envp NULL */
		for (i = 0; i < naux; i++)
			block[w++] = aux[i];			/* auxv */

		if (!as_copyto(as, sp, block, w * 8))
			return (0);
	}
	return (sp);
}

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

/*
 * R-P11 signals. A tiny POSIX-shaped signal set: NSIG signals, a pending bitmask
 * (p_sigpend), and a per-signal disposition table (p_sighand: 0 = default,
 * SIG_IGN_VAL = ignore, else a user handler PC). Delivery happens on the way
 * back to U-mode (proc_deliver_signals): SIGKILL force-exits; a signal with a
 * handler pushes a small signal frame and redirects sepc to the handler, which
 * returns via the sigreturn trampoline (rt_sigreturn syscall) that restores the
 * saved frame. This is the seed of illumos sig / lwp_sigmask + sendsig.
 * NOTE (R-P11 ceiling): 32 signals, no sigprocmask/queued siginfo, one frame
 * deep (no nested handlers); a full sigaction/sigprocmask stack is R-P12.
 */
#define	NSIG		32
#define	SIGINT		2
#define	SIGKILL		9
#define	SIGCHLD		17
#define	SIG_DFL_VAL	0UL
#define	SIG_IGN_VAL	1UL

typedef struct proc {
	int		p_pid;
	int		p_ppid;
	pstate_t	p_state;
	int		p_status;	/* exit status when ZOMBIE */
	as_t		*p_as;
	struct kthread	*p_thread;
	struct regs	p_uframe;	/* frame to (re)enter U-mode with */
	int		p_inuse;
	unsigned int	p_uid;		/* R-P11: /etc/passwd login sets these */
	unsigned int	p_gid;
	unsigned long	p_sigpend;	/* R-P11: pending-signal bitmask */
	unsigned long	p_sighand[NSIG];/* disposition per signal */
	int		p_insig;	/* currently in a handler (frame saved) */
	struct regs	p_sigsave;	/* frame saved across a handler */
	/* Tiny per-process fd table: fd 0/1/2 are the console (stdin/out/err);
	 * fd 3.. are open files (a vfs node + a cursor). fd_wnode!=0 => a
	 * writable ramfs node (R-P11 writable FS); else a read-only vfs image. */
	struct {
		int		fd_used;
		const unsigned char *fd_data;
		unsigned long	fd_len;
		unsigned long	fd_pos;
		void		*fd_wnode;	/* ramfs node if writable */
		int		fd_snfs;	/* SNFS slot if on-disk file, else -1 */
		int		fd_pipe;	/* pipe index if a pipe, else -1 */
		int		fd_pipe_w;	/* 1 = write end, 0 = read end */
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
			p->p_uid = 0;
			p->p_gid = 0;
			p->p_sigpend = 0;
			p->p_insig = 0;
			for (k = 0; k < NSIG; k++)
				p->p_sighand[k] = SIG_DFL_VAL;
			for (k = 0; k < 8; k++)
			for (k = 0; k < 8; k++) {
				p->p_fd[k].fd_used = 0;
				p->p_fd[k].fd_snfs = -1;
				p->p_fd[k].fd_pipe = -1;
			}
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

/*
 * proc_cow_fault — called from the trap dispatcher on a store page fault taken
 * from U-mode. If the faulting VA is a copy-on-write page in the current
 * process's AS, split it private and return 1 (retry the store); otherwise
 * return 0 (a genuine fault). This is the R-P9 COW store-fault path.
 */
int
proc_cow_fault(unsigned long va)
{
	if (curproc == 0 || curproc->p_as == 0)
		return (0);
	return (as_cow_fault(curproc->p_as, va));
}

/*
 * proc_get_current / proc_set_current — opaque save/restore of the global
 * curproc, so the dispatcher can make curproc follow the thread across a
 * context switch (needed once the clock preempts a user thread: the preempted
 * thread must resume with ITS curproc, not the preempter's). Returns/takes a
 * void* cookie (the proc_t pointer).
 */
void *
proc_get_current(void)
{
	return (curproc);
}

void
proc_set_current(void *p)
{
	curproc = (proc_t *)p;
}

/* COW fork stats (as.c) for the gate banner. */
extern unsigned long as_cow_shared_total;
extern unsigned long as_cow_copied_total;
unsigned long proc_cow_shared(void) { return (as_cow_shared_total); }
unsigned long proc_cow_copied(void) { return (as_cow_copied_total); }

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
	char kpath[128];
	unsigned long i;
	int fd;

	if (p == 0 || path == 0)
		return (-1);
	/* Fault-safe copy of the path string from user space. */
	for (i = 0; i < sizeof (kpath) - 1; i++) {
		if (copyin(path + i, &kpath[i], 1) != 0)
			return (-14);		/* EFAULT: bad path pointer */
		if (kpath[i] == 0)
			break;
	}
	kpath[i] = 0;
	if (!vfs_lookup(kpath, &data, &len))
		return (-1);
	for (fd = 3; fd < 8; fd++) {
		if (!p->p_fd[fd].fd_used) {
			p->p_fd[fd].fd_used = 1;
			p->p_fd[fd].fd_data = (const unsigned char *)data;
			p->p_fd[fd].fd_len = len;
			p->p_fd[fd].fd_pos = 0;
			p->p_fd[fd].fd_wnode = 0;   /* read-only vfs image */
			p->p_fd[fd].fd_snfs = -1;
			p->p_fd[fd].fd_pipe = -1;
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
	unsigned long avail;
	const unsigned char *src;
	unsigned long len;

	if (p == 0 || fd < 3 || fd >= 8 || !p->p_fd[fd].fd_used)
		return (-1);
	/* R-P12: pipe read end. */
	if (p->p_fd[fd].fd_pipe >= 0)
		return (pipe_read(p->p_fd[fd].fd_pipe, ubuf, n));
	/* R-P12: on-disk SNFS file. */
	if (p->p_fd[fd].fd_snfs >= 0) {
		unsigned char kb[256];
		unsigned long got, off = p->p_fd[fd].fd_pos;
		long r;
		if (n > sizeof (kb))
			n = sizeof (kb);
		r = snfs_read(p->p_fd[fd].fd_snfs, off, kb, n);
		if (r <= 0)
			return (r);
		got = (unsigned long)r;
		if (copyout(kb, ubuf, got) != 0)
			return (-14);
		p->p_fd[fd].fd_pos += got;
		return ((long)got);
	}
	/* R-P11: a writable ramfs fd reads back live data (it may have grown
	 * since open); a read-only vfs fd reads the snapshotted image. */
	if (p->p_fd[fd].fd_wnode != 0) {
		extern const unsigned char *ramfile_data(void *node,
		    unsigned long *lenp);
		src = ramfile_data(p->p_fd[fd].fd_wnode, &len);
	} else {
		src = p->p_fd[fd].fd_data;
		len = p->p_fd[fd].fd_len;
	}
	avail = (p->p_fd[fd].fd_pos < len) ? (len - p->p_fd[fd].fd_pos) : 0;
	if (n > avail)
		n = avail;
	/* Fault-safe copy into the user buffer. */
	if (n > 0 && copyout(&src[p->p_fd[fd].fd_pos], ubuf, n) != 0)
		return (-14);			/* EFAULT */
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
	p->p_fd[fd].fd_wnode = 0;	/* R-P11: clear so a reused slot is clean */
	/* R-P12: releasing a pipe end drops one reference on the pipe. */
	if (p->p_fd[fd].fd_pipe >= 0)
		pipe_close(p->p_fd[fd].fd_pipe, p->p_fd[fd].fd_pipe_w);
	p->p_fd[fd].fd_snfs = -1;
	p->p_fd[fd].fd_pipe = -1;
	return (0);
}

/*
 * load_elf_into — build/replace `p`'s address space from the ELF image, map a
 * fresh user stack, set the initial break, and fill p->p_uframe (entry PC + a
 * user stack carrying argc/argv/envp/auxv per the RISC-V ELF ABI). `snap` may
 * be NULL (no args: argc=0). Shared by proc_first/exec. Returns 1 on success,
 * 0 on failure (p->p_as is left NULL on failure).
 */
static int
load_elf_into(proc_t *p, const char *path, const void *img, unsigned long len,
    const struct argsnap *snap)
{
	as_t *as;
	unsigned long entry, brk = 0;
	unsigned long sp;
	int nseg, i;
	struct argsnap empty;

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

	if (snap == 0) {
		empty.argc = 0;
		empty.envc = 0;
		snap = &empty;
	}

	/* Build the initial stack (argc/argv/envp/auxv) in the new AS. */
	sp = build_user_stack(as, USTACK_TOP, entry, snap);
	if (sp == 0) {
		p->p_as = 0;
		as_free(as);
		return (0);
	}

	/* Fresh user frame: entry PC + the ABI stack. a0=argc, a1=argv per the
	 * RISC-V psABI hint (the true source of truth is the stack at 0(sp)). */
	{
		unsigned char *fp = (unsigned char *)&p->p_uframe;
		for (i = 0; i < (int)sizeof (p->p_uframe); i++)
			fp[i] = 0;
	}
	p->p_uframe.r_sepc = entry;
	p->p_uframe.r_sp = sp;
	p->p_uframe.r_a0 = (unsigned long)snap->argc;	/* argc */
	p->p_uframe.r_a1 = sp + 8;			/* argv (past argc) */

	/* exec starts with a clean fd table (only console fds 0/1/2 implicit). */
	for (i = 0; i < 8; i++) {
		p->p_fd[i].fd_used = 0;
		p->p_fd[i].fd_snfs = -1;
		p->p_fd[i].fd_pipe = -1;
	}
	/* R-P11: exec resets caught signals to default (POSIX); ignored stay
	 * ignored. No handler survives an image replacement. */
	for (i = 0; i < NSIG; i++) {
		if (p->p_sighand[i] != SIG_IGN_VAL)
			p->p_sighand[i] = SIG_DFL_VAL;
	}
	p->p_insig = 0;
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
	struct argsnap snap;

	if (p == 0)
		return (-1);
	p->p_ppid = 0;			/* init has no user parent */

	/* init's argv is just its path (argv[0]=path, no env). Build the snap
	 * kernel-side (no user AS to copyin from yet). */
	{
		unsigned long l = 0;
		while (path[l] != 0 && l < ARG_STRBUF - 1) {
			snap.str[l] = path[l];
			l++;
		}
		snap.str[l] = 0;
		snap.aoff[0] = 0;
		snap.argc = 1;
		snap.envc = 0;
	}

	if (!load_elf_into(p, path, img, len, &snap)) {
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
	child->p_uid = parent->p_uid;	/* R-P11: inherit credentials */
	child->p_gid = parent->p_gid;
	{
		int s;
		for (s = 0; s < NSIG; s++)
			child->p_sighand[s] = parent->p_sighand[s];
	}

	child->p_as = as_cow_copy(parent->p_as);
	if (child->p_as == 0) {
		child->p_inuse = 0;
		return (-1);
	}

	/* R-P12: child inherits the parent's open fd table (pipes, files). Bump
	 * the refcount on any inherited pipe end so close accounting is right. */
	for (i = 0; i < 8; i++) {
		child->p_fd[i] = parent->p_fd[i];
		if (parent->p_fd[i].fd_used && parent->p_fd[i].fd_pipe >= 0)
			pipe_ref(parent->p_fd[i].fd_pipe,
			    parent->p_fd[i].fd_pipe_w);
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
proc_exec(const char *path, const void *img, unsigned long len,
    const struct argsnap *snap)
{
	proc_t *p = curproc;
	as_t *oldas;
	unsigned long kstacktop;

	if (p == 0)
		return (-1);
	oldas = p->p_as;

	/* Build the new AS into the process (load_elf_into sets p->p_as). */
	if (!load_elf_into(p, path, img, len, snap)) {
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
 * proc_execve — the execve(path, argv, envp) syscall backing: snapshot the
 * caller's argv/envp out of its (still-loaded) user AS via fault-safe copyin,
 * resolve `path` to an ELF image via the vfs, then proc_exec it (replace the
 * current AS + re-enter U-mode with the argv/env/auxv stack). Returns -1 (into
 * a0) only on failure; on success it does not return to the caller's U context
 * (the new image runs). This is the RISC-V ELF ABI exec: argv/env/auxv on the
 * initial user stack (R-P9).
 */
int
proc_execve(const char *path, char *const uargv[], char *const uenvp[])
{
	const void *img;
	unsigned long len;
	struct argsnap snap;
	char kpath[128];
	unsigned long i;

	if (path == 0)
		return (-1);
	/* Fault-safe copy of the path from user space. */
	for (i = 0; i < sizeof (kpath) - 1; i++) {
		if (copyin(path + i, &kpath[i], 1) != 0)
			return (-14);		/* EFAULT */
		if (kpath[i] == 0)
			break;
	}
	kpath[i] = 0;
	if (!vfs_lookup(kpath, &img, &len))
		return (-1);

	/* Snapshot argv/envp from the CALLER's AS before it is torn down. If
	 * uargv is NULL, fall back to argv[0]=path so the new image still sees
	 * its own name. */
	if (uargv != 0) {
		argsnap_copy(&snap, uargv, uenvp);
		if (snap.argc == 0) {
			unsigned long l = 0;
			while (kpath[l] != 0 && l < ARG_STRBUF - 1) {
				snap.str[l] = kpath[l]; l++;
			}
			snap.str[l] = 0;
			snap.aoff[0] = 0;
			snap.argc = 1;
		}
	} else {
		unsigned long l = 0;
		while (kpath[l] != 0 && l < ARG_STRBUF - 1) {
			snap.str[l] = kpath[l]; l++;
		}
		snap.str[l] = 0;
		snap.aoff[0] = 0;
		snap.argc = 1;
		snap.envc = 0;
	}
	return (proc_exec(kpath, img, len, &snap));
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
	int ppid = (p != 0) ? p->p_ppid : 0;

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

	/*
	 * Wake the parent if it is blocked in wait4 (R-P9 sleepq). The wait
	 * channel is the parent's proc_t address; proc_waitpid slept on `self`.
	 * wakeup before thread_exit so the parent becomes runnable and is
	 * dispatched once we switch away.
	 */
	{
		int i;
		for (i = 0; i < NPROC; i++) {
			if (proctab[i].p_inuse && proctab[i].p_pid == ppid) {
				/* R-P11: post SIGCHLD to the parent (it may have
				 * a handler, e.g. init reaping via the handler). */
				proctab[i].p_sigpend |= (1UL << SIGCHLD);
				wakeup(&proctab[i]);
				break;
			}
		}
	}

	thread_exit();		/* off the cpu for good; parent reaps */
	for (;;)
		__asm__ __volatile__("wfi");	/* NOTREACHED */
}

/*
 * proc_waitpid — block on a real sleep queue (R-P9) until a child of the
 * current process becomes ZOMBIE, reap it (free its AS + kthread + slot), and
 * return its pid; write the exit status through *statusp (if non-NULL). If the
 * caller has no children, returns -1. pid == -1 waits for any child.
 *
 * The parent sleeps on its own proc_t address; a child's proc_exit calls
 * wakeup(&parent), so the parent is re-dispatched exactly when a child exits —
 * no cpu spin. This is the illumos cv_wait/cv_signal analog (sleep_on/wakeup).
 */
static int waitq_slept_once;

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
		/*
		 * A matching child exists but is not yet a ZOMBIE: block on the
		 * sleep queue (R-P9) until a child's proc_exit wakes us — no cpu
		 * spin. sleep_on takes us off the run queue; we resume here when
		 * woken.
		 */
		if (!waitq_slept_once) {
			waitq_slept_once = 1;
			sbi_console_puts("sleepq: parent slept in wait, "
			    "woken by child exit\n");
		}
		sleep_on(self);
		/*
		 * Woken. A child (or other user thread) that ran while we slept
		 * clobbered the global curproc; restore ours before the next scan.
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

/*
 * ===========================================================================
 * R-P11 signals: kill(2), sigaction(2), delivery on return-to-U, sigreturn.
 * ===========================================================================
 *
 * Delivery model (POSIX-shaped, one frame deep):
 *   - proc_deliver_signals(tf) runs on the way back to U-mode (called from the
 *     trap dispatcher after a syscall / preempt tick / fault, when returning to
 *     a user thread). It picks the lowest pending signal not blocked.
 *   - SIGKILL / a default-terminate signal (SIGINT default) -> proc_exit.
 *   - SIGCHLD default -> ignored (discarded), matching POSIX SIG_DFL for CHLD.
 *   - a caught signal (handler PC in p_sighand[sig]) -> save the interrupted
 *     frame into p_sigsave, set sepc=handler, a0=sig, ra=p_sigrestore (the libc
 *     sigreturn trampoline), and mark p_insig. When the handler returns it
 *     jumps to the restorer, which calls SYS_rt_sigreturn -> proc_sigreturn,
 *     restoring p_sigsave so the interrupted code resumes.
 */

static unsigned long p_sigrestore_va;	/* libc __sigreturn trampoline VA */

/*
 * proc_signal — post signal `sig` to the process with pid `pid` (or to every
 * user proc if pid<=0 for the console-broadcast case handled by the caller).
 * Sets the pending bit and wakes the target if it is asleep. Returns 0 on
 * success, -1 if no such pid. This is the kernel-internal post used by kill(2),
 * SIGCHLD (proc_exit), and the console ^C path.
 */
int
proc_signal(int pid, int sig)
{
	int i;

	if (sig <= 0 || sig >= NSIG)
		return (-1);
	for (i = 0; i < NPROC; i++) {
		if (proctab[i].p_inuse && proctab[i].p_pid == pid &&
		    proctab[i].p_state == PS_RUN) {
			proctab[i].p_sigpend |= (1UL << sig);
			wakeup(&proctab[i]);	/* if blocked, make runnable */
			return (0);
		}
	}
	return (-1);
}

/* sys_kill — the kill(2) backing: post `sig` to pid. */
long
sys_kill(int pid, int sig)
{
	return (proc_signal(pid, sig));
}

/*
 * sys_sigaction — install a disposition for `sig`. handler==0 => SIG_DFL,
 * handler==1 => SIG_IGN, else a user handler PC. `restorer` is the libc
 * sigreturn trampoline VA (recorded once, shared by all handlers). SIGKILL
 * cannot be caught or ignored (POSIX). Returns the previous disposition.
 */
long
sys_sigaction(int sig, unsigned long handler, unsigned long restorer)
{
	proc_t *p = curproc;
	unsigned long prev;

	if (p == 0 || sig <= 0 || sig >= NSIG)
		return (-1);
	if (sig == SIGKILL)
		return (-1);		/* uncatchable */
	prev = p->p_sighand[sig];
	p->p_sighand[sig] = handler;
	if (restorer != 0)
		p_sigrestore_va = restorer;
	return ((long)prev);
}

/* sys_setuid / sys_setgid — set the process credentials (login uses these
 * after reading /etc/passwd). No privilege check yet (single-user trust model);
 * a real cred/uid==0 gate is R-P12. */
long
sys_setuid(unsigned int uid)
{
	if (curproc == 0)
		return (-1);
	curproc->p_uid = uid;
	return (0);
}

long
sys_setgid(unsigned int gid)
{
	if (curproc == 0)
		return (-1);
	curproc->p_gid = gid;
	return (0);
}

long
sys_getuid(void)
{
	return (curproc != 0 ? (long)curproc->p_uid : 0);
}

/*
 * proc_deliver_signals — deliver at most one pending signal to the current
 * process on the way back to U-mode. `tf` is the trap frame we are about to
 * sret through (the process's live register state). Called from the trap
 * dispatcher for any return to a user thread. Returns after either doing
 * nothing (no pending signal), redirecting tf into a handler, or NOT returning
 * (a terminating default disposition calls proc_exit).
 */
void
proc_deliver_signals(struct regs *tf)
{
	proc_t *p = curproc;
	int sig;
	unsigned long disp;

	if (p == 0 || p->p_sigpend == 0)
		return;
	if (p->p_insig)
		return;		/* already in a handler (one frame deep) */

	for (sig = 1; sig < NSIG; sig++) {
		if ((p->p_sigpend & (1UL << sig)) == 0)
			continue;
		p->p_sigpend &= ~(1UL << sig);	/* consume */
		disp = p->p_sighand[sig];

		if (disp == SIG_IGN_VAL)
			continue;		/* ignored: discard */

		if (disp == SIG_DFL_VAL) {
			/* Default action. SIGCHLD default = ignore; SIGKILL and
			 * SIGINT default = terminate. */
			if (sig == SIGCHLD)
				continue;
			sbi_console_puts("signal: pid ");
			kputdec((unsigned long)p->p_pid);
			sbi_console_puts(" terminated by signal ");
			kputdec((unsigned long)sig);
			sbi_console_puts("\n");
			proc_exit(128 + sig);	/* does not return */
		}

		/* Caught: push a signal frame and redirect to the handler. */
		if (p_sigrestore_va == 0)
			continue;		/* no trampoline: cannot deliver */
		p->p_sigsave = *tf;		/* save the interrupted frame */
		p->p_insig = 1;
		tf->r_sepc = disp;		/* enter handler */
		tf->r_a0 = (unsigned long)sig;	/* handler(sig) */
		tf->r_ra = p_sigrestore_va;	/* return -> sigreturn trampoline */
		return;				/* deliver one per return */
	}
}

/*
 * proc_sigreturn — the rt_sigreturn(2) backing. The libc trampoline calls this
 * when a handler returns; restore the frame saved at delivery so the
 * interrupted user code resumes exactly where it was. `tf` is the current
 * (handler-return) trap frame we overwrite with the saved one. Returns nothing
 * meaningful (the restored a0 is the interrupted code's a0).
 */
void
proc_sigreturn(struct regs *tf)
{
	proc_t *p = curproc;

	if (p == 0 || !p->p_insig)
		return;
	*tf = p->p_sigsave;		/* restore interrupted state */
	p->p_insig = 0;
}

/*
 * ===========================================================================
 * R-P11 writable/seekable FS: a tiny in-memory ramfs over /tmp. A file is a
 * growable kmem buffer; open(O_CREAT) makes one, write() appends/overwrites at
 * the cursor and grows the buffer, lseek() moves the cursor, read() reads back.
 * This gives real write-back + seek semantics (the gate) without a full on-disk
 * FS; a block-cache-backed vioblk FS is the R-P12 upgrade.
 * NOTE (R-P11 ceiling): in-memory, fixed file count, no dirs/unlink/persistence;
 * a vnode + block cache over vioblk with write-back is R-P12.
 * ===========================================================================
 */
#define	NRAMFILE	8
#define	RAMFILE_MAX	(64UL * 1024)	/* 64 KiB per file cap */
#define	O_CREAT		0x40		/* matches libc O_CREAT */
#define	O_WRONLY	0x1
#define	O_RDWR		0x2

struct ramfile {
	int		rf_used;
	char		rf_path[64];
	unsigned char	*rf_data;
	unsigned long	rf_len;		/* current file size */
	unsigned long	rf_cap;		/* allocated capacity */
};
static struct ramfile ramfiles[NRAMFILE];

/* Live data accessor for a ramfs node (used by proc_fread, declared earlier). */
const unsigned char *
ramfile_data(void *node, unsigned long *lenp)
{
	struct ramfile *r = (struct ramfile *)node;
	*lenp = r->rf_len;
	return (r->rf_data);
}

static struct ramfile *
ramfs_find(const char *path)
{
	int i;
	for (i = 0; i < NRAMFILE; i++)
		if (ramfiles[i].rf_used &&
		    str_eq_uproc(ramfiles[i].rf_path, path))
			return (&ramfiles[i]);
	return (0);
}

static struct ramfile *
ramfs_create(const char *path)
{
	int i, j;
	for (i = 0; i < NRAMFILE; i++) {
		if (!ramfiles[i].rf_used) {
			struct ramfile *r = &ramfiles[i];
			r->rf_data = kmem_alloc(RAMFILE_MAX);
			if (r->rf_data == 0)
				return (0);
			r->rf_cap = RAMFILE_MAX;
			r->rf_len = 0;
			for (j = 0; path[j] != 0 && j < 62; j++)
				r->rf_path[j] = path[j];
			r->rf_path[j] = 0;
			r->rf_used = 1;
			return (r);
		}
	}
	return (0);
}

/*
 * proc_openat_w — open supporting O_CREAT/O_WRONLY/O_RDWR against the ramfs.
 * If the flags request write/create and the path is not a read-only vfs file,
 * back the fd with a ramfs node (creating it on O_CREAT). Read-only opens fall
 * through to the existing proc_open (vfs image). Returns fd or negative errno.
 */
long
proc_openat_w(const char *path, int flags)
{
	proc_t *p = curproc;
	char kpath[64];
	unsigned long i;
	int fd;
	struct ramfile *r;

	if (p == 0 || path == 0)
		return (-1);
	for (i = 0; i < sizeof (kpath) - 1; i++) {
		if (copyin(path + i, &kpath[i], 1) != 0)
			return (-14);
		if (kpath[i] == 0)
			break;
	}
	kpath[i] = 0;

	/* R-P12: paths under /data/ live on the on-disk SNFS (block-cached). */
	if (kpath[0] == '/' && kpath[1] == 'd' && kpath[2] == 'a' &&
	    kpath[3] == 't' && kpath[4] == 'a' && kpath[5] == '/') {
		extern long proc_openat_snfs(const char *kpath, int flags);
		return (proc_openat_snfs(kpath, flags));
	}

	/* Read-only open of an existing file: route to the read-only vfs path
	 * unless it already exists in the ramfs. */
	if ((flags & (O_CREAT | O_WRONLY | O_RDWR)) == 0 &&
	    ramfs_find(kpath) == 0)
		return (proc_open(path));

	r = ramfs_find(kpath);
	if (r == 0) {
		if (!(flags & O_CREAT))
			return (-1);		/* ENOENT-ish */
		r = ramfs_create(kpath);
		if (r == 0)
			return (-1);
	}
	for (fd = 3; fd < 8; fd++) {
		if (!p->p_fd[fd].fd_used) {
			p->p_fd[fd].fd_used = 1;
			p->p_fd[fd].fd_wnode = r;
			p->p_fd[fd].fd_data = r->rf_data;
			p->p_fd[fd].fd_len = r->rf_len;
			p->p_fd[fd].fd_pos = 0;
			p->p_fd[fd].fd_snfs = -1;
			p->p_fd[fd].fd_pipe = -1;
			return (fd);
		}
	}
	return (-1);				/* fd table full */
}

/*
 * proc_fwrite — write to an open writable (ramfs) fd. Copies from the user
 * buffer into the file buffer at the cursor, growing rf_len, and advances the
 * cursor. Console fds (1/2) are handled by the syscall layer. Returns bytes
 * written or negative errno.
 */
long
proc_fwrite(int fd, const char *ubuf, unsigned long n)
{
	proc_t *p = curproc;
	struct ramfile *r;
	unsigned long pos;

	if (p == 0 || fd < 3 || fd >= 8 || !p->p_fd[fd].fd_used)
		return (-1);
	/* R-P12: pipe write end. */
	if (p->p_fd[fd].fd_pipe >= 0)
		return (pipe_write(p->p_fd[fd].fd_pipe, ubuf, n));
	/* R-P12: on-disk SNFS file. */
	if (p->p_fd[fd].fd_snfs >= 0) {
		unsigned char kb[256];
		unsigned long done = 0;
		while (done < n) {
			unsigned long chunk = n - done;
			long w;
			if (chunk > sizeof (kb))
				chunk = sizeof (kb);
			if (copyin(ubuf + done, kb, chunk) != 0)
				return (done > 0 ? (long)done : -14);
			w = snfs_write(p->p_fd[fd].fd_snfs,
			    p->p_fd[fd].fd_pos, kb, chunk);
			if (w <= 0)
				break;
			p->p_fd[fd].fd_pos += (unsigned long)w;
			done += (unsigned long)w;
		}
		return ((long)done);
	}
	r = (struct ramfile *)p->p_fd[fd].fd_wnode;
	if (r == 0)
		return (-1);			/* read-only file */
	pos = p->p_fd[fd].fd_pos;
	if (pos + n > r->rf_cap)
		n = (pos < r->rf_cap) ? (r->rf_cap - pos) : 0;
	if (n == 0)
		return (0);
	if (copyin(ubuf, r->rf_data + pos, n) != 0)
		return (-14);
	pos += n;
	if (pos > r->rf_len)
		r->rf_len = pos;		/* file grew (write-back) */
	p->p_fd[fd].fd_pos = pos;
	p->p_fd[fd].fd_len = r->rf_len;
	return ((long)n);
}

/*
 * proc_lseek — move the read/write cursor of an open fd. whence 0=SET, 1=CUR,
 * 2=END. Works for both writable ramfs fds and read-only vfs fds. Returns the
 * new offset or -1.
 */
long
proc_lseek(int fd, long off, int whence)
{
	proc_t *p = curproc;
	unsigned long base, len;
	long np;

	if (p == 0 || fd < 3 || fd >= 8 || !p->p_fd[fd].fd_used)
		return (-1);
	if (p->p_fd[fd].fd_pipe >= 0)
		return (-1);		/* pipes are not seekable */
	{
		struct ramfile *r = (struct ramfile *)p->p_fd[fd].fd_wnode;
		if (p->p_fd[fd].fd_snfs >= 0)
			len = snfs_len(p->p_fd[fd].fd_snfs);
		else
			len = (r != 0) ? r->rf_len : p->p_fd[fd].fd_len;
	}
	switch (whence) {
	case 0: base = 0; break;			/* SEEK_SET */
	case 1: base = p->p_fd[fd].fd_pos; break;	/* SEEK_CUR */
	case 2: base = len; break;			/* SEEK_END */
	default: return (-1);
	}
	np = (long)base + off;
	if (np < 0)
		return (-1);
	p->p_fd[fd].fd_pos = (unsigned long)np;
	return (np);
}

/*
 * ===========================================================================
 * R-P12 pipes: pipe(2), dup2(2), and blocking pipe read/write. A pipe is a
 * fixed ring buffer with a read cursor and a write cursor, plus reader/writer
 * reference counts so a read returns EOF (0) once all write ends are closed.
 * The shell wires `cmd1 | cmd2` by pipe()+fork()+dup2(): child1's stdout is the
 * write end, child2's stdin is the read end. This is the seed of illumos
 * fifofs/pipe(2). NOTE (R-P12 ceiling): fixed NPIPE pipes, PIPEBUF bytes each,
 * no O_NONBLOCK, no SIGPIPE; a real fifofs vnode is R-P13.
 * ===========================================================================
 */
#define	NPIPE		8
#define	PIPEBUF		4096

struct pipe {
	int		pp_used;
	unsigned long	pp_rpos;	/* total bytes read */
	unsigned long	pp_wpos;	/* total bytes written */
	int		pp_readers;	/* open read ends */
	int		pp_writers;	/* open write ends */
	unsigned char	pp_data[PIPEBUF];
};
static struct pipe pipetab[NPIPE];

static struct pipe *
pipe_alloc(void)
{
	int i;
	for (i = 0; i < NPIPE; i++)
		if (!pipetab[i].pp_used) {
			pipetab[i].pp_used = 1;
			pipetab[i].pp_rpos = 0;
			pipetab[i].pp_wpos = 0;
			pipetab[i].pp_readers = 1;
			pipetab[i].pp_writers = 1;
			return (&pipetab[i]);
		}
	return (0);
}

static void
pipe_ref(int pi, int is_write)
{
	if (pi < 0 || pi >= NPIPE || !pipetab[pi].pp_used)
		return;
	if (is_write)
		pipetab[pi].pp_writers++;
	else
		pipetab[pi].pp_readers++;
}

static void
pipe_close(int pi, int is_write)
{
	if (pi < 0 || pi >= NPIPE || !pipetab[pi].pp_used)
		return;
	if (is_write) {
		if (pipetab[pi].pp_writers > 0)
			pipetab[pi].pp_writers--;
		/* Last writer gone: wake blocked readers so they see EOF. */
		if (pipetab[pi].pp_writers == 0)
			wakeup(&pipetab[pi]);
	} else {
		if (pipetab[pi].pp_readers > 0)
			pipetab[pi].pp_readers--;
		if (pipetab[pi].pp_readers == 0)
			wakeup(&pipetab[pi]);	/* wake blocked writers */
	}
	if (pipetab[pi].pp_readers == 0 && pipetab[pi].pp_writers == 0)
		pipetab[pi].pp_used = 0;	/* free when both ends closed */
}

/*
 * pipe_read — copy up to n bytes from the pipe to the user buffer. Blocks (real
 * sleepq) while the pipe is empty and a writer still exists; returns 0 (EOF)
 * once empty and all writers have closed.
 */
static long
pipe_read(int pi, char *ubuf, unsigned long n)
{
	struct pipe *pp;
	proc_t *self = curproc;
	unsigned long avail, got = 0;

	if (pi < 0 || pi >= NPIPE || !pipetab[pi].pp_used)
		return (-1);
	pp = &pipetab[pi];
	for (;;) {
		avail = pp->pp_wpos - pp->pp_rpos;
		if (avail > 0)
			break;
		if (pp->pp_writers == 0)
			return (0);		/* EOF: no more writers */
		sleep_on(pp);			/* wait for data / writer close */
		curproc = self;			/* restore after wakeup */
	}
	if (n > avail)
		n = avail;
	while (got < n) {
		unsigned long idx = pp->pp_rpos % PIPEBUF;
		unsigned long run = PIPEBUF - idx;
		char ch;
		if (run > n - got)
			run = n - got;
		/* Copy byte-run through a small bounce (fault-safe). */
		{
			unsigned long i;
			for (i = 0; i < run; i++) {
				ch = (char)pp->pp_data[idx + i];
				if (copyout(&ch, ubuf + got + i, 1) != 0)
					return (got + i > 0 ? (long)(got + i) : -14);
			}
		}
		pp->pp_rpos += run;
		got += run;
	}
	wakeup(pp);				/* space freed: wake writers */
	return ((long)got);
}

/*
 * pipe_write — copy up to n bytes from the user buffer into the pipe. Blocks
 * while the pipe is full and a reader still exists; if all readers are gone
 * returns -1 (EPIPE-ish, no SIGPIPE yet).
 */
static long
pipe_write(int pi, const char *ubuf, unsigned long n)
{
	struct pipe *pp;
	proc_t *self = curproc;
	unsigned long put = 0, space;

	if (pi < 0 || pi >= NPIPE || !pipetab[pi].pp_used)
		return (-1);
	pp = &pipetab[pi];
	while (put < n) {
		if (pp->pp_readers == 0)
			return (put > 0 ? (long)put : -1);	/* EPIPE */
		space = PIPEBUF - (pp->pp_wpos - pp->pp_rpos);
		if (space == 0) {
			sleep_on(pp);
			curproc = self;
			continue;
		}
		{
			unsigned long idx = pp->pp_wpos % PIPEBUF;
			unsigned long run = PIPEBUF - idx;
			char ch;
			unsigned long i;
			if (run > space)
				run = space;
			if (run > n - put)
				run = n - put;
			for (i = 0; i < run; i++) {
				if (copyin(ubuf + put + i, &ch, 1) != 0)
					return (put + i > 0 ? (long)(put + i) : -14);
				pp->pp_data[idx + i] = (unsigned char)ch;
			}
			pp->pp_wpos += run;
			put += run;
		}
		wakeup(pp);			/* data available: wake readers */
	}
	return ((long)put);
}

/*
 * proc_pipe — the pipe(2) backing. Allocate a pipe object, grab two fds (read
 * end, write end) in the current process, and copy the pair out to the user
 * int[2]. Returns 0 on success, -1 on failure.
 */
long
proc_pipe(int *ufds)
{
	proc_t *p = curproc;
	struct pipe *pp;
	int pi, rfd = -1, wfd = -1, fd;
	int pair[2];

	if (p == 0 || ufds == 0)
		return (-1);
	pp = pipe_alloc();
	if (pp == 0)
		return (-1);
	pi = (int)(pp - pipetab);

	for (fd = 3; fd < 8 && rfd < 0; fd++)
		if (!p->p_fd[fd].fd_used) rfd = fd;
	for (fd = rfd + 1; fd < 8 && wfd < 0; fd++)
		if (!p->p_fd[fd].fd_used) wfd = fd;
	if (rfd < 0 || wfd < 0) {
		pp->pp_used = 0;
		return (-1);
	}
	p->p_fd[rfd].fd_used = 1; p->p_fd[rfd].fd_pipe = pi;
	p->p_fd[rfd].fd_pipe_w = 0; p->p_fd[rfd].fd_snfs = -1;
	p->p_fd[rfd].fd_wnode = 0; p->p_fd[rfd].fd_pos = 0;
	p->p_fd[wfd].fd_used = 1; p->p_fd[wfd].fd_pipe = pi;
	p->p_fd[wfd].fd_pipe_w = 1; p->p_fd[wfd].fd_snfs = -1;
	p->p_fd[wfd].fd_wnode = 0; p->p_fd[wfd].fd_pos = 0;

	pair[0] = rfd;
	pair[1] = wfd;
	if (copyout(pair, ufds, sizeof (pair)) != 0) {
		proc_close(rfd);
		proc_close(wfd);
		return (-14);
	}
	return (0);
}

/*
 * proc_dup2 — the dup2(2) backing. Redirect newfd to refer to the same object
 * as oldfd (closing newfd first). Supports the console fds (0/1/2) as targets:
 * dup2(pipe_wfd, 1) makes a child's stdout the pipe. We model console-target
 * redirection by recording the source object in the console-fd's slot; the
 * syscall read/write layer already special-cases fd 0/1/2, so we instead move
 * the object into the low fd slot and mark it used. Returns newfd or -1.
 */
long
proc_dup2(int oldfd, int newfd)
{
	proc_t *p = curproc;

	if (p == 0 || oldfd < 0 || oldfd >= 8 || newfd < 0 || newfd >= 8)
		return (-1);
	if (oldfd == newfd)
		return (newfd);
	if (oldfd >= 3 && !p->p_fd[oldfd].fd_used)
		return (-1);
	/* Close the target first (drops a pipe ref if it held one). */
	if (newfd >= 3 && p->p_fd[newfd].fd_used)
		proc_close(newfd);
	/* Duplicate oldfd's slot into newfd. For a console source (0/1/2) there
	 * is no slot object; but the only use is dup2(pipe_fd, 0|1), i.e. old is
	 * a real fd >=3, new is a console fd — copy the object down. */
	if (oldfd >= 3) {
		p->p_fd[newfd] = p->p_fd[oldfd];
		if (p->p_fd[oldfd].fd_pipe >= 0)
			pipe_ref(p->p_fd[oldfd].fd_pipe,
			    p->p_fd[oldfd].fd_pipe_w);
	}
	return (newfd);
}

/*
 * proc_openat_snfs — open a path under the on-disk SNFS mount point "/data/".
 * Called from proc_openat_w when the path starts with /data/. create honors
 * O_CREAT. Returns an fd (>=3) or negative errno.
 */
long
proc_openat_snfs(const char *kpath, int flags)
{
	proc_t *p = curproc;
	const char *name = kpath + 6;	/* strip "/data/" */
	unsigned long len = 0;
	int slot, fd;

	if (!snfs_ready_p())
		return (-1);
	slot = snfs_open(name, (flags & O_CREAT) ? 1 : 0, &len);
	if (slot < 0)
		return (-1);
	for (fd = 3; fd < 8; fd++) {
		if (!p->p_fd[fd].fd_used) {
			p->p_fd[fd].fd_used = 1;
			p->p_fd[fd].fd_snfs = slot;
			p->p_fd[fd].fd_pipe = -1;
			p->p_fd[fd].fd_wnode = 0;
			p->p_fd[fd].fd_len = len;
			p->p_fd[fd].fd_pos = 0;
			return (fd);
		}
	}
	return (-1);
}

/* sys_sync — flush the on-disk FS block cache to disk (R-P12). */
long
sys_sync(void)
{
	return (snfs_ready_p() ? snfs_sync() : 0);
}

/* sys_remount — invalidate the block cache + re-mount (proves persistence). */
long
sys_remount(void)
{
	return (snfs_remount() ? 0 : -1);
}
