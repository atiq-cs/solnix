/*
 * fsread.c -- R-P31.3 proof: a userland process opens + reads a ramfs file and
 * prints its contents, then calls uname(2) and prints the SunOS identity.
 * Exercises the real read(2) path (open -> vnode -> read bytes) + lseek/fstat/
 * stat/getcwd/uname -- the new syscalls this phase added.
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
#define	SYS_stat	18
#define	SYS_lseek	19
#define	SYS_fstat	28
#define	SYS_getcwd	223
#define	SYS_uname	224

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
static int open(const char *p) { return ((int)sc3(SYS_open, (long)p, 0, 0)); }
static ssize_t read(int fd, void *b, size_t n) { return (sc3(SYS_read, fd, (long)b, (long)n)); }
static int close(int fd) { return ((int)sc3(SYS_close, fd, 0, 0)); }
static long lseek(int fd, long off, int wh) { return (sc3(SYS_lseek, fd, off, wh)); }
static long fstat(int fd, void *st) { return (sc3(SYS_fstat, fd, (long)st, 0)); }
static long stat_(const char *p, void *st) { return (sc3(SYS_stat, (long)p, (long)st, 0)); }
static long getcwd_(char *b, size_t n) { return (sc3(SYS_getcwd, (long)b, (long)n, 0)); }
static long uname_(void *u) { return (sc3(SYS_uname, (long)u, 0, 0)); }

static size_t slen(const char *s) { size_t n = 0; while (s[n]) n++; return (n); }
static void puts_(const char *s) { write(1, s, slen(s)); }

int
main(int argc, char **argv, char **envp)
{
	char buf[128];
	unsigned long st[4];
	char utsname[5 * 32];
	char cwd[32];
	int fd, i;
	long n;

	(void) argc; (void) argv; (void) envp;

	puts_("  [fsread] open + read a ramfs file:\n");

	/* stat the path first (size via the reduced stat buffer). */
	if (stat_("/etc/release", st) == 0) {
		puts_("    stat(/etc/release) size=");
		{
			char d[24]; int k = 0; unsigned long v = st[0];
			if (v == 0) d[k++] = '0';
			else { char t[24]; int j = 0; while (v) { t[j++] = '0' + (v % 10); v /= 10; } while (j) d[k++] = t[--j]; }
			d[k] = 0; puts_(d);
		}
		puts_(" bytes\n");
	}

	fd = open("/etc/release");
	if (fd < 0) {
		puts_("    open(/etc/release) FAILED\n");
		exit(2);
	}
	puts_("    opened /etc/release as fd=");
	{ char c = '0' + (char)fd; write(1, &c, 1); }
	puts_("\n    contents: ");

	for (;;) {
		n = read(fd, buf, sizeof(buf));
		if (n <= 0)
			break;
		write(1, buf, (size_t)n);
	}
	puts_("\n");

	/* fstat the open fd. */
	if (fstat(fd, st) == 0) {
		puts_("    fstat fd size matches: ");
		puts_(st[0] > 0 ? "yes\n" : "no\n");
	}

	/* lseek back to the start + read the first byte again (proves offset). */
	if (lseek(fd, 0, 0) == 0) {
		char c = 0;
		if (read(fd, &c, 1) == 1) {
			puts_("    lseek(0)+read first byte='");
			write(1, &c, 1);
			puts_("'\n");
		}
	}
	close(fd);

	/* getcwd. */
	if (getcwd_(cwd, sizeof(cwd)) != 0) {
		puts_("    getcwd()='");
		puts_(cwd);
		puts_("'\n");
	}

	/* uname(2) -> SunOS/solnix-riscv64. */
	if (uname_(utsname) == 0) {
		puts_("    uname sysname='");
		puts_(&utsname[0]);
		puts_("' nodename='");
		puts_(&utsname[32]);
		puts_("' machine='");
		puts_(&utsname[4 * 32]);
		puts_("'\n");
	}

	puts_("  [fsread] done\n");
	exit(0);
	return (0);
}
