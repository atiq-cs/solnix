/*
 * fdexecee.c -- R-P34.2 exec target for the CLOEXEC-across-exec proof.  Run in
 * place of fdtest via execve.  fd 9 was marked FD_CLOEXEC in the old image so
 * it must be CLOSED here (a read fails); fd 8 was NOT close-on-exec so it must
 * still be OPEN (a read succeeds).  Prints the outcome + exits.
 */

typedef unsigned long size_t;
typedef long ssize_t;

#define	SYS_exit	1
#define	SYS_read	3
#define	SYS_write	4

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
static ssize_t read_(int fd, void *b, size_t n) { return (sc3(SYS_read, fd, (long)b, (long)n)); }
static void exit(int s) { sc3(SYS_exit, s, 0, 0); for (;;); }
static size_t slen(const char *s) { size_t n = 0; while (s[n]) n++; return (n); }
static void puts_(const char *s) { write(1, s, slen(s)); }

int
main(int argc, char **argv, char **envp)
{
	char buf[16];
	long r9, r8;
	(void) argc; (void) argv; (void) envp;

	puts_("    [fdexecee] NEW image after exec: probing inherited fds\n");
	r9 = read_(9, buf, sizeof (buf));	/* CLOEXEC fd: should be closed */
	r8 = read_(8, buf, sizeof (buf));	/* non-CLOEXEC fd: should read */

	puts_((r9 < 0) ?
	    "    [fdexecee] CLOEXEC fd 9 is CLOSED after exec (OK)\n" :
	    "    [fdexecee] BUG: CLOEXEC fd 9 survived exec\n");
	puts_((r8 >= 0) ?
	    "    [fdexecee] non-CLOEXEC fd 8 survived exec (OK)\n" :
	    "    [fdexecee] BUG: non-CLOEXEC fd 8 was closed\n");
	if (r9 < 0 && r8 >= 0)
		puts_("    [fdexecee] CLOEXEC-across-exec PROVEN\n");
	exit(0);
	return (0);
}
