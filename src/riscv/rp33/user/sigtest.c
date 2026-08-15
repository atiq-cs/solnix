/*
 * sigtest.c -- R-P33.1 proof: signals + kill(2).
 *
 *   1. A child installs a SIGUSR1 handler (sigaction) + spins; the PARENT
 *      kill(2)s it with SIGUSR1.  The kernel delivers the signal on the child's
 *      return-to-U edge: it builds a signal frame on the child's user stack,
 *      sret's into the handler, the handler sets a flag + returns (through the
 *      sa_restorer, which ecalls SYS_sigreturn), and the child resumes exactly
 *      where the signal interrupted it -- it sees the flag, prints, exits 0.
 *   2. The parent forks a SECOND child (no handler) that spins forever, then
 *      kill(2)s it with SIGKILL; the default action terminates the child.  The
 *      parent wait(2)s + reaps it (status 128+9=137), proving SIGKILL kills.
 *
 * Self-contained inline syscall stubs (illumos riscv64 ABI: a7=nr, a0..a5=args,
 * result in a0), NO libc beyond crt.  The sa_restorer is a tiny naked stub that
 * ecalls SYS_sigreturn (the kernel restores the interrupted frame).
 */

typedef unsigned long size_t;
typedef long ssize_t;

#define	SYS_exit	1
#define	SYS_write	4
#define	SYS_getpid	20
#define	SYS_fork	142
#define	SYS_wait	107
#define	SYS_kill	232
#define	SYS_sigaction	233
#define	SYS_sigreturn	234

#define	SIGKILL		9
#define	SIGUSR1		16

static long
sc0(long nr)
{
	register long a7 __asm__("a7") = nr;
	register long a0 __asm__("a0");
	__asm__ __volatile__("ecall" : "=r"(a0) : "r"(a7) : "memory");
	return (a0);
}
static long
sc2(long nr, long x0, long x1)
{
	register long a7 __asm__("a7") = nr;
	register long a0 __asm__("a0") = x0;
	register long a1 __asm__("a1") = x1;
	__asm__ __volatile__("ecall"
	    : "+r"(a0) : "r"(a7), "r"(a1) : "memory");
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
static long kill(long pid, long sig) { return (sc2(SYS_kill, pid, sig)); }

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

/*
 * __sigrestorer -- the sa_restorer trampoline.  A signal handler `ret`s here
 * (the kernel set ra to this address); it ecalls SYS_sigreturn, which restores
 * the interrupted frame (this stub never returns to C).
 */
__attribute__((naked)) static void
__sigrestorer(void)
{
	__asm__ __volatile__(
	    "li a7, %0\n"
	    "ecall\n"
	    :: "i"(SYS_sigreturn) : "memory");
}

static long sigaction_(int sig, void (*h)(int), void (*r)(void))
{
	return (sc3(SYS_sigaction, sig, (long)h, (long)r));
}

/* set by the SIGUSR1 handler; volatile so the spin loop re-reads it. */
static volatile int got_usr1;

static void
usr1_handler(int sig)
{
	puts_("    [sigtest][child] SIGUSR1 handler RAN (sig=");
	putn(sig);
	puts_(")\n");
	got_usr1 = 1;
}

#define	SPIN	(4UL * 1000UL * 1000UL)

int
main(int argc, char **argv, char **envp)
{
	long child1, child2;
	long st = -1;
	volatile unsigned long i;
	(void) argc; (void) argv; (void) envp;

	puts_("  [sigtest] signals + kill(2): a handler runs on delivery; "
	    "SIGKILL terminates\n");

	/* --- part 1: SIGUSR1 caught by a handler --------------------------- */
	child1 = fork();
	if (child1 == 0) {
		/* child: install the SIGUSR1 handler, spin until it fires. */
		sigaction_(SIGUSR1, usr1_handler, __sigrestorer);
		puts_("    [sigtest][child] installed SIGUSR1 handler; "
		    "waiting for the signal\n");
		while (!got_usr1) {
			for (i = 0; i < SPIN; i++)
				;
		}
		puts_("    [sigtest][child] resumed after the handler "
		    "returned (sigreturn OK); exiting 0\n");
		exit(0);
	}
	/* parent: give the child time to install the handler + start spinning,
	   then send it SIGUSR1. */
	for (i = 0; i < SPIN * 4; i++)
		;
	puts_("    [sigtest][parent] kill(child, SIGUSR1)\n");
	kill(child1, SIGUSR1);
	wait_(&st);
	puts_("    [sigtest][parent] reaped SIGUSR1 child status=");
	putn(st);
	puts_("\n");

	/* --- part 2: SIGKILL terminates an uncatchable spinner ------------- */
	child2 = fork();
	if (child2 == 0) {
		/* child: no handler, spin forever -- only SIGKILL stops it. */
		puts_("    [sigtest][child2] spinning forever (only SIGKILL "
		    "can stop me)\n");
		for (;;) {
			for (i = 0; i < SPIN; i++)
				;
		}
		exit(99);	/* unreachable */
	}
	for (i = 0; i < SPIN * 4; i++)
		;
	puts_("    [sigtest][parent] kill(child2, SIGKILL)\n");
	kill(child2, SIGKILL);
	st = -1;
	wait_(&st);
	puts_("    [sigtest][parent] reaped SIGKILL child2 status=");
	putn(st);
	puts_((st == 128 + SIGKILL) ?
	    " (128+SIGKILL -- terminated by signal, as expected)\n" :
	    " (unexpected status)\n");

	puts_("  [sigtest] done\n");
	exit(0);
	return (0);
}
