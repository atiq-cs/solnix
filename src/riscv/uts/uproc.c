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
#include "fp.h"
#include "port.h"

/*
 * Per-process open-file limit.
 *
 * Raised from 8 to 32 because a Wayland compositor binds on this early and in a
 * way that is easy to misdiagnose: it holds a listening socket, one or two fds
 * per connected client, the framebuffer, and an event port -- so 8 is exhausted
 * at roughly the THIRD client, and the symptom is a client failing to connect
 * rather than anything pointing at a table size.
 *
 * Named rather than literal because the bound appeared at ~24 separate sites
 * (bounds checks, allocation scans, fork copies, close-all loops); a literal is
 * how one of them gets missed and the table is walked past its end.
 */
#define	NOFILE		32

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
extern int as_anon_unmap(as_t *as, unsigned long va, unsigned long len);
extern unsigned long as_anon_map(as_t *as, unsigned long len);
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
struct proc;
static int ns_execpath(struct proc *p, const char *upath, char *out);

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
static short fd_ready(struct proc *p, int fd);	/* rvlogin: O_NONBLOCK gate */
static long pipe_write(int pi, const char *ubuf, unsigned long n);

/*
 * The AF_UNIX socket layer (unixsock.c). Declared here because the fd table --
 * which is this file's business -- is what binds a socket index to a descriptor,
 * and read/write/close/fork must route to the socket when a descriptor holds one.
 */
extern int unsock_socket(int domain, int type, int protocol);
extern int unsock_bind(int si, const char *kpath);
extern int unsock_listen(int si, int backlog);
extern int unsock_connect(int si, const char *kpath);
extern int unsock_accept(int si);
extern void unsock_accepted(int si);
extern long unsock_send(int si, const char *ubuf, unsigned long n,
    const int *kfds, int nfds);
extern long unsock_recv(int si, char *ubuf, unsigned long n, int *outfds,
    int *noutfds);
extern int unsock_socketpair(int domain, int type, int *sa, int *sb);
extern void unsock_ref(int si);
extern void unsock_close(int si);
/* inet.c: AF_INET sockets. Their index in fd_sock carries INET_SI_FLAG. */
extern int inet_is(int si);
extern int inet_socket(int type, int protocol);
extern int inet_bind(int si, const void *ksa, unsigned int len);
extern int inet_listen(int si, int backlog);
extern int inet_accept(int si, void *ksa_out);
extern int inet_connect(int si, const void *ksa, unsigned int len);
extern long inet_send(int si, const unsigned char *kbuf, unsigned long n,
    const void *ksa, unsigned int salen);
extern long inet_recv(int si, unsigned char *kbuf, unsigned long n,
    void *ksa_out);
extern int inet_poll(int si);
extern void inet_ref(int si);
extern void inet_close(int si);
extern int inet_getsockname(int si, void *ksa_out, int peer);
static long inet_uread(int si, char *ubuf, unsigned long n, unsigned long usa,
    unsigned long ulenp);
static long inet_uwrite(int si, const char *ubuf, unsigned long n,
    unsigned long usa, unsigned int salen);
/* Defined at the bottom of this file (the SCM_RIGHTS capture/install helpers). */
int unsock_fd_dup_into(int fd);
int unsock_fd_install_slot(int ri);
void unsock_rights_drop(int ri);

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
 * AT_SUN_EXECNAME (2014) is illumos-specific: it carries the full path of the
 * executable, and libc's getexecname(3C) reads it. Rust's env::current_exe()
 * goes through getexecname, so without this slot that call fails -- survivable,
 * but it is one auxv entry and the string is already on the stack as argv[0].
 */
#define	AT_SUN_EXECNAME	2014

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
	/*
	 * Sized with headroom on purpose: the current set is 8 pairs (16 words)
	 * counting AT_NULL, so aux[16] was exactly full and the next slot anyone
	 * adds would silently overflow a stack array. 24 leaves room for the
	 * dynamic-linker slots (AT_PHDR/AT_PHENT/AT_PHNUM/AT_BASE) that ld.so.1
	 * will need.
	 */
	unsigned long aux[24];
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
	/*
	 * argv[0] is already planted in the string block, so the exec name costs
	 * nothing extra -- point at it rather than copying the path twice.
	 * Skipped when argc==0 (nothing to point at) rather than planting a null
	 * that getexecname would have to special-case.
	 */
	if (snap->argc > 0) {
		aux[naux++] = AT_SUN_EXECNAME;
		aux[naux++] = uargv[0];
	}
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
	unsigned int	p_euid, p_suid;	/* rvlogin: effective + saved (p_uid = real) */
	unsigned int	p_egid, p_sgid;
	int		p_sid;		/* rvlogin: session id (setsid) */
	int		p_pgid;		/* rvlogin: process group (= sid here) */
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
		int		fd_fb;		/* 1 = the /dev/fb scanout node */
		int		fd_sock;	/* AF_UNIX socket index, else -1 */
		int		fd_port;	/* event-port index, else -1 */
		int		fd_cloexec;	/* FD_CLOEXEC: exec releases the slot */
		int		fd_dir;		/* 1 = a directory (getdents) */
		int		fd_append;	/* O_APPEND: every write goes at EOF */
		int		fd_nonblock;	/* rvlogin: O_NONBLOCK (EAGAIN, not block) */
		char		fd_path[128];	/* the name opened (dir fds, st_ino) */
	} p_fd[NOFILE];
	char		p_cwd[128];	/* rvsh: working directory, canonical */
} proc_t;

#define	NPROC	16
static proc_t proctab[NPROC];
static int next_pid = 1;

/*
 * rvsmp-b: per-hart current user process, indexed by tp (the S-mode hart id).
 * One global was shared by every hart, so a fork or fault on one hart resolved
 * against another hart's proc. swtch saves/restores it per thread (t_curproc).
 * The asm is volatile so a read after a sleep re-reads tp (the thread may have
 * moved harts).
 */
#include <sys/machtypes.h>
static proc_t *curproc_hart[MAXCPU];
static inline proc_t **
curproc_slot(void)
{
	unsigned long id;

	__asm__ __volatile__("mv %0, tp" : "=r"(id));
	return (&curproc_hart[id < MAXCPU ? id : 0]);
}
#define	curproc	(*curproc_slot())

volatile int userland_active = 0;

/* ------------------------------------------------------------------------- */

static proc_t *
proc_alloc(void)
{
	int i;

	for (i = 0; i < NPROC; i++) {
		/* rvsmp-d: claim slot + pid atomically (forks on many harts) */
		if (!proctab[i].p_inuse &&
		    !__atomic_exchange_n(&proctab[i].p_inuse, 1, __ATOMIC_ACQUIRE)) {
			proc_t *p = &proctab[i];
			int k;
			unsigned char *fp = (unsigned char *)&p->p_uframe;

			for (k = 0; k < (int)sizeof (p->p_uframe); k++)
				fp[k] = 0;
			p->p_pid = __atomic_fetch_add(&next_pid, 1, __ATOMIC_RELAXED);
			p->p_ppid = 0;
			p->p_state = PS_RUN;
			p->p_status = 0;
			p->p_as = 0;
			p->p_thread = 0;
			p->p_uid = p->p_euid = p->p_suid = 0;
			p->p_gid = p->p_egid = p->p_sgid = 0;
			p->p_sid = p->p_pid;	/* fork overwrites; init leads its own */
			p->p_pgid = p->p_pid;
			p->p_sigpend = 0;
			p->p_insig = 0;
			for (k = 0; k < NSIG; k++)
				p->p_sighand[k] = SIG_DFL_VAL;
			for (k = 0; k < NOFILE; k++) {
				p->p_fd[k].fd_used = 0;
				p->p_fd[k].fd_snfs = -1;
				p->p_fd[k].fd_pipe = -1;
				p->p_fd[k].fd_sock = -1;
				p->p_fd[k].fd_port = -1;
				p->p_fd[k].fd_fb = 0;
				p->p_fd[k].fd_cloexec = 0;
				p->p_fd[k].fd_dir = 0;
				p->p_fd[k].fd_append = 0;
				p->p_fd[k].fd_nonblock = 0;
				p->p_fd[k].fd_path[0] = 0;
			}
			p->p_cwd[0] = '/';
			p->p_cwd[1] = 0;
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
	for (fd = 3; fd < NOFILE; fd++) {
		if (!p->p_fd[fd].fd_used) {
			p->p_fd[fd].fd_used = 1;
			p->p_fd[fd].fd_data = (const unsigned char *)data;
			p->p_fd[fd].fd_len = len;
			p->p_fd[fd].fd_pos = 0;
			p->p_fd[fd].fd_wnode = 0;   /* read-only vfs image */
			p->p_fd[fd].fd_snfs = -1;
			p->p_fd[fd].fd_pipe = -1;
			p->p_fd[fd].fd_sock = -1;
		p->p_fd[fd].fd_port = -1;
			return (fd);
		}
	}
	return (-1);			/* fd table full */
}

/*
 * proc_fread — read from an open fd (any slot holding an object) into the user
 * buffer `ubuf`. Returns bytes read (0 at EOF), or -1 for a bad/closed fd. An
 * empty fd 0/1/2 is the console, handled by the syscall layer (uart).
 */
long
proc_fread(int fd, char *ubuf, unsigned long n)
{
	proc_t *p = curproc;
	unsigned long avail;
	const unsigned char *src;
	unsigned long len;

	if (p == 0 || fd < 0 || fd >= NOFILE || !p->p_fd[fd].fd_used)
		return (-1);
	/* rvlogin: O_NONBLOCK on a pipe/socket: EAGAIN instead of blocking. */
	if (p->p_fd[fd].fd_nonblock && n > 0 && (p->p_fd[fd].fd_pipe >= 0 ||
	    p->p_fd[fd].fd_sock >= 0) && (fd_ready(p, fd) & 0x0019) == 0)
		return (-11 /* EAGAIN */);
	/* R-P12: pipe read end. */
	if (p->p_fd[fd].fd_pipe >= 0)
		return (pipe_read(p->p_fd[fd].fd_pipe, ubuf, n));
	/* An AF_UNIX endpoint: read(2) is recvmsg with no ancillary data. Rights
	 * sent by the peer stay queued for a real recvmsg rather than being
	 * silently discarded here. */
	if (p->p_fd[fd].fd_sock >= 0 && inet_is(p->p_fd[fd].fd_sock))
		return (inet_uread(p->p_fd[fd].fd_sock, ubuf, n, 0, 0));
	if (p->p_fd[fd].fd_sock >= 0)
		return (unsock_recv(p->p_fd[fd].fd_sock, ubuf, n, 0, 0));
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

/*
 * proc_fd_open -- 1 if slot `fd` holds an object. For fd 0..2 that means dup2
 * put a pipe/file/socket there; an empty 0..2 is the console (syscall.c).
 */
int
proc_fd_open(int fd)
{
	proc_t *p = curproc;

	return (p != 0 && fd >= 0 && fd < NOFILE && p->p_fd[fd].fd_used);
}

/*
 * fd_hold -- take the reference a NEW copy of slot `fd` owns (fork, dup2). The
 * mirror of fd_release: every object kind that fd_release drops is held here,
 * so a copied descriptor can never release a reference it did not take.
 */
static void
fd_hold(proc_t *p, int fd)
{
	if (!p->p_fd[fd].fd_used)
		return;
	if (p->p_fd[fd].fd_pipe >= 0)
		pipe_ref(p->p_fd[fd].fd_pipe, p->p_fd[fd].fd_pipe_w);
	if (p->p_fd[fd].fd_sock >= 0 && inet_is(p->p_fd[fd].fd_sock))
		inet_ref(p->p_fd[fd].fd_sock);
	else if (p->p_fd[fd].fd_sock >= 0)
		unsock_ref(p->p_fd[fd].fd_sock);
	if (p->p_fd[fd].fd_port >= 0)
		port_hold(p->p_fd[fd].fd_port);
	if (p->p_fd[fd].fd_fb) {
		extern long fb_open(void);
		(void) fb_open();
	}
}

/*
 * fd_release -- drop the reference slot `fd` holds and empty the slot. Every
 * path that empties a slot comes here (close, dup2 onto an open fd, exit,
 * exec), any slot 0..NOFILE-1: a pipe end that sat in fd 1 is released exactly
 * like one in fd 7, so its reader sees EOF when the last writer goes.
 */
static void
fd_release(proc_t *p, int fd)
{
	if (!p->p_fd[fd].fd_used)
		return;
	p->p_fd[fd].fd_used = 0;
	p->p_fd[fd].fd_cloexec = 0;
	p->p_fd[fd].fd_dir = 0;
	p->p_fd[fd].fd_append = 0;
	p->p_fd[fd].fd_nonblock = 0;
	p->p_fd[fd].fd_wnode = 0;	/* R-P11: clear so a reused slot is clean */
	/* R-P12: releasing a pipe end drops one reference on the pipe. */
	if (p->p_fd[fd].fd_pipe >= 0)
		pipe_close(p->p_fd[fd].fd_pipe, p->p_fd[fd].fd_pipe_w);
	/*
	 * An AF_UNIX endpoint is reference-counted the same way: the socket is torn
	 * down (and its peer told, so a blocked reader sees EOF rather than hanging)
	 * only when the last descriptor referring to it goes away.
	 */
	/*
	 * Releasing a port on close matters more than it looks: the port table is
	 * fixed at four, so a leaked port permanently costs a compositor one of
	 * the handles it needs.
	 */
	if (p->p_fd[fd].fd_port >= 0) {
		port_free(p->p_fd[fd].fd_port);
		p->p_fd[fd].fd_port = -1;
	}
	if (p->p_fd[fd].fd_sock >= 0) {
		if (inet_is(p->p_fd[fd].fd_sock))
			inet_close(p->p_fd[fd].fd_sock);
		else
			unsock_close(p->p_fd[fd].fd_sock);
		p->p_fd[fd].fd_sock = -1;
		p->p_fd[fd].fd_port = -1;
	}
	/* The scanout node: drop the driver's open reference.  The user mapping
	 * deliberately outlives close (as_free reclaims it at exit), which is what
	 * a compositor expects from a framebuffer it has mmap'd. */
	if (p->p_fd[fd].fd_fb) {
		extern long fb_close(void);
		(void) fb_close();
		p->p_fd[fd].fd_fb = 0;
	}
	p->p_fd[fd].fd_snfs = -1;
	p->p_fd[fd].fd_pipe = -1;
	p->p_fd[fd].fd_sock = -1;
	p->p_fd[fd].fd_port = -1;
}

/*
 * proc_close -- close(2). A console fd (0/1/2 with nothing dup2'd into it) has
 * no object and always "succeeds"; anything else, in any slot, is released.
 */
long
proc_close(int fd)
{
	proc_t *p = curproc;

	if (p == 0 || fd < 0 || fd >= NOFILE)
		return (-1);
	if (!p->p_fd[fd].fd_used)
		return (fd <= 2 ? 0 : -1);
	fd_release(p, fd);
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
	/*
	 * Start the process with the FPU DISABLED (sstatus.FS = Off, bits 14:13
	 * cleared). Nothing else seeded this field, so a fresh process used to
	 * inherit whatever FS the kernel happened to leave set -- and since
	 * fp_save/fp_restore enable the FPU to run fsd/fld, userland arrived with
	 * FP already on. The first-use trap then never fired, no context was ever
	 * allocated, and FP state was neither saved nor restored: exactly the
	 * corruption this is meant to prevent, but silently.
	 *
	 * Off is also the correct initial state semantically: a process that never
	 * touches the FPU should never pay for one.
	 */
	p->p_uframe.r_sstatus &= ~(3UL << 13);
	p->p_uframe.r_a0 = (unsigned long)snap->argc;	/* argc */
	p->p_uframe.r_a1 = sp + 8;			/* argv (past argc) */

	/* POSIX: open fds survive exec, except those marked FD_CLOEXEC. A slot
	 * that is released drops its reference (a pipe end must not leak). */
	for (i = 0; i < NOFILE; i++) {
		if (p->p_fd[i].fd_cloexec)
			fd_release(p, i);
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
	{
		int c;

		for (c = 0; c < (int)sizeof (child->p_cwd); c++)
			child->p_cwd[c] = parent->p_cwd[c];
	}
	child->p_uid = parent->p_uid;	/* R-P11: inherit credentials */
	child->p_gid = parent->p_gid;
	child->p_euid = parent->p_euid;
	child->p_suid = parent->p_suid;
	child->p_egid = parent->p_egid;
	child->p_sgid = parent->p_sgid;
	child->p_sid = parent->p_sid;	/* rvlogin: same session + group */
	child->p_pgid = parent->p_pgid;
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
	for (i = 0; i < NOFILE; i++) {
		child->p_fd[i] = parent->p_fd[i];
		/* Pipe, AF_UNIX endpoint, port, fb: the child's copy is a second
		 * reference, so the object outlives whichever process closes first. */
		fd_hold(child, i);
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
	/*
	 * FP state must be COPIED, not shared: two processes writing one
	 * register file is exactly the bug fp.c exists to fix, one level down.
	 * fp_fork flushes the parent first (its live registers may be dirtier
	 * than its saved context) and leaves the child NULL if the parent never
	 * used FP, which costs nothing.
	 */
	if (child->p_thread != 0) {
		fpu_ctx_t **pslot = fp_self_slot();
		fpu_ctx_t *cfp = 0;

		if (!fp_fork(pslot != 0 ? *pslot : 0, &cfp)) {
			/* allocation failure: fail the fork rather than share */
			child->p_thread = 0;
		} else {
			fp_thread_set(child->p_thread, cfp);
		}
	}
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
	/*
	 * exec replaces the program, so its FP registers must not leak into the
	 * new one. Zero rather than free: the allocation is reused, and an
	 * all-zero register file is a valid initial FP state.
	 */
	{
		fpu_ctx_t **slot = fp_self_slot();

		if (slot != 0)
			fp_exec_reset(*slot);
	}

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

	if (path == 0 || curproc == 0)
		return (-1);
	/* Fault-safe copy of the path, made absolute against the cwd (rvsh). */
	if (ns_execpath(curproc, path, kpath) != 0)
		return (-14);			/* EFAULT / too long */
	if (!vfs_lookup(kpath, &img, &len)) {
		/* A ramfs copy of an image is not executable: no exec from the
		 * writable fs (ramfs files are data). */
		return (-1);
	}
	(void) i;

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
		int fd;

		/* Release every fd (POSIX _exit): a pipe end this process held,
		 * in any slot, must not keep its reader from seeing EOF. */
		for (fd = 0; fd < NOFILE; fd++)
			fd_release(p, fd);
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
proc_waitpid(int pid, int *statusp, int nohang)
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
		if (nohang) {			/* rvlogin: WNOHANG */
			curproc = self;
			return (0);
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
/*
 * rvlogin: real/effective/saved ids with the POSIX rules. Privilege is euid 0.
 * setuid(u): privileged sets all three; otherwise u must be the real or saved id
 * and only the effective id changes. setresuid(r, e, s): -1 keeps a field; an
 * unprivileged caller may only pick among its current three. Same for gids.
 */
static long
cred_setres(unsigned int *c, long r, long e, long s, int priv)
{
	long v[3];
	int i, j, ok;

	v[0] = r; v[1] = e; v[2] = s;
	for (i = 0; i < 3 && !priv; i++) {
		if (v[i] == -1)
			continue;
		for (ok = 0, j = 0; j < 3; j++)
			ok |= (unsigned int)v[i] == c[j];
		if (!ok)
			return (-1 /* EPERM */);
	}
	for (i = 0; i < 3; i++)
		if (v[i] != -1)
			c[i] = (unsigned int)v[i];
	return (0);
}

static long
cred_set(int gid, long r, long e, long s)
{
	proc_t *p = curproc;
	unsigned int c[3];
	long rv;

	if (p == 0)
		return (-1);
	c[0] = gid ? p->p_gid : p->p_uid;
	c[1] = gid ? p->p_egid : p->p_euid;
	c[2] = gid ? p->p_sgid : p->p_suid;
	if ((rv = cred_setres(c, r, e, s, p->p_euid == 0)) != 0)
		return (rv);
	if (gid) {
		p->p_gid = c[0]; p->p_egid = c[1]; p->p_sgid = c[2];
	} else {
		p->p_uid = c[0]; p->p_euid = c[1]; p->p_suid = c[2];
	}
	return (0);
}

long
sys_setuid(unsigned int uid)
{
	if (curproc != 0 && curproc->p_euid == 0)
		return (cred_set(0, uid, uid, uid));
	return (cred_set(0, -1, uid, -1));	/* EPERM unless uid is real or saved */
}

long
sys_setgid(unsigned int gid)
{
	if (curproc != 0 && curproc->p_euid == 0)
		return (cred_set(1, gid, gid, gid));
	return (cred_set(1, -1, gid, -1));
}

/* setresuid/setresgid: -1 (as the u32 0xffffffff the ABI passes) = unchanged. */
long
sys_setres(int gid, unsigned long r, unsigned long e, unsigned long s)
{
	return (cred_set(gid, (unsigned int)r == 0xffffffffU ? -1 : (long)(unsigned int)r,
	    (unsigned int)e == 0xffffffffU ? -1 : (long)(unsigned int)e,
	    (unsigned int)s == 0xffffffffU ? -1 : (long)(unsigned int)s));
}

/* which: 0 uid, 1 euid, 2 gid, 3 egid */
long
sys_getid(int which)
{
	proc_t *p = curproc;

	if (p == 0)
		return (0);
	return ((long)(which == 0 ? p->p_uid : which == 1 ? p->p_euid :
	    which == 2 ? p->p_gid : p->p_egid));
}

long
sys_getuid(void)
{
	return (curproc != 0 ? (long)curproc->p_uid : 0);
}

/*
 * rvlogin: setsid/getsid/getpgid (Linux 157/156/155). A session leader cannot
 * start a new session (EPERM, as POSIX says). No controlling tty exists yet, so
 * there is nothing to detach; process groups are only as fine as sessions.
 */
long
sys_setsid(void)
{
	proc_t *p = curproc;

	if (p == 0 || p->p_pgid == p->p_pid)
		return (-1 /* EPERM */);
	p->p_sid = p->p_pid;
	p->p_pgid = p->p_pid;
	return (p->p_pid);
}

long
sys_getsid(int pid, int pg)
{
	int i;

	if (pid == 0 && curproc != 0)
		return (pg ? curproc->p_pgid : curproc->p_sid);
	for (i = 0; i < NPROC; i++)
		if (proctab[i].p_inuse && proctab[i].p_pid == pid &&
		    proctab[i].p_state != PS_ZOMBIE)
			return (pg ? proctab[i].p_pgid : proctab[i].p_sid);
	return (-3 /* ESRCH */);
}

/*
 * rvlogin: would a pending signal do something on return to U-mode (a handler or
 * a default kill)? Then a blocking call returns EINTR so it gets the chance, as
 * POSIX says; dropbear's SIGCHLD handler is what tells it a session's child died.
 */
static int
proc_sig_wakes(proc_t *p)
{
	int sig;

	if (p == 0 || p->p_insig)
		return (0);
	for (sig = 1; sig < NSIG; sig++)
		if ((p->p_sigpend & (1UL << sig)) != 0 &&
		    p->p_sighand[sig] != SIG_IGN_VAL &&
		    !(p->p_sighand[sig] == SIG_DFL_VAL && sig == SIGCHLD))
			return (1);
	return (0);
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
 * NOTE (R-P11 ceiling): in-memory, fixed file count, no persistence (rvsh added
 * dirs, unlink and rename in the namespace layer below);
 * a vnode + block cache over vioblk with write-back is R-P12.
 * ===========================================================================
 */
#define	NRAMFILE	64		/* rvsh: a session's scratch + edits */
#define	RAMFILE_MAX	(256UL * 1024)	/* 256 KiB per file cap (kmem at create) */
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
			/* an unlinked slot keeps its buffer for the next create */
			if (r->rf_data == 0)
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
 * ===========================================================================
 * rvsh: the directory namespace -- getdents64, mkdirat, unlinkat, renameat,
 * newfstatat/fstat, chdir/getcwd, and openat relative to a dirfd. Linux riscv
 * syscall numbers, errno values and struct stat, like the rest of this table.
 *
 * There is no vnode tree to walk. A name exists if one of the three flat tables
 * holds it: the root fs (rootfs_path: fixed top-level dirs, ustar files and the
 * embedded images), the ramfs files, or nsdirs (directories made by mkdir). Any
 * proper prefix of an existing name is a directory too, which is how a ustar
 * root's /usr/share/terminfo/v/vt100 makes /usr and /usr/share real. getdents
 * scans all three for the direct children of a directory. Small tables, linear
 * scans: the namespace is a few hundred names at most.
 *
 * NOTE: /data (the on-disk SNFS) is listed as a directory but its files are
 * reached only by name (open/read/write), not by getdents/unlink/rename.
 * ===========================================================================
 */
#define	NS_PATHMAX	128
#define	NNSDIR		64
#define	NS_ENOENT	2
#define	NS_EBADF	9
#define	NS_EFAULT	14
#define	NS_EEXIST	17
#define	NS_EXDEV	18
#define	NS_ENOTDIR	20
#define	NS_EISDIR	21
#define	NS_EINVAL	22
#define	NS_ENOSPC	28
#define	NS_EROFS	30
#define	NS_ENAMETOOLONG	36
#define	NS_ENOTEMPTY	39
#define	AT_FDCWD_K	(-100)
#define	AT_REMOVEDIR_K	0x200

static char nsdirs[NNSDIR][NS_PATHMAX];	/* mkdir'd directories ("" = free) */

extern int rootfs_path(int i, const char **pp, int *dirp);
extern char *rootfs_wpath(int i, int *capp);

static int
ns_len(const char *s)
{
	int n = 0;

	while (s[n] != 0)
		n++;
	return (n);
}

/* 1 if `name` is `dir` itself or lies below it ("/" contains everything). */
static int
ns_under(const char *name, const char *dir, int dl)
{
	int i;

	if (dl == 1)
		return (name[0] == '/');
	for (i = 0; i < dl; i++)
		if (name[i] != dir[i])
			return (0);
	return (name[dl] == 0 || name[dl] == '/');
}

/*
 * Visit every name in the namespace: fn(arg, path, isdir, kind) where kind is
 * 1 = ustar file (index ix), 2 = immutable, 3 = ramfs file, 4 = nsdir. fn
 * returning nonzero stops the walk and is returned.
 */
typedef int (*ns_fn_t)(void *, const char *, int, int, int);

static int
ns_walk(ns_fn_t fn, void *arg)
{
	int i, k, d, r;
	const char *pp;

	for (i = 0; (k = rootfs_path(i, &pp, &d)) >= 0; i++)
		if (k > 0 && (r = fn(arg, pp, d, k, i)) != 0)
			return (r);
	for (i = 0; i < NRAMFILE; i++)
		if (ramfiles[i].rf_used &&
		    (r = fn(arg, ramfiles[i].rf_path, 0, 3, i)) != 0)
			return (r);
	for (i = 0; i < NNSDIR; i++)
		if (nsdirs[i][0] != 0 && (r = fn(arg, nsdirs[i], 1, 4, i)) != 0)
			return (r);
	return (0);
}

struct ns_q { const char *path; int len; int isdir; int found; };

static int
ns_stat_cb(void *a, const char *name, int isdir, int kind, int ix)
{
	struct ns_q *q = a;

	(void) kind; (void) ix;
	if (q->len == 1) {		/* "/" */
		q->found = 1;
		q->isdir = 1;
		return (1);
	}
	if (!ns_under(name, q->path, q->len))
		return (0);
	q->found = 1;
	if (name[q->len] == '/' || isdir) {
		q->isdir = 1;		/* a prefix of a name, or a dir itself */
		return (1);
	}
	return (0);			/* a file: keep looking for a dir */
}

/* Does `path` exist? Returns 0 = no, 1 = file, 2 = directory. */
static int
ns_kind(const char *path)
{
	struct ns_q q;

	q.path = path;
	q.len = ns_len(path);
	q.isdir = 0;
	q.found = 0;
	(void) ns_walk(ns_stat_cb, &q);
	if (!q.found)
		return (0);
	return (q.isdir ? 2 : 1);
}

/*
 * Make `upath` (a user pointer) absolute and canonical in `out` (NS_PATHMAX):
 * relative to dirfd (AT_FDCWD = the cwd), "." and ".." folded, no trailing or
 * doubled '/'. Returns 0 or a negative errno.
 */
static int
ns_abspath(proc_t *p, int dirfd, const char *upath, char *out)
{
	char in[NS_PATHMAX];
	char tmp[2 * NS_PATHMAX];
	const char *base;
	int i, n, o;

	for (i = 0; i < NS_PATHMAX - 1; i++) {
		if (copyin(upath + i, &in[i], 1) != 0)
			return (-NS_EFAULT);
		if (in[i] == 0)
			break;
	}
	if (i == NS_PATHMAX - 1)
		return (-NS_ENAMETOOLONG);
	in[i] = 0;
	if (in[0] == 0)
		return (-NS_ENOENT);
	n = 0;
	if (in[0] != '/') {
		if (dirfd == AT_FDCWD_K)
			base = p->p_cwd;
		else if (dirfd >= 0 && dirfd < NOFILE &&
		    p->p_fd[dirfd].fd_used && p->p_fd[dirfd].fd_dir)
			base = p->p_fd[dirfd].fd_path;
		else
			return (dirfd >= 0 && dirfd < NOFILE &&
			    p->p_fd[dirfd].fd_used ? -NS_ENOTDIR : -NS_EBADF);
		while (*base != 0)
			tmp[n++] = *base++;
		tmp[n++] = '/';
	}
	for (i = 0; in[i] != 0; i++)
		tmp[n++] = in[i];
	tmp[n] = 0;

	/* Fold the components into out. */
	o = 0;
	i = 0;
	while (tmp[i] != 0) {
		int s, l;

		while (tmp[i] == '/')
			i++;
		if (tmp[i] == 0)
			break;
		s = i;
		while (tmp[i] != 0 && tmp[i] != '/')
			i++;
		l = i - s;
		if (l == 1 && tmp[s] == '.')
			continue;
		if (l == 2 && tmp[s] == '.' && tmp[s + 1] == '.') {
			while (o > 0 && out[o - 1] != '/')
				o--;
			if (o > 0)
				o--;
			continue;
		}
		if (o + 1 + l >= NS_PATHMAX)
			return (-NS_ENAMETOOLONG);
		out[o++] = '/';
		while (s < i)
			out[o++] = tmp[s++];
	}
	if (o == 0)
		out[o++] = '/';
	out[o] = 0;
	return (0);
}

/* exec's path resolution: ns_abspath against the cwd (out is NS_PATHMAX). */
static int
ns_execpath(struct proc *p, const char *upath, char *out)
{
	return (ns_abspath((proc_t *)p, AT_FDCWD_K, upath, out));
}

/* FNV-1a of the path: a stable inode number (find/du/ls -i compare them). */
static unsigned long
ns_ino(const char *path)
{
	unsigned long h = 1469598103934665603UL;

	while (*path != 0)
		h = (h ^ (unsigned char)*path++) * 1099511628211UL;
	return (h == 0 ? 1 : h);
}

/* Linux riscv64 struct stat (asm-generic/stat.h), 128 bytes. */
struct kstat_k {
	unsigned long	st_dev;
	unsigned long	st_ino;
	unsigned int	st_mode;
	unsigned int	st_nlink;
	unsigned int	st_uid;
	unsigned int	st_gid;
	unsigned long	st_rdev;
	unsigned long	__pad1;
	long		st_size;
	int		st_blksize;
	int		__pad2;
	long		st_blocks;
	long		st_atime_k, st_atime_nsec;
	long		st_mtime_k, st_mtime_nsec;
	long		st_ctime_k, st_ctime_nsec;
	unsigned int	__unused4, __unused5;
};

static long
ns_statout(const char *path, int kind, long size, unsigned int fmt,
    unsigned long ustat)
{
	struct kstat_k st;
	unsigned char *b = (unsigned char *)&st;
	int i;

	for (i = 0; i < (int)sizeof (st); i++)
		b[i] = 0;
	st.st_dev = 1;
	st.st_ino = ns_ino(path);
	if (fmt == 0)
		fmt = (kind == 2) ? 0040000 : 0100000;	/* S_IFDIR : S_IFREG */
	st.st_mode = fmt | ((fmt == 0040000 || fmt == 0100000) ? 0755 : 0620);
	st.st_nlink = (kind == 2) ? 2 : 1;
	st.st_size = (kind == 2) ? 0 : size;
	st.st_blksize = 512;
	st.st_blocks = (st.st_size + 511) / 512;
	if (copyout(&st, (void *)ustat, sizeof (st)) != 0)
		return (-NS_EFAULT);
	return (0);
}

/* Size of the file at `path`, wherever it lives. */
static long
ns_fsize(const char *path)
{
	const void *d;
	unsigned long l;
	struct ramfile *r = ramfs_find(path);

	if (r != 0)
		return ((long)r->rf_len);
	if (vfs_lookup(path, &d, &l))
		return ((long)l);
	return (0);
}

/* newfstatat(dirfd, path, statbuf, flags) */
long
proc_fstatat(int dirfd, const char *upath, unsigned long ustat, int flags)
{
	proc_t *p = curproc;
	char path[NS_PATHMAX];
	int r, kind;

	(void) flags;			/* no symlinks: NOFOLLOW is moot */
	if (p == 0)
		return (-NS_EINVAL);
	if ((r = ns_abspath(p, dirfd, upath, path)) != 0)
		return (r);
	/* /data/<name>: an SNFS file is reachable by name only. */
	if (path[0] == '/' && ns_under(path, "/data", 5) && path[5] == '/') {
		unsigned long len;
		int slot = snfs_open(path + 6, 0, &len);

		if (slot < 0)
			return (-NS_ENOENT);
		return (ns_statout(path, 1, (long)len, 0, ustat));
	}
	if (str_eq_uproc(path, "/dev/fb"))
		return (ns_statout(path, 1, 0, 0020000, ustat));
	kind = ns_kind(path);
	if (kind == 0)
		return (-NS_ENOENT);
	return (ns_statout(path, kind, kind == 1 ? ns_fsize(path) : 0, 0,
	    ustat));
}

/* fstat(fd, statbuf) */
long
proc_fstat(int fd, unsigned long ustat)
{
	proc_t *p = curproc;
	struct ramfile *r;

	if (p == 0 || fd < 0 || fd >= NOFILE)
		return (-NS_EBADF);
	if (!p->p_fd[fd].fd_used) {
		if (fd <= 2)		/* the console */
			return (ns_statout("/dev/console", 1, 0, 0020000, ustat));
		return (-NS_EBADF);
	}
	if (p->p_fd[fd].fd_pipe >= 0 || p->p_fd[fd].fd_sock >= 0 ||
	    p->p_fd[fd].fd_port >= 0)
		return (ns_statout("", 1, 0, p->p_fd[fd].fd_sock >= 0 ?
		    0140000 : 0010000, ustat));	/* S_IFSOCK : S_IFIFO */
	if (p->p_fd[fd].fd_fb)
		return (ns_statout("/dev/fb", 1, 0, 0020000, ustat));
	if (p->p_fd[fd].fd_dir)
		return (ns_statout(p->p_fd[fd].fd_path, 2, 0, 0, ustat));
	r = (struct ramfile *)p->p_fd[fd].fd_wnode;
	if (p->p_fd[fd].fd_snfs >= 0)
		return (ns_statout(p->p_fd[fd].fd_path, 1,
		    (long)snfs_len(p->p_fd[fd].fd_snfs), 0, ustat));
	return (ns_statout(p->p_fd[fd].fd_path, 1, r != 0 ? (long)r->rf_len :
	    (long)p->p_fd[fd].fd_len, 0, ustat));
}

/* Open directory `path` (already canonical) as an fd for getdents. */
static long
ns_opendir(proc_t *p, const char *path)
{
	int fd, i;

	for (fd = 3; fd < NOFILE; fd++) {
		if (p->p_fd[fd].fd_used)
			continue;
		p->p_fd[fd].fd_used = 1;
		p->p_fd[fd].fd_dir = 1;
		p->p_fd[fd].fd_pos = 0;
		p->p_fd[fd].fd_len = 0;
		p->p_fd[fd].fd_data = 0;
		p->p_fd[fd].fd_wnode = 0;
		p->p_fd[fd].fd_snfs = -1;
		p->p_fd[fd].fd_pipe = -1;
		p->p_fd[fd].fd_sock = -1;
		p->p_fd[fd].fd_port = -1;
		p->p_fd[fd].fd_fb = 0;
		p->p_fd[fd].fd_cloexec = 0;
		for (i = 0; path[i] != 0; i++)
			p->p_fd[fd].fd_path[i] = path[i];
		p->p_fd[fd].fd_path[i] = 0;
		return (fd);
	}
	return (-24 /* EMFILE */);
}

/* A read-only fd over image bytes (a ustar or embedded root file). */
static long
ns_openimg(proc_t *p, const void *data, unsigned long len)
{
	int fd;

	for (fd = 3; fd < NOFILE; fd++) {
		if (p->p_fd[fd].fd_used)
			continue;
		p->p_fd[fd].fd_used = 1;
		p->p_fd[fd].fd_data = (const unsigned char *)data;
		p->p_fd[fd].fd_len = len;
		p->p_fd[fd].fd_pos = 0;
		p->p_fd[fd].fd_wnode = 0;
		p->p_fd[fd].fd_snfs = -1;
		p->p_fd[fd].fd_pipe = -1;
		p->p_fd[fd].fd_sock = -1;
		p->p_fd[fd].fd_port = -1;
		p->p_fd[fd].fd_fb = 0;
		p->p_fd[fd].fd_dir = 0;
		p->p_fd[fd].fd_cloexec = 0;
		return (fd);
	}
	return (-24 /* EMFILE */);
}

struct ns_find { const char *path; int kind; int ix; };

static int
ns_find_cb(void *a, const char *name, int isdir, int kind, int ix)
{
	struct ns_find *f = a;

	(void) isdir;
	if (!str_eq_uproc(name, f->path))
		return (0);
	f->kind = kind;
	f->ix = ix;
	return (1);
}

/* The ramfs copy of a ustar file replaces it: drop the ustar name so the
 * namespace names the file once (ls, rm, mv see one entry). */
static void
ns_hide(const char *path)
{
	struct ns_find f;
	int cap;
	char *w;

	f.path = path;
	f.kind = 0;
	if (ns_walk(ns_find_cb, &f) && f.kind == 1 &&
	    (w = rootfs_wpath(f.ix, &cap)) != 0)
		w[0] = 0;
}

/* Record `path` as the name behind a file fd (fstat's st_ino). */
static void
ns_setpath(proc_t *p, long fd, const char *path)
{
	int i;

	if (fd < 0 || fd >= NOFILE)
		return;
	for (i = 0; path[i] != 0 && i < NS_PATHMAX - 1; i++)
		p->p_fd[fd].fd_path[i] = path[i];
	p->p_fd[fd].fd_path[i] = 0;
}

/* Extract the child component of `name` under dir (length; 0 if none). */
static int
ns_comp(const char *name, const char *dir, int dl, const char **cp, int *isdir,
    int nameisdir)
{
	const char *c;
	int l;

	if (!ns_under(name, dir, dl))
		return (0);
	c = name + (dl == 1 ? 0 : dl);
	if (*c != '/')
		return (0);		/* the dir itself */
	c++;
	for (l = 0; c[l] != 0 && c[l] != '/'; l++)
		;
	if (l == 0)
		return (0);
	*cp = c;
	*isdir = (c[l] == '/') || nameisdir;
	return (l);
}

/* A name's stable slot id: removing a name never renumbers the others, so a
 * directory cursor survives `rm -r` unlinking entries while it lists them. */
static long
ns_id(int kind, int ix)
{
	return (kind <= 2 ? ix : (kind == 3 ? 100000L : 200000L) + ix);
}

struct ns_first { const char *dir; int dl; const char *cand; int cl;
	long stop; int found; };

/* Is child (cand, cl) produced by a name at a walk position before `stop`? */
static int
ns_first_cb(void *a, const char *name, int isdir, int kind, int ix)
{
	struct ns_first *f = a;
	const char *c;
	int l, d, i;

	if (ns_id(kind, ix) >= f->stop)
		return (1);
	l = ns_comp(name, f->dir, f->dl, &c, &d, isdir);
	if (l != f->cl)
		return (0);
	for (i = 0; i < l; i++)
		if (c[i] != f->cand[i])
			return (0);
	f->found = 1;
	return (1);
}

/*
 * getdents64 state. The directory cursor (fd_pos) is 0 = ".", 1 = "..", else
 * 2 + the slot id of the next name to examine; a child is emitted at the FIRST
 * name that produces it (a dir named by many deeper paths appears once). A
 * listing costs O(names^2) string compares: fine for a few hundred names.
 */
struct ns_gd { proc_t *p; int fd; const char *dir; int dl; long start;
	unsigned long ubuf, n, off; int err; };

static int
ns_emit(struct ns_gd *g, const char *nm, int nl, int isdir, long next)
{
	unsigned char rec[24 + NS_PATHMAX];
	char full[NS_PATHMAX];
	unsigned long ino;
	int reclen, i, k = 0;
	const char *dp = g->dir;

	reclen = (19 + nl + 1 + 7) & ~7;
	if (g->off + (unsigned long)reclen > g->n) {
		if (g->off == 0)
			g->err = -NS_EINVAL;	/* buffer too small */
		return (1);
	}
	while (*dp != 0)
		full[k++] = *dp++;
	if (k > 1)
		full[k++] = '/';
	for (i = 0; i < nl && k < NS_PATHMAX - 1; i++)
		full[k++] = nm[i];
	full[k] = 0;
	ino = ns_ino(full);
	for (i = 0; i < reclen; i++)
		rec[i] = 0;
	for (i = 0; i < 8; i++) {
		rec[i] = (unsigned char)(ino >> (8 * i));		/* d_ino */
		rec[8 + i] = (unsigned char)((unsigned long)next >> (8 * i));
	}
	rec[16] = (unsigned char)reclen;			/* d_reclen */
	rec[17] = (unsigned char)(reclen >> 8);
	rec[18] = isdir ? 4 : 8;				/* DT_DIR : DT_REG */
	for (i = 0; i < nl; i++)
		rec[19 + i] = (unsigned char)nm[i];
	if (copyout(rec, (void *)(g->ubuf + g->off), reclen) != 0) {
		g->err = -NS_EFAULT;
		return (1);
	}
	g->off += reclen;
	g->p->p_fd[g->fd].fd_pos = (unsigned long)next;
	return (0);
}

static int
ns_gd_cb(void *a, const char *name, int isdir, int kind, int ix)
{
	struct ns_gd *g = a;
	struct ns_first f;
	const char *c;
	int l, d;
	long pos = ns_id(kind, ix);

	if (pos < g->start)
		return (0);
	l = ns_comp(name, g->dir, g->dl, &c, &d, isdir);
	if (l == 0) {
		g->p->p_fd[g->fd].fd_pos = (unsigned long)(pos + 3);
		return (0);
	}
	f.dir = g->dir; f.dl = g->dl; f.cand = c; f.cl = l;
	f.stop = pos; f.found = 0;
	(void) ns_walk(ns_first_cb, &f);
	if (f.found) {
		g->p->p_fd[g->fd].fd_pos = (unsigned long)(pos + 3);
		return (0);
	}
	return (ns_emit(g, c, l, d, pos + 3));
}

long
proc_getdents64(int fd, unsigned long ubuf, unsigned long n)
{
	proc_t *p = curproc;
	struct ns_gd g;

	if (p == 0 || fd < 0 || fd >= NOFILE || !p->p_fd[fd].fd_used)
		return (-NS_EBADF);
	if (!p->p_fd[fd].fd_dir)
		return (-NS_ENOTDIR);
	g.p = p; g.fd = fd; g.dir = p->p_fd[fd].fd_path; g.dl = ns_len(g.dir);
	g.ubuf = ubuf; g.n = n; g.off = 0; g.err = 0;
	if (p->p_fd[fd].fd_pos == 0 && ns_emit(&g, ".", 1, 1, 1))
		return (g.err != 0 ? g.err : (long)g.off);
	if (p->p_fd[fd].fd_pos == 1 && ns_emit(&g, "..", 2, 1, 2))
		return (g.err != 0 ? g.err : (long)g.off);
	g.start = (long)p->p_fd[fd].fd_pos - 2;
	(void) ns_walk(ns_gd_cb, &g);
	return (g.err != 0 ? g.err : (long)g.off);
}

static int
ns_any_cb(void *a, const char *name, int isdir, int kind, int ix)
{
	struct ns_q *q = a;
	const char *c;
	int d;

	(void) kind; (void) ix;
	return (ns_comp(name, q->path, q->len, &c, &d, isdir) != 0);
}

/* 1 if directory `path` has any child. */
static int
ns_has_child(const char *path)
{
	struct ns_q q;

	q.path = path;
	q.len = ns_len(path);
	return (ns_walk(ns_any_cb, &q) != 0);
}

/* The parent of canonical `path` must be an existing directory. */
static int
ns_parent_ok(const char *path)
{
	char par[NS_PATHMAX];
	int i, l = ns_len(path);

	for (i = l - 1; i > 0 && path[i] != '/'; i--)
		;
	if (i == 0)
		return (1);		/* parent is "/" */
	for (l = 0; l < i; l++)
		par[l] = path[l];
	par[i] = 0;
	return (ns_kind(par) == 2);
}

long
proc_mkdirat(int dirfd, const char *upath, int mode)
{
	proc_t *p = curproc;
	char path[NS_PATHMAX];
	int r, i, j;

	(void) mode;
	if (p == 0)
		return (-NS_EINVAL);
	if ((r = ns_abspath(p, dirfd, upath, path)) != 0)
		return (r);
	if (ns_kind(path) != 0)
		return (-NS_EEXIST);
	if (!ns_parent_ok(path))
		return (ns_kind(path) == 0 ? -NS_ENOENT : -NS_ENOTDIR);
	for (i = 0; i < NNSDIR; i++) {
		if (nsdirs[i][0] != 0)
			continue;
		for (j = 0; path[j] != 0; j++)
			nsdirs[i][j] = path[j];
		nsdirs[i][j] = 0;
		return (0);
	}
	return (-NS_ENOSPC);
}

/*
 * A directory that existed only as the prefix of its children would vanish
 * with its last child; POSIX leaves it, empty. Record it before that happens.
 */
static void
ns_keep_parent(const char *path)
{
	char par[NS_PATHMAX];
	int i, j, l = ns_len(path);

	for (i = l - 1; i > 0 && path[i] != '/'; i--)
		;
	if (i <= 0)
		return;			/* parent is "/" */
	for (j = 0; j < i; j++)
		par[j] = path[j];
	par[i] = 0;
	{
		struct ns_find f;

		f.path = par;
		f.kind = 0;
		if (ns_walk(ns_find_cb, &f))
			return;		/* named explicitly already */
	}
	for (i = 0; i < NNSDIR; i++) {
		if (nsdirs[i][0] != 0)
			continue;
		for (j = 0; par[j] != 0; j++)
			nsdirs[i][j] = par[j];
		nsdirs[i][j] = 0;
		return;
	}
}

/* Remove the exact name `path` from whichever table holds it. */
static int
ns_remove(const char *path)
{
	struct ns_find f;
	int cap;
	char *w;

	f.path = path;
	f.kind = 0;
	if (!ns_walk(ns_find_cb, &f))
		return (-NS_ENOENT);
	if (f.kind != 2)
		ns_keep_parent(path);
	switch (f.kind) {
	case 1:
		w = rootfs_wpath(f.ix, &cap);
		if (w == 0)
			return (-NS_EROFS);
		w[0] = 0;
		return (0);
	case 3:
		/* the buffer stays with the slot: ramfs_create reuses it */
		ramfiles[f.ix].rf_used = 0;
		return (0);
	case 4:
		nsdirs[f.ix][0] = 0;
		return (0);
	}
	return (-NS_EROFS);
}

long
proc_unlinkat(int dirfd, const char *upath, int flags)
{
	proc_t *p = curproc;
	char path[NS_PATHMAX];
	int r, kind;

	if (p == 0)
		return (-NS_EINVAL);
	if ((r = ns_abspath(p, dirfd, upath, path)) != 0)
		return (r);
	kind = ns_kind(path);
	if (kind == 0)
		return (-NS_ENOENT);
	if (flags & AT_REMOVEDIR_K) {
		if (kind != 2)
			return (-NS_ENOTDIR);
		if (ns_has_child(path))
			return (-NS_ENOTEMPTY);
		r = ns_remove(path);
		return (r == -NS_ENOENT ? -NS_EROFS : r);	/* implicit dir */
	}
	if (kind == 2)
		return (-NS_EISDIR);
	return (ns_remove(path));
}

struct ns_ren { const char *from; int fl; const char *to; int tl; int err; };

/* Rewrite every name at or under `from` to live under `to`. */
static int
ns_ren_cb(void *a, const char *name, int isdir, int kind, int ix)
{
	struct ns_ren *rn = a;
	char nn[NS_PATHMAX];
	char *dst;
	int cap, i, k;

	(void) isdir;
	if (!ns_under(name, rn->from, rn->fl))
		return (0);
	k = 0;
	for (i = 0; i < rn->tl; i++)
		nn[k++] = rn->to[i];
	for (i = rn->fl; name[i] != 0; i++) {
		if (k >= NS_PATHMAX - 1) {
			rn->err = -NS_ENAMETOOLONG;
			return (1);
		}
		nn[k++] = name[i];
	}
	nn[k] = 0;
	switch (kind) {
	case 1: dst = rootfs_wpath(ix, &cap); break;
	case 3: dst = ramfiles[ix].rf_path; cap = 64; break;
	case 4: dst = nsdirs[ix]; cap = NS_PATHMAX; break;
	default: rn->err = -NS_EROFS; return (1);
	}
	if (dst == 0 || k >= cap) {
		rn->err = dst == 0 ? -NS_EROFS : -NS_ENAMETOOLONG;
		return (1);
	}
	for (i = 0; i <= k; i++)
		dst[i] = nn[i];
	return (0);
}

/* Pre-check: every name the rename would move must be movable. */
static int
ns_ren_chk(void *a, const char *name, int isdir, int kind, int ix)
{
	struct ns_ren *rn = a;
	int i, l = ns_len(name);

	(void) isdir; (void) ix;
	if (!ns_under(name, rn->from, rn->fl))
		return (0);
	if (kind == 2) {
		rn->err = -NS_EROFS;
		return (1);
	}
	i = rn->tl + l - rn->fl;
	if (i >= (kind == 3 ? 64 : (kind == 1 ? 100 : NS_PATHMAX))) {
		rn->err = -NS_ENAMETOOLONG;
		return (1);
	}
	return (0);
}

long
proc_renameat(int ofd, const char *uold, int nfd, const char *unew)
{
	proc_t *p = curproc;
	char from[NS_PATHMAX], to[NS_PATHMAX];
	int r, fk, tk;
	struct ns_ren rn;

	if (p == 0)
		return (-NS_EINVAL);
	if ((r = ns_abspath(p, ofd, uold, from)) != 0)
		return (r);
	if ((r = ns_abspath(p, nfd, unew, to)) != 0)
		return (r);
	fk = ns_kind(from);
	if (fk == 0)
		return (-NS_ENOENT);
	if (str_eq_uproc(from, to))
		return (0);
	rn.from = from; rn.fl = ns_len(from);
	rn.to = to; rn.tl = ns_len(to);
	rn.err = 0;
	if (fk == 2 && ns_under(to, from, rn.fl))
		return (-NS_EINVAL);		/* into its own subtree */
	if (!ns_parent_ok(to))
		return (-NS_ENOENT);
	tk = ns_kind(to);
	if (tk == 2 && fk != 2)
		return (-NS_EISDIR);
	if (tk == 1 && fk == 2)
		return (-NS_ENOTDIR);
	if (tk == 2 && ns_has_child(to))
		return (-NS_ENOTEMPTY);
	(void) ns_walk(ns_ren_chk, &rn);
	if (rn.err != 0)
		return (rn.err);
	if (tk != 0 && (r = ns_remove(to)) != 0 && r != -NS_ENOENT)
		return (r);			/* replace the target */
	ns_keep_parent(from);		/* the source dir stays, maybe empty */
	(void) ns_walk(ns_ren_cb, &rn);
	return (rn.err);
}

long
proc_chdir(const char *upath)
{
	proc_t *p = curproc;
	char path[NS_PATHMAX];
	int r, i;

	if (p == 0)
		return (-NS_EINVAL);
	if ((r = ns_abspath(p, AT_FDCWD_K, upath, path)) != 0)
		return (r);
	r = ns_kind(path);
	if (r == 0)
		return (-NS_ENOENT);
	if (r != 2)
		return (-NS_ENOTDIR);
	for (i = 0; path[i] != 0; i++)
		p->p_cwd[i] = path[i];
	p->p_cwd[i] = 0;
	return (0);
}

/* getcwd(buf, size): Linux returns the length including the NUL. */
long
proc_getcwd(unsigned long ubuf, unsigned long size)
{
	proc_t *p = curproc;
	int l;

	if (p == 0)
		return (-NS_EINVAL);
	l = ns_len(p->p_cwd) + 1;
	if ((unsigned long)l > size)
		return (-34 /* ERANGE */);
	if (copyout(p->p_cwd, (void *)ubuf, l) != 0)
		return (-NS_EFAULT);
	return (l);
}

/*
 * proc_openat_w — open supporting O_CREAT/O_WRONLY/O_RDWR against the ramfs.
 * If the flags request write/create and the path is not a read-only vfs file,
 * back the fd with a ramfs node (creating it on O_CREAT). Read-only opens fall
 * through to the existing proc_open (vfs image). Returns fd or negative errno.
 */
#define	O_EXCL_K	0x80
#define	O_TRUNC_K	0x200
#define	O_DIRECTORY_K	0x10000
#define	O_CLOEXEC_K	0x80000
#define	O_APPEND_K	0x400

static long proc_openat_ns(const char *kpath, int flags);

/*
 * openat(dirfd, path, flags): resolve `path` against dirfd/the cwd, then open a
 * directory (an fd for getdents) or a file. O_EXCL, O_TRUNC, O_DIRECTORY and
 * O_CLOEXEC are honoured here; the file kinds are proc_openat_ns's.
 */
long
proc_openat(int dirfd, const char *upath, int flags)
{
	proc_t *p = curproc;
	char path[NS_PATHMAX];
	int r, kind;
	long fd;

	if (p == 0 || upath == 0)
		return (-NS_EFAULT);
	if ((r = ns_abspath(p, dirfd, upath, path)) != 0)
		return (r);
	/* /dev/fb and /data/<name> (SNFS) are reached by name, not listed. */
	if (str_eq_uproc(path, "/dev/fb") || (ns_under(path, "/data", 5) &&
	    path[5] == '/'))
		return (proc_openat_ns(path, flags));
	kind = ns_kind(path);
	if (kind != 0 && (flags & O_CREAT) && (flags & O_EXCL_K))
		return (-NS_EEXIST);
	if (kind == 2) {
		if (flags & (O_WRONLY | O_RDWR))
			return (-NS_EISDIR);
		fd = ns_opendir(p, path);
	} else {
		if (flags & O_DIRECTORY_K)
			return (kind == 0 ? -NS_ENOENT : -NS_ENOTDIR);
		if (kind == 0 && !(flags & O_CREAT))
			return (-NS_ENOENT);
		if (kind == 0 && !ns_parent_ok(path))
			return (-NS_ENOENT);
		fd = proc_openat_ns(path, flags);
		if (fd >= 0)
			ns_setpath(p, fd, path);
	}
	if (fd >= 0 && (flags & O_CLOEXEC_K))
		p->p_fd[fd].fd_cloexec = 1;
	if (fd >= 0 && (flags & O_APPEND_K))
		p->p_fd[fd].fd_append = 1;
	return (fd);
}

/* proc_openat_w -- the pre-rvsh entry (absolute path, flags), kept for callers
 * that pass a user pointer and no dirfd. */
long
proc_openat_w(const char *path, int flags)
{
	return (proc_openat(AT_FDCWD_K, path, flags));
}

/*
 * proc_openat_ns -- open canonical kernel path `kpath`: /data -> SNFS, /dev/fb
 * -> the scanout node, else the ramfs (writable) or the read-only image. A
 * write open of a read-only root file copies it into the ramfs first (copy on
 * write), so editing /etc/words in place works; O_TRUNC empties the file.
 */
static long
proc_openat_ns(const char *kpath, int flags)
{
	proc_t *p = curproc;
	int fd;
	struct ramfile *r;

	/* R-P12: paths under /data/ live on the on-disk SNFS (block-cached). */
	if (kpath[0] == '/' && kpath[1] == 'd' && kpath[2] == 'a' &&
	    kpath[3] == 't' && kpath[4] == 'a' && kpath[5] == '/') {
		extern long proc_openat_snfs(const char *kpath, int flags);
		return (proc_openat_snfs(kpath, flags));
	}

	/*
	 * The scanout seam: /dev/fb is a character device, not a file -- it has no
	 * bytes to read, only the FBIOGMODE/FBIOFLUSH ioctls and an mmap of the
	 * framebuffer (docs/riscv64-scanout-seam.md section 2).  Route it to the
	 * fb driver and mark the fd so ioctl/mmap can find it and read/write
	 * cannot mistake it for a ramfs node.
	 *
	 * NOTE: one hardcoded device path rather than a devfs; a real /dev needs a
	 * vnode layer, and one node is what the scanout seam requires.
	 */
	if (str_eq_uproc(kpath, "/dev/fb")) {
		extern long fb_open(void);
		long r = fb_open();

		if (r < 0)
			return (r);		/* ENXIO: no scanout engine */
		for (fd = 3; fd < NOFILE; fd++) {
			if (!p->p_fd[fd].fd_used) {
				p->p_fd[fd].fd_used = 1;
				p->p_fd[fd].fd_fb = 1;
				p->p_fd[fd].fd_wnode = 0;
				p->p_fd[fd].fd_data = 0;
				p->p_fd[fd].fd_len = 0;
				p->p_fd[fd].fd_pos = 0;
				p->p_fd[fd].fd_snfs = -1;
				p->p_fd[fd].fd_pipe = -1;
				p->p_fd[fd].fd_sock = -1;
		p->p_fd[fd].fd_port = -1;
				return (fd);
			}
		}
		{
			extern long fb_close(void);
			(void) fb_close();	/* undo the open reference */
		}
		return (-1);			/* fd table full */
	}

	/* Read-only open of an existing file: the read-only image path
	 * unless the ramfs holds it. */
	if ((flags & (O_WRONLY | O_RDWR)) == 0 && ramfs_find(kpath) == 0) {
		const void *d;
		unsigned long l;

		if (vfs_lookup(kpath, &d, &l))
			return (ns_openimg(p, d, l));
	}

	r = ramfs_find(kpath);
	if (r == 0) {
		const void *d;
		unsigned long l;
		int have = vfs_lookup(kpath, &d, &l);

		if (!have && !(flags & O_CREAT))
			return (-NS_ENOENT);
		if (have && l > RAMFILE_MAX)
			return (-27 /* EFBIG: past the ramfs file cap */);
		if (ns_len(kpath) >= (int)sizeof (r->rf_path))
			return (-NS_ENAMETOOLONG);
		r = ramfs_create(kpath);
		if (r == 0)
			return (-NS_ENOSPC);
		if (have) {		/* copy on write of a root image file */
			unsigned long k;

			for (k = 0; k < l; k++)
				r->rf_data[k] = ((const unsigned char *)d)[k];
			r->rf_len = l;
			ns_hide(kpath);
		}
	}
	if (flags & O_TRUNC_K)
		r->rf_len = 0;
	for (fd = 3; fd < NOFILE; fd++) {
		if (!p->p_fd[fd].fd_used) {
			p->p_fd[fd].fd_used = 1;
			p->p_fd[fd].fd_wnode = r;
			p->p_fd[fd].fd_data = r->rf_data;
			p->p_fd[fd].fd_len = r->rf_len;
			p->p_fd[fd].fd_pos = 0;
			p->p_fd[fd].fd_snfs = -1;
			p->p_fd[fd].fd_pipe = -1;
			p->p_fd[fd].fd_sock = -1;
		p->p_fd[fd].fd_port = -1;
			return (fd);
		}
	}
	return (-1);				/* fd table full */
}

/*
 * proc_fwrite — write to an open writable (ramfs) fd. Copies from the user
 * buffer into the file buffer at the cursor, growing rf_len, and advances the
 * cursor. An empty fd 1/2 is the console (syscall layer). Returns bytes
 * written or negative errno.
 */
long
proc_fwrite(int fd, const char *ubuf, unsigned long n)
{
	proc_t *p = curproc;
	struct ramfile *r;
	unsigned long pos;

	if (p == 0 || fd < 0 || fd >= NOFILE || !p->p_fd[fd].fd_used)
		return (-1);
	if (p->p_fd[fd].fd_nonblock && n > 0 && (p->p_fd[fd].fd_pipe >= 0 ||
	    p->p_fd[fd].fd_sock >= 0) && (fd_ready(p, fd) & 0x001c) == 0)
		return (-11 /* EAGAIN */);
	/* R-P12: pipe write end. */
	if (p->p_fd[fd].fd_pipe >= 0)
		return (pipe_write(p->p_fd[fd].fd_pipe, ubuf, n));
	/* An AF_UNIX endpoint: write(2) is sendmsg with no ancillary data. */
	if (p->p_fd[fd].fd_sock >= 0 && inet_is(p->p_fd[fd].fd_sock))
		return (inet_uwrite(p->p_fd[fd].fd_sock, ubuf, n, 0, 0));
	if (p->p_fd[fd].fd_sock >= 0)
		return (unsock_send(p->p_fd[fd].fd_sock, ubuf, n, 0, 0));
	/* O_APPEND: the cursor moves to EOF before each write (POSIX). */
	if (p->p_fd[fd].fd_append) {
		if (p->p_fd[fd].fd_snfs >= 0)
			p->p_fd[fd].fd_pos = snfs_len(p->p_fd[fd].fd_snfs);
		else if (p->p_fd[fd].fd_wnode != 0)
			p->p_fd[fd].fd_pos =
			    ((struct ramfile *)p->p_fd[fd].fd_wnode)->rf_len;
	}
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

	if (p == 0 || fd < 0 || fd >= NOFILE || !p->p_fd[fd].fd_used)
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
		/* rvsmp-d: claim atomically; two harts' pipe2 took one slot */
		if (!pipetab[i].pp_used &&
		    !__atomic_exchange_n(&pipetab[i].pp_used, 1, __ATOMIC_ACQUIRE)) {
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

	for (fd = 3; fd < NOFILE && rfd < 0; fd++)
		if (!p->p_fd[fd].fd_used) rfd = fd;
	for (fd = rfd + 1; fd < NOFILE && wfd < 0; fd++)
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

	if (p == 0 || oldfd < 0 || oldfd >= NOFILE || newfd < 0 || newfd >= NOFILE)
		return (-1);
	if (oldfd == newfd)
		return (newfd);
	if (oldfd >= 3 && !p->p_fd[oldfd].fd_used)
		return (-1);
	/* Close the target first (drops its reference, any slot). */
	fd_release(p, newfd);
	/* Duplicate oldfd's slot into newfd and take the copy's reference. A
	 * console source (0/1/2 holding no object) has nothing to copy: newfd is
	 * left empty, which is the console again. */
	if (p->p_fd[oldfd].fd_used) {
		p->p_fd[newfd] = p->p_fd[oldfd];
		p->p_fd[newfd].fd_cloexec = 0;	/* POSIX: dup2 clears FD_CLOEXEC */
		fd_hold(p, newfd);
	}
	return (newfd);
}

/*
 * proc_fcntl -- fcntl(2), the descriptor commands only (Linux riscv numbering,
 * as the rest of this syscall table): F_DUPFD/F_DUPFD_CLOEXEC (lowest free fd
 * >= arg) and F_GETFD/F_SETFD (FD_CLOEXEC). An empty fd 0..2 is the console,
 * which is not an object: F_GETFD/F_SETFD on it succeed, F_DUPFD of it is EBADF.
 * shortcut: the console is not a slot object, so it cannot be dup'd above fd 2
 * (dash's savefd then treats it as closed and close() restores the console);
 * make it an fd kind when `exec 3>&1` on an unredirected stdout is needed.
 */
#define	F_DUPFD_K		0
#define	F_GETFD_K		1
#define	F_SETFD_K		2
#define	F_GETFL_K		3
#define	F_SETFL_K		4
#define	O_NONBLOCK_K		0x800
#define	F_DUPFD_CLOEXEC_K	1030
#define	FD_CLOEXEC_K		1
long
proc_fcntl(int fd, int cmd, long arg)
{
	proc_t *p = curproc;
	int nfd;

	if (p == 0 || fd < 0 || fd >= NOFILE)
		return (-9 /* EBADF */);
	if (!p->p_fd[fd].fd_used && fd > 2)
		return (-9 /* EBADF */);
	switch (cmd) {
	case F_GETFD_K:
		return (p->p_fd[fd].fd_cloexec ? FD_CLOEXEC_K : 0);
	case F_SETFD_K:
		if (p->p_fd[fd].fd_used)
			p->p_fd[fd].fd_cloexec = (arg & FD_CLOEXEC_K) != 0;
		return (0);
	case F_GETFL_K:		/* rvlogin: status flags; an empty 0..2 is the console */
		return (2 /* O_RDWR */ | (p->p_fd[fd].fd_used && p->p_fd[fd].fd_append ?
		    O_APPEND_K : 0) | (p->p_fd[fd].fd_used && p->p_fd[fd].fd_nonblock ?
		    O_NONBLOCK_K : 0));
	case F_SETFL_K:
		if (!p->p_fd[fd].fd_used)
			return (-19 /* ENODEV: the console is always blocking */);
		p->p_fd[fd].fd_append = (arg & O_APPEND_K) != 0;
		p->p_fd[fd].fd_nonblock = (arg & O_NONBLOCK_K) != 0;
		return (0);
	case F_DUPFD_K:
	case F_DUPFD_CLOEXEC_K:
		if (arg < 0 || arg >= NOFILE)
			return (-22 /* EINVAL */);
		if (!p->p_fd[fd].fd_used)
			return (-9 /* EBADF: the console is not dup-able */);
		for (nfd = (int)arg; nfd < NOFILE; nfd++)
			if (!p->p_fd[nfd].fd_used && nfd > 2)
				break;
		if (nfd >= NOFILE)
			return (-24 /* EMFILE */);
		p->p_fd[nfd] = p->p_fd[fd];
		p->p_fd[nfd].fd_cloexec = (cmd == F_DUPFD_CLOEXEC_K);
		fd_hold(p, nfd);
		return (nfd);
	}
	return (-22 /* EINVAL */);
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
	for (fd = 3; fd < NOFILE; fd++) {
		if (!p->p_fd[fd].fd_used) {
			p->p_fd[fd].fd_used = 1;
			p->p_fd[fd].fd_snfs = slot;
			p->p_fd[fd].fd_pipe = -1;
			p->p_fd[fd].fd_sock = -1;
		p->p_fd[fd].fd_port = -1;
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

/*
 * ===========================================================================
 * The scanout seam's syscall backends: ioctl + mmap for /dev/fb.
 *
 * These are the two entry points syscall.c routes SYS_ioctl / SYS_mmap to. They
 * exist here rather than in fb.c because only uproc.c knows the fd table and
 * the calling process's address space; fb.c owns everything about the device.
 * ===========================================================================
 */

/* fb.c: the /dev/fb driver (the cb_ops-shaped entry points). */
extern long fb_ioctl(int cmd, unsigned long arg);
extern long fb_mmap(unsigned long root, unsigned long len);
/* as.c: the caller's AS root page-table PA, for fb_mmap's hat_as_map loop. */
extern unsigned long as_root(as_t *as);

#define	ENOTTY_UPROC	25

/*
 * proc_ioctl — dispatch an ioctl on an open fd. Only the scanout node has any
 * ioctls; every other fd kind gets ENOTTY, which is the correct POSIX answer
 * for "this fd is not a device that understands ioctls".
 */
long
proc_ioctl(int fd, int cmd, unsigned long arg)
{
	proc_t *p = curproc;

	/* An empty fd 0..2 is the console, the one tty: TCGETS (Linux 0x5401)
	 * succeeds there, so isatty() can ask the kernel. No termios yet: the
	 * struct termios (36 bytes) is returned zeroed. */
	if (p != 0 && fd >= 0 && fd <= 2 && !p->p_fd[fd].fd_used) {
		static const char zt[36];

		if (cmd != 0x5401)
			return (-ENOTTY_UPROC);
		if (arg != 0 && copyout(zt, (void *)arg, sizeof (zt)) != 0)
			return (-14 /* EFAULT */);
		return (0);
	}
	if (p == 0 || fd < 0 || fd >= NOFILE || !p->p_fd[fd].fd_used)
		return (-9 /* EBADF */);
	if (p->p_fd[fd].fd_fb)
		return (fb_ioctl(cmd, arg));
	return (-ENOTTY_UPROC);
}

/*
 * proc_mmap — map an open fd's memory into the calling process. Only the
 * scanout node is mappable through THIS path; anonymous memory goes through
 * proc_mmap_anon below. There is no general segment list to hang file-backed
 * mappings off yet (as.c is explicit about that).
 *
 * Returns the user VA on success, negative errno otherwise.
 *
 * NOTE: device mapping only for file-backed mmap, fixed VA; a real
 * seg_vn/seg_dev mmap is the upgrade when userland needs to map a file.
 */
long
proc_mmap(int fd, unsigned long len)
{
	proc_t *p = curproc;

	if (p == 0 || p->p_as == 0)
		return (-22 /* EINVAL */);
	if (fd < 0 || fd >= NOFILE || !p->p_fd[fd].fd_used)
		return (-9 /* EBADF */);
	if (!p->p_fd[fd].fd_fb)
		return (-19 /* ENODEV: only /dev/fb is mappable */);
	return (fb_mmap(as_root(p->p_as), len));
}

/*
 * proc_mmap_anon -- the MAP_ANON|MAP_PRIVATE path: fresh zeroed private pages in
 * the calling process's anon arena. This is what Rust std, every malloc
 * implementation and every thread-stack allocator actually asks for, and until
 * now the only mappable thing in this kernel was /dev/fb.
 *
 * Returns the user VA, or a negative errno. as.c owns the arena (as_anon_map).
 */
long
proc_mmap_anon(unsigned long len)
{
	proc_t *p = curproc;
	unsigned long va;

	if (p == 0 || p->p_as == 0)
		return (-22 /* EINVAL */);
	if (len == 0)
		return (-22 /* EINVAL */);
	va = as_anon_map(p->p_as, len);
	if (va == 0)
		return (-12 /* ENOMEM */);
	return ((long)va);
}

/*
 * ===========================================================================
 * poll(2) -- the syscall a compositor's main loop is built on.
 *
 * WHY THIS IS THE GATE. A Wayland compositor (and calloop, which smithay and
 * smallvil use) does not read sockets speculatively; it asks the kernel which of
 * its descriptors can be serviced and then services exactly those. Without
 * poll(2) the main loop cannot exist, no matter how good the socket layer is.
 *
 * LEVEL-TRIGGERED, DELIBERATELY. This implementation holds NO per-fd state
 * between calls: fd_ready() recomputes every answer from the current ring
 * cursors, backlog depth and reference counts. That is what makes it
 * level-triggered rather than edge-triggered, and it is the property this
 * project has been bitten by repeatedly on illumos (see
 * docs/cosmic-shell-session-layer.md and the calloop / wayland-client
 * timer-dispatch patches): a socket that ALREADY has buffered bytes when poll is
 * called must report readable on that call, not on the next write. The scan
 * therefore happens BEFORE any waiting, on every pass, and the test suite
 * checks exactly that case.
 *
 * WHAT "READY" MEANS. POLLIN is "a read will not block", which includes EOF: a
 * socket or pipe whose peer has gone reports POLLIN|POLLHUP, because read()
 * returns 0 immediately and an event loop watching only POLLIN must still learn
 * the client left. POLLOUT is "a write will not block". POLLERR is reported only
 * where the kernel can really tell a write would fail (all readers gone), never
 * as a catch-all. POLLNVAL is a closed/never-opened descriptor and counts toward
 * the return value, as POSIX requires.
 *
 * NOTE (ceiling): the wait is a yield loop, not a per-object wait queue, so a
 * poll that blocks costs a time slice per pass instead of zero cpu. It is
 * correct -- the deadline comes from the `time` CSR (gethrtime), which advances
 * in hardware and cannot stall the way a tick counter can while S-mode
 * interrupts are masked inside a syscall -- but it is not efficient. The upgrade
 * is registering the poller on each polled object's wait channel; wakeup()
 * already runs at every readiness change and already uses those channel
 * addresses, so the hooks exist. NPOLLFD tracks NOFILE (a process cannot poll
 * more fds than it can hold open); a real poll cache (illumos pollcache) is the
 * same upgrade.
 * ===========================================================================
 */

/* illumos sys/poll.h values (identical to the Linux ones, so no translation). */
#define	POLLIN		0x0001
#define	POLLPRI		0x0002
#define	POLLOUT		0x0004
#define	POLLERR		0x0008
#define	POLLHUP		0x0010
#define	POLLNVAL	0x0020
#define	POLLRDNORM	0x0040
#define	POLLWRNORM	POLLOUT

/*
 * Polling more fds than a process can hold open is meaningless, so this tracks
 * NOFILE rather than being an independent number -- when NOFILE went 8 -> 32 a
 * separate constant here would have silently become the new ceiling.
 */
#define	NPOLLFD		NOFILE

/* unixsock.c readiness bits (UNPOLL_*), kept out of the poll ABI on purpose. */
#define	UNPOLL_RD	0x1
#define	UNPOLL_WR	0x2
#define	UNPOLL_HUP	0x4
extern int unsock_poll(int si);

/* uart.c: is a console input byte waiting? The read(0) path blocks on this. */
extern int uart_rx_ready(void);
/* timer.c: the monotonic clock, read from the `time` CSR. */
extern unsigned long gethrtime(void);

/* The user ABI struct. int fd; short events; short revents -- 8 bytes. */
struct upollfd {
	int		pf_fd;
	short		pf_events;
	short		pf_revents;
};

/*
 * fd_ready -- the whole readiness policy, in one place, recomputed from live
 * state. Returns the full revents mask for `fd` ignoring `events` (the caller
 * applies the event filter); returns POLLNVAL for a descriptor that is not open.
 */
static short
fd_ready(proc_t *p, int fd)
{
	short r = 0;

	if (fd < 0 || fd >= NOFILE)
		return (POLLNVAL);

	/*
	 * fd 0/1/2 are the console UNLESS dup2 moved a real object into the slot
	 * (the shell does exactly that for a pipeline), so check the slot first
	 * and only fall back to console semantics.
	 */
	if (fd <= 2 && !p->p_fd[fd].fd_used) {
		if (fd == 0)
			return (uart_rx_ready() ? (short)POLLIN : (short)0);
		return (POLLOUT);	/* stdout/stderr never block */
	}

	if (!p->p_fd[fd].fd_used)
		return (POLLNVAL);

	if (p->p_fd[fd].fd_sock >= 0) {
		/* inet_poll returns the same RD/WR/HUP bits (1/2/4). */
		int m = inet_is(p->p_fd[fd].fd_sock) ?
		    inet_poll(p->p_fd[fd].fd_sock) :
		    unsock_poll(p->p_fd[fd].fd_sock);

		if (m & UNPOLL_RD)
			r |= POLLIN | POLLRDNORM;
		if (m & UNPOLL_WR)
			r |= POLLOUT;
		if (m & UNPOLL_HUP) {
			/*
			 * Peer gone: a write would fail EPIPE, which is a real
			 * error the kernel can see, so POLLERR is earned here
			 * rather than sprayed as a catch-all.
			 */
			r |= POLLHUP | POLLERR;
			r &= ~(short)POLLOUT;
		}
		return (r);
	}

	if (p->p_fd[fd].fd_pipe >= 0) {
		int pi = p->p_fd[fd].fd_pipe;
		struct pipe *pp = &pipetab[pi];

		if (!pp->pp_used)
			return (POLLNVAL);
		if (p->p_fd[fd].fd_pipe_w) {
			if (pp->pp_readers == 0)
				return (POLLERR);	/* write would EPIPE */
			if (pp->pp_wpos - pp->pp_rpos < PIPEBUF)
				r |= POLLOUT;
		} else {
			if (pp->pp_wpos != pp->pp_rpos)
				r |= POLLIN | POLLRDNORM;
			else if (pp->pp_writers == 0)
				r |= POLLIN | POLLHUP;	/* read returns 0 now */
		}
		return (r);
	}

	if (p->p_fd[fd].fd_fb) {
		/*
		 * The framebuffer is writable and has no readable event. Reporting
		 * POLLIN would be worse than useless: read() on it returns 0
		 * forever, so a compositor told "readable" would spin. Say only
		 * what is true.
		 */
		return (POLLOUT);
	}

	/* Regular file (ramfs, on-disk SNFS, or an embedded image): POSIX says a
	 * regular file is always ready in both directions. */
	return (POLLIN | POLLRDNORM | POLLOUT);
}

/*
 * proc_poll -- poll(2). `ufds` is a user array of nfds struct pollfd; `timeout`
 * is in milliseconds, with the two special values POSIX defines: 0 = scan once
 * and return immediately, negative = block until something is ready.
 *
 * Returns the number of descriptors with a non-zero revents (0 on timeout), or a
 * negative errno. revents is written back for every entry, including the zero
 * ones, because a caller reusing the array must not see stale bits.
 */
long
proc_poll(unsigned long ufds, int nfds, int timeout)
{
	proc_t *p = curproc;
	proc_t *self;
	struct upollfd kfds[NPOLLFD];
	unsigned long deadline = 0;
	int i, nready;

	if (p == 0)
		return (-9 /* EBADF */);
	if (nfds < 0 || nfds > NPOLLFD)
		return (-22 /* EINVAL */);
	if (nfds == 0) {
		/* A pure sleep. Still honors the timeout rather than returning
		 * instantly, which is what a poll-based timer does. */
		if (timeout <= 0)
			return (0);
	} else {
		if (ufds == 0)
			return (-14 /* EFAULT */);
		if (copyin((const void *)ufds, kfds,
		    (unsigned long)nfds * sizeof (struct upollfd)) != 0)
			return (-14 /* EFAULT */);
	}

	if (timeout > 0)
		deadline = gethrtime() + (unsigned long)timeout * 1000000UL;

	self = p;
	for (;;) {
		/*
		 * Scan FIRST, on every pass. This is the level-triggered contract:
		 * already-buffered data must be visible to the very first scan.
		 */
		nready = 0;
		for (i = 0; i < nfds; i++) {
			short want, got;

			if (kfds[i].pf_fd < 0) {
				kfds[i].pf_revents = 0;	/* POSIX: ignored */
				continue;
			}
			got = fd_ready(p, kfds[i].pf_fd);
			/*
			 * Only the requested events are reported, except
			 * POLLERR/POLLHUP/POLLNVAL which POSIX always reports --
			 * a caller must not be able to opt out of learning that
			 * its descriptor died.
			 */
			want = (short)(kfds[i].pf_events |
			    POLLERR | POLLHUP | POLLNVAL);
			kfds[i].pf_revents = (short)(got & want);
			if (kfds[i].pf_revents != 0)
				nready++;
		}
		if (nready > 0)
			break;
		if (timeout == 0)
			break;			/* immediate: 0 ready is the answer */
		if (timeout > 0 && gethrtime() >= deadline)
			break;			/* timed out: return 0 */
		if (proc_sig_wakes(p))
			return (-4 /* EINTR: the handler runs on the way out */);

		/*
		 * Wait. thread_yield gives the cpu to whoever might make us ready
		 * (the peer process is on its own kernel thread), and curproc is
		 * restored after because the dispatcher switches processes under
		 * us. See the ceiling NOTE above: correct, not cheap.
		 */
		thread_yield();
		curproc = self;
		p = self;
	}

	if (nfds > 0 && copyout(kfds, (void *)ufds,
	    (unsigned long)nfds * sizeof (struct upollfd)) != 0)
		return (-14 /* EFAULT */);
	return ((long)nready);
}

/*
 * nanosleep(&req, &rem) -- suspend for at least req, then report any remainder.
 *
 * WHY THIS MATTERS BEYOND sleep(1). Rust's thread::sleep goes through it, and so
 * does every event loop that arms a timer: calloop's Timer sources are what this
 * project's own illumos dispatch patches lean on (the calloop-wayland-source and
 * cosmic-panel timer-dispatch fixes both replaced a broken FD-readiness path with
 * a periodic Timer). A compositor with no working sleep busy-waits instead.
 *
 * It is also a librt symbol, which on illumos is a whole-library FILTER over
 * libc -- librt has zero objects, so every one of its 75 symbols must ultimately
 * live in libc. This is one of them.
 *
 * Deadline-based rather than tick-counting, matching proc_poll: counting ticks
 * accumulates error on every early wakeup, whereas re-checking gethrtime() against
 * a fixed deadline is self-correcting. thread_yield() rather than a spin so other
 * threads actually run -- the whole point of sleeping.
 */
long
proc_nanosleep(unsigned long ureq, unsigned long urem)
{
	struct {
		long tv_sec;
		long tv_nsec;
	} req;
	unsigned long deadline, now;

	if (ureq == 0)
		return (-22 /* EINVAL */);
	if (copyin((void *)ureq, &req, sizeof (req)) != 0)
		return (-14 /* EFAULT */);
	/*
	 * POSIX: tv_nsec must be in [0, 1e9). Reject rather than normalising, so
	 * a caller passing 2e9 ns learns it was wrong instead of silently
	 * sleeping a different length of time than it asked for.
	 */
	if (req.tv_sec < 0 || req.tv_nsec < 0 || req.tv_nsec >= 1000000000L)
		return (-22 /* EINVAL */);

	deadline = gethrtime() + (unsigned long)req.tv_sec * 1000000000UL +
	    (unsigned long)req.tv_nsec;

	while ((now = gethrtime()) < deadline)
		thread_yield();

	/*
	 * We only return when the deadline has passed, so the remainder is always
	 * zero. It is still written when asked for: a caller that loops on
	 * `while (nanosleep(&req, &req))` after a signal would otherwise re-read
	 * its ORIGINAL request and sleep twice. (Signals cannot interrupt this
	 * yet -- when they can, this is where the true remainder goes.)
	 */
	if (urem != 0) {
		struct {
			long tv_sec;
			long tv_nsec;
		} rem = { 0, 0 };

		if (copyout(&rem, (void *)urem, sizeof (rem)) != 0)
			return (-14 /* EFAULT */);
	}
	return (0);
}

/*
 * munmap(addr, len) -- release an anon mapping and make its VA reusable.
 *
 * Previously absent, and its absence was load-bearing: the anon arena was a bump
 * allocator, so every unmap leaked until process exit and a program that mapped
 * and unmapped in a loop exhausted the arena. A long-running compositor resizing
 * buffer pools does exactly that.
 *
 * Only the anon arena is unmappable. /dev/fb's mapping deliberately outlives
 * close() (as_free reclaims it at exit), so pointing munmap at it returns EINVAL
 * rather than tearing the framebuffer out from under the compositor.
 */
long
proc_munmap(unsigned long addr, unsigned long len)
{
	proc_t *p = curproc;

	if (p == 0 || p->p_as == 0)
		return (-22 /* EINVAL */);
	if (len == 0 || (addr & 0xfff) != 0)
		return (-22 /* EINVAL: POSIX requires an aligned addr */);
	if (as_anon_unmap(p->p_as, addr, len) != 0)
		return (-22 /* EINVAL: not a range we handed out */);
	/*
	 * Flush now: this AS is the one currently loaded (we are in its syscall),
	 * so stale TLB entries for the just-unmapped pages would let userland keep
	 * touching freed pages -- a use-after-free that would look like memory
	 * corruption far from its cause.
	 */
	__asm__ __volatile__("sfence.vma" ::: "memory");
	return (0);
}

/*
 * ------------------------------------------------------------------
 * Event ports (illumos port_create/associate/dissociate/getn/send).
 *
 * This is what calloop actually uses on illumos -- see port.c for the traced
 * dependency chain and why poll(2) alone is not sufficient. These wrappers do
 * the userland-facing work (fd allocation, copyin/copyout, blocking) and defer
 * the port bookkeeping to port.c, which knows nothing about proc_t.
 * ------------------------------------------------------------------
 */

/* fd_ready with the void* signature port_scan takes, so port.c stays proc-free. */
static int
port_ready_cb(void *owner, int fd)
{
	return (fd_ready((proc_t *)owner, fd));
}

/*
 * port_create() -> a new fd. The fd is the handle userland holds; the port index
 * lives in fd_port, exactly as a socket index lives in fd_sock.
 */
long
proc_port_create(void)
{
	proc_t *p = curproc;
	int fd, port;

	if (p == 0)
		return (-22 /* EINVAL */);
	for (fd = 0; fd < NOFILE; fd++)
		if (!p->p_fd[fd].fd_used)
			break;
	if (fd == NOFILE)
		return (-24 /* EMFILE */);

	port = port_alloc(p);
	if (port < 0)
		return (-23 /* ENFILE: no free port objects */);

	p->p_fd[fd].fd_used = 1;
	p->p_fd[fd].fd_snfs = -1;
	p->p_fd[fd].fd_pipe = -1;
	p->p_fd[fd].fd_sock = -1;
	p->p_fd[fd].fd_fb = 0;
	p->p_fd[fd].fd_port = port;
	return (fd);
}

/* Resolve an fd to its port index, or -1 if it is not a port. */
static int
fd_to_port(proc_t *p, int fd)
{
	if (p == 0 || fd < 0 || fd >= NOFILE || !p->p_fd[fd].fd_used)
		return (-1);
	return (p->p_fd[fd].fd_port);
}

/*
 * port_associate(port_fd, source, object, events, user).
 *
 * Only PORT_SOURCE_FD is accepted. Anything else returns EINVAL rather than
 * being silently ignored: a consumer that asked to watch a timer and got no
 * error would wait forever on an event that can never arrive.
 */
long
proc_port_associate(int pfd, int source, int object, int events,
    unsigned long user)
{
	proc_t *p = curproc;
	int port = fd_to_port(p, pfd);

	if (port < 0)
		return (-9 /* EBADF */);
	if (source != PORT_SOURCE_FD)
		return (-22 /* EINVAL: only fd sources are implemented */);
	if (object < 0 || object >= NOFILE || !p->p_fd[object].fd_used)
		return (-9 /* EBADF: the watched fd */);
	if (port_assoc_add(port, object, events, user) != 0)
		return (-28 /* ENOSPC: association table full */);
	return (0);
}

/*
 * port_dissociate(port_fd, source, object). Absent is deliberately NOT an error
 * -- see port.c: a oneshot association may have fired and removed itself between
 * the consumer deciding to drop it and doing so, and `polling` tolerates ENOENT.
 */
long
proc_port_dissociate(int pfd, int source, int object)
{
	proc_t *p = curproc;
	int port = fd_to_port(p, pfd);

	if (port < 0)
		return (-9 /* EBADF */);
	if (source != PORT_SOURCE_FD)
		return (-22 /* EINVAL */);
	(void) port_assoc_del(port, object);
	return (0);
}

/*
 * port_getn(port_fd, list, max, &n, timeout_ms).
 *
 * Blocking semantics deliberately match proc_poll's, which are already proven to
 * actually block (a 200 ms request measured 203 ms) rather than spin: timeout 0
 * polls once, >0 waits until a deadline computed from gethrtime(), <0 blocks.
 *
 * timeout is milliseconds here rather than illumos's timespec, because that is
 * the shape rustix passes down and translating it twice would only add a place
 * to get it wrong.
 */
long
proc_port_getn(int pfd, unsigned long ulist, int max, unsigned long unp,
    int timeout)
{
	proc_t *p = curproc;
	int port = fd_to_port(p, pfd);
	port_event_t ev[8];
	unsigned long deadline = 0;
	int n, i;

	if (port < 0)
		return (-9 /* EBADF */);
	if (max <= 0 || ulist == 0)
		return (-22 /* EINVAL */);
	if (max > 8)
		max = 8;		/* the on-stack batch bound */

	if (timeout > 0)
		deadline = gethrtime() + (unsigned long)timeout * 1000000UL;

	for (;;) {
		n = port_scan(port, ev, max, port_ready_cb);
		if (n < 0)
			return (-9 /* EBADF */);
		if (n > 0)
			break;
		if (timeout == 0)
			break;			/* poll once and report zero */
		if (timeout > 0 && gethrtime() >= deadline)
			break;			/* timed out: n stays 0 */
		thread_yield();
	}

	for (i = 0; i < n; i++) {
		if (copyout(&ev[i], (void *)(ulist +
		    (unsigned long)i * sizeof (ev[0])), sizeof (ev[0])) != 0)
			return (-14 /* EFAULT */);
	}
	if (unp != 0) {
		unsigned int un = (unsigned int)n;

		if (copyout(&un, (void *)unp, sizeof (un)) != 0)
			return (-14 /* EFAULT */);
	}
	return (0);
}

/*
 * port_send(port_fd, events, user) -- queue a user event. This is calloop's
 * Ping/LoopSignal wakeup, so it is not optional; port_scan drains user events
 * ahead of the fd scan so a wakeup wins even when no fd is ready.
 */
long
proc_port_send(int pfd, unsigned long user)
{
	proc_t *p = curproc;
	int port = fd_to_port(p, pfd);

	if (port < 0)
		return (-9 /* EBADF */);
	if (port_user_send(port, user) != 0)
		return (-11 /* EAGAIN: user-event queue full */);
	return (0);
}

/*
 * ===========================================================================
 * AF_UNIX socket syscalls: the fd-table half of unixsock.c.
 *
 * unixsock.c owns the protocol (rings, backlog, rights queue, blocking) and
 * speaks in SOCKET INDICES. This half owns the fd table and translates between
 * descriptors and those indices. Splitting it this way keeps every write to
 * p_fd[] in one file, which is what makes the reference counting auditable.
 *
 * The SCM_RIGHTS direction of travel is the subtle part and is handled here
 * deliberately:
 *   sending   -- the sender's descriptors are DUPLICATED into kernel-side
 *                references BEFORE the bytes are queued, so the sender may
 *                close its own copies immediately after sendmsg (exactly what a
 *                Wayland client does with a buffer fd) without the receiver
 *                losing the object.
 *   receiving -- the kernel-side references are INSTALLED into the receiver's
 *                own fd table, producing descriptor numbers that are valid in
 *                the receiver and unrelated to the sender's numbers. That is
 *                what "passing a file descriptor" actually means.
 * ===========================================================================
 */

/* unixsock.c calls these to reach the fd table + curproc without including it. */
void *
unsock_curproc(void)
{
	return (curproc);
}

void
unsock_setcurproc(void *p)
{
	curproc = (proc_t *)p;
}

/*
 * sock_fd_install -- bind socket index `si` to a fresh descriptor in the current
 * process. Returns the fd, or a negative errno. The socket's reference count is
 * NOT bumped here: the caller already owns exactly one reference (from
 * unsock_socket / unsock_accept / unsock_socketpair) and this transfers it to
 * the descriptor.
 */
static int
sock_fd_install(int si)
{
	proc_t *p = curproc;
	int fd;

	if (p == 0)
		return (-9 /* EBADF */);
	for (fd = 3; fd < NOFILE; fd++) {
		if (p->p_fd[fd].fd_used)
			continue;
		p->p_fd[fd].fd_used = 1;
		p->p_fd[fd].fd_data = 0;
		p->p_fd[fd].fd_len = 0;
		p->p_fd[fd].fd_pos = 0;
		p->p_fd[fd].fd_wnode = 0;
		p->p_fd[fd].fd_snfs = -1;
		p->p_fd[fd].fd_pipe = -1;
		p->p_fd[fd].fd_fb = 0;
		p->p_fd[fd].fd_sock = si;
		return (fd);
	}
	return (-24 /* EMFILE */);
}

/*
 * sock_of_fd -- the socket index behind a descriptor, or -1 if the descriptor is
 * not a socket. Every socket syscall validates through here so a file or pipe fd
 * passed to setsockopt/listen/accept fails cleanly instead of corrupting state.
 */
static int
sock_of_fd(int fd)
{
	proc_t *p = curproc;

	if (p == 0 || fd < 0 || fd >= NOFILE || !p->p_fd[fd].fd_used)
		return (-1);
	return (p->p_fd[fd].fd_sock);
}

/*
 * copy_sun_path -- pull the sun_path string out of a user sockaddr_un.
 *
 * struct sockaddr_un is { uint16_t sun_family; char sun_path[108]; } on illumos,
 * so the path begins 2 bytes in. We validate the family rather than trusting it:
 * a caller that passes AF_INET here gets EAFNOSUPPORT, not a path parsed out of
 * an IP address.
 */
static long
copy_sun_path(unsigned long uaddr, unsigned int ulen, char *kpath,
    unsigned long kmax)
{
	unsigned short fam = 0;
	unsigned long n;

	if (uaddr == 0)
		return (-14 /* EFAULT */);
	if (ulen < 3)
		return (-22 /* EINVAL: no room for a family + a byte of path */);
	if (copyin((const void *)uaddr, &fam, sizeof (fam)) != 0)
		return (-14 /* EFAULT */);
	if (fam != 1 /* AF_UNIX */)
		return (-97 /* EAFNOSUPPORT */);

	n = ulen - 2;
	if (n > kmax - 1)
		n = kmax - 1;
	if (copyin((const void *)(uaddr + 2), kpath, n) != 0)
		return (-14 /* EFAULT */);
	kpath[n] = '\0';
	if (kpath[0] == '\0')
		return (-22 /* EINVAL: the abstract namespace is not supported */);
	return (0);
}

long
sys_socket(int domain, int type, int protocol)
{
	/* type may carry SOCK_CLOEXEC/SOCK_NONBLOCK flag bits: keep the type. */
	int si = domain == 2 /* AF_INET */ ?
	    inet_socket(type & 0xf, protocol) :
	    unsock_socket(domain, type, protocol);
	int fd;

	if (si < 0)
		return (si);		/* already a negative errno */
	fd = sock_fd_install(si);
	if (fd < 0) {
		unsock_close(si);
		return (fd);
	}
	return (fd);
}

long
sys_bind(int fd, unsigned long uaddr, unsigned int ulen)
{
	char path[108];
	int si = sock_of_fd(fd);
	long r;

	if (si < 0)
		return (-88 /* ENOTSOCK */);
	if (inet_is(si)) {
		unsigned char sa[16];

		if (ulen < sizeof (sa) || copyin((void *)uaddr, sa, sizeof (sa)))
			return (ulen < sizeof (sa) ? -22 : -14);
		return (inet_bind(si, sa, sizeof (sa)));
	}
	r = copy_sun_path(uaddr, ulen, path, sizeof (path));
	if (r != 0)
		return (r);
	return (unsock_bind(si, path));
}

long
sys_listen(int fd, int backlog)
{
	int si = sock_of_fd(fd);

	if (si < 0)
		return (-88 /* ENOTSOCK */);
	if (inet_is(si))
		return (inet_listen(si, backlog));
	return (unsock_listen(si, backlog));
}

long
sys_connect(int fd, unsigned long uaddr, unsigned int ulen)
{
	char path[108];
	int si = sock_of_fd(fd);
	long r;

	if (si < 0)
		return (-88 /* ENOTSOCK */);
	if (inet_is(si)) {
		unsigned char sa[16];

		if (ulen < sizeof (sa) || copyin((void *)uaddr, sa, sizeof (sa)))
			return (ulen < sizeof (sa) ? -22 : -14);
		return (inet_connect(si, sa, sizeof (sa)));
	}
	r = copy_sun_path(uaddr, ulen, path, sizeof (path));
	if (r != 0)
		return (r);
	return (unsock_connect(si, path));
}

/*
 * sys_accept -- accept(2). Blocks in unsock_accept until a connection is queued,
 * installs the new endpoint into a descriptor, and only THEN calls
 * unsock_accepted -- which is what releases the peer's blocked connect(). The
 * order matters: if connect returned before the server had a valid descriptor, a
 * client could write into a socket the server cannot yet read.
 */
long
sys_accept(int fd, unsigned long uaddr, unsigned long ulenp)
{
	int si = sock_of_fd(fd);
	int peer, nfd;

	(void) uaddr;
	(void) ulenp;		/* AF_UNIX accept: no meaningful peer address */

	if (si < 0)
		return (-88 /* ENOTSOCK */);
	if (inet_is(si)) {
		unsigned char sa[16];
		unsigned int ulen = 0;

		peer = inet_accept(si, sa);
		if (peer < 0)
			return (peer);
		nfd = sock_fd_install(peer);
		if (nfd < 0) {
			inet_close(peer);
			return (nfd);
		}
		if (uaddr != 0 && ulenp != 0 &&
		    copyin((void *)ulenp, &ulen, sizeof (ulen)) == 0 &&
		    ulen >= sizeof (sa)) {
			ulen = sizeof (sa);
			(void) copyout(sa, (void *)uaddr, sizeof (sa));
			(void) copyout(&ulen, (void *)ulenp, sizeof (ulen));
		}
		return (nfd);
	}
	peer = unsock_accept(si);
	if (peer < 0)
		return (peer);
	nfd = sock_fd_install(peer);
	if (nfd < 0) {
		unsock_close(peer);
		return (nfd);
	}
	unsock_accepted(peer);
	return (nfd);
}

long
sys_socketpair(int domain, int type, int protocol, int *ufds)
{
	int a, b, fda, fdb, pair[2];
	int r;

	(void) protocol;
	r = unsock_socketpair(domain, type, &a, &b);
	if (r != 0)
		return (r);
	fda = sock_fd_install(a);
	if (fda < 0) {
		unsock_close(a);
		unsock_close(b);
		return (fda);
	}
	fdb = sock_fd_install(b);
	if (fdb < 0) {
		(void) proc_close(fda);
		unsock_close(b);
		return (fdb);
	}
	pair[0] = fda;
	pair[1] = fdb;
	if (copyout(pair, ufds, sizeof (pair)) != 0) {
		(void) proc_close(fda);
		(void) proc_close(fdb);
		return (-14 /* EFAULT */);
	}
	return (0);
}

/*
 * sendmsg/recvmsg, reduced to what SCM_RIGHTS needs.
 *
 * Rather than decode a full struct msghdr + cmsghdr chain in the kernel (which
 * is a lot of user-memory parsing for a fixed shape), the syscall takes the two
 * things that actually vary: the data buffer and a flat array of descriptors.
 * libsocket's __xnet_sendmsg is where the cmsghdr walk belongs -- that is
 * userland's job in the illumos layering, and doing it there keeps this kernel
 * path small and total. The ABI is deliberately explicit about this so nobody
 * mistakes it for a complete sendmsg(2).
 */
long
sys_sendmsg_fds(int fd, const char *ubuf, unsigned long n, unsigned long ufds,
    int nfds)
{
	int si = sock_of_fd(fd);
	int sendfds[8], kfds[8];
	int i, dup;
	long r;

	if (si < 0)
		return (-88 /* ENOTSOCK */);
	if (nfds < 0 || nfds > 8)
		return (-22 /* EINVAL */);

	if (nfds > 0) {
		if (copyin((const void *)ufds, sendfds,
		    (unsigned long)nfds * sizeof (int)) != 0)
			return (-14 /* EFAULT */);
		/*
		 * Duplicate each descriptor into a kernel-side reference BEFORE
		 * queueing, so the sender can close its copy right after this
		 * call. A descriptor that is not passable (not open, or not a
		 * type we can duplicate) fails the whole call rather than being
		 * dropped -- a silently-missing fd is worse than an error.
		 */
		for (i = 0; i < nfds; i++) {
			dup = unsock_fd_dup_into(sendfds[i]);
			if (dup < 0) {
				while (--i >= 0)
					unsock_rights_drop(kfds[i]);
				return (dup);
			}
			kfds[i] = dup;
		}
	}

	r = unsock_send(si, ubuf, n, nfds > 0 ? kfds : 0, nfds);
	if (r < 0 && nfds > 0) {
		for (i = 0; i < nfds; i++)
			unsock_rights_drop(kfds[i]);
	}
	return (r);
}

/*
 * sys_recvmsg_fds -- receive bytes plus any descriptors whose place in the byte
 * stream has been reached. The received fds are the RECEIVER's descriptor
 * numbers (installed by unsock_fd_dup_into's kernel references being handed
 * over), which is why the caller must read *unfds_out to learn how many arrived.
 */
long
sys_recvmsg_fds(int fd, char *ubuf, unsigned long n, unsigned long ufds,
    int maxfds, unsigned long unfds_out)
{
	int si = sock_of_fd(fd);
	int gotfds[8];
	int ngot = 0, i, out[8], nout = 0;
	long r;

	if (si < 0)
		return (-88 /* ENOTSOCK */);
	if (maxfds < 0 || maxfds > 8)
		return (-22 /* EINVAL */);

	r = unsock_recv(si, ubuf, n, maxfds > 0 ? gotfds : 0,
	    maxfds > 0 ? &ngot : 0);
	if (r < 0)
		return (r);

	if (ngot > maxfds)
		ngot = maxfds;
	for (i = 0; i < ngot; i++) {
		/*
		 * The queued value is a RIGHTS index (a captured object), not a
		 * descriptor. Install it into THIS process's fd table: that is
		 * the step that makes the received fd genuinely usable, because
		 * the number handed to userland then indexes the receiver's own
		 * table and names the sender's object.
		 */
		int nfd = unsock_fd_install_slot(gotfds[i]);

		if (nfd < 0) {
			/* Out of descriptors: drop the rest rather than leak. */
			int j;

			for (j = i; j < ngot; j++)
				unsock_rights_drop(gotfds[j]);
			break;
		}
		out[nout++] = nfd;
	}
	if (nout > 0 && ufds != 0) {
		if (copyout(out, (void *)ufds,
		    (unsigned long)nout * sizeof (int)) != 0)
			return (-14 /* EFAULT */);
	}
	if (unfds_out != 0) {
		if (copyout(&nout, (void *)unfds_out, sizeof (nout)) != 0)
			return (-14 /* EFAULT */);
	}
	return (r);
}

/*
 * sys_getsockopt / sys_setsockopt -- the minimum that lets a client library's
 * boilerplate succeed without lying about behaviour.
 *
 * SO_TYPE and SO_ERROR are answered for real (we know both). Everything else
 * returns ENOPROTOOPT rather than 0: a compositor that sets SO_PASSCRED and gets
 * a silent success would believe it has credentials it will never receive.
 */
long
sys_getsockopt(int fd, int level, int name, unsigned long uval,
    unsigned long ulenp)
{
	int si = sock_of_fd(fd);
	int v;
	unsigned int len = 0;

	if (si < 0)
		return (-88 /* ENOTSOCK */);
	if (level != 0xffff /* SOL_SOCKET */)
		return (-99 /* ENOPROTOOPT */);
	switch (name) {
	case 0x1008:		/* SO_TYPE */
		v = 2;		/* SOCK_STREAM */
		break;
	case 0x1007:		/* SO_ERROR */
		v = 0;		/* no pending async error is tracked */
		break;
	default:
		return (-99 /* ENOPROTOOPT */);
	}
	if (ulenp != 0) {
		if (copyin((const void *)ulenp, &len, sizeof (len)) != 0)
			return (-14 /* EFAULT */);
		if (len > sizeof (v))
			len = sizeof (v);
	} else {
		len = sizeof (v);
	}
	if (uval != 0 && copyout(&v, (void *)uval, len) != 0)
		return (-14 /* EFAULT */);
	if (ulenp != 0 && copyout(&len, (void *)ulenp, sizeof (len)) != 0)
		return (-14 /* EFAULT */);
	return (0);
}

long
sys_setsockopt(int fd, int level, int name, unsigned long uval,
    unsigned int ulen)
{
	int si = sock_of_fd(fd);

	(void) uval;
	(void) ulen;
	if (si < 0)
		return (-88 /* ENOTSOCK */);
	/*
	 * Nothing is settable yet. Returning ENOPROTOOPT is the honest answer;
	 * pretending to accept SO_SNDBUF/SO_PASSCRED would make a caller believe
	 * a buffer size or a credential mode took effect.
	 */
	(void) level;
	(void) name;
	return (-99 /* ENOPROTOOPT */);
}

/*
 * unsock_fd_dup_into -- capture descriptor `fd` as an in-flight SCM_RIGHTS
 * reference; unsock_fd_install_slot -- plant a captured reference into the
 * RECEIVER's fd table.
 *
 * WHY A SLOT COPY AND NOT AN FD NUMBER. A descriptor number means nothing in
 * another process; passing the number is what a fake implementation does. What
 * has to travel is the OBJECT the slot names. Here an fd slot is a small value
 * struct (a ramfs node pointer, an SNFS slot index, a pipe index, the fb flag),
 * and every one of those identifiers is GLOBAL -- ramfs nodes and pipes live in
 * kernel tables, not per-process ones -- so copying the slot transfers the object
 * correctly across unrelated processes, which is what SCM_RIGHTS means.
 * (Measured: passing the number let the server receive "an fd" that referred to
 * nothing, and the write through it failed.)
 *
 * NOTE: a slot copy is a flattened stand-in for illumos's file_t. It carries the
 * file OFFSET by value, so sender and receiver end up with independent cursors
 * rather than the shared offset real SCM_RIGHTS gives (dup semantics). For a
 * Wayland buffer fd -- mmap'd, or read whole -- that is immaterial; for a shared
 * append-mode log it would be wrong. The upgrade is a refcounted file_t the slot
 * points AT rather than contains.
 */
struct sock_rights {
	int	r_used;
	const unsigned char *r_data;
	unsigned long r_len;
	unsigned long r_pos;
	void	*r_wnode;
	int	r_snfs;
	int	r_pipe;
	int	r_pipe_w;
	int	r_fb;
	int	r_sock;
};

#define	NRIGHTS	16
static struct sock_rights rightstab[NRIGHTS];

int
unsock_fd_dup_into(int fd)
{
	proc_t *p = curproc;
	int i;

	if (p == 0 || fd < 0 || fd >= NOFILE || !p->p_fd[fd].fd_used)
		return (-9 /* EBADF */);
	for (i = 0; i < NRIGHTS; i++) {
		if (rightstab[i].r_used)
			continue;
		rightstab[i].r_used = 1;
		rightstab[i].r_data = p->p_fd[fd].fd_data;
		rightstab[i].r_len = p->p_fd[fd].fd_len;
		rightstab[i].r_pos = p->p_fd[fd].fd_pos;
		rightstab[i].r_wnode = p->p_fd[fd].fd_wnode;
		rightstab[i].r_snfs = p->p_fd[fd].fd_snfs;
		rightstab[i].r_pipe = p->p_fd[fd].fd_pipe;
		rightstab[i].r_pipe_w = p->p_fd[fd].fd_pipe_w;
		rightstab[i].r_fb = p->p_fd[fd].fd_fb;
		rightstab[i].r_sock = p->p_fd[fd].fd_sock;
		/*
		 * Hold a reference for the in-flight entry so the sender may
		 * close its own descriptor immediately after sendmsg (exactly
		 * what a Wayland client does with a buffer fd) without the
		 * object going away before the receiver claims it.
		 */
		if (rightstab[i].r_pipe >= 0)
			pipe_ref(rightstab[i].r_pipe, rightstab[i].r_pipe_w);
		if (rightstab[i].r_sock >= 0)
			unsock_ref(rightstab[i].r_sock);
		return (i);		/* a RIGHTS index, not an fd */
	}
	return (-24 /* EMFILE */);
}

/*
 * unsock_fd_install_slot -- claim rights index `ri` into a free descriptor of the
 * CURRENT process. This is the step that makes a received fd genuinely usable:
 * the number it returns indexes the RECEIVER's table and names the SENDER's
 * object. Returns the new fd, or a negative errno.
 */
int
unsock_fd_install_slot(int ri)
{
	proc_t *p = curproc;
	int fd;

	if (p == 0 || ri < 0 || ri >= NRIGHTS || !rightstab[ri].r_used)
		return (-9 /* EBADF */);
	for (fd = 3; fd < NOFILE; fd++) {
		if (p->p_fd[fd].fd_used)
			continue;
		p->p_fd[fd].fd_used = 1;
		p->p_fd[fd].fd_data = rightstab[ri].r_data;
		p->p_fd[fd].fd_len = rightstab[ri].r_len;
		p->p_fd[fd].fd_pos = rightstab[ri].r_pos;
		p->p_fd[fd].fd_wnode = rightstab[ri].r_wnode;
		p->p_fd[fd].fd_snfs = rightstab[ri].r_snfs;
		p->p_fd[fd].fd_pipe = rightstab[ri].r_pipe;
		p->p_fd[fd].fd_pipe_w = rightstab[ri].r_pipe_w;
		p->p_fd[fd].fd_fb = rightstab[ri].r_fb;
		p->p_fd[fd].fd_sock = rightstab[ri].r_sock;
		rightstab[ri].r_used = 0;	/* reference moves to the fd */
		return (fd);
	}
	return (-24 /* EMFILE */);
}

/*
 * unsock_rights_drop -- release an in-flight rights entry nobody claimed (a
 * failed send, or a socket closed with rights still queued) so the underlying
 * object's reference is not leaked.
 */
void
unsock_rights_drop(int ri)
{
	if (ri < 0 || ri >= NRIGHTS || !rightstab[ri].r_used)
		return;
	if (rightstab[ri].r_pipe >= 0)
		pipe_close(rightstab[ri].r_pipe, rightstab[ri].r_pipe_w);
	if (rightstab[ri].r_sock >= 0)
		unsock_close(rightstab[ri].r_sock);
	rightstab[ri].r_used = 0;
}

/* Diagnostics for the gate banner (unixsock.c owns the counters). */
extern void unsock_stats(int *nsock, int *nbind);

void
sock_report(void)
{
	int ns = 0, nb = 0;

	unsock_stats(&ns, &nb);
	sbi_console_puts("[unixsock] live sockets ");
	kputdec((unsigned long)ns);
	sbi_console_puts(", bound names ");
	kputdec((unsigned long)nb);
	sbi_console_puts("\n");
}

/*
 * ---------------------------------------------------------------------------
 * rvsrv: AF_INET data path. inet.c works on kernel memory under its lock, so
 * user data crosses through a bounce buffer here (copyin/copyout catch a bad
 * user pointer as EFAULT instead of a kernel fault).
 * ---------------------------------------------------------------------------
 */
#define	INET_BOUNCE	1472

static long
inet_uread(int si, char *ubuf, unsigned long n, unsigned long usa,
    unsigned long ulenp)
{
	unsigned char kb[INET_BOUNCE];
	unsigned char sa[16];
	long r;

	if (n > sizeof (kb))
		n = sizeof (kb);
	r = inet_recv(si, kb, n, usa != 0 ? sa : 0);
	if (r > 0 && copyout(kb, ubuf, (unsigned long)r) != 0)
		return (-14 /* EFAULT */);
	if (r >= 0 && usa != 0 && ulenp != 0) {
		unsigned int ulen = sizeof (sa);

		(void) copyout(sa, (void *)usa, sizeof (sa));
		(void) copyout(&ulen, (void *)ulenp, sizeof (ulen));
	}
	return (r);
}

static long
inet_uwrite(int si, const char *ubuf, unsigned long n, unsigned long usa,
    unsigned int salen)
{
	unsigned char kb[INET_BOUNCE];
	unsigned char sa[16];
	unsigned long done = 0;

	if (usa != 0) {
		if (salen < sizeof (sa) || copyin((void *)usa, sa, sizeof (sa)))
			return (salen < sizeof (sa) ? -22 : -14);
		if (n > sizeof (kb))
			return (-90 /* EMSGSIZE */);
	}
	do {
		unsigned long chunk = n - done < sizeof (kb) ? n - done :
		    sizeof (kb);
		long r;

		if (copyin(ubuf + done, kb, chunk) != 0)
			return (done > 0 ? (long)done : -14 /* EFAULT */);
		r = inet_send(si, kb, chunk, usa != 0 ? sa : 0,
		    usa != 0 ? sizeof (sa) : 0);
		if (r < 0)
			return (done > 0 ? (long)done : r);
		done += (unsigned long)r;
		if ((unsigned long)r < chunk)
			break;
	} while (done < n);
	return ((long)done);
}

/* sendto(2): a0=fd a1=buf a2=len a3=flags a4=sockaddr* a5=addrlen */
long
sys_sendto(int fd, const char *ubuf, unsigned long n, int flags,
    unsigned long usa, unsigned int salen)
{
	int si = sock_of_fd(fd);

	(void) flags;
	if (si < 0)
		return (-88 /* ENOTSOCK */);
	if (!inet_is(si)) {
		if (usa != 0)
			return (-106 /* EISCONN: AF_UNIX stream */);
		return (unsock_send(si, ubuf, n, 0, 0));
	}
	return (inet_uwrite(si, ubuf, n, usa, salen));
}

/* recvfrom(2): a0=fd a1=buf a2=len a3=flags a4=sockaddr* a5=socklen_t* */
long
sys_recvfrom(int fd, char *ubuf, unsigned long n, int flags,
    unsigned long usa, unsigned long ulenp)
{
	int si = sock_of_fd(fd);

	(void) flags;
	if (si < 0)
		return (-88 /* ENOTSOCK */);
	if (!inet_is(si))
		return (unsock_recv(si, ubuf, n, 0, 0));
	return (inet_uread(si, ubuf, n, usa, ulenp));
}

/* getsockname(2) / getpeername(2) for AF_INET: a0=fd a1=sockaddr* a2=len* */
long
sys_getname(int fd, unsigned long usa, unsigned long ulenp, int peer)
{
	int si = sock_of_fd(fd);
	unsigned char sa[16];
	unsigned int ulen = 0;
	int r;

	if (si < 0)
		return (-88 /* ENOTSOCK */);
	if (!inet_is(si))
		return (-95 /* EOPNOTSUPP: AF_UNIX names are not tracked */);
	if (copyin((void *)ulenp, &ulen, sizeof (ulen)) != 0)
		return (-14);
	if (ulen < sizeof (sa))
		return (-22);
	if ((r = inet_getsockname(si, sa, peer)) != 0)
		return (r);
	ulen = sizeof (sa);
	if (copyout(sa, (void *)usa, sizeof (sa)) != 0 ||
	    copyout(&ulen, (void *)ulenp, sizeof (ulen)) != 0)
		return (-14);
	return (0);
}
