/*
 * dynexec3.c -- the R-P31.2 ld.so.1-hardening proof driver.  Execs
 * "/bin/hellolazy" (DYNAMIC, PT_INTERP=/usr/lib/ld.so.1) by absolute path.  The
 * hellolazy ELF is linked with LAZY binding, --hash-style=both (.gnu.hash) and
 * -z relro (PT_GNU_RELRO), and calls __multf3 in libgcc_s.so.1 TWICE.  ld.so.1
 * looks up via .gnu.hash + matches @GCC_3.0 versioning, arms lazy PLT (so the
 * first call fires the _rtld_bind trampoline + the second uses the patched
 * GOT), and mprotects the relro read-only after relocation.
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
	puts_("  [dynexec3] exec /bin/hellolazy (LAZY PLT + .gnu.hash + "
	    "versioning + relro)\n");
	execve("/bin/hellolazy", 0, 0);
	puts_("  [dynexec3] exec FAILED\n");
	exit(126);
}
