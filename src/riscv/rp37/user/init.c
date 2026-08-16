/*
 * init.c -- R-P37.4: /sbin/init (pid 1), inittab-driven.  The classic Unix
 * init: read /etc/inittab (a tiny ramfs file), and for its console-spawn line
 * fork+exec the shell ON THE CONSOLE (fd 0/1/2 = the live tty), then RESPAWN it
 * whenever it exits -- the getty/respawn loop.  init also reaps any orphan it
 * adopts (reparented to pid 1) in the same wait loop.
 *
 * inittab format (reduced /etc/inittab): one entry per line
 *     id:action:command
 * where action is "respawn" (restart on exit) or "once" (run once).  The '#'
 * comment + blank lines are ignored.  The reduced init understands one entry
 * (a console shell) and the respawn action; it re-reads nothing (the table is
 * parsed once at boot, as SVR4 init does for the initial run level).
 *
 * The shell now reads its commands from the LIVE console (no /etc/rc dup2):
 * init leaves fd 0/1/2 as the console, so the exec'd /bin/sh reads interactively
 * from the tty line discipline.  Boot proof feeds the console via qemu's piped
 * stdin.
 *
 * Self-contained inline syscall stubs, NO libc beyond crt.
 *
 * CRIB PROVENANCE: init(1M) reading /etc/inittab and respawning a console
 * getty/shell (action=respawn) is illumos usr/src/cmd/init/init.c + the SVR4
 * inittab(4) format (id:rstate:action:command) + BSD /etc/ttys getty respawn;
 * the pid-1 orphan-reaping wait loop is xv6 user/init.c ("for(;;) wait()").
 */

typedef unsigned long size_t;

#define	SYS_exit	1
#define	SYS_read	3
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
static long read_(int fd, void *b, size_t n) { return (sc3(SYS_read, fd, (long)b, (long)n)); }
static int close_(int fd) { return ((int)sc1(SYS_close, fd)); }
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

static int streq(const char *a, const char *b)
{
	size_t i = 0;
	while (a[i] && a[i] == b[i]) i++;
	return (a[i] == b[i]);
}

/*
 * parse_inittab -- read /etc/inittab, find the FIRST respawn entry, and copy its
 * command (the field after the second ':') into `cmd`.  Returns 1 if a respawn
 * console entry was found, 0 otherwise.  Reduced to a single entry.
 */
static int
parse_inittab(char *cmd, size_t cmdsz)
{
	static char buf[512];
	int fd = open_("/etc/inittab", 0);
	long n;
	int i, start;

	if (fd < 0)
		return (0);
	n = read_(fd, buf, sizeof (buf) - 1);
	close_(fd);
	if (n <= 0)
		return (0);
	buf[n] = 0;

	/* scan line by line for  id:respawn:command  (skip # and blanks). */
	for (start = 0, i = 0; i <= n; i++) {
		if (buf[i] != '\n' && buf[i] != 0)
			continue;
		buf[i] = 0;
		{
			char *line = &buf[start];
			int c1 = -1, c2 = -1, k;
			start = i + 1;
			if (line[0] == '#' || line[0] == 0)
				continue;
			for (k = 0; line[k]; k++) {
				if (line[k] == ':') {
					if (c1 < 0) c1 = k;
					else if (c2 < 0) { c2 = k; break; }
				}
			}
			if (c1 < 0 || c2 < 0)
				continue;
			line[c1] = 0;
			line[c2] = 0;
			if (!streq(&line[c1 + 1], "respawn"))
				continue;
			{
				const char *src = &line[c2 + 1];
				size_t j = 0;
				while (src[j] && j < cmdsz - 1) { cmd[j] = src[j]; j++; }
				cmd[j] = 0;
				return (1);
			}
		}
	}
	return (0);
}

int
main(int argc, char **argv, char **envp)
{
	long shpid, st, reaped;
	char cmd[72];
	static char *shargv[2] = { "/bin/sh", 0 };
	int spawns = 0;
	int max_spawns = 2;		/* boot proof: show init respawn (2 spawns) */
	(void) argc; (void) argv; (void) envp;

	puts_("[init] pid ");
	putn(getpid_());
	puts_(" running: reading /etc/inittab\n");

	if (parse_inittab(cmd, sizeof (cmd))) {
		puts_("[init] inittab: respawn console -> ");
		puts_(cmd);
		puts_("\n");
	} else {
		puts_("[init] no inittab respawn entry; defaulting to /bin/sh\n");
		cmd[0] = 0;
	}

	/*
	 * The getty/respawn loop: fork+exec the console shell (fd 0/1/2 = the
	 * live tty -- no dup2, so the shell reads interactively from the
	 * console line discipline), then reap it (+ any adopted orphan) and,
	 * for a respawn entry, spawn it again.  The boot proof shows two spawns.
	 */
	for (;;) {
		shpid = fork_();
		if (shpid == 0) {
			execve_("/bin/sh", shargv);
			puts_("[init] exec /bin/sh FAILED\n");
			exit_(127);
		}
		spawns++;
		puts_("[init] spawn #");
		putn(spawns);
		puts_(": forked shell pid ");
		putn(shpid);
		puts_(" on the console\n");

		/* reap children until the shell we spawned exits. */
		for (;;) {
			st = -1;
			reaped = wait_(&st);
			if (reaped < 0)
				break;		/* no children left */
			/* WIFSTOPPED sentinel (status 0x7f): a stopped job -- not exited. */
			if ((st & 0xff) == 0x7f) {
				puts_("[init] child pid ");
				putn(reaped);
				puts_(" stopped (not respawning)\n");
				continue;
			}
			puts_("[init] reaped pid ");
			putn(reaped);
			puts_(" status ");
			putn(st);
			if (reaped == shpid) {
				puts_(" (the console shell)\n");
				break;		/* respawn the shell */
			}
			puts_(" (adopted orphan)\n");
		}

		if (spawns >= max_spawns) {
			puts_("[init] respawn demo complete (");
			putn(spawns);
			puts_(" spawns); init done.\n");
			break;
		}
		puts_("[init] respawning the console shell\n");
	}
	exit_(0);
	return (0);
}
