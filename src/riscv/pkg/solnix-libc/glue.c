/*
 * glue.c -- the newlib 4.5.0 OS port layer for userland PACKAGES on the solnix
 * riscv64 kernel (src/riscv/uts). It grows user/newlib_glue.c (the 11-symbol
 * NEWLIBTEST port) into what real packages (zlib, sbase, ed, dash, ncurses) link
 * against. Every entry point is tagged:
 *
 *   [REAL]     backed by a kernel syscall that does the thing.
 *   [DERIVED]  real answer computed from other real syscalls (e.g. a file's size
 *              from lseek); the limit is stated.
 *   [STUB]     returns a fixed value because the kernel has no such facility.
 *   [ENOSYS]   fails with ENOSYS / ENOTTY, never a plausible fake.
 *
 * Kernel syscall ABI (uts/syscall.c): Linux riscv numbers, a7 = number, a0.. =
 * args, negative return = -errno (the kernel often returns a bare -1).
 */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#define	_POSIX_TIMERS 1
#define	_POSIX_MONOTONIC_CLOCK 200112L
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/times.h>
#include <sys/types.h>
#include <sys/wait.h>
struct rusage;
#include <sys/utsname.h>

#define	K_openat	56
#define	K_close		57
#define	K_pipe2		59
#define	K_lseek		62
#define	K_read		63
#define	K_write		64
#define	K_dup3		24
#define	K_poll		73
#define	K_exit		93
#define	K_nanosleep	101
#define	K_clock_gettime	113
#define	K_kill		129
#define	K_rt_sigaction	134
#define	K_setgid	144
#define	K_setuid	146
#define	K_getpid	172
#define	K_getuid	174
#define	K_brk		214
#define	K_fork		220
#define	K_execve	221
#define	K_wait4		260

#define	K_fcntl		25
#define	K_getcwd	17
#define	K_mkdirat	34
#define	K_unlinkat	35
#define	K_renameat	38
#define	K_chdir		49
#define	K_getdents64	61
#define	K_fstatat	79
#define	K_fstat		80
#define	K_AT_FDCWD	(-100)
#define	K_O_EXCL	0x80
#define	K_O_TRUNC	0x200
#define	K_O_DIRECTORY	0x10000
#define	K_O_CLOEXEC	0x80000
#define	K_O_APPEND	0x400
#define	K_ioctl		29
#define	K_O_WRONLY	0x1
#define	K_O_RDWR	0x2
#define	K_O_CREAT	0x40
#define	K_NOFILE	32		/* uproc.c NOFILE */

extern char **environ;
extern void __solnix_sigreturn(void);

static long
ksys(long n, long a0, long a1, long a2, long a3)
{
	register long r0 __asm__("a0") = a0;
	register long r1 __asm__("a1") = a1;
	register long r2 __asm__("a2") = a2;
	register long r3 __asm__("a3") = a3;
	register long r7 __asm__("a7") = n;

	__asm__ __volatile__("ecall" : "+r"(r0)
	    : "r"(r1), "r"(r2), "r"(r3), "r"(r7) : "memory");
	return (r0);
}

/* Kernel -1 (no errno given) maps to `dflt`; -N maps to N. */
static long
kret(long r, int dflt)
{
	if (r < 0 && r > -4096) {
		/* Linux errno = newlib's for 1..34; the kernel uses two above */
		errno = (r == -1) ? dflt : r == -36 ? ENAMETOOLONG :
		    r == -39 ? ENOTEMPTY : (int)-r;
		return (-1);
	}
	return (r);
}

/*
 * SIGNAL NUMBERS. The kernel numbers signals the Linux way (uts/uproc.c: SIGINT 2,
 * SIGKILL 9, SIGCHLD 17 -- and its default action ignores only 17). newlib's
 * <sys/signal.h> numbers them the BSD way (SIGCHLD 20, SIGSTOP 17, SIGUSR1 25).
 * Passing newlib numbers straight through would make "SIGCHLD" a different signal
 * from the one the kernel posts on child exit. Translate at every boundary.
 */
#ifdef SOLNIX_NO_SIGXLATE
/* Negative-control build ONLY: pass newlib numbers straight to the kernel. */
static int sig_to_k(int s) { return (s); }
static int sig_from_k(int k) { return (k); }
#else
/* newlib values MEASURED with `solnix-cc -dM -E` on <signal.h> (its riscv64 branch),
 * kernel values = the Linux riscv numbering uts/syscall.c follows. 0 = no kernel
 * equivalent (EMT 7, LOST 29): refused with EINVAL. */
static const unsigned char nl2k[NSIG] = {
	[1] = 1, [2] = 2, [3] = 3, [4] = 4, [5] = 5, [6] = 6,	/* HUP..ABRT */
	[8] = 8, [9] = 9, [10] = 7 /* BUS */, [11] = 11, [12] = 31 /* SYS */,
	[13] = 13, [14] = 14, [15] = 15, [16] = 23 /* URG */, [17] = 19 /* STOP */,
	[18] = 20 /* TSTP */, [19] = 18 /* CONT */, [20] = 17 /* CHLD */,
	[21] = 21 /* TTIN */, [22] = 22 /* TTOU */, [23] = 29 /* IO */,
	[24] = 24, [25] = 25, [26] = 26, [27] = 27, [28] = 28,	/* XCPU..WINCH */
	[30] = 10 /* USR1 */, [31] = 12 /* USR2 */,
};
static int
sig_to_k(int s)
{
	return ((s > 0 && s < NSIG && nl2k[s] != 0) ? nl2k[s] : -1);
}
static int
sig_from_k(int k)
{
	int s;

	for (s = 1; s < NSIG; s++)
		if (nl2k[s] == k)
			return (s);
	return (k);
}
#endif

/*
 * USERLAND FD TABLE. Every fd a program sees is a user fd u, mapped to either the
 * console or a kernel fd. Why, measured against uts/uproc.c + uts/syscall.c:
 *   - sys_read/sys_write send kernel fds 0/1/2 to the console UNCONDITIONALLY, so
 *     a kernel dup2(pipe, 1) does not redirect stdout;
 *   - proc_close(0..2) returns 0 without releasing, proc_exit closes nothing, and
 *     exec zeroes the table without pipe_close: a pipe end that ever sat in a
 *     process is never released, so the reader never sees EOF (dash's $(...)
 *     hung forever on exactly this).
 * So kernel slots 0..2 are never given objects, and the glue closes its kernel
 * fds itself at _exit and before a successful execve. The table is process
 * memory: fork copies it (the kernel ref-counts the copied fds), exec discards
 * it (the kernel restarts the image with only the console).
 * LIMIT that no userland can fix: redirection does not survive exec.
 */
#define	VF_CON		(-2)		/* the console */
#define	VF_FREE		(-1)
static struct { int k; unsigned char app; } vt[K_NOFILE];
static int vt_ready;

static void
vt_init(void)
{
	int u;

	if (vt_ready)
		return;
	for (u = 0; u < K_NOFILE; u++)
		vt[u].k = u <= 2 ? VF_CON : VF_FREE;
	vt_ready = 1;
}
/* kernel fd behind u: 0 for console input, 1 for console output, else k. */
static int
vk(int u, int out)
{
#ifdef SOLNIX_NO_VFD
	/* No userland table: hand the kernel its own fd numbers, ANY fd (one
	 * inherited across exec included); the kernel says EBADF. */
	vt_init();
	if (u >= 0 && u < K_NOFILE) {
		if (vt[u].k < 0)
			vt[u].k = u;
		return (u);
	}
#endif
	vt_init();
	if (u < 0 || u >= K_NOFILE || vt[u].k == VF_FREE) {
		errno = EBADF;
		return (-1);
	}
	return (vt[u].k == VF_CON ? out : vt[u].k);
}
static int
vt_alloc(int min)
{
	int u;

	vt_init();
	for (u = min < 0 ? 0 : min; u < K_NOFILE; u++)
		if (vt[u].k == VF_FREE)
			return (u);
	errno = EMFILE;
	return (-1);
}
/* a kernel slot >= 3 that no user fd maps to */
static int
k_free(void)
{
	int k, u, used;

	for (k = 3; k < K_NOFILE; k++) {
		for (used = 0, u = 0; u < K_NOFILE; u++)
			if (vt[u].k == k)
				used = 1;
		if (!used)
			return (k);
	}
	errno = EMFILE;
	return (-1);
}
static int
vt_bind(int k, int app)
{
#ifdef SOLNIX_NO_VFD
	/* No userland table: the program's fd IS the kernel fd. */
	vt_init();
	vt[k].k = k;
	vt[k].app = (unsigned char)app;
	return (k);
#endif
	int u = vt_alloc(0);

	if (u < 0) {
		(void) ksys(K_close, k, 0, 0, 0);
		return (-1);
	}
	vt[u].k = k;
	vt[u].app = (unsigned char)app;
	return (u);
}
/* close every kernel fd this process holds (pipe ends drop their refs) */
static void
vt_close_all(void)
{
	int u;

#ifdef SOLNIX_NO_VFD
	return;		/* the kernel releases every fd at exit, CLOEXEC ones at exec */
#endif
	vt_init();
	for (u = 0; u < K_NOFILE; u++) {
		if (vt[u].k >= 0)
			(void) ksys(K_close, vt[u].k, 0, 0, 0);
		vt[u].k = u <= 2 ? VF_CON : VF_FREE;
	}
}

/* ---- I/O ---------------------------------------------------------------- */

/* [REAL] write; O_APPEND emulated by seeking to end before each write. */
_ssize_t
_write(int fd, const void *buf, size_t n)
{
	int k = vk(fd, 1);

	if (k < 0)
		return (-1);
	if (vt[fd].app)
		(void) ksys(K_lseek, k, 0, SEEK_END, 0);
	return (kret(ksys(K_write, k, (long)buf, (long)n, 0), EBADF));
}

/* [REAL] read. The console is the kernel's line-mode echoing reader. */
_ssize_t
_read(int fd, void *buf, size_t n)
{
	int k = vk(fd, 0);

	if (k < 0)
		return (-1);
	return (kret(ksys(K_read, k, (long)buf, (long)n, 0), EBADF));
}

/*
 * [REAL] open via openat. newlib's O_* values are translated to the kernel's;
 * the kernel honours O_EXCL, O_TRUNC and O_DIRECTORY, and opens directories
 * (an fd for getdents64) since rvsh.
 */
int
_open(const char *path, int flags, ...)
{
	long kf = 0, r;

	if ((flags & O_ACCMODE) == O_WRONLY)
		kf |= K_O_WRONLY;
	else if ((flags & O_ACCMODE) == O_RDWR)
		kf |= K_O_RDWR;
	if (flags & O_CREAT)
		kf |= K_O_CREAT;
	if (flags & O_EXCL)
		kf |= K_O_EXCL;
	if (flags & O_TRUNC)
		kf |= K_O_TRUNC;
	if (flags & O_DIRECTORY)
		kf |= K_O_DIRECTORY;
	if (flags & O_CLOEXEC)
		kf |= K_O_CLOEXEC;
	if (flags & O_APPEND)
		kf |= K_O_APPEND;	/* the kernel keeps it across dup2/exec */
	r = kret(ksys(K_openat, -100, (long)path, kf, 0), ENOENT);
	if (r < 0)
		return (-1);
	return (vt_bind((int)r, (flags & O_APPEND) != 0));
}
int open(const char *p, int f, ...) __attribute__((alias("_open")));

/* [REAL] */
int
_close(int fd)
{
	int k = vk(fd, 1);

	if (k < 0)
		return (-1);
	if (vt[fd].k >= 0)
		(void) ksys(K_close, k, 0, 0, 0);
	vt[fd].k = VF_FREE;
	vt[fd].app = 0;
	return (0);
}

/* [REAL] (ESPIPE on pipes and the console) */
_off_t
_lseek(int fd, _off_t off, int whence)
{
	int k = vk(fd, 1);

	if (k < 0)
		return (-1);
	if (vt[fd].k == VF_CON) {
		errno = ESPIPE;
		return (-1);
	}
	return (kret(ksys(K_lseek, k, off, whence, 0), ESPIPE));
}

/* Linux riscv64 struct stat (asm-generic), what newfstatat/fstat fill. */
struct kstat {
	unsigned long dev, ino;
	unsigned int mode, nlink, uid, gid;
	unsigned long rdev, pad1;
	long size;
	int blksize, pad2;
	long blocks;
	long atime, atime_ns, mtime, mtime_ns, ctime, ctime_ns;
	unsigned int unused4, unused5;
};
static void
kstat2(const struct kstat *k, struct stat *st)
{
	memset(st, 0, sizeof (*st));
	st->st_dev = k->dev;
	st->st_ino = k->ino;
	st->st_mode = k->mode;
	st->st_nlink = k->nlink;
	st->st_size = k->size;
	st->st_blksize = k->blksize;
	st->st_blocks = k->blocks;
}

/* [REAL] fstat: the kernel's fstat(80); the console is a char device. */
int
_fstat(int fd, struct stat *st)
{
	struct kstat k;
	int kf = vk(fd, 1);

	if (kf < 0)
		return (-1);
	if (vt[fd].k == VF_CON) {
		memset(st, 0, sizeof (*st));
		st->st_mode = S_IFCHR | 0620;
		return (0);
	}
	if (kret(ksys(K_fstat, kf, (long)&k, 0, 0), EBADF) < 0)
		return (-1);
	kstat2(&k, st);
	return (0);
}
int fstat(int fd, struct stat *st) __attribute__((alias("_fstat")));

/* [REAL] stat: newfstatat(AT_FDCWD); the kernel resolves the cwd. No symlinks,
 * so lstat is stat. */
int
_stat(const char *path, struct stat *st)
{
	struct kstat k;

	if (kret(ksys(K_fstatat, K_AT_FDCWD, (long)path, (long)&k, 0), ENOENT) < 0)
		return (-1);
	kstat2(&k, st);
	return (0);
}
int stat(const char *p, struct stat *s) __attribute__((alias("_stat")));
int lstat(const char *p, struct stat *s) __attribute__((alias("_stat")));

/* [REAL] only the console is a tty. */
int
_isatty(int fd)
{
#ifdef SOLNIX_NO_VFD
	char tb[64];

	/* Ask the kernel: TCGETS succeeds only on a console slot. */
	if (fd >= 0 && ksys(K_ioctl, fd, 0x5401 /* TCGETS */, (long)tb, 0) == 0)
		return (1);
	errno = ENOTTY;
	return (0);
#endif
	if (vk(fd, 1) >= 0 && vt[fd].k == VF_CON)
		return (1);
	errno = ENOTTY;
	return (0);
}
int isatty(int fd) __attribute__((alias("_isatty")));

/* [DERIVED] access: existence via open. No permission bits to check. */
int
access(const char *path, int mode)
{
	struct stat st;
	(void) mode;
	return (_stat(path, &st));
}

/* [REAL] */
int
pipe(int fds[2])
{
	int kf[2], a, b;

	vt_init();
	if (kret(ksys(K_pipe2, (long)kf, 0, 0, 0), EMFILE) < 0)
		return (-1);
#ifdef SOLNIX_NO_VFD
	fds[0] = kf[0]; fds[1] = kf[1];
	vt[kf[0]].k = kf[0]; vt[kf[1]].k = kf[1];
	return (0);
#endif
	if ((a = vt_bind(kf[0], 0)) < 0) {
		(void) ksys(K_close, kf[1], 0, 0, 0);
		return (-1);
	}
	if ((b = vt_bind(kf[1], 0)) < 0) {
		(void) _close(a);
		return (-1);
	}
	fds[0] = a;
	fds[1] = b;
	return (0);
}

/* [REAL] dup2: a console fd copies as the console; a kernel fd gets a NEW kernel
 * slot via the kernel's dup3 (independently ref-counted). */
int
dup2(int o, int n)
{
	int ko = vk(o, 1), kn;

	if (ko < 0)
		return (-1);
	if (n < 0 || n >= K_NOFILE) {
		errno = EBADF;
		return (-1);
	}
	if (o == n)
		return (n);
	if (vt[n].k != VF_FREE)
		(void) _close(n);
#ifdef SOLNIX_NO_VFD
	if (kret(ksys(K_dup3, ko, n, 0, 0), EBADF) < 0)
		return (-1);
	vt[n].k = n;
	return (n);
#endif
	if (vt[o].k == VF_CON) {
		vt[n].k = VF_CON;
	} else {
		if ((kn = k_free()) < 0)
			return (-1);
		if (kret(ksys(K_dup3, ko, kn, 0, 0), EBADF) < 0)
			return (-1);
		vt[n].k = kn;
	}
	vt[n].app = vt[o].app;
	return (n);
}

/* [REAL] dup = dup2 onto the lowest free user fd. */
int _fcntl(int fd, int cmd, ...);
int
dup(int o)
{
#ifdef SOLNIX_NO_VFD
	return (_fcntl(o, F_DUPFD, 0));	/* the kernel knows which fds are free */
#endif
	int n = vt_alloc(0);
	return (n < 0 ? -1 : dup2(o, n));
}

/*
 * fcntl. F_DUPFD [REAL]. FD_CLOEXEC: [REAL by construction] -- exec drops EVERY
 * fd here, so every fd is close-on-exec; F_GETFD reports that. F_GETFL/F_SETFL:
 * only O_APPEND is tracked; O_NONBLOCK does not exist in the kernel.
 */
int
_fcntl(int fd, int cmd, ...)
{
	va_list ap;
	long arg;
	int n;

	va_start(ap, cmd);
	arg = va_arg(ap, long);
	va_end(ap);
	if (vk(fd, 1) < 0)
		return (-1);
#ifdef SOLNIX_NO_VFD
	/* The kernel owns the table: descriptor flags and F_DUPFD go to it
	 * (Linux numbering: F_DUPFD_CLOEXEC 1030; FD_CLOEXEC is 1 in both). */
	switch (cmd) {
	case F_DUPFD:
	case F_DUPFD_CLOEXEC:
		n = (int)kret(ksys(K_fcntl, vk(fd, 1), cmd == F_DUPFD ? 0 : 1030,
		    arg, 0), EBADF);
		if (n >= 0)
			vt[n].k = n;
		return (n);
	case F_GETFD:
	case F_SETFD:
		return ((int)kret(ksys(K_fcntl, vk(fd, 1), cmd, arg, 0), EBADF));
	}
#endif
	switch (cmd) {
	case F_DUPFD:
	case F_DUPFD_CLOEXEC:
		n = vt_alloc((int)arg);
		return (n < 0 ? -1 : dup2(fd, n));
	case F_GETFD:
		return (FD_CLOEXEC);
	case F_SETFD:
		return (0);
	case F_GETFL:
		return (O_RDWR | (vt[fd].app ? O_APPEND : 0));
	case F_SETFL:
		if (arg & O_NONBLOCK) {
			errno = ENOSYS;
			return (-1);
		}
		vt[fd].app = (arg & O_APPEND) != 0;
		return (0);
	}
	errno = EINVAL;
	return (-1);
}
int fcntl(int fd, int cmd, ...) __attribute__((alias("_fcntl")));

/* ---- processes ---------------------------------------------------------- */

/* [REAL] */
void
_exit(int status)
{
	vt_close_all();		/* the kernel's exit releases no fds */
	(void) ksys(K_exit, status & 0xff, 0, 0, 0);
	for (;;)
		;
}

/* [REAL] */
int _getpid(void) { return ((int)ksys(K_getpid, 0, 0, 0, 0)); }
pid_t getpid(void) { return (_getpid()); }

/* [STUB] no getppid in the kernel; 1 (init) is the only parent we can name. */
pid_t getppid(void) { return (1); }

/* [REAL] */
int _fork(void) { return ((int)kret(ksys(K_fork, 0, 0, 0, 0), EAGAIN)); }
pid_t fork(void) { return (_fork()); }
pid_t vfork(void) { return (_fork()); }

/* [REAL] */
/*
 * [REAL] execve. The kernel's exec drops the fd table without releasing pipe
 * ends, so release them first -- but only once the target is known to exist
 * (probe open), so a failed PATH-search attempt keeps the caller's fds.
 */
int
_execve(const char *path, char *const argv[], char *const envp[])
{
	long pr = ksys(K_openat, -100, (long)path, 0, 0);

	if (pr < 0) {
		errno = ENOENT;
		return (-1);
	}
	(void) ksys(K_close, pr, 0, 0, 0);
	vt_close_all();
	return ((int)kret(ksys(K_execve, (long)path, (long)argv, (long)envp,
	    0), ENOEXEC));
}
int execve(const char *p, char *const a[], char *const e[])
    __attribute__((alias("_execve")));

int
execv(const char *path, char *const argv[])
{
	return (_execve(path, argv, environ));
}

/* [REAL] PATH search over execve. */
int
execvp(const char *file, char *const argv[])
{
	const char *path, *p, *e;
	char buf[256];

	if (strchr(file, '/') != NULL)
		return (execv(file, argv));
	path = getenv("PATH");
	if (path == NULL)
		path = "/bin:/usr/bin";
	for (p = path; ; p = e + 1) {
		size_t dl;

		e = strchr(p, ':');
		if (e == NULL)
			e = p + strlen(p);
		dl = (size_t)(e - p);
		if (dl + strlen(file) + 2 < sizeof (buf)) {
			memcpy(buf, p, dl);
			buf[dl] = '/';
			strcpy(buf + dl + 1, file);
			(void) execv(buf, argv);
		}
		if (*e == '\0')
			break;
	}
	errno = ENOENT;
	return (-1);
}

int
execl(const char *path, const char *a0, ...)
{
	char *av[32];
	va_list ap;
	int i = 0;

	av[i++] = (char *)a0;
	va_start(ap, a0);
	while (i < 31 && (av[i] = va_arg(ap, char *)) != NULL)
		i++;
	va_end(ap);
	av[i] = NULL;
	return (execv(path, av));
}

/*
 * [REAL, with two kernel limits] waitpid. The kernel stores the RAW exit code
 * (and 128+sig for a signal death) and ignores options, so WNOHANG BLOCKS when
 * a matching child is still running. The status is re-encoded the POSIX way
 * (code << 8) so WIFEXITED/WEXITSTATUS work; a signal death reads as exit
 * 128+sig, which is what a shell prints anyway.
 */
pid_t
waitpid(pid_t pid, int *status, int options)
{
	int raw = 0;
	long r;

	(void) options;
	r = ksys(K_wait4, pid, (long)&raw, 0, 0);
	if (r < 0) {
		errno = ECHILD;
		return (-1);
	}
	if (status != NULL)
		*status = (raw & 0xff) << 8;
	return ((pid_t)r);
	/* NOTE: a signal death arrives as exit code 128+<kernel signo>, indistinguishable
	 * from exit(128+n); WIFSIGNALED is therefore never true. */
}
int _wait(int *status) { return (waitpid(-1, status, 0)); }
pid_t wait(int *status) { return (waitpid(-1, status, 0)); }
pid_t wait3(int *status, int options, struct rusage *ru)
{
	(void) ru;
	return (waitpid(-1, status, options));
}

/* [REAL] */
int
_kill(int pid, int sig)
{
	int k = sig == 0 ? 0 : sig_to_k(sig);

	if (k < 0) {
		errno = EINVAL;
		return (-1);
	}
	return ((int)kret(ksys(K_kill, pid, k, 0, 0), ESRCH));
}
int kill(pid_t pid, int sig) { return (_kill(pid, sig)); }
int raise(int sig) { return (_kill(_getpid(), sig)); }

/* ---- signals ------------------------------------------------------------ */

/*
 * The kernel's rt_sigaction SETS a handler and returns the previous one; it has
 * no query and no mask. A query (act == NULL) is answered from a shadow table
 * of what this image installed ([DERIVED]; starts at SIG_DFL, which is right
 * after exec except for inherited SIG_IGN). sa_mask/sa_flags are ignored.
 */
static _sig_func_ptr shadow[NSIG];

/*
 * Every caught signal enters here: the kernel calls the registered handler with
 * a0 = KERNEL signo and ra = the sigreturn trampoline, so this ordinary C
 * function translates the number, runs the program's handler, and returns
 * through ra into rt_sigreturn.
 */
static void
sigdispatch(int ksig)
{
	int s = sig_from_k(ksig);

	if (s > 0 && s < NSIG && shadow[s] != SIG_DFL && shadow[s] != SIG_IGN)
		shadow[s](s);
}

int
sigaction(int sig, const struct sigaction *act, struct sigaction *oact)
{
	if (sig <= 0 || sig >= NSIG) {
		errno = EINVAL;
		return (-1);
	}
	if (oact != NULL) {
		memset(oact, 0, sizeof (*oact));
		oact->sa_handler = shadow[sig];
	}
	if (act != NULL) {
		int k = sig_to_k(sig);

		if (k < 0) {
			errno = EINVAL;
			return (-1);
		}
		_sig_func_ptr h = act->sa_handler;
		long kh = (h == SIG_DFL || h == SIG_IGN) ? (long)h : (long)sigdispatch;

		if (kret(ksys(K_rt_sigaction, k, kh,
		    (long)__solnix_sigreturn, 0), EINVAL) < 0)
			return (-1);
		shadow[sig] = act->sa_handler;
	}
	return (0);
}

_sig_func_ptr
signal(int sig, _sig_func_ptr h)
{
	struct sigaction a, o;

	memset(&a, 0, sizeof (a));
	a.sa_handler = h;
	if (sigaction(sig, &a, &o) < 0)
		return (SIG_ERR);
	return (o.sa_handler);
}

/* [STUB] no signal mask in the kernel: the mask is recorded, never applied. */
static sigset_t shadow_mask;
int
sigprocmask(int how, const sigset_t *set, sigset_t *old)
{
	if (old != NULL)
		*old = shadow_mask;
	if (set != NULL) {
		if (how == SIG_BLOCK)
			shadow_mask |= *set;
		else if (how == SIG_UNBLOCK)
			shadow_mask &= ~*set;
		else
			shadow_mask = *set;
	}
	return (0);
}
/* sigemptyset & co. are macros in newlib's <sys/signal.h>. */

/* [DERIVED] sigsuspend: sleep 10 ms and report EINTR (no wait-for-signal). */
int
sigsuspend(const sigset_t *m)
{
	struct timespec ts = { 0, 10000000 };
	(void) m;
	(void) ksys(K_nanosleep, (long)&ts, 0, 0, 0);
	errno = EINTR;
	return (-1);
}

/* ---- memory ------------------------------------------------------------- */

/* [REAL] sbrk over the kernel's absolute brk (0 = query, 0 = success). */
void *
_sbrk(ptrdiff_t incr)
{
	long old = ksys(K_brk, 0, 0, 0, 0), r;

	if (old <= 0) {
		errno = ENOMEM;
		return ((void *)-1);
	}
	if (incr == 0)
		return ((void *)old);
	r = ksys(K_brk, old + incr, 0, 0, 0);
	if (r < 0) {
		errno = ENOMEM;
		return ((void *)-1);
	}
	return ((void *)old);
}

/* ---- time --------------------------------------------------------------- */

/*
 * [REAL] (REALTIME is time-since-boot: the platform has no TOD source).
 * newlib numbers CLOCK_REALTIME 1; the kernel takes the Linux/illumos 0 for
 * REALTIME and 4 for MONOTONIC, so translate rather than pass through.
 */
int
clock_gettime(clockid_t id, struct timespec *ts)
{
	long kid;

	if (id == CLOCK_REALTIME)
		kid = 0;
	else if (id == CLOCK_MONOTONIC)
		kid = 4;
	else {
		errno = EINVAL;
		return (-1);
	}
	return ((int)kret(ksys(K_clock_gettime, kid, (long)ts, 0, 0), EINVAL));
}

int
_gettimeofday(struct timeval *tv, void *tz)
{
	struct timespec ts;
	(void) tz;
	if (clock_gettime(CLOCK_REALTIME, &ts) < 0)
		return (-1);
	if (tv != NULL) {
		tv->tv_sec = ts.tv_sec;
		tv->tv_usec = ts.tv_nsec / 1000;
	}
	return (0);
}

/* [DERIVED] times: elapsed ticks since boot; no per-process CPU accounting. */
clock_t
_times(struct tms *t)
{
	struct timespec ts;
	if (t != NULL)
		memset(t, 0, sizeof (*t));
	if (clock_gettime(CLOCK_MONOTONIC, &ts) < 0)
		return ((clock_t)-1);
	return ((clock_t)(ts.tv_sec * 100 + ts.tv_nsec / 10000000));
}

/* [REAL] */
int
nanosleep(const struct timespec *rq, struct timespec *rm)
{
	return ((int)kret(ksys(K_nanosleep, (long)rq, (long)rm, 0, 0), EINVAL));
}
unsigned
sleep(unsigned s)
{
	struct timespec ts = { s, 0 };
	return (nanosleep(&ts, NULL) == 0 ? 0 : s);
}
int
usleep(useconds_t us)
{
	struct timespec ts = { us / 1000000, (us % 1000000) * 1000 };
	return (nanosleep(&ts, NULL));
}

/* ---- identity ----------------------------------------------------------- */

uid_t getuid(void) { return ((uid_t)ksys(K_getuid, 0, 0, 0, 0)); }	/* [REAL] */
uid_t geteuid(void) { return (getuid()); }	/* [REAL]: one uid per proc */
gid_t getgid(void) { return (0); }		/* [STUB] no getgid syscall */
gid_t getegid(void) { return (0); }		/* [STUB] */
int setuid(uid_t u) { return ((int)kret(ksys(K_setuid, u, 0, 0, 0), EPERM)); }
int setgid(gid_t g) { return ((int)kret(ksys(K_setgid, g, 0, 0, 0), EPERM)); }
mode_t umask(mode_t m) { (void) m; return (022); }	/* [STUB] no modes */

/* [STUB] values the kernel prints in its own banner; no uname syscall. */
int
uname(struct utsname *u)
{
	memset(u, 0, sizeof (*u));
	strcpy(u->sysname, "SunOS");
	strcpy(u->nodename, "solnix");
	strcpy(u->release, "5.11");
	strcpy(u->version, "solnix");
	strcpy(u->machine, "riscv64");
	return (0);
}
int
gethostname(char *n, size_t l)
{
	strncpy(n, "solnix", l);
	return (0);
}

/* [REAL] the kernel's getcwd (17) and chdir (49). */
char *
getcwd(char *buf, size_t sz)
{
	if (buf == NULL) {
		buf = malloc(sz ? sz : 2);
		if (buf == NULL)
			return (NULL);
	}
	if (sz < 2) {
		errno = ERANGE;
		return (NULL);
	}
	if (kret(ksys(K_getcwd, (long)buf, (long)sz, 0, 0), ERANGE) < 0)
		return (NULL);
	return (buf);
}
int
chdir(const char *p)
{
	return ((int)kret(ksys(K_chdir, (long)p, 0, 0, 0), ENOENT));
}

/* ---- [ENOSYS]: no kernel facility at all ---------------------------------- */
#define	NOSYS(proto) proto { errno = ENOSYS; return (-1); }
NOSYS(int _link(const char *a, const char *b))
NOSYS(int link(const char *a, const char *b))
NOSYS(int chmod(const char *a, mode_t m))
NOSYS(int fchmod(int f, mode_t m))
NOSYS(int chown(const char *a, uid_t u, gid_t g))
NOSYS(int symlink(const char *a, const char *b))
NOSYS(ssize_t readlink(const char *a, char *b, size_t n))
NOSYS(int ftruncate(int f, off_t l))
NOSYS(int fsync(int f))
NOSYS(int setpgid(pid_t a, pid_t b))
NOSYS(int _getentropy(void *b, size_t n))
pid_t getpgrp(void) { return (_getpid()); }	/* [STUB] no process groups */
pid_t setsid(void) { errno = ENOSYS; return (-1); }

/* No termios: the console is the kernel's fixed line-mode echoing reader. */
int tcgetattr(int f, void *t) { (void) f; (void) t; errno = ENOTTY; return (-1); }
int tcsetattr(int f, int a, const void *t) { (void) f; (void) a; (void) t; errno = ENOTTY; return (-1); }
pid_t tcgetpgrp(int f) { (void) f; errno = ENOTTY; return (-1); }
int tcsetpgrp(int f, pid_t p) { (void) f; (void) p; errno = ENOTTY; return (-1); }
int ioctl(int f, unsigned long r, ...) { (void) f; (void) r; errno = ENOTTY; return (-1); }
char *ttyname(int f) { return (f >= 0 && f <= 2 ? "/dev/console" : NULL); }

long
sysconf(int name)
{
	switch (name) {
	case _SC_PAGESIZE:	return (4096);
	case _SC_CLK_TCK:	return (100);
	case _SC_OPEN_MAX:	return (K_NOFILE);
	case _SC_ARG_MAX:	return (1024);	/* uproc.c ARG_STRBUF */
	}
	errno = EINVAL;
	return (-1);
}

/* ---- small POSIX pieces newlib 4.5.0 leaves out --------------------------- */

/* newlib only exports __getdelim/__getline. [REAL] */
ssize_t __getdelim(char **, size_t *, int, void *);
ssize_t __getline(char **, size_t *, void *);
ssize_t getdelim(char **l, size_t *n, int d, void *f) { return (__getdelim(l, n, d, f)); }
ssize_t getline(char **l, size_t *n, void *f) { return (__getline(l, n, f)); }

/* [REAL] poll(2): the kernel's flat poll(ufds, nfds, timeout_ms). */
int
poll(void *fds, unsigned long n, int timeout)
{
	struct { int fd; short ev, rev; } *pf = fds, kp[K_NOFILE];
	unsigned long i;
	long r;

	if (n > K_NOFILE) {
		errno = EINVAL;
		return (-1);
	}
	for (i = 0; i < n; i++) {
		kp[i] = pf[i];
		kp[i].fd = vk(pf[i].fd, (pf[i].ev & 1) ? 0 : 1);
	}
	r = kret(ksys(K_poll, (long)kp, (long)n, timeout, 0), EINVAL);
	for (i = 0; i < n; i++)
		pf[i].rev = kp[i].fd < 0 ? 0x20 /* POLLNVAL */ : kp[i].rev;
	return ((int)r);
}

/*
 * [REAL] directories: the kernel's getdents64 (61) over an fd from openat
 * (O_DIRECTORY). The DIR is malloc'd with its own record buffer.
 */
#include <dirent.h>
struct sdir { DIR d; int fd; long n, off; struct dirent ent; char buf[2048]; };
DIR *
fdopendir(int fd)
{
	struct sdir *sd;
	struct stat st;

	if (_fstat(fd, &st) < 0)
		return (NULL);
	if (!S_ISDIR(st.st_mode)) {
		errno = ENOTDIR;
		return (NULL);
	}
	if ((sd = malloc(sizeof (*sd))) == NULL)
		return (NULL);
	sd->d.dd_fd = fd;
	sd->fd = fd;
	sd->n = sd->off = 0;
	return (&sd->d);
}
DIR *
opendir(const char *p)
{
	int fd = _open(p, O_RDONLY | O_DIRECTORY);
	DIR *d;

	if (fd < 0)
		return (NULL);
	if ((d = fdopendir(fd)) == NULL)
		(void) _close(fd);
	return (d);
}
struct dirent *
readdir(DIR *d)
{
	struct sdir *sd = (struct sdir *)d;
	unsigned short reclen;
	int kf;

	if (sd->off >= sd->n) {
		if ((kf = vk(sd->fd, 0)) < 0)
			return (NULL);
		sd->n = kret(ksys(K_getdents64, kf, (long)sd->buf,
		    sizeof (sd->buf), 0), EBADF);
		sd->off = 0;
		if (sd->n <= 0)
			return (NULL);
	}
	/* linux_dirent64: u64 ino, s64 off, u16 reclen, u8 type, name[] */
	memcpy(&sd->ent.d_ino, sd->buf + sd->off, sizeof (sd->ent.d_ino));
	memcpy(&reclen, sd->buf + sd->off + 16, sizeof (reclen));
	strncpy(sd->ent.d_name, sd->buf + sd->off + 19, sizeof (sd->ent.d_name) - 1);
	sd->ent.d_name[sizeof (sd->ent.d_name) - 1] = 0;
	sd->off += reclen;
	return (&sd->ent);
}
int
closedir(DIR *d)
{
	struct sdir *sd = (struct sdir *)d;
	int r = _close(sd->fd);

	free(sd);
	return (r);
}
int dirfd(DIR *d) { return (((struct sdir *)d)->fd); }
void rewinddir(DIR *d) { (void) _lseek(((struct sdir *)d)->fd, 0, SEEK_SET); ((struct sdir *)d)->n = 0; }

/* [REAL] the namespace calls, all relative to the kernel's cwd. */
int _mkdir(const char *a, mode_t m) { return ((int)kret(ksys(K_mkdirat, K_AT_FDCWD, (long)a, m, 0), ENOENT)); }
int mkdir(const char *a, mode_t m) { return (_mkdir(a, m)); }
int _unlink(const char *a) { return ((int)kret(ksys(K_unlinkat, K_AT_FDCWD, (long)a, 0, 0), ENOENT)); }
int unlink(const char *a) { return (_unlink(a)); }
int rmdir(const char *a) { return ((int)kret(ksys(K_unlinkat, K_AT_FDCWD, (long)a, 0x200 /* AT_REMOVEDIR */, 0), ENOENT)); }
int _rename(const char *a, const char *b) { return ((int)kret(ksys(K_renameat, K_AT_FDCWD, (long)a, K_AT_FDCWD, (long)b), ENOENT)); }
/* newlib's libc.a is built without HAVE_RENAME (rename = link + unlink, and
 * there is no link): provide rename itself so stdio's rename is the kernel's. */
int rename(const char *a, const char *b) { return (_rename(a, b)); }

int tcflush(int f, int q) { (void) f; (void) q; errno = ENOTTY; return (-1); }
int tcdrain(int f) { (void) f; errno = ENOTTY; return (-1); }
unsigned cfgetospeed(const void *t) { (void) t; return (0010002); }
unsigned cfgetispeed(const void *t) { (void) t; return (0010002); }
int cfsetospeed(void *t, unsigned s) { (void) t; (void) s; return (0); }
int cfsetispeed(void *t, unsigned s) { (void) t; (void) s; return (0); }

NOSYS(int mknod(const char *a, mode_t m, dev_t d))
NOSYS(int mkfifo(const char *a, mode_t m))

/* ---- *at() family: the kernel resolves a dirfd (or AT_FDCWD = the cwd). ---- */
#define	AT_FDCWD_	(-2)		/* newlib's AT_FDCWD */
static int
kdirfd(int d)
{
	return (d == AT_FDCWD_ ? K_AT_FDCWD : vk(d, 0));
}
int
fstatat(int d, const char *p, struct stat *s, int f)
{
	struct kstat k;

	(void) f;		/* no symlinks: AT_SYMLINK_NOFOLLOW is moot */
	if (kret(ksys(K_fstatat, kdirfd(d), (long)p, (long)&k, 0), ENOENT) < 0)
		return (-1);
	kstat2(&k, s);
	return (0);
}
int
faccessat(int d, const char *p, int m, int f)
{
	struct stat st;

	(void) m;		/* no permission bits to check */
	return (fstatat(d, p, &st, f));
}
int
openat(int d, const char *p, int fl, ...)
{
	va_list ap; int m;
	va_start(ap, fl); m = va_arg(ap, int); va_end(ap);
	if (d == AT_FDCWD_ || (p != NULL && p[0] == '/'))
		return (_open(p, fl, m));
	{
		long kf = 0, r;

		if ((fl & O_ACCMODE) == O_WRONLY)
			kf |= K_O_WRONLY;
		else if ((fl & O_ACCMODE) == O_RDWR)
			kf |= K_O_RDWR;
		if (fl & O_CREAT)
			kf |= K_O_CREAT;
		if (fl & O_EXCL)
			kf |= K_O_EXCL;
		if (fl & O_TRUNC)
			kf |= K_O_TRUNC;
		if (fl & O_DIRECTORY)
			kf |= K_O_DIRECTORY;
		if (fl & O_CLOEXEC)
			kf |= K_O_CLOEXEC;
		if (fl & O_APPEND)
			kf |= K_O_APPEND;
		r = kret(ksys(K_openat, kdirfd(d), (long)p, kf, 0), ENOENT);
		return (r < 0 ? -1 : vt_bind((int)r, (fl & O_APPEND) != 0));
	}
}
int
unlinkat(int d, const char *p, int f)
{
	return ((int)kret(ksys(K_unlinkat, kdirfd(d), (long)p,
	    (f & AT_REMOVEDIR) ? 0x200 : 0, 0), ENOENT));
}
int
renameat(int a, const char *p, int b, const char *q)
{
	return ((int)kret(ksys(K_renameat, kdirfd(a), (long)p, kdirfd(b),
	    (long)q), ENOENT));
}
int creat(const char *p, mode_t m) { return (_open(p, O_WRONLY | O_CREAT | O_TRUNC, m)); }
NOSYS(int linkat(int a, const char *b, int c, const char *e, int f))
NOSYS(int symlinkat(const char *a, int b, const char *c))
NOSYS(int fchmodat(int d, const char *p, mode_t m, int f))
NOSYS(int fchownat(int d, const char *p, uid_t u, gid_t g, int f))
NOSYS(int fchown(int f, uid_t u, gid_t g))
NOSYS(int lchown(const char *p, uid_t u, gid_t g))
NOSYS(int utimensat(int d, const char *p, const struct timespec *t, int f))
NOSYS(int futimens(int f, const struct timespec *t))
NOSYS(int chroot(const char *p))
NOSYS(int flock(int f, int o))
NOSYS(int clock_settime(clockid_t c, const struct timespec *t))
NOSYS(int setpriority(int w, int who, int p))
int getpriority(int w, int who) { (void) w; (void) who; return (0); }	/* [STUB] no priorities */
void sync(void) { }			/* [STUB] the kernel exposes no sync to newlib-built code here */
long pathconf(const char *p, int n) { (void) p; (void) n; return (255); }	/* [STUB] */
char *getlogin(void) { return (getuid() == 0 ? "root" : NULL); }	/* [DERIVED] */

/*
 * popen/pclose: [ENOSYS]. A child's dup2(pipe, 1) does not survive exec in this
 * kernel (exec clears the fd table), so a popen'd command would write to the
 * console, not the pipe: refuse rather than return a stream that never fills.
 */
void *popen(const char *c, const char *m) { (void) c; (void) m; errno = ENOSYS; return (NULL); }
int pclose(void *f) { (void) f; errno = ECHILD; return (-1); }

/* [REAL] realpath: no symlinks and cwd is "/", so it is pure path normalisation. */
char *
realpath(const char *in, char *out)
{
	char buf[1024], *o = out ? out : malloc(1024);
	const char *p = in;
	size_t n = 0;

	if (o == NULL)
		return (NULL);
	if (in[0] != '/')
		buf[n++] = '/';
	while (*p && n < sizeof (buf) - 1)
		buf[n++] = *p++;
	buf[n] = '\0';
	n = 0;
	o[n++] = '/';
	for (p = buf; *p; ) {
		const char *s;
		size_t l;

		while (*p == '/')
			p++;
		for (s = p; *p && *p != '/'; p++)
			;
		l = (size_t)(p - s);
		if (l == 0 || (l == 1 && s[0] == '.'))
			continue;
		if (l == 2 && s[0] == '.' && s[1] == '.') {
			while (n > 1 && o[n - 1] != '/')
				n--;
			if (n > 1)
				n--;
			continue;
		}
		if (n > 1)
			o[n++] = '/';
		memcpy(o + n, s, l);
		n += l;
	}
	o[n] = '\0';
	return (o);
}

/* [REAL] POSIX basename/dirname (they may modify their argument). */
char *
basename(char *p)
{
	char *e;

	if (p == NULL || *p == '\0')
		return (".");
	e = p + strlen(p) - 1;
	while (e > p && *e == '/')
		*e-- = '\0';
	if (e == p && *p == '/')
		return (p);
	while (e > p && e[-1] != '/')
		e--;
	return (e);
}
char *
dirname(char *p)
{
	char *e;

	if (p == NULL || *p == '\0')
		return (".");
	e = p + strlen(p) - 1;
	while (e > p && *e == '/')
		e--;
	while (e > p && *e != '/')
		e--;
	if (e == p)
		return (*p == '/' ? "/" : ".");
	while (e > p && *e == '/')
		e--;
	e[1] = '\0';
	return (p);
}

/* ---- /etc/passwd + /etc/group lookups: [REAL] "files" backend, one file each. */
#include <pwd.h>
#include <grp.h>
static struct passwd pw;
static struct group gr;
static char pwline[256], grline[256];
static char *grmem[1];
static int
pw_scan(const char *name, long uid)
{
	int fd = _open("/etc/passwd", O_RDONLY);
	char c;
	size_t n = 0;
	long r;

	if (fd < 0)
		return (0);
	for (;;) {
		r = _read(fd, &c, 1);
		if (r == 1 && c != '\n' && n < sizeof (pwline) - 1) {
			pwline[n++] = c;
			continue;
		}
		pwline[n] = '\0';
		if (n > 0 && pwline[0] != '#') {
			char *f[7], *s = pwline;
			int k;

			for (k = 0; k < 7; k++)
				f[k] = strsep(&s, ":");
			if (f[6] != NULL && ((name && strcmp(f[0], name) == 0) ||
			    (!name && atol(f[2]) == uid))) {
				pw.pw_name = f[0]; pw.pw_passwd = f[1];
				pw.pw_uid = atoi(f[2]); pw.pw_gid = atoi(f[3]);
				pw.pw_gecos = f[4]; pw.pw_dir = f[5]; pw.pw_shell = f[6];
				_close(fd);
				return (1);
			}
		}
		n = 0;
		if (r != 1)
			break;
	}
	_close(fd);
	return (0);
}
struct passwd *getpwnam(const char *n) { return (pw_scan(n, 0) ? &pw : NULL); }
struct passwd *getpwuid(uid_t u) { return (pw_scan(NULL, u) ? &pw : NULL); }
/* [STUB] groups: gid 0 is "root", nothing else exists (no /etc/group parser). */
struct group *
getgrgid(gid_t g)
{
	if (g != 0)
		return (NULL);
	strcpy(grline, "root");
	gr.gr_name = grline; gr.gr_passwd = ""; gr.gr_gid = 0; gr.gr_mem = grmem;
	return (&gr);
}
struct group *getgrnam(const char *n) { return (strcmp(n, "root") == 0 ? getgrgid(0) : NULL); }

/* [REAL] execlp = execl with PATH search. */
int
execlp(const char *file, const char *a0, ...)
{
	char *av[32];
	va_list ap;
	int i = 0;

	av[i++] = (char *)a0;
	va_start(ap, a0);
	while (i < 31 && (av[i] = va_arg(ap, char *)) != NULL)
		i++;
	va_end(ap);
	av[i] = NULL;
	return (execvp(file, av));
}
NOSYS(int sethostname(const char *n, size_t l))

/* [DERIVED] killpg: no process groups, so a "group" is its leader pid only. */
int killpg(pid_t pg, int sig) { return (_kill(pg, sig)); }
