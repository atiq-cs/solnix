/*
 * smproc.c -- R-P32.1 proof: the REAL proc_t dispatcher runs processes on BOTH
 * harts.  A first process forks N children; each child prints the HART it is
 * running on (SYS_gethartid, == its proc_t p_hart set by the dispatcher) plus a
 * short compute loop so it stays dispatchable across ticks, then exits with its
 * index.  Because the two harts drain ONE shared runq, the children are
 * dispatched across BOTH hartids -- a proc forked on hart 0 can run on hart 1.
 * The parent waits + reaps all N.  The kernel tallies dispatches per hart.
 *
 * Self-contained inline syscall stubs (illumos riscv64 ABI: a7=nr, a0..a5=args,
 * result in a0), NO libc beyond crt.
 */

typedef unsigned long size_t;
typedef long ssize_t;

#define	SYS_exit	1
#define	SYS_write	4
#define	SYS_getpid	20
#define	SYS_fork	142
#define	SYS_wait	107
#define	SYS_gethartid	231	/* R-P32: which hart am I running on */

static long
sc0(long nr)
{
	register long a7 __asm__("a7") = nr;
	register long a0 __asm__("a0");
	__asm__ __volatile__("ecall" : "=r"(a0) : "r"(a7) : "memory");
	return (a0);
}
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
static long fork(void) { return (sc0(SYS_fork)); }
static long getpid(void) { return (sc0(SYS_getpid)); }
static long wait_(long *st) { return (sc3(SYS_wait, (long)st, 0, 0)); }
static long gethartid(void) { return (sc0(SYS_gethartid)); }

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

#define	NKIDS	6
#define	SPIN	(8UL * 1000UL * 1000UL)

int
main(int argc, char **argv, char **envp)
{
	int k;
	long st = -1;
	(void) argc; (void) argv; (void) envp;

	puts_("  [smproc] parent forking ");
	putn(NKIDS);
	puts_(" children (each reports its hart)\n");

	for (k = 0; k < NKIDS; k++) {
		long pid = fork();
		if (pid == 0) {
			/* child: spin a bit (so it is dispatched + preempted),
			   then report which hart it ran on. */
			volatile unsigned long x = 0, i;
			long h;
			for (i = 0; i < SPIN; i++)
				x += i;
			h = gethartid();
			puts_("    [smproc][child ");
			putn(k);
			puts_(" pid=");
			putn(getpid());
			puts_("] running on hart ");
			putn(h);
			puts_("\n");
			(void) x;
			exit(k);
		}
	}

	/* parent: reap all children. */
	for (k = 0; k < NKIDS; k++) {
		long r = wait_(&st);
		(void) r;
	}
	puts_("  [smproc] parent reaped all ");
	putn(NKIDS);
	puts_(" children\n");
	exit(0);
	return (0);
}
