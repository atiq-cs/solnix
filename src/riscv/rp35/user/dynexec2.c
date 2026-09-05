/*
 * dynexec2.c -- the R-P28 cross-object-linking proof driver.  This process
 * execs "/bin/hellodyn" by absolute path.  That ELF carries a PT_INTERP
 * (/usr/lib/ld.so.1) AND a real cross-object reference: it calls __multf3 /
 * __fixtfsi, which live in libgcc_s.so.1 (R_RISCV_JUMP_SLOT relocations against
 * UNDEF .dynsym entries).  The kernel exec_dynamic path loads the app + ld.so.1
 * into one AS and enters ld.so.1, which MAPS libgcc_s.so.1 (via SYS_mapso),
 * processes its dynamic section, and BINDS the app's PLT slots to the resolved
 * libgcc_s addresses.  The hello then calls those functions across the object
 * boundary and exits 42 -- proof that real cross-object dynamic linking works.
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
	puts_("  [dynexec2] exec /bin/hellodyn (DYNAMIC + cross-object "
	    "libgcc_s call)\n");
	execve("/bin/hellodyn", 0, 0);
	puts_("  [dynexec2] exec FAILED\n");
	exit(126);
}
