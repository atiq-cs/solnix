/*
 * newlib_glue.c -- the OS port layer that lets a REAL third-party libc
 * (newlib 4.5.0, the libc shipped with the pinned riscv64-none-elf gcc 14.3.0)
 * run on the solnix riscv64 kernel.
 *
 * WHAT THIS IS AND IS NOT. This file is NOT a libc. It is the ~10-function
 * syscall port that newlib's libgloss layer expects an OS to supply. Every
 * string, stdio, and malloc routine used by a program linked against this comes
 * out of newlib's own libc.a -- real upstream code, not user/libc.c. That is the
 * whole point of the exercise: user/libc.c's printf understands only %d/%u/%x/%s,
 * so a program that prints a %ld correctly is proving a real libc ran.
 *
 * newlib calls these through its reentrant wrappers (_write_r -> _write etc.),
 * so the names are the libgloss "syscalls.c" set. Each is tagged:
 *
 *   [REAL]   backed by a genuine kernel syscall doing genuine work
 *   [STUB]   returns a plausible constant because the kernel has no such
 *            facility; documented per function with what breaks
 *   [ENOSYS] fails loudly/explicitly rather than lying
 *
 * ABI NOTE: newlib's libc.a is built rv64imafdc/lp64d (HARD FLOAT) and there is
 * only ONE multilib (`gcc -print-multi-lib` => ".;"), so anything linked against
 * it is hard-float. That makes the kernel's FP context-switch support a hard
 * prerequisite for a real-libc userland, not an optional extra.
 */

/* The riscv Linux-ABI numbers the solnix kernel's syscall.c dispatches. */
#define	SYS_openat	56
#define	SYS_close	57
#define	SYS_lseek	62
#define	SYS_read	63
#define	SYS_write	64
#define	SYS_exit	93
#define	SYS_getpid	172
#define	SYS_brk		214

#define	ENOSYS		89
#define	EBADF		9

/* newlib pulls in <errno.h>'s errno via its own reent machinery; we only need
 * the integer to report through. Declared here to avoid dragging a host header
 * into a freestanding glue file. */
extern int errno;

static long
sys3(long n, long a0, long a1, long a2)
{
	register long r_a0 __asm__("a0") = a0;
	register long r_a1 __asm__("a1") = a1;
	register long r_a2 __asm__("a2") = a2;
	register long r_a7 __asm__("a7") = n;

	__asm__ __volatile__("ecall"
	    : "+r"(r_a0) : "r"(r_a1), "r"(r_a2), "r"(r_a7) : "memory");
	return (r_a0);
}

/*
 * setret -- the kernel returns -errno on failure (Linux convention). newlib
 * expects -1 with errno set (POSIX convention). This is the seam between them,
 * and getting it wrong is how a working syscall looks broken.
 */
static long
setret(long r)
{
	if (r < 0) {
		errno = (int)-r;
		return (-1);
	}
	return (r);
}

/* [REAL] write(2) -- console for fd 1/2, real vfs file for fd >= 3. */
long
_write(int fd, const char *buf, unsigned long n)
{
	return (setret(sys3(SYS_write, fd, (long)buf, (long)n)));
}

/* [REAL] read(2) -- console for fd 0, real vfs file for fd >= 3. */
long
_read(int fd, char *buf, unsigned long n)
{
	return (setret(sys3(SYS_read, fd, (long)buf, (long)n)));
}

/* [REAL] close(2). */
int
_close(int fd)
{
	return ((int)setret(sys3(SYS_close, fd, 0, 0)));
}

/* [REAL] lseek(2). */
long
_lseek(int fd, long off, int whence)
{
	return (setret(sys3(SYS_lseek, fd, off, whence)));
}

/* [REAL] getpid(2). */
int
_getpid(void)
{
	return ((int)sys3(SYS_getpid, 0, 0, 0));
}

/* [REAL] _exit -- terminate. Never returns. */
void
_exit(int status)
{
	(void) sys3(SYS_exit, status, 0, 0);
	for (;;)			/* unreachable; keeps noreturn honest */
		;
}

/*
 * [REAL] _sbrk -- the heap primitive newlib's malloc is built on.
 *
 * The kernel's brk(2) is the absolute-address form: brk(0) queries the current
 * break, brk(new) sets it. newlib wants sbrk(incr) returning the OLD break, so
 * the increment arithmetic lives here. This is the single most load-bearing
 * function in the file: if it is wrong, newlib's malloc hands out memory that is
 * not mapped and the program dies in a page fault rather than an error.
 */
void *
_sbrk(long incr)
{
	long old = sys3(SYS_brk, 0, 0, 0);	/* query */
	long ret;

	if (old < 0) {
		errno = ENOSYS;
		return ((void *)-1);
	}
	if (incr == 0)
		return ((void *)old);
	ret = sys3(SYS_brk, old + incr, 0, 0);
	if (ret < 0) {
		errno = 12;			/* ENOMEM */
		return ((void *)-1);
	}
	return ((void *)old);
}

/*
 * [STUB] _fstat -- newlib's stdio calls this to decide whether a stream is a
 * character device (unbuffered) or a regular file (block buffered). The solnix
 * kernel has NO stat(2) at all, so we claim "character device" unconditionally.
 *
 * WHAT THIS COSTS: every stream becomes line/unbuffered-ish, and a program that
 * genuinely needs a file's size or mode gets a wrong answer. That is acceptable
 * for a console-printing probe and NOT acceptable in general. Honest fix: a real
 * stat/fstat syscall over the vfs layer.
 *
 * S_IFCHR is 0020000 octal; newlib only inspects st_mode here, so the struct is
 * declared minimally rather than pulling in <sys/stat.h> layout assumptions.
 */
struct __glue_stat {
	unsigned long	pad0[3];
	unsigned int	st_mode;
	unsigned int	pad1[32];
};

int
_fstat(int fd, void *st)
{
	struct __glue_stat *s = (struct __glue_stat *)st;

	if (fd < 0) {
		errno = EBADF;
		return (-1);
	}
	s->st_mode = 0020000;			/* S_IFCHR */
	return (0);
}

/*
 * [STUB] _isatty -- always "yes". Same rationale and same cost as _fstat: the
 * kernel cannot answer the question, and for a console probe the answer is
 * genuinely yes for 0/1/2.
 */
int
_isatty(int fd)
{
	(void) fd;
	return (1);
}

/*
 * [ENOSYS] _kill -- newlib's abort() path calls this. The kernel HAS kill(2)
 * (SYS_kill 129), but wiring abort() to it would make a libc-internal assertion
 * failure look like a signal death, so this reports ENOSYS explicitly rather
 * than half-working. abort() then falls through to _exit.
 */
int
_kill(int pid, int sig)
{
	(void) pid;
	(void) sig;
	errno = ENOSYS;
	return (-1);
}

/*
 * [ENOSYS] _open -- deliberately NOT wired to the kernel's openat(2).
 *
 * The kernel's open path takes a bare path (dirfd/mode ignored) and serves
 * EMBEDDED vfiles plus the on-disk ustar rootfs. Wiring it is a few lines, but
 * newlib's fopen() then needs working fstat to buffer correctly, and this probe
 * has no file to open. Left explicit so nobody mistakes a stub for a port.
 */
int
_open(const char *path, int flags, int mode)
{
	(void) path;
	(void) flags;
	(void) mode;
	errno = ENOSYS;
	return (-1);
}
