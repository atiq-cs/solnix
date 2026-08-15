/*
 * cat.c -- R-P35.3: the /bin/cat command.  Opens each path argument
 * (argv[1..]) and copies its bytes to stdout; with no args it reads stdin
 * (fd 0) to stdout.  The shell fork+execs "cat /etc/release" and a pipe
 * "echo hi | cat" routes echo's stdout into cat's stdin via the R-P33 pipe +
 * dup2, proving the file + pipe read path end-to-end.
 *
 * Self-contained inline syscall stubs, NO libc beyond crt.
 *
 * CRIB PROVENANCE: cat(1) copying open(path)/read/write to stdout (and stdin
 * when no args) is the BSD/illumos usr/src/cmd/cat idiom.
 */

typedef unsigned long size_t;
typedef long ssize_t;

#define	SYS_exit	1
#define	SYS_read	3
#define	SYS_write	4
#define	SYS_open	5
#define	SYS_close	6

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

static ssize_t read_(int fd, void *b, size_t n) { return (sc3(SYS_read, fd, (long)b, (long)n)); }
static ssize_t write_(int fd, const void *b, size_t n) { return (sc3(SYS_write, fd, (long)b, (long)n)); }
static int open_(const char *p, int fl) { return ((int)sc3(SYS_open, (long)p, fl, 0)); }
static int close_(int fd) { return ((int)sc3(SYS_close, fd, 0, 0)); }
static void exit(int s) { sc3(SYS_exit, s, 0, 0); for (;;); }

/* copy fd -> stdout until EOF (read returns 0). */
static void
catfd(int fd)
{
	char buf[128];
	ssize_t n;
	while ((n = read_(fd, buf, sizeof(buf))) > 0)
		write_(1, buf, (size_t)n);
}

int
main(int argc, char **argv, char **envp)
{
	int i, rc = 0;
	(void) envp;

	if (argc <= 1) {
		catfd(0);		/* no args: cat stdin */
		exit(0);
	}
	for (i = 1; i < argc; i++) {
		int fd = open_(argv[i], 0);
		if (fd < 0) {
			write_(2, "cat: cannot open ", 17);
			{ size_t k = 0; while (argv[i][k]) k++; write_(2, argv[i], k); }
			write_(2, "\n", 1);
			rc = 1;
			continue;
		}
		catfd(fd);
		close_(fd);
	}
	exit(rc);
	return (0);
}
