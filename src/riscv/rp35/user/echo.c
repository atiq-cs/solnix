/*
 * echo.c -- R-P35.3: the /bin/echo command.  Prints its arguments
 * (argv[1..argc-1]) separated by spaces + a trailing newline.  The shell
 * fork+execs it with a real argv (echo hello -> "hello\n"), proving argv
 * passthrough across exec(2).
 *
 * Self-contained inline syscall stubs (illumos riscv64 ABI: a7=nr, a0..=args,
 * result in a0), NO libc beyond crt.
 *
 * CRIB PROVENANCE: echo(1) printing argv separated by spaces is the classic
 * BSD/illumos usr/src/cmd/echo + the coreutils echo behavior; the syscall stub
 * shape is the illumos libc SYSTRAP idiom.
 */

typedef unsigned long size_t;

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

static void write_(int fd, const void *b, size_t n) { (void) sc3(SYS_write, fd, (long)b, (long)n); }
static void exit(int s) { sc3(SYS_exit, s, 0, 0); for (;;); }
static size_t slen(const char *s) { size_t n = 0; while (s[n]) n++; return (n); }

int
main(int argc, char **argv, char **envp)
{
	int i;
	(void) envp;
	for (i = 1; i < argc; i++) {
		if (i > 1)
			write_(1, " ", 1);
		write_(1, argv[i], slen(argv[i]));
	}
	write_(1, "\n", 1);
	exit(0);
	return (0);
}
