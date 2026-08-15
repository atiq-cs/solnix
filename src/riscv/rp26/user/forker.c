/*
 * forker.c -- the R-P26 riscv64-solaris userland process that proves
 * MULTIPROCESS: a parent forks a child, both run through the dispatcher and
 * print distinct output (their own pid), the child exits, and the parent
 * waits + reaps it and prints the reaped pid + status.  This is the first
 * riscv64-solaris fork(2)/wait(2).
 *
 * Self-contained: inline riscv64 syscall stubs (illumos ABI: a7=nr,
 * a0..a5=args, ecall, result in a0), NO libc beyond the R-P20 crt _start.
 *
 * CRIB PROVENANCE: the fork -> "in child pid==0 / in parent pid>0" branch is
 * the POSIX/illumos fork(2) contract; the syscall numbers (SYS_exit=1,
 * SYS_write=4, SYS_getpid=20, SYS_forksys=142, SYS_waitid=107) are the native
 * illumos <sys/syscall.h>; the per-syscall stub shape (li a7,NR; ecall) is the
 * illumos libc SYSCALL()/SYSTRAP() csu idiom + the RISC-V psABI arg registers.
 */

typedef unsigned long size_t;
typedef long ssize_t;

#define	SYS_exit	1
#define	SYS_write	4
#define	SYS_getpid	20
#define	SYS_execve	59	/* reduced: exec the embedded execee image */
#define	SYS_fork	142	/* reduced forksys: returns pid (parent) / 0 (child) */
#define	SYS_wait	107	/* reduced waitid: wait any child, return pid, *status */

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

static ssize_t
write(int fd, const void *buf, size_t n)
{
	return (sc3(SYS_write, fd, (long)buf, (long)n));
}

static void
exit(int status)
{
	sc3(SYS_exit, status, 0, 0);
	for (;;)
		;
}

static long fork(void) { return (sc0(SYS_fork)); }
static long getpid(void) { return (sc0(SYS_getpid)); }
static long wait_(long *status) { return (sc3(SYS_wait, (long)status, 0, 0)); }
static long execve(const char *p, char **av, char **ev)
{ return (sc3(SYS_execve, (long)p, (long)av, (long)ev)); }

static size_t
slen(const char *s)
{
	size_t n = 0;
	while (s[n])
		n++;
	return (n);
}

static void
puts_(const char *s)
{
	write(1, s, slen(s));
}

/* print a small unsigned decimal (pids/status are small). */
static void
putn(long v)
{
	char b[24];
	int i = 0;
	if (v < 0) { write(1, "-", 1); v = -v; }
	if (v == 0) { write(1, "0", 1); return; }
	while (v > 0 && i < (int)sizeof (b)) { b[i++] = (char)('0' + v % 10); v /= 10; }
	while (i-- > 0)
		write(1, &b[i], 1);
}

int
main(int argc, char **argv, char **envp)
{
	long pid, status = -1, reaped;
	(void) argc; (void) argv; (void) envp;

	/* --- phase 1: fork + wait a plain child (the multiprocess headline) --- */
	pid = fork();
	if (pid == 0) {
		/* child */
		puts_("  [child]  running; my pid=");
		putn(getpid());
		puts_("\n");
		exit(7);		/* distinct exit status for the reap proof */
	}

	/* parent */
	puts_("  [parent] forked child pid=");
	putn(pid);
	puts_("; my pid=");
	putn(getpid());
	puts_("\n");

	reaped = wait_(&status);
	puts_("  [parent] wait(2) reaped pid=");
	putn(reaped);
	puts_(" status=");
	putn(status);
	puts_("\n");

	/* --- phase 2: fork + exec a DIFFERENT program + wait (the exec proof) --- */
	pid = fork();
	if (pid == 0) {
		puts_("  [child]  exec(2)ing a new program image...\n");
		execve("execee", 0, 0);
		puts_("  [child]  exec FAILED\n");
		exit(127);
	}
	puts_("  [parent] forked exec-child pid=");
	putn(pid);
	puts_("\n");
	status = -1;
	reaped = wait_(&status);
	puts_("  [parent] wait(2) reaped exec-child pid=");
	putn(reaped);
	puts_(" status=");
	putn(status);
	puts_("\n");

	return (0);
}
