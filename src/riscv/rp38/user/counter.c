/*
 * counter.c -- R-P38.2 job-control demo command.  Prints "counter: N" for a
 * bounded number of ticks (each tick spins a busy loop, crossing the kernel
 * boundary via getpid so a posted SIGTSTP/SIGCONT is delivered promptly), then
 * exits.  Unlike /bin/loop (spins forever, for the ^C test), counter COMPLETES,
 * so the shell can launch it with '&', bring it to the foreground with fg, ^Z
 * it (stop), resume it with bg (SIGCONT), and finally reap it when it finishes
 * -- the full fg/bg lifecycle.
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
static void putn(unsigned long v)
{
	char b[24]; int i = 0;
	if (v == 0) { (void) sc3(SYS_write, 1, (long)"0", 1); return; }
	while (v > 0 && i < 24) { b[i++] = (char)('0' + v % 10); v /= 10; }
	while (i-- > 0) (void) sc3(SYS_write, 1, (long)&b[i], 1);
}
int
main(int argc, char **argv, char **envp)
{
	int n, ticks = 8;
	(void) envp;
	/* R-P38.2: optional argv[1] tick count (real argv use through the shell). */
	if (argc > 1) {
		const char *a = argv[1];
		int v = 0, k = 0;
		while (a[k] >= '0' && a[k] <= '9') { v = v * 10 + (a[k] - '0'); k++; }
		if (v > 0) ticks = v;
	}
	puts_("counter: start\n");
	for (n = 1; n <= ticks; n++) {
		volatile unsigned long i;
		for (i = 0; i < 0x2000000UL; i++)
			if ((i & 0xffff) == 0)
				(void) sc0(SYS_getpid);	/* delivery edge */
		puts_("counter: ");
		putn((unsigned long)n);
		puts_("\n");
	}
	puts_("counter: done\n");
	return (0);
}
