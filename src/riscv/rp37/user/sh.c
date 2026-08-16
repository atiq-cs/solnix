/*
 * sh.c -- R-P37.1/.2: an INTERACTIVE shell (/bin/sh).  Reads one line at a time
 * from stdin (fd 0 = the live console tty via the kernel line discipline),
 * prints a prompt, tokenizes argv, and:
 *   - runs a builtin (exit, cd, mkdir, rmdir),
 *   - or fork+exec+waits an external command (bare name looked up under /bin/),
 *   - or runs a "cmd1 | cmd2" pipeline (pipe + fork + dup2),
 *   with > / < file redirection (O_CREAT|O_TRUNC for >).
 *
 * R-P37.2 JOB CONTROL: before running a foreground command the shell puts the
 * child in its OWN process group (setpgid) and makes that group the tty
 * foreground group (tty_setfg), so a ^C on the console delivers SIGINT to the
 * running command -- not to the shell.  When the command finishes the shell
 * reclaims the tty (tty_setfg to its own group) and re-prompts.  A ^Z stops the
 * command (SIGTSTP) and the shell reports the stopped job (WUNTRACED wait).
 *
 * Interactive-verifiable: the boot proof feeds the console via qemu's piped
 * stdin (a here-doc of commands); the shell echoes each typed line, runs it,
 * and ^D (EOF) exits the shell -- init then respawns it (the inittab respawn).
 *
 * CRIB PROVENANCE: the read-line/parse/fork-exec-wait loop + pipeline is xv6
 * sh.c; the per-command process group + tcsetpgrp(tty, pgrp) foreground-group
 * handoff around a foreground job is the illumos/BSD shell job-control model
 * (setpgid in the child + the terminal's t_pgrp) reduced to a single fg job.
 */

typedef unsigned long size_t;
typedef long ssize_t;

#define	SYS_exit	1
#define	SYS_read	3
#define	SYS_write	4
#define	SYS_open	5
#define	SYS_close	6
#define	SYS_getpid	20
#define	SYS_wait	107
#define	SYS_fork	142
#define	SYS_pipe	235
#define	SYS_dup2	242
#define	SYS_execve	59
#define	SYS_chdir	247	/* R-P36 */
#define	SYS_setpgid	249	/* R-P37.2 */
#define	SYS_tty_setfg	251	/* R-P37.2 */
#define	SYS_rmdir	252	/* R-P37.3 */
#define	SYS_mkdir	236	/* R-P33.2 */
#define	O_CREAT		0x100	/* R-P36 */
#define	O_TRUNC		0x200	/* R-P37.3 */

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
static long getpid_(void) { return (sc0(SYS_getpid)); }
static long wait_(long *st) { return (sc3(SYS_wait, (long)st, 0, 0)); }
static int close_(int fd) { return ((int)sc1(SYS_close, fd)); }
static int pipe_(int *fds) { return ((int)sc1(SYS_pipe, (long)fds)); }
static int dup2_(int o, int n) { return ((int)sc2(SYS_dup2, o, n)); }
static long execve_(const char *p, char **av) { return (sc3(SYS_execve, (long)p, (long)av, 0)); }
static int open_(const char *p, int fl) { return ((int)sc3(SYS_open, (long)p, fl, 0)); }
static int chdir_(const char *p) { return ((int)sc1(SYS_chdir, (long)p)); }
static int mkdir_(const char *p) { return ((int)sc1(SYS_mkdir, (long)p)); }
static int rmdir_(const char *p) { return ((int)sc1(SYS_rmdir, (long)p)); }
static int setpgid_(int pid, int pgid) { return ((int)sc2(SYS_setpgid, pid, pgid)); }
static int tty_setfg_(int pgrp) { return ((int)sc1(SYS_tty_setfg, pgrp)); }

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

static int
streq(const char *a, const char *b)
{
	size_t i = 0;
	while (a[i] && a[i] == b[i])
		i++;
	return (a[i] == b[i]);
}

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

static long g_shpid;			/* the shell's own pid (its process group) */

/*
 * run_line -- run one command line.  Pipeline (single '|'), else a single
 * command with > / < redirection + builtins (exit/cd/mkdir/rmdir).  A foreground
 * external command runs in its own process group with the tty handed to it, so
 * a ^C on the console interrupts IT, not the shell.
 */
static void
run_line(char *line)
{
	char *bar = 0;
	char *p;
	long st;

	for (p = line; *p; p++)
		if (*p == '\n' || *p == '\r') { *p = 0; break; }
	for (p = line; *p == ' ' || *p == '\t'; p++)
		;
	if (*p == 0 || *p == '#')
		return;

	for (p = line; *p; p++)
		if (*p == '|') { bar = p; break; }

	if (bar != 0) {
		char *largv[MAXARG + 1], *rargv[MAXARG + 1];
		int fds[2];
		long p1, p2;
		*bar = 0;
		(void) tokenize(line, largv);
		(void) tokenize(bar + 1, rargv);
		if (pipe_(fds) != 0) { puts_("sh: pipe failed\n"); return; }
		p1 = fork_();
		if (p1 == 0) {
			dup2_(fds[1], 1); close_(fds[0]); close_(fds[1]);
			exec_cmd(largv);
		}
		p2 = fork_();
		if (p2 == 0) {
			dup2_(fds[0], 0); close_(fds[0]); close_(fds[1]);
			exec_cmd(rargv);
		}
		close_(fds[0]); close_(fds[1]);
		st = -1; wait_(&st);
		st = -1; wait_(&st);
		return;
	}

	{
		char *argv[MAXARG + 1];
		char *cargv[MAXARG + 1];
		char *infile = 0, *outfile = 0;
		long pid;
		int argc = tokenize(line, argv);
		int i, cn = 0;
		if (argc == 0)
			return;

		for (i = 0; i < argc; i++) {
			if (argv[i][0] == '>') {
				if (argv[i][1] != 0) outfile = &argv[i][1];
				else if (i + 1 < argc) outfile = argv[++i];
			} else if (argv[i][0] == '<') {
				if (argv[i][1] != 0) infile = &argv[i][1];
				else if (i + 1 < argc) infile = argv[++i];
			} else if (cn < MAXARG) {
				cargv[cn++] = argv[i];
			}
		}
		cargv[cn] = 0;
		if (cn == 0)
			return;

		/* --- builtins: run in the shell itself (no fork) --- */
		if (streq(cargv[0], "exit"))
			exit_(0);
		if (streq(cargv[0], "cd")) {
			const char *d = (cargv[1] != 0) ? cargv[1] : "/";
			if (chdir_(d) != 0) { puts_("sh: cd: "); puts_(d); puts_(": no such directory\n"); }
			return;
		}
		if (streq(cargv[0], "mkdir")) {
			if (cargv[1] == 0 || mkdir_(cargv[1]) != 0) puts_("sh: mkdir failed\n");
			return;
		}
		if (streq(cargv[0], "rmdir")) {
			if (cargv[1] == 0 || rmdir_(cargv[1]) != 0) puts_("sh: rmdir failed\n");
			return;
		}

		pid = fork_();
		if (pid == 0) {
			/* R-P37.2: the fg command leads its own process group. */
			setpgid_(0, 0);
			if (infile != 0) {
				int fd = open_(infile, 0);
				if (fd >= 0) { dup2_(fd, 0); if (fd != 0) close_(fd); }
				else { puts_("sh: cannot open "); puts_(infile); puts_("\n"); exit_(1); }
			}
			if (outfile != 0) {
				int fd = open_(outfile, O_CREAT | O_TRUNC);
				if (fd >= 0) { dup2_(fd, 1); if (fd != 1) close_(fd); }
				else { puts_("sh: cannot create "); puts_(outfile); puts_("\n"); exit_(1); }
			}
			exec_cmd(cargv);
		}
		/* R-P37.2: give the child's group the tty, so ^C hits the child. */
		setpgid_((int)pid, (int)pid);
		tty_setfg_((int)pid);
		st = -1;
		wait_(&st);
		if ((st & 0xff) == 0x7f) {		/* WIFSTOPPED: a stopped job */
			puts_("[sh] job pid ");
			putn(pid);
			puts_(" stopped\n");
		}
		tty_setfg_((int)g_shpid);	/* reclaim the tty for the shell */
	}
}

int
main(int argc, char **argv, char **envp)
{
	static char buf[256];
	long n;
	(void) argc; (void) argv; (void) envp;

	g_shpid = getpid_();
	tty_setfg_((int)g_shpid);	/* the shell owns the tty initially */
	puts_("solnix sh (interactive): type commands; ^D to exit, ^C interrupts\n");

	/*
	 * Interactive read loop: prompt, read ONE line from the console (the
	 * kernel line discipline returns a whole cooked line, or 0 at ^D EOF),
	 * run it, repeat.  ^D at the prompt ends the shell -> init respawns it.
	 */
	for (;;) {
		puts_("$ ");
		n = read_(0, buf, sizeof (buf) - 1);
		if (n <= 0) {
			puts_("\nsh: EOF (^D); exiting\n");
			exit_(0);
		}
		buf[n] = 0;
		run_line(buf);
	}
	return (0);
}
