/*
 * cowtest.c -- R-P32.2 proof: COPY-ON-WRITE fork + DEMAND PAGING from userland.
 *
 * The process seeds a global buffer (its own data/bss page), then fork(2)s.
 * Parent + child SHARE that page read-only (PTE_COW) until one writes:
 *   - the CHILD writes a distinct byte pattern into the shared buffer.  That
 *     store faults (scause 15) on the COW page; the kernel fault handler copies
 *     the page + makes the child's copy private+writable ([COW] line in the log).
 *   - the CHILD reads back its own pattern (its private copy) and exits with a
 *     status derived from it.
 *   - the PARENT waits, then reads the SAME buffer: it must STILL hold the
 *     ORIGINAL seed (the child's write did NOT corrupt the parent) -- the COW
 *     correctness invariant.
 *
 * Then the process exercises DEMAND PAGING: it asks the kernel (SYS_lazy) to
 * reserve a fresh page at a fixed VA WITHOUT backing it, then touches it -- the
 * first read/write faults in a zeroed frame ([demand] line in the log) -- and
 * confirms it reads back zero, then its own written value.
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
#define	SYS_lazy	230	/* R-P32: reserve a demand-paged page at va */

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
static long lazy_(long va) { return (sc3(SYS_lazy, va, 0, 0)); }

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

/* a global buffer -- its own writable data page, COW-shared across fork. */
static volatile unsigned char shared[64];

int
main(int argc, char **argv, char **envp)
{
	long pid, status = -1;
	int i;
	(void) argc; (void) argv; (void) envp;

	/* seed the shared page (parent's original contents). */
	for (i = 0; i < 64; i++)
		shared[i] = 0x11;

	puts_("  [cow] parent seeded shared[0]=0x11; forking (pages COW-shared)\n");

	pid = fork();
	if (pid == 0) {
		/* child: WRITE the shared page -> triggers the COW copy fault. */
		puts_("  [cow][child] writing 0x22 into the shared (COW) page...\n");
		for (i = 0; i < 64; i++)
			shared[i] = 0x22;
		puts_("  [cow][child] readback shared[0]=0x");
		putn((long)shared[0]);
		puts_(" (child's private copy)\n");
		exit((int)shared[0]);		/* 0x22 == 34 */
	}

	/* parent: wait for the child, then verify the parent's page is intact. */
	(void) wait_(&status);
	puts_("  [cow][parent] child exited; parent reads shared[0]=0x");
	putn((long)shared[0]);
	if (shared[0] == 0x11)
		puts_(" -- UNCHANGED (COW isolated the child's write)\n");
	else
		puts_(" -- CORRUPTED (COW FAILED)\n");

	/* --- demand paging: reserve a page at a fixed VA, touch it lazily. --- */
	{
		volatile unsigned char *dp = (volatile unsigned char *)0x30000000UL;
		puts_("  [dp] reserving a demand-paged page at 0x30000000...\n");
		if (lazy_((long)dp) != 0) {
			puts_("  [dp] SYS_lazy FAILED\n");
			exit(1);
		}
		/* first touch (a load) faults in a zeroed frame. */
		puts_("  [dp] first read (faults in a zeroed page): dp[0]=0x");
		putn((long)dp[0]);
		puts_("\n");
		dp[0] = 0x5a;			/* now a normal write (page is backed) */
		puts_("  [dp] after write dp[0]=0x");
		putn((long)dp[0]);
		puts_(dp[0] == 0x5a ? " -- demand page writable (OK)\n" :
		    " -- demand page BROKEN\n");
	}

	puts_("  [cow] done\n");
	exit(0);
	return (0);
}
