/*
 * preempt.c -- the R-P27 timer-tick preemption proof.  The parent forks TWO
 * CPU-bound children; each child runs a tight compute loop with NO yielding
 * syscall in its hot path (only a periodic write to announce progress) and
 * never calls fork/wait/exit until it is done.  Under the R-P26 COOPERATIVE
 * dispatcher one child would monopolize the CPU and print all its lines before
 * the other ever ran; under R-P27 PREEMPTION the 100 Hz timer tick forces a
 * context switch mid-loop, so the two children's output INTERLEAVES -- proving
 * neither monopolizes the CPU.
 *
 * Self-contained inline riscv64 syscall stubs (illumos ABI: a7=nr,
 * a0..a5=args, ecall, result in a0), NO libc beyond the R-P20 crt _start.
 *
 * CRIB PROVENANCE: the "two CPU-bound tasks interleave only if the scheduler
 * preempts on a timer tick" is the classic preemptive-scheduling proof
 * (illumos clock()/preempt(), xv6-riscv yield-on-tick); the fork/wait/write
 * syscall stubs are the native illumos <sys/syscall.h> + the RISC-V psABI.
 */

typedef unsigned long size_t;
typedef long ssize_t;

#define	SYS_exit	1
#define	SYS_write	4
#define	SYS_getpid	20
#define	SYS_fork	142
#define	SYS_wait	107

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

static size_t slen(const char *s) { size_t n = 0; while (s[n]) n++; return (n); }
static void puts_(const char *s) { write(1, s, slen(s)); }
static void putn(long v)
{
	char b[24]; int i = 0;
	if (v == 0) { write(1, "0", 1); return; }
	while (v > 0 && i < (int)sizeof (b)) { b[i++] = (char)('0' + v % 10); v /= 10; }
	while (i-- > 0) write(1, &b[i], 1);
}

/*
 * A CPU-bound worker: ROUNDS iterations, each doing a long no-syscall spin
 * (SPIN volatile increments -- the compiler cannot elide them) then a single
 * progress line.  The spin is long enough that several 100 Hz timer ticks land
 * inside it, so a preemptive scheduler switches to the peer mid-spin.
 */
#define	ROUNDS	4
#define	SPIN	(30UL * 1000UL * 1000UL)

static void
worker(char tag)
{
	long pid = getpid();
	int r;
	for (r = 0; r < ROUNDS; r++) {
		volatile unsigned long x = 0, i;
		for (i = 0; i < SPIN; i++)
			x += i;			/* pure compute: no syscall */
		puts_("    [worker ");
		write(1, &tag, 1);
		puts_(" pid=");
		putn(pid);
		puts_("] round ");
		putn(r);
		puts_("\n");
		(void) x;
	}
	exit((int)(tag - 'A') + 1);		/* A->1, B->2 */
}

int
main(int argc, char **argv, char **envp)
{
	long a, b, st = -1, reaped;
	(void) argc; (void) argv; (void) envp;

	puts_("  [preempt] parent forking two CPU-bound children "
	    "(no cooperative yields)\n");

	a = fork();
	if (a == 0)
		worker('A');			/* child A: never returns */
	b = fork();
	if (b == 0)
		worker('B');			/* child B: never returns */

	/* parent: reap both.  The interleaved worker output above proves the
	   timer preempted between the children (cooperative -> preemptive). */
	reaped = wait_(&st);
	puts_("  [preempt] reaped child pid=");
	putn(reaped);
	puts_(" status=");
	putn(st);
	puts_("\n");
	st = -1;
	reaped = wait_(&st);
	puts_("  [preempt] reaped child pid=");
	putn(reaped);
	puts_(" status=");
	putn(st);
	puts_("\n");
	return (0);
}
