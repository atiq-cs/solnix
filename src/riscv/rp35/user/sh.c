/*
 * sh.c -- R-P35.3: a minimal interactive shell (/bin/sh).  Reads a line from
 * stdin (fd 0), splits it into whitespace-separated words (argv), and:
 *   - runs a builtin (exit),
 *   - or fork+exec+waits an external command by path (a bare name is looked up
 *     under /bin/),
 *   - or, if the line has a single `|`, runs "cmd1 | cmd2" by wiring cmd1's
 *     stdout to cmd2's stdin through a pipe(2) + dup2(2) (the R-P33 pipe +
 *     R-P34 dup2), forking both halves and waiting for both.
 *
 * Non-interactive-verifiable: init opens the ramfs script /etc/rc and dup2's it
 * onto the shell's fd 0, so the shell reads its commands from the script (a
 * scripted stdin) rather than a live console -- the boot is deterministic.
 *
 * Self-contained inline syscall stubs (illumos riscv64 ABI: a7=nr, a0..=args,
 * result in a0), NO libc beyond crt.
 *
 * CRIB PROVENANCE: the read-line / parse-argv / fork-exec-wait loop and the
 * "pipe + fork + dup2 the ends" pipeline mechanism are the xv6 sh.c runcmd()
 * (EXEC / PIPE nodes) + the BSD/illumos /bin/sh execution model, reduced to one
 * pipe stage and whitespace tokenizing (no quoting/globbing/redirs yet).
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
#define	SYS_dup2	242
#define	SYS_execve	59

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

static ssize_t read_(int fd, void *b, size_t n) { return (sc3(SYS_read, fd, (long)b, (long)n)); }
static ssize_t write_(int fd, const void *b, size_t n) { return (sc3(SYS_write, fd, (long)b, (long)n)); }
static void exit_(int s) { sc1(SYS_exit, s); for (;;); }
static long fork_(void) { return (sc0(SYS_fork)); }
static long wait_(long *st) { return (sc3(SYS_wait, (long)st, 0, 0)); }
static int close_(int fd) { return ((int)sc1(SYS_close, fd)); }
static int pipe_(int *fds) { return ((int)sc1(SYS_pipe, (long)fds)); }
static int dup2_(int o, int n) { return ((int)sc2(SYS_dup2, o, n)); }
static long execve_(const char *p, char **av) { return (sc3(SYS_execve, (long)p, (long)av, 0)); }

static size_t slen(const char *s) { size_t n = 0; while (s[n]) n++; return (n); }
static void puts_(const char *s) { write_(1, s, slen(s)); }

static int
streq(const char *a, const char *b)
{
	size_t i = 0;
	while (a[i] && a[i] == b[i])
		i++;
	return (a[i] == b[i]);
}

/*
 * resolve -- turn a bare command name into a path the ramfs holds.  A name
 * with a leading '/' is used as-is; otherwise it is looked up under /bin/.
 * Writes into `out` (>= 72 bytes) and returns it.
 */
static char *
resolve(const char *name, char *out)
{
	size_t i = 0, j = 0;
	if (name[0] == '/') {
		while (name[i] && j < 71)
			out[j++] = name[i++];
	} else {
		const char *pfx = "/bin/";
		while (pfx[i]) { out[j++] = pfx[i++]; }
		i = 0;
		while (name[i] && j < 71)
			out[j++] = name[i++];
	}
	out[j] = 0;
	return (out);
}

#define	MAXARG	8

/*
 * tokenize -- split `line` in place into up to MAXARG words (NUL-terminating
 * each), filling argv[] + a trailing NULL.  Returns argc.  Whitespace is space/
 * tab; the pipe '|' has already been split out by the caller.
 */
static int
tokenize(char *line, char **argv)
{
	int argc = 0;
	char *p = line;
	while (*p && argc < MAXARG) {
		while (*p == ' ' || *p == '\t')
			p++;
		if (*p == 0)
			break;
		argv[argc++] = p;
		while (*p && *p != ' ' && *p != '\t')
			p++;
		if (*p)
			*p++ = 0;
	}
	argv[argc] = 0;
	return (argc);
}

/* exec argv[0] (resolved to a path) -- replaces this (child) image. */
static void
exec_cmd(char **argv)
{
	char path[72];
	char *av[MAXARG + 1];
	int i;
	if (argv[0] == 0)
		exit_(0);
	(void) resolve(argv[0], path);
	av[0] = path;
	for (i = 1; argv[i] != 0 && i <= MAXARG; i++)
		av[i] = argv[i];
	av[i] = 0;
	execve_(path, av);
	puts_("sh: exec failed: ");
	puts_(argv[0]);
	puts_("\n");
	exit_(127);
}

/*
 * run_line -- run one command line.  If it contains a single '|', split it
 * into left|right and run them as a pipeline (left's stdout -> right's stdin);
 * otherwise run the single command.  Blank/comment (#) lines are ignored.
 */
static void
run_line(char *line)
{
	char *bar = 0;
	char *p;
	long st;

	/* strip a trailing newline + skip blank/comment lines. */
	for (p = line; *p; p++) {
		if (*p == '\n' || *p == '\r') { *p = 0; break; }
	}
	for (p = line; *p == ' ' || *p == '\t'; p++)
		;
	if (*p == 0 || *p == '#')
		return;

	/* find a single '|'. */
	for (p = line; *p; p++) {
		if (*p == '|') { bar = p; break; }
	}

	if (bar != 0) {
		/* --- pipeline: left | right --- */
		char *largv[MAXARG + 1], *rargv[MAXARG + 1];
		int fds[2];
		long p1, p2;
		*bar = 0;
		(void) tokenize(line, largv);
		(void) tokenize(bar + 1, rargv);
		if (pipe_(fds) != 0) {
			puts_("sh: pipe failed\n");
			return;
		}
		p1 = fork_();
		if (p1 == 0) {
			/* left: stdout -> pipe write end. */
			dup2_(fds[1], 1);
			close_(fds[0]);
			close_(fds[1]);
			exec_cmd(largv);
		}
		p2 = fork_();
		if (p2 == 0) {
			/* right: stdin -> pipe read end. */
			dup2_(fds[0], 0);
			close_(fds[0]);
			close_(fds[1]);
			exec_cmd(rargv);
		}
		close_(fds[0]);
		close_(fds[1]);
		st = -1; wait_(&st);
		st = -1; wait_(&st);
		return;
	}

	/* --- single command --- */
	{
		char *argv[MAXARG + 1];
		long pid;
		int argc = tokenize(line, argv);
		if (argc == 0)
			return;
		if (streq(argv[0], "exit"))
			exit_(0);
		pid = fork_();
		if (pid == 0)
			exec_cmd(argv);
		st = -1;
		wait_(&st);
	}
}

int
main(int argc, char **argv, char **envp)
{
	static char buf[512];
	char line[256];
	long n, pos = 0;
	int li = 0;
	(void) argc; (void) argv; (void) envp;

	puts_("solnix sh: reading commands from stdin\n");

	/*
	 * Read stdin into `buf`, splitting on '\n' into lines run one at a
	 * time.  stdin is the /etc/rc script (init dup2'd it onto fd 0), so the
	 * loop ends at EOF (read returns 0) -- a deterministic scripted session.
	 * A live console would block in read here instead.
	 */
	n = read_(0, buf, sizeof(buf) - 1);
	if (n <= 0) {
		puts_("sh: no input (EOF); exiting\n");
		exit_(0);
	}
	buf[n] = 0;
	for (pos = 0; pos < n; pos++) {
		char c = buf[pos];
		if (c == '\n' || li >= (int)sizeof(line) - 1) {
			line[li] = 0;
			puts_("sh$ ");
			puts_(line);
			puts_("\n");
			run_line(line);
			li = 0;
		} else {
			line[li++] = c;
		}
	}
	if (li > 0) {			/* last line without a trailing newline */
		line[li] = 0;
		puts_("sh$ ");
		puts_(line);
		puts_("\n");
		run_line(line);
	}
	puts_("sh: end of script; exiting\n");
	exit_(0);
	return (0);
}
