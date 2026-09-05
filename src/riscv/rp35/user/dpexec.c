/*
 * dpexec.c -- R-P33.3 proof: file-backed demand-exec target.  A plain static
 * program whose text (PT_LOAD PF_X segment) is mapped LAZY by exec_image_demand
 * and demand-paged in from the ELF image on the first instruction fetch.  It
 * runs a small compute loop (so the text spans real code that must be paged in)
 * and prints a marker, proving the demand-paged text executed correctly.
 *
 * Self-contained inline syscall stubs (illumos riscv64 ABI), NO libc beyond crt.
 */

typedef unsigned long size_t;
typedef long ssize_t;

#define	SYS_exit	1
#define	SYS_write	4

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
static size_t slen(const char *s) { size_t n = 0; while (s[n]) n++; return (n); }
static void puts_(const char *s) { write(1, s, slen(s)); }
static void putn(long v)
{
	char b[24]; int i = 0;
	if (v < 0) { write(1, "-", 1); v = -v; }
	if (v == 0) { write(1, "0", 1); return; }
	while (v > 0 && i < (int)sizeof (b)) { b[i++] = (char)('0' + v % 10); v /= 10; }
	while (i-- > 0) write(1, &b[i], 1);
}

/* a few noinline functions to give the text some spread across pages. */
__attribute__((noinline)) static long f1(long x) { return (x * 3 + 1); }
__attribute__((noinline)) static long f2(long x) { return (f1(x) ^ (x << 2)); }
__attribute__((noinline)) static long f3(long x) { return (f2(x) + f1(x * 7)); }

int
main(int argc, char **argv, char **envp)
{
	long acc = 0;
	int i;
	(void) argc; (void) argv; (void) envp;

	puts_("    [dpexec] demand-paged text is executing\n");
	for (i = 0; i < 1000; i++)
		acc += f3(i) - f2(i) + f1(i);
	puts_("    [dpexec] compute loop result=");
	putn(acc);
	puts_(" (text ran from demand-paged pages)\n");
	exit(0);
	return (0);
}
