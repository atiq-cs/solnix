/*
 * libu.h — solnix riscv64 userland tiny syscall-stub "libc" (R-P8).
 *
 * Freestanding, static, no real libc: just the ecall wrappers for the syscalls
 * the R-P8 kernel implements, plus a few string helpers. Every userland ELF
 * (init, sh, hello, echo, cat) includes this and provides its own main(); the
 * shared _start below calls main and exit()s its return value.
 *
 * The syscall ABI matches the kernel's syscall.c (riscv Linux-ABI subset):
 *   a7 = number, a0..a5 = args, ecall, a0 = return (negative = -errno).
 */
#ifndef _LIBU_H
#define _LIBU_H

/* Syscall numbers — must match kernel syscall.c. */
#define SYS_getpid  172
#define SYS_close   57
#define SYS_read    63
#define SYS_write   64
#define SYS_exit    93
#define SYS_brk     214
#define SYS_fork    220	  /* clone-ish; our kernel treats 220 as fork */
#define SYS_execve  221
#define SYS_wait4   260
#define SYS_openat  56	  /* open(path,flags): we ignore dirfd/mode */

#define O_RDONLY 0

static long
__sys(long n, long a0, long a1, long a2, long a3)
{
	register long r_a0 asm("a0") = a0;
	register long r_a1 asm("a1") = a1;
	register long r_a2 asm("a2") = a2;
	register long r_a3 asm("a3") = a3;
	register long r_a7 asm("a7") = n;

	__asm__ __volatile__("ecall"
	    : "+r"(r_a0)
	    : "r"(r_a1), "r"(r_a2), "r"(r_a3), "r"(r_a7)
	    : "memory");
	return (r_a0);
}

static long uwrite(int fd, const char *b, unsigned long n)
{ return __sys(SYS_write, fd, (long)b, (long)n, 0); }
static long uread(int fd, char *b, unsigned long n)
{ return __sys(SYS_read, fd, (long)b, (long)n, 0); }
static long uopen(const char *path, int flags)
{ return __sys(SYS_openat, -100, (long)path, flags, 0); }
static long uclose(int fd)
{ return __sys(SYS_close, fd, 0, 0, 0); }
static int  ugetpid(void)
{ return (int)__sys(SYS_getpid, 0, 0, 0, 0); }
static long ubrk(unsigned long p)
{ return __sys(SYS_brk, (long)p, 0, 0, 0); }
static int  ufork(void)
{ return (int)__sys(SYS_fork, 0, 0, 0, 0); }
static int  uexecve(const char *path, char *const argv[], char *const envp[])
{ return (int)__sys(SYS_execve, (long)path, (long)argv, (long)envp, 0); }
static int  uwaitpid(int pid, int *status, int opt)
{ return (int)__sys(SYS_wait4, pid, (long)status, opt, 0); }

static void uexit(int status)
{ __sys(SYS_exit, status, 0, 0, 0); for (;;) ; }

static unsigned long ustrlen(const char *s)
{ unsigned long n = 0; while (s[n]) n++; return n; }
static void uputs(const char *s)
{ uwrite(1, s, ustrlen(s)); }
static int ustreq(const char *a, const char *b)
{ while (*a && *a == *b) { a++; b++; } return *a == *b; }

/* Print an unsigned decimal to fd 1. */
static void uputdec(unsigned long v)
{
	char buf[24];
	int i = 0;
	if (v == 0) { uputs("0"); return; }
	while (v) { buf[i++] = '0' + (v % 10); v /= 10; }
	while (i--) uwrite(1, &buf[i], 1);
}

int main(int argc, char **argv);

void
_start(void)
{
	/* The kernel enters with a0=argc=0 (no argv passed in R-P8). We build a
	 * NULL argv so main sees argc=0, argv={NULL}. */
	static char *argv0[1] = { 0 };
	uexit(main(0, argv0));
}

#endif /* _LIBU_H */
