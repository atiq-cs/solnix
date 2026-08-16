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
void
_exit(int status)
{
	(void) __systrap1(SYS_exit, status & 0xff);
	for (;;)
		;
}
