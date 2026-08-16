/*
 * loop.c -- R-P37.2: the /bin/loop command.  Prints a start marker, then spins
 * forever.  Used by the job-control boot proof: the shell runs it in the
 * foreground, a ^C on the console delivers SIGINT to its process group, the
 * default action terminates it, and the shell reaps it + re-prompts (proving
 * ^C interrupts the running command, not the shell).
 */
typedef unsigned long size_t;
#define	SYS_exit	1
#define	SYS_write	4
#define	SYS_getpid	20
static long sc0(long nr)
{
	register long a7 __asm__("a7") = nr;
	register long a0 __asm__("a0");
	__asm__ __volatile__("ecall" : "=r"(a0) : "r"(a7) : "memory");
	return (a0);
}
static long sc3(long nr, long x0, long x1, long x2)
{
	register long a7 __asm__("a7") = nr;
	register long a0 __asm__("a0") = x0;
	register long a1 __asm__("a1") = x1;
	register long a2 __asm__("a2") = x2;
	__asm__ __volatile__("ecall" : "+r"(a0) : "r"(a7), "r"(a1), "r"(a2) : "memory");
	return (a0);
}
static void puts_(const char *s)
{
	size_t n = 0;
	while (s[n]) n++;
	(void) sc3(SYS_write, 1, (long)s, (long)n);
}
int
main(int argc, char **argv, char **envp)
{
	volatile unsigned long i = 0;
	(void) argc; (void) argv; (void) envp;
	puts_("loop: running (send ^C to interrupt)\n");
	/*
	 * Spin, crossing the kernel/user boundary periodically (a cheap getpid
	 * ecall) so a posted SIGINT/SIGTSTP is delivered on the syscall-return
	 * edge without waiting for a timer preempt -- prompt, quiet interruption.
	 */
	for (;;) {
		i++;
		if ((i & 0xffff) == 0)
			(void) sc0(SYS_getpid);
	}
	return (0);
}
