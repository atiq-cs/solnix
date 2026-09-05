/*
 * fdtest.c -- R-P34.2 proof: fd management (dup/dup2/fcntl + FD_CLOEXEC).
 *
 *   1. dup2 REDIRECT: open a writable tmpfs file, dup2 it onto fd 1 (stdout),
 *      write through fd 1, restore stdout, then read the file back to prove the
 *      write landed in the file (stdout was redirected to the file).
 *   2. fcntl(F_DUPFD/F_GETFD/F_SETFD): dup an fd to a chosen slot, set + query
 *      FD_CLOEXEC via fcntl.
 *   3. CLOEXEC ACROSS EXEC: open a file, set FD_CLOEXEC on it, then exec the
 *      fdexecee program.  The CLOEXEC fd must be CLOSED in the new image (a
 *      read on it fails) while a non-CLOEXEC fd stays open (a read succeeds).
 *
 * Self-contained inline syscall stubs (illumos riscv64 ABI). No libc beyond crt.
 */

typedef unsigned long size_t;
typedef long ssize_t;

#define	SYS_exit	1
#define	SYS_read	3
#define	SYS_write	4
#define	SYS_open	5
#define	SYS_close	6
#define	SYS_lseek	19
#define	SYS_execve	59
#define	SYS_dup		241
#define	SYS_dup2	242
#define	SYS_fcntl	243

#define	O_CREAT		0x100
#define	F_DUPFD		0
#define	F_GETFD		1
#define	F_SETFD		2
#define	FD_CLOEXEC	1

static long
sc1(long nr, long a)
{
	register long a7 __asm__("a7") = nr;
	register long a0 __asm__("a0") = a;
	__asm__ __volatile__("ecall" : "+r"(a0) : "r"(a7) : "memory");
	return (a0);
}
static long
sc2(long nr, long x0, long x1)
{
	register long a7 __asm__("a7") = nr;
	register long a0 __asm__("a0") = x0;
	register long a1 __asm__("a1") = x1;
	__asm__ __volatile__("ecall" : "+r"(a0) : "r"(a7), "r"(a1) : "memory");
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
static ssize_t read_(int fd, void *b, size_t n) { return (sc3(SYS_read, fd, (long)b, (long)n)); }
static int open_(const char *p, int fl) { return ((int)sc2(SYS_open, (long)p, fl)); }
static int close_(int fd) { return ((int)sc1(SYS_close, fd)); }
static long lseek_(int fd, long off, int wh) { return (sc3(SYS_lseek, fd, off, wh)); }
static int dup_(int fd) { return ((int)sc1(SYS_dup, fd)); }
static int dup2_(int o, int n) { return ((int)sc2(SYS_dup2, o, n)); }
static long fcntl_(int fd, int cmd, long arg) { return (sc3(SYS_fcntl, fd, cmd, arg)); }
static long execve_(const char *p) { return (sc3(SYS_execve, (long)p, 0, 0)); }
static void exit(int s) { sc3(SYS_exit, s, 0, 0); for (;;); }

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

int
main(int argc, char **argv, char **envp)
{
	int f, d, fl;
	char buf[64];
	long r;
	(void) argc; (void) argv; (void) envp;

	puts_("  [fdtest] fd management: dup/dup2/fcntl + FD_CLOEXEC\n");

	/* --- part 1: dup2 redirects stdout to a file --------------------- */
	f = open_("/tmp/fdout.txt", O_CREAT);
	if (f < 0) { puts_("  [fdtest] open FAILED\n"); exit(1); }
	dup2_(f, 1);			/* fd 1 (stdout) now points at the file */
	puts_("REDIRECTED-STDOUT-LINE\n");	/* goes to the file, not console */
	dup2_(2, 1);			/* restore stdout from stderr(console) */
	/* read the file back: it must contain the redirected line. */
	lseek_(f, 0, 0);
	r = read_(f, buf, sizeof (buf) - 1);
	if (r > 0) buf[r] = 0; else buf[0] = 0;
	puts_("    [fdtest] file contents after dup2 redirect: ");
	puts_(buf);
	if (buf[0] == 'R')
		puts_("    [fdtest] dup2 redirected stdout to the file (OK)\n");
	else
		puts_("    [fdtest] BUG: dup2 redirect did not land in the file\n");
	close_(f);

	/* --- part 2: fcntl F_DUPFD / F_GETFD / F_SETFD ------------------- */
	f = open_("/tmp/fdout.txt", 0);
	d = (int)fcntl_(f, F_DUPFD, 7);		/* dup f to a slot >= 7 */
	puts_("    [fdtest] fcntl(F_DUPFD, 7) -> fd ");
	putn(d);
	puts_("\n");
	fcntl_(d, F_SETFD, FD_CLOEXEC);		/* mark it close-on-exec */
	fl = (int)fcntl_(d, F_GETFD, 0);
	puts_((fl & FD_CLOEXEC) ?
	    "    [fdtest] fcntl(F_SETFD/F_GETFD) FD_CLOEXEC set (OK)\n" :
	    "    [fdtest] BUG: FD_CLOEXEC not readable back\n");
	close_(f);

	/* --- part 3: CLOEXEC across exec --------------------------------- */
	/* fd `d` (from part 2) is CLOEXEC; open another fd that is NOT. */
	{
		int keep = open_("/tmp/fdout.txt", 0);
		/* fdexecee reads the two fds; put them at known slots. */
		dup2_(d, 9);		/* CLOEXEC fd -> slot 9 (dup2 CLEARS it) */
		fcntl_(9, F_SETFD, FD_CLOEXEC);	/* re-mark slot 9 CLOEXEC */
		dup2_(keep, 8);		/* non-CLOEXEC fd -> slot 8 */
		puts_("    [fdtest] exec fdexecee: fd 9 is CLOEXEC (should be "
		    "closed), fd 8 is inherited\n");
		execve_("/bin/fdexecee");
		puts_("  [fdtest] BUG: exec returned\n");
		exit(1);
	}
	return (0);
}
