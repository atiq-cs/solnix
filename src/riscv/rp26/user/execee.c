/*
 * execee.c -- the R-P26 exec(2) target: a second, DISTINCT riscv64-solaris
 * program that the exec test runs in place of its caller.  The forker's exec
 * child replaces its address space with this ELF, so seeing THIS line proves
 * exec(2) reloaded a new program image (vs the fork copy of the caller).
 *
 * Self-contained inline syscall stubs (illumos ABI), NO libc beyond crt.
 */

typedef unsigned long size_t;
typedef long ssize_t;

#define	SYS_exit	1
#define	SYS_write	4
#define	SYS_getpid	20

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

static long
sc0(long nr)
{
	register long a7 __asm__("a7") = nr;
	register long a0 __asm__("a0");
	__asm__ __volatile__("ecall" : "=r"(a0) : "r"(a7) : "memory");
	return (a0);
}

static ssize_t write(int fd, const void *b, size_t n) { return (sc3(SYS_write, fd, (long)b, (long)n)); }
static long getpid(void) { return (sc0(SYS_getpid)); }
static void exit(int s) { sc3(SYS_exit, s, 0, 0); for (;;); }

static size_t slen(const char *s) { size_t n = 0; while (s[n]) n++; return (n); }
static void puts_(const char *s) { write(1, s, slen(s)); }
static void putn(long v)
{
	char b[24]; int i = 0;
	if (v == 0) { write(1, "0", 1); return; }
	while (v > 0 && i < (int)sizeof (b)) { b[i++] = (char)('0' + v % 10); v /= 10; }
	while (i-- > 0) write(1, &b[i], 1);
}

int
main(int argc, char **argv, char **envp)
{
	(void) argc; (void) argv; (void) envp;
	puts_("  [execee] NEW program image running after exec(2); pid=");
	putn(getpid());
	puts_("\n");
	exit(9);
}
