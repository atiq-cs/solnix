/*
 * pipetest.c -- R-P33.2 proof: pipe(2) IPC + directories.
 *
 *   1. pipe(fds) -> a read end (fds[0]) + a write end (fds[1]).
 *   2. fork() -- the child inherits BOTH fds.  The child closes the write end +
 *      reads from fds[0] (BLOCKS until the parent writes); the parent closes the
 *      read end + writes a message to fds[1].  The child prints what it read.
 *   3. mkdir("/tmp/d") + create two files under it, then open("/tmp/d") +
 *      getdents to list the directory entries.
 *
 * Self-contained inline syscall stubs (illumos riscv64 ABI: a7=nr, a0..a5=args,
 * result in a0), NO libc beyond crt.
 */

typedef unsigned long size_t;
typedef long ssize_t;

#define	SYS_exit	1
#define	SYS_read	3
#define	SYS_write	4
#define	SYS_open	5
#define	SYS_close	6
#define	SYS_wait	107
#define	SYS_fork	142
#define	SYS_pipe	235
#define	SYS_mkdir	236
#define	SYS_getdents	237

#define	O_CREAT		0x100

static long
sc1(long nr, long x0)
{
	register long a7 __asm__("a7") = nr;
	register long a0 __asm__("a0") = x0;
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
static long sc0(long nr)
{
	register long a7 __asm__("a7") = nr;
	register long a0 __asm__("a0");
	__asm__ __volatile__("ecall" : "=r"(a0) : "r"(a7) : "memory");
	return (a0);
}

static ssize_t write(int fd, const void *b, size_t n) { return (sc3(SYS_write, fd, (long)b, (long)n)); }
static ssize_t read(int fd, void *b, size_t n) { return (sc3(SYS_read, fd, (long)b, (long)n)); }
static void exit(int s) { sc3(SYS_exit, s, 0, 0); for (;;); }
static long fork(void) { return (sc0(SYS_fork)); }
static long wait_(long *st) { return (sc3(SYS_wait, (long)st, 0, 0)); }
static int close(int fd) { return ((int)sc1(SYS_close, fd)); }
static int pipe(int *fds) { return ((int)sc1(SYS_pipe, (long)fds)); }
static int open2(const char *p, int fl) { return ((int)sc3(SYS_open, (long)p, fl, 0)); }
static int mkdir(const char *p) { return ((int)sc1(SYS_mkdir, (long)p)); }
static long getdents(int fd, char *b, size_t n) { return (sc3(SYS_getdents, fd, (long)b, (long)n)); }

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

static const char pmsg[] = "hello from parent over the pipe";

int
main(int argc, char **argv, char **envp)
{
	int fds[2];
	long pid;
	long st = -1;
	char buf[64];
	(void) argc; (void) argv; (void) envp;

	puts_("  [pipetest] pipe(2) IPC across fork:\n");

	if (pipe(fds) != 0) {
		puts_("    pipe() FAILED\n");
		exit(1);
	}
	puts_("    pipe fds: read=");
	putn(fds[0]);
	puts_(" write=");
	putn(fds[1]);
	puts_("\n");

	pid = fork();
	if (pid == 0) {
		/* child: read end only; blocks until the parent writes. */
		long n;
		close(fds[1]);
		puts_("    [child] reading from the pipe (blocks)...\n");
		n = read(fds[0], buf, sizeof(buf));
		puts_("    [child] read ");
		putn(n);
		puts_(" bytes: '");
		if (n > 0)
			write(1, buf, (size_t)n);
		puts_("'\n");
		close(fds[0]);
		exit(0);
	}

	/* parent: write end only; send the message. */
	close(fds[0]);
	{
		long n = write(fds[1], pmsg, slen(pmsg));
		puts_("    [parent] wrote ");
		putn(n);
		puts_(" bytes to the pipe\n");
	}
	close(fds[1]);
	wait_(&st);
	puts_("    [parent] child exited status=");
	putn(st);
	puts_("\n");

	/* --- directories: mkdir + create files + getdents ------------------ */
	puts_("  [pipetest] directories: mkdir + readdir over tmpfs:\n");
	if (mkdir("/tmp/d") == 0)
		puts_("    mkdir(/tmp/d) OK\n");
	else
		puts_("    mkdir(/tmp/d) FAILED\n");
	{
		int fd;
		fd = open2("/tmp/d/one", O_CREAT);
		if (fd >= 0) { write(fd, "1", 1); close(fd); }
		fd = open2("/tmp/d/two", O_CREAT);
		if (fd >= 0) { write(fd, "22", 2); close(fd); }
	}
	{
		int dfd = open2("/tmp/d", 0);
		int count = 0;
		if (dfd < 0) {
			puts_("    open(/tmp/d) FAILED\n");
		} else {
			long n;
			puts_("    readdir(/tmp/d):\n");
			while ((n = getdents(dfd, buf, sizeof(buf))) > 0) {
				puts_("      entry: ");
				write(1, buf, (size_t)n);
				puts_("\n");
				count++;
			}
			close(dfd);
			puts_("    dir entries listed: ");
			putn(count);
			puts_(count == 2 ? " (mkdir+readdir OK)\n" :
			    " (unexpected count)\n");
		}
	}

	puts_("  [pipetest] done\n");
	exit(0);
	return (0);
}
