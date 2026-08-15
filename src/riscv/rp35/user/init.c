/*
 * init.c -- R-P35.2: the first user process (pid 1).  The classic Unix init:
 *   1. Set up the shell's input: open the ramfs script /etc/rc and dup2 it
 *      onto fd 0, so the child shell reads its commands from the script (a
 *      deterministic, non-interactive session for the boot proof).
 *   2. fork + exec /bin/sh (the login/session shell).
 *   3. Spawn an "orphan maker": a child that itself forks a grandchild and then
 *      exits immediately -- the grandchild is reparented to init (pid 1) by the
 *      kernel and init reaps it, proving init adopts + reaps orphans.
 *   4. Loop in wait(2), reaping every child (the shell, the orphan maker, and
 *      the adopted grandchild) until none remain, then exit.
 *
 * Self-contained inline syscall stubs, NO libc beyond crt.
 *
 * CRIB PROVENANCE: init(1M) as pid 1 forking the shell and looping in wait(2)
 * to reap orphaned children is the illumos usr/src/cmd/init + BSD /sbin/init +
 * xv6 user/init.c (the "for(;;) wait()" reaper); orphan re-parenting to init is
 * the SVR4/illumos exit() reparent-to-init behavior.
 */

typedef unsigned long size_t;

#define	SYS_exit	1
#define	SYS_write	4
#define	SYS_open	5
#define	SYS_close	6
#define	SYS_getpid	20
#define	SYS_execve	59
#define	SYS_wait	107
#define	SYS_fork	142
#define	SYS_dup2	242

static long sc0(long nr)
{
	register long a7 __asm__("a7") = nr;
	register long a0 __asm__("a0");
	__asm__ __volatile__("ecall" : "=r"(a0) : "r"(a7) : "memory");
	return (a0);
}
static long sc1(long nr, long x0)
{
	register long a7 __asm__("a7") = nr;
	register long a0 __asm__("a0") = x0;
	__asm__ __volatile__("ecall" : "+r"(a0) : "r"(a7) : "memory");
	return (a0);
}
static long sc2(long nr, long x0, long x1)
{
	register long a7 __asm__("a7") = nr;
	register long a0 __asm__("a0") = x0;
	register long a1 __asm__("a1") = x1;
	__asm__ __volatile__("ecall" : "+r"(a0) : "r"(a7), "r"(a1) : "memory");
	return (a0);
}
static long sc3(long nr, long x0, long x1, long x2)
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
static void exit_(int s) { sc1(SYS_exit, s); for (;;); }
static long fork_(void) { return (sc0(SYS_fork)); }
static long getpid_(void) { return (sc0(SYS_getpid)); }
static long wait_(long *st) { return (sc3(SYS_wait, (long)st, 0, 0)); }
static int open_(const char *p, int fl) { return ((int)sc3(SYS_open, (long)p, fl, 0)); }
static int close_(int fd) { return ((int)sc1(SYS_close, fd)); }
static int dup2_(int o, int n) { return ((int)sc2(SYS_dup2, o, n)); }
static long execve_(const char *p, char **av) { return (sc3(SYS_execve, (long)p, (long)av, 0)); }

static size_t slen(const char *s) { size_t n = 0; while (s[n]) n++; return (n); }
static void puts_(const char *s) { write_(1, s, slen(s)); }
static void putn(long v)
{
	char b[24]; int i = 0;
	if (v < 0) { write_(1, "-", 1); v = -v; }
	if (v == 0) { write_(1, "0", 1); return; }
	while (v > 0 && i < (int)sizeof (b)) { b[i++] = (char)('0' + v % 10); v /= 10; }
	while (i-- > 0) write_(1, &b[i], 1);
}

static void
spin(volatile long n)
{
	while (n-- > 0)
		;
}

int
main(int argc, char **argv, char **envp)
{
	long pid, shpid, st, reaped, nreaped = 0;
	static char *shargv[2] = { "/bin/sh", 0 };
	(void) argc; (void) argv; (void) envp;

	puts_("[init] pid ");
	putn(getpid_());
	puts_(" running: the first user process\n");

	/* --- spawn the orphan maker (proves init adopts + reaps orphans) --- */
	pid = fork_();
	if (pid == 0) {
		/* orphan maker: fork a grandchild, then exit at once.  The
		   grandchild outlives us and is reparented to init (pid 1). */
		long gc = fork_();
		if (gc == 0) {
			spin(2000000);		/* outlive the parent */
			puts_("[orphan] grandchild (adopted by init) exiting\n");
			exit_(23);
		}
		puts_("[orphan] maker exiting; grandchild pid ");
		putn(gc);
		puts_(" is now orphaned -> init adopts it\n");
		exit_(0);
	}

	/* --- launch the shell with /etc/rc as its stdin --------------------- */
	shpid = fork_();
	if (shpid == 0) {
		int rc = open_("/etc/rc", 0);
		if (rc >= 0) {
			dup2_(rc, 0);		/* scripted stdin */
			if (rc != 0)
				close_(rc);
		}
		execve_("/bin/sh", shargv);
		puts_("[init] exec /bin/sh FAILED\n");
		exit_(127);
	}
	puts_("[init] forked shell pid ");
	putn(shpid);
	puts_("\n");

	/* --- reap loop: reap the shell, the orphan maker, and the adopted
	   grandchild, until no children remain (wait returns -1). --- */
	for (;;) {
		st = -1;
		reaped = wait_(&st);
		if (reaped < 0)
			break;			/* no children left */
		nreaped++;
		puts_("[init] reaped pid ");
		putn(reaped);
		puts_(" status ");
		putn(st);
		if (reaped == shpid)
			puts_(" (the shell)");
		puts_("\n");
	}
	puts_("[init] all children reaped; count ");
	putn(nreaped);
	puts_(". init done.\n");
	exit_(0);
	return (0);
}
