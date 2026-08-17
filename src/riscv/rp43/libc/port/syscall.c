/*
 * syscall.c -- solnix riscv64 libc syscall wrappers.  Each wrapper loads the
 * illumos riscv64 syscall trap (a7=nr, args in a0..) via <sys/systrap.h>, and
 * on the reduced SunOS error-return ABI (a negative return is -errno) sets the
 * global errno and returns -1.
 *
 * CRIB PROVENANCE: the thin "trap, translate -errno, return" wrapper is the
 * illumos libc sysent wrapper reduced to one C body per call; the trap idiom
 * and SYS_* numbers are the kernel's rv_syscall ABI (uts riscv64).
 */
#include <sys/systrap.h>
#include <sys/types.h>
#include <unistd.h>

int errno;

/* translate a raw syscall return into the errno/-1 convention. */
static long
__ret(long r)
{
	if (r < 0 && r > -256) {
		errno = (int)(-r);
		return (-1);
	}
	return (r);
}

ssize_t
read(int fd, void *buf, size_t n)
{
	return (__ret(__systrap3(SYS_read, fd, (long)buf, (long)n)));
}

ssize_t
write(int fd, const void *buf, size_t n)
{
	return (__ret(__systrap3(SYS_write, fd, (long)buf, (long)n)));
}

int
open(const char *path, int flags)
{
	return ((int)__ret(__systrap2(SYS_open, (long)path, flags)));
}

int
close(int fd)
{
	return ((int)__ret(__systrap1(SYS_close, fd)));
}

off_t
lseek(int fd, off_t off, int whence)
{
	return (__ret(__systrap3(SYS_lseek, fd, off, whence)));
}

pid_t
getpid(void)
{
	return ((pid_t)__systrap0(SYS_getpid));
}

int
chdir(const char *path)
{
	return ((int)__ret(__systrap1(SYS_chdir, (long)path)));
}

/*
 * getcwd(buf, size) -- SYS_getcwd copies the proc's tracked cwd into buf.
 * The gnulib/GNU extension getcwd(NULL, 0) allocates a buffer; support it by
 * mallocing a PATH_MAX-ish buffer and shrinking on the trap's error return.
 * On success returns buf (or the malloc'd buffer); on error returns NULL/errno.
 */
extern void *malloc(size_t);
extern void free(void *);
char *
getcwd(char *buf, size_t size)
{
	char *b = buf;
	size_t sz = size;
	long r;

	if (b == 0) {			/* GNU extension: allocate */
		sz = (size != 0) ? size : 4096;
		b = malloc(sz);
		if (b == 0) {
			errno = 12;	/* ENOMEM */
			return (0);
		}
	}
	r = __systrap2(SYS_getcwd, (long)b, (long)sz);
	if (r < 0 && r > -256) {
		errno = (int)(-r);
		if (buf == 0)
			free(b);
		return (0);
	}
	return (char *)r;		/* kernel returns the buffer pointer */
}

int
unlink(const char *path)
{
	return ((int)__ret(__systrap1(SYS_unlink, (long)path)));
}

int
rmdir(const char *path)
{
	return ((int)__ret(__systrap1(SYS_rmdir, (long)path)));
}

int
dup(int fd)
{
	return ((int)__ret(__systrap1(SYS_dup, fd)));
}

int
dup2(int o, int n)
{
	return ((int)__ret(__systrap2(SYS_dup2, o, n)));
}

/*
 * The raw exit(2) trap; the C-visible exit() (which runs atexit hooks + flushes
 * stdio) lives in stdlib.c and calls this.
 */
int
execve(const char *path, char *const argv[], char *const envp[])
{
	/* the reduced SYS_execve carries path + argv; envp is set up by the
	   kernel as the process default (see exec_elf.c).  On success it does
	   not return; on failure it returns -1 with errno. */
	(void) envp;
	return ((int)__ret(__systrap2(SYS_execve, (long)path, (long)argv)));
}

int
sigprocmask(int how, const void *set, void *old)
{
	return ((int)__ret(__systrap3(SYS_sigprocmask, how, (long)set, (long)old)));
}

void
_exit(int status)
{
	(void) __systrap1(SYS_exit, status & 0xff);
	for (;;)
		;
}

/*
 * getpagesize -- the kernel MMU page size (Sv39 base page).  A constant here
 * (the kernel has no sysconf yet); grows to a sysconf(_SC_PAGESIZE) trap when
 * the kernel reports it.
 */
int
getpagesize(void)
{
	return (4096);
}
