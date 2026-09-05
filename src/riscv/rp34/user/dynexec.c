/*
 * dynexec.c -- the R-P27 ld.so.1 proof driver.  This process execs the DYNAMIC
 * hello by absolute path ("/bin/hello"); because that ELF carries a PT_INTERP
 * (/usr/lib/ld.so.1), the kernel's exec_dynamic path loads BOTH the app and
 * the interpreter into the AS and enters ld.so.1, which relocates the app and
 * jumps to its _start.  Seeing the ld.so.1 lines + the hello running + being
 * reaped proves the first DYNAMICALLY-LINKED riscv64-solaris process.
 *
 * Self-contained inline syscall stubs (illumos ABI), NO libc beyond crt.
 */

typedef unsigned long size_t;
typedef long ssize_t;

#define	SYS_exit	1
#define	SYS_write	4
#define	SYS_execve	59

static long
sc3(long nr, long x0, long x1, long x2)
{
	register long a7 __asm__("a7") = nr;
	register long a0 __asm__("a0") = x0;
	register long a1 __asm__("a1") = x1;
	register long a2 __asm__("a2") = x2;
	__asm__ __volatile__("ecall"
	    : "+r"(a0) : "r"(a7), "r"(a1), "r"(a2) : "memory");
	return (a0);
}

static ssize_t write(int fd, const void *b, size_t n) { return (sc3(SYS_write, fd, (long)b, (long)n)); }
static void exit(int s) { sc3(SYS_exit, s, 0, 0); for (;;); }
static long execve(const char *p, char **av, char **ev)
{ return (sc3(SYS_execve, (long)p, (long)av, (long)ev)); }
static size_t slen(const char *s) { size_t n = 0; while (s[n]) n++; return (n); }
static void puts_(const char *s) { write(1, s, slen(s)); }

int
main(int argc, char **argv, char **envp)
{
	(void) argc; (void) argv; (void) envp;
	puts_("  [dynexec] exec /bin/hello (DYNAMIC: INTERP=/usr/lib/ld.so.1)\n");
	execve("/bin/hello", 0, 0);
	puts_("  [dynexec] exec FAILED\n");
	exit(125);
}
