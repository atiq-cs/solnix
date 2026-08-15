/*
 * fptest.c -- R-P29 sub-task 3: the FP-context-switch proof + a getpid/brk
 * exercise.  The parent forks TWO children; each pins a DISTINCT floating-point
 * value in a callee-saved FP register (fs0) and, between long CPU-bound spins
 * that the 100 Hz timer preempts many times, re-reads fs0 and checks it still
 * holds its value.  If rv_swtch did NOT save/restore the FP register file, the
 * two children -- which write different values into the SAME architectural FP
 * registers -- would corrupt each other's fs0 across a preemptive switch, and
 * the check would FAIL.  Each child reports PASS/FAIL for its own FP state.
 *
 * The parent also demonstrates the new syscalls: getpid(2) and brk(2) (grow the
 * heap, write through the new page, read it back) + the reduced SunOS errno
 * return ABI (a negative syscall return is -errno).
 *
 * Self-contained inline riscv64 syscall stubs (illumos ABI: a7=nr, a0..=args,
 * ecall, result in a0), NO libc beyond the R-P20 crt _start.
 *
 * CRIB PROVENANCE: the "two tasks pin different values in the same FP register,
 * interleave via preemption, and the values survive only if the switch saves
 * FP" is the classic FP-context-switch correctness proof (illumos fpu_save/
 * fp_restore + the lwp FPU save area); the fork/wait/brk/getpid syscall stubs
 * are the native illumos <sys/syscall.h> + the RISC-V psABI.
 */

typedef unsigned long size_t;
typedef long ssize_t;

#define	SYS_exit	1
#define	SYS_write	4
#define	SYS_brk		17
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
static long brk_(unsigned long a) { return (sc3(SYS_brk, (long)a, 0, 0)); }

static size_t slen(const char *s) { size_t n = 0; while (s[n]) n++; return (n); }
static void puts_(const char *s) { write(1, s, slen(s)); }
static void putn(long v)
{
	char b[24]; int i = 0; int neg = 0;
	if (v < 0) { neg = 1; v = -v; }
	if (v == 0) { write(1, "0", 1); return; }
	while (v > 0 && i < (int)sizeof (b)) { b[i++] = (char)('0' + v % 10); v /= 10; }
	if (neg) write(1, "-", 1);
	while (i-- > 0) write(1, &b[i], 1);
}

/* keep `val` pinned in fs0 across the spin; read it back and compare. */
#define	ROUNDS	4
#define	SPIN	(25UL * 1000UL * 1000UL)

static void
fp_worker(char tag, double val)
{
	long pid = getpid();
	int r, ok = 1;
	double back;

	/* load the sentinel into fs0 (callee-saved) and keep it live. */
	__asm__ __volatile__("fmv.d fs0, %0" :: "f"(val) : "fs0");

	for (r = 0; r < ROUNDS; r++) {
		volatile unsigned long x = 0, i;
		for (i = 0; i < SPIN; i++)
			x += i;			/* CPU-bound: gets preempted */
		/* also do FP arithmetic so f-regs are actively in use. */
		__asm__ __volatile__("fmv.d %0, fs0" : "=f"(back));
		if (back != val)
			ok = 0;
		puts_("    [fp ");
		write(1, &tag, 1);
		puts_(" pid=");
		putn(pid);
		puts_("] round ");
		putn(r);
		puts_(" fs0=");
		putn((long)back);
		puts_(back == val ? " (intact)\n" : " (CORRUPTED)\n");
		(void) x;
	}
	puts_("  [fp ");
	write(1, &tag, 1);
	puts_("] FP state ");
	puts_(ok ? "PRESERVED across preemption\n" : "CORRUPTED across preemption\n");
	exit(ok ? 0 : 1);
}

int
main(int argc, char **argv, char **envp)
{
	long a, b, st = -1, reaped;
	long mypid;
	unsigned long obrk, nbrk;
	volatile long *heap;
	(void) argc; (void) argv; (void) envp;

	mypid = getpid();
	puts_("  [fptest] parent getpid()=");
	putn(mypid);
	puts_("\n");

	/* brk(2): query, grow, write+read through the new heap page. */
	obrk = (unsigned long)brk_(0);
	puts_("  [fptest] brk(0) query -> ");
	putn((long)obrk);
	puts_("\n");
	nbrk = (unsigned long)brk_(obrk + 4096);
	if ((long)nbrk < 0) {
		puts_("  [fptest] brk grow FAILED (errno ");
		putn(-(long)nbrk);
		puts_(")\n");
	} else {
		heap = (volatile long *)obrk;
		heap[0] = 0x29;			/* write through the new page */
		puts_("  [fptest] brk grew heap to ");
		putn((long)nbrk);
		puts_("; wrote+read heap[0]=");
		putn(heap[0]);
		puts_(heap[0] == 0x29 ? " (OK)\n" : " (BAD)\n");
	}

	/* fork two FP children with DISTINCT sentinels in the same reg. */
	a = fork();
	if (a == 0)
		fp_worker('A', 111.0);		/* child A pins 111 in fs0 */
	b = fork();
	if (b == 0)
		fp_worker('B', 222.0);		/* child B pins 222 in fs0 */

	reaped = wait_(&st);
	puts_("  [fptest] reaped fp child pid=");
	putn(reaped);
	puts_(" status=");
	putn(st);
	puts_("\n");
	st = -1;
	reaped = wait_(&st);
	puts_("  [fptest] reaped fp child pid=");
	putn(reaped);
	puts_(" status=");
	putn(st);
	puts_("\n");
	return (0);
}
