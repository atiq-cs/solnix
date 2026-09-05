/*
 * fsexec.c -- the R-P27 fs-backed-exec proof.  This process execs a program BY
 * ABSOLUTE PATH ("/bin/execee"); the kernel resolves that path in the
 * initramfs (ramfs_lookup) and loads the ELF bytes -- vs the R-P26 exec which
 * ignored the path and always ran the one embedded execee.  Seeing the execee
 * line after "/bin/execee" proves the path drove the lookup.
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
	puts_("  [fsexec] exec by absolute path: /bin/execee (via ramfs)\n");
	execve("/bin/execee", 0, 0);
	puts_("  [fsexec] exec FAILED (path not in ramfs?)\n");
	exit(126);
}
