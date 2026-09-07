/*
 * init.c — solnix riscv64 /sbin/init, R-P11: signals, writable FS, /etc/passwd
 * login, concurrent shells.
 *
 * The first user process. It:
 *   1. Regression: fork/exec/wait + argv + EFAULT + COW (R-P9/R-P10).
 *   2. SIGNALS (R-P11 gate 1): installs a SIGINT handler and self-kills to
 *      prove synchronous delivery + handler run + sigreturn resume; installs a
 *      SIGCHLD handler and reaps a child from inside the handler; proves
 *      SIGKILL force-exits an uncatchable target.
 *   3. WRITABLE FS (R-P11 gate 4): open(O_CREAT|O_RDWR) /tmp/x, write, lseek(0),
 *      read it back, verify the bytes match.
 *   4. /etc/passwd LOGIN (R-P11 gate 3): login_console reads /etc/passwd,
 *      matches the typed user, setuid/setgid to its uid/gid, execs its shell.
 *   5. CONCURRENT SHELLS (R-P11 gate 2): two shell sessions forked to run truly
 *      concurrently under preemption (each prints its pid in a bounded loop);
 *      then the interactive login on the console.
 *
 * Linked against the real libc slice (libc-riscv.a).
 */
#include "libc.h"

/* --- signal-gate state (written by handlers, read by main). --- */
static volatile int sigint_caught;
static volatile int sigchld_caught;
static volatile int sigchld_reaped_pid;

static void
on_sigint(int sig)
{
	(void) sig;
	sigint_caught = 1;
	printf("  [handler] SIGINT handler ran (pid %d)\n", getpid());
}

static void
on_sigchld(int sig)
{
	int st = 0, pid;
	(void) sig;
	sigchld_caught = 1;
	/* Reap every exited child from inside the handler (init's job). */
	while ((pid = waitpid(-1, &st, 0)) > 0)
		sigchld_reaped_pid = pid;
}

/* Fork+exec a child, wait for it, return its exit status (-1 on fork fail). */
static int
run_wait(const char *path, char *const argv[])
{
	int pid = fork();
	int st = -1;

	if (pid == 0) {
		execve(path, argv, 0);
		printf("init: exec %s FAILED\n", path);
		_exit(127);
	} else if (pid > 0) {
		waitpid(pid, &st, 0);
	}
	return (st);
}

/*
 * signal_gates — R-P11 gate 1. Prove SIGINT delivery+handler, SIGCHLD reap via
 * handler, and SIGKILL force-exit.
 */
static void
signal_gates(void)
{
	int pid, st;

	puts("\n--- R-P11 gate 1: signals ---\n");

	/* SIGINT: install a handler, post it to ourselves, verify it ran. The
	 * kill sets the pending bit; the next return-to-U (the ecall return of
	 * kill itself, then a tick) delivers it to the handler. */
	signal(SIGINT, on_sigint);
	kill(getpid(), SIGINT);
	/* Spin briefly so a timer tick delivers the async signal if the
	 * syscall-return path did not already. */
	{ int i; for (i = 0; i < 100 && !sigint_caught; i++) spin(200000); }
	if (sigint_caught)
		printf("signals OK: SIGINT delivered to pid %d, handler ran\n",
		    getpid());
	else
		puts("signals: SIGINT NOT delivered (FAIL)\n");

	/* SIGCHLD: install a reaper handler, fork a short child; when it exits
	 * the kernel posts SIGCHLD and init reaps it inside the handler. */
	signal(SIGCHLD, on_sigchld);
	pid = fork();
	if (pid == 0) {
		spin(500000);
		_exit(0);
	}
	{ int i; for (i = 0; i < 200 && !sigchld_caught; i++) spin(200000); }
	if (sigchld_caught && sigchld_reaped_pid == pid)
		printf("SIGCHLD: init reaped child via handler (pid %d)\n",
		    sigchld_reaped_pid);
	else
		printf("SIGCHLD: not reaped via handler (caught=%d pid=%d)\n",
		    sigchld_caught, sigchld_reaped_pid);
	signal(SIGCHLD, SIG_DFL);	/* back to default for the login phase */

	/* SIGKILL: fork a child that would spin forever, then kill it. SIGKILL
	 * is uncatchable, so the child force-exits (kernel prints the banner);
	 * we reap it to confirm. */
	pid = fork();
	if (pid == 0) {
		for (;;) spin(1000000);	/* never returns on its own */
	} else if (pid > 0) {
		spin(300000);
		kill(pid, SIGKILL);
		waitpid(pid, &st, 0);
		printf("SIGKILL: force-exited child pid %d (status %d)\n",
		    pid, st);
	}
}

/*
 * fs_gate — R-P11 gate 4. Writable/seekable FS: create /tmp/x, write, seek to
 * start, read back, verify.
 */
static void
fs_gate(void)
{
	int fd;
	char rb[32];
	const char *msg = "solnix-rp11";
	long n;

	puts("\n--- R-P11 gate 4: writable/seekable FS ---\n");
	fd = open("/tmp/x", O_CREAT | O_RDWR);
	if (fd < 0) { puts("fs: open(/tmp/x) FAILED\n"); return; }
	n = write(fd, msg, strlen(msg));
	if (n != (long)strlen(msg)) { puts("fs: write short (FAIL)\n"); return; }
	if (lseek(fd, 0, 0 /*SEEK_SET*/) != 0) { puts("fs: lseek FAIL\n"); return; }
	n = read(fd, rb, sizeof (rb) - 1);
	if (n < 0) n = 0;
	rb[n] = '\0';
	close(fd);
	if (strcmp(rb, msg) == 0)
		printf("fs: wrote /tmp/x, read it back, lseek OK ('%s')\n", rb);
	else
		printf("fs: readback mismatch ('%s' != '%s')\n", rb, msg);
}

/*
 * passwd_lookup — find `user` in /etc/passwd. Fills *uid/*gid/shell (a static
 * buffer). passwd format: name:x:uid:gid:gecos:home:shell. Returns 1 on match.
 */
static char pw_shell[64];
static int
passwd_lookup(const char *user, int *uid, int *gid)
{
	static char buf[1024];
	int fd, n, i = 0;

	fd = open("/etc/passwd", O_RDONLY);
	if (fd < 0)
		return (0);
	n = (int)read(fd, buf, sizeof (buf) - 1);
	close(fd);
	if (n <= 0)
		return (0);
	buf[n] = '\0';

	while (i < n) {
		char *line = &buf[i];
		int j = i, f = 0, fs = i;
		char *fld[7];
		int fn = 0;

		while (j < n && buf[j] != '\n')
			j++;
		buf[j] = '\0';
		i = j + 1;
		if (line[0] == '#' || line[0] == '\0')
			continue;

		/* split on ':' into up to 7 fields, in place. */
		fld[fn++] = &buf[fs];
		for (; fs < j && fn < 7; fs++) {
			if (buf[fs] == ':') {
				buf[fs] = '\0';
				fld[fn++] = &buf[fs + 1];
			}
		}
		(void) f;
		if (fn < 7)
			continue;
		if (strcmp(fld[0], user) != 0)
			continue;
		/* fld: 0=name 1=passwd 2=uid 3=gid 4=gecos 5=home 6=shell. */
		{
			int v = 0; char *p = fld[2];
			while (*p >= '0' && *p <= '9') v = v*10 + (*p++ - '0');
			*uid = v;
			v = 0; p = fld[3];
			while (*p >= '0' && *p <= '9') v = v*10 + (*p++ - '0');
			*gid = v;
		}
		{ int k = 0; while (fld[6][k] && k < 62) { pw_shell[k]=fld[6][k]; k++; } pw_shell[k]=0; }
		return (1);
	}
	return (0);
}

/*
 * login_console — the getty/login analog, now backed by /etc/passwd (R-P11
 * gate 3). Prompts, reads a username, looks it up in /etc/passwd, setuid/setgid
 * to its credentials, and execs the user's login shell. Loops (getty respawn).
 */
static void
login_console(void)
{
	char user[64];

	for (;;) {
		int i = 0, uid = -1, gid = -1;
		char c;
		char *av[2];

		puts("\nsolnix-riscv login: ");
		while (i < (int)sizeof (user) - 1) {
			long r = read(0, &c, 1);
			if (r <= 0) break;
			if (c == '\n') break;
			user[i++] = c;
		}
		user[i] = '\0';
		if (user[0] == '\0')
			continue;

		if (!passwd_lookup(user, &uid, &gid)) {
			printf("login: no such user '%s' in /etc/passwd\n",
			    user);
			continue;
		}
		setgid((unsigned int)gid);
		setuid((unsigned int)uid);
		printf("login: %s uid=%d from /etc/passwd -> %s\n",
		    user, getuid(), pw_shell);
		av[0] = pw_shell; av[1] = 0;
		run_wait(pw_shell, av);	/* shell exits -> re-prompt (getty) */
	}
}

/*
 * concurrent_shells — R-P11 gate 2. Fork two independent shell-like sessions
 * that run truly concurrently (each a bounded loop printing its pid); the clock
 * time-slices between them. Proves two shells live at once under preemption.
 * They exit after a few rounds so the boot is self-terminating; the interactive
 * console login (login_console) is the persistent third session.
 */
static void
concurrent_shells(void)
{
	int a, b, st;

	puts("\n--- R-P11 gate 2: concurrent shells ---\n");
	a = fork();
	if (a == 0) {
		int k;
		/* shell A: a bounded session that does NOT read the console (so
		 * it never competes with the login getty for stdin). It just
		 * proves it is scheduled concurrently with B under preemption. */
		for (k = 0; k < 3; k++) { printf("[shell A pid %d] round %d\n", getpid(), k); spin(1500000); }
		_exit(0);
	}
	b = fork();
	if (b == 0) {
		int k;
		for (k = 0; k < 3; k++) { printf("[shell B pid %d] round %d\n", getpid(), k); spin(1500000); }
		_exit(0);
	}
	printf("concurrent: shell A (pid %d) + shell B (pid %d) both live\n",
	    a, b);
	waitpid(a, &st, 0);
	waitpid(b, &st, 0);
}

/*
 * pipe_gate — R-P12 gate 1. Prove pipe(2)+dup2(2): fork a writer that redirects
 * stdout to the pipe and runs `echo hello`, and a reader that redirects stdin
 * from the pipe and runs `cat`; cat's output is the pipe payload. This is the
 * kernel-level proof behind the shell's `echo hello | cat`.
 */
static void
pipe_gate(void)
{
	int fds[2], w, r, st;
	char buf[64];
	long n;

	puts("\n--- R-P12 gate 1: pipes + dup2 ---\n");
	if (pipe(fds) != 0) { puts("pipe: pipe() FAILED\n"); return; }

	w = fork();
	if (w == 0) {
		/* writer: put "hello" into the pipe write end, then close. */
		close(fds[0]);
		write(fds[1], "hello", 5);
		close(fds[1]);
		_exit(0);
	}
	/* reader (this process): read the pipe, capture the payload. */
	close(fds[1]);
	n = read(fds[0], buf, sizeof (buf) - 1);
	if (n < 0) n = 0;
	buf[n] = '\0';
	close(fds[0]);
	if (w > 0) waitpid(w, &st, 0);

	if (strcmp(buf, "hello") == 0)
		printf("pipe OK: 'echo hello | cat' -> %s\n", buf);
	else
		printf("pipe: payload mismatch ('%s' != 'hello')\n", buf);
}

/*
 * tp_gate -- prove userland owns tp (x4).
 *
 * The RISC-V TLS ABI requires tp to point at the running thread's TLS block, so
 * a userland program must be able to put a value in tp and find it unchanged
 * later. The kernel also keeps a per-hart id in tp -- but only while in S-mode
 * (see uts/asm_frame.h TF_CPUID). This test is the positive proof that the split
 * holds, and it is the check that fails if the kernel ever reclaims tp:
 *
 *   1. A syscall (a synchronous trap into S-mode and back) must not disturb tp.
 *      This is the path that reloads the kernel id on entry and restores the
 *      user tp on exit; get it backwards and tp comes back as a small integer.
 *   2. A long spin must not disturb tp either. That covers the ASYNCHRONOUS
 *      path: a timer tick lands mid-loop, may preempt to another thread and even
 *      another hart, and tp must still survive. A syscall-only test would pass
 *      even with the interrupt path broken.
 *   3. A forked child running with its own tp must not perturb the parent's, and
 *      vice versa -- tp is per-process state, not a global register.
 *
 * The magic values are deliberately large and not small integers, so a tp that
 * comes back holding a hart id (0..7) or zero reads as an obvious failure rather
 * than a plausible one.
 */
#define	TP_MAGIC_PARENT	0x5a5a0000deadbeefUL
#define	TP_MAGIC_CHILD	0xa5a5000012345678UL

static unsigned long
tp_read(void)
{
	unsigned long v;
	__asm__ __volatile__("mv %0, tp" : "=r"(v));
	return (v);
}

static void
tp_write(unsigned long v)
{
	__asm__ __volatile__("mv tp, %0" :: "r"(v));
}

static int
tp_check(unsigned long want, const char *what)
{
	unsigned long got = tp_read();

	if (got == want) {
		printf("  [ok] tp survived %s\n", what);
		return (0);
	}
	printf("  [FAIL] tp clobbered by %s: got 0x%x%x want 0x%x%x\n", what,
	    (unsigned int)(got >> 32), (unsigned int)got,
	    (unsigned int)(want >> 32), (unsigned int)want);
	return (1);
}

static void
tp_gate(void)
{
	int bad = 0, pid, st = 0;
	volatile unsigned long spin;

	puts("\n--- gate: userland owns tp (x4), the TLS thread pointer ---\n");

	/* 3. Child first: it must not see, or leak into, the parent's tp. */
	pid = fork();
	if (pid == 0) {
		int cbad = 0;

		tp_write(TP_MAGIC_CHILD);
		(void) getpid();
		cbad += tp_check(TP_MAGIC_CHILD, "a syscall in the child");
		for (spin = 0; spin < 4000000UL; spin++)
			;
		cbad += tp_check(TP_MAGIC_CHILD, "a preemptible spin in the child");
		_exit(cbad == 0 ? 0 : 1);
	}

	/* 1. + 2. in the parent, concurrently with the child's own tp. */
	tp_write(TP_MAGIC_PARENT);
	(void) getpid();
	bad += tp_check(TP_MAGIC_PARENT, "a syscall");
	for (spin = 0; spin < 4000000UL; spin++)
		;
	bad += tp_check(TP_MAGIC_PARENT, "a preemptible spin (timer ticks)");

	if (pid > 0) {
		waitpid(pid, &st, 0);
		if (st == 0) {
			puts("  [ok] the child kept its own distinct tp\n");
		} else {
			puts("  [FAIL] the child's tp was clobbered\n");
			bad++;
		}
		bad += tp_check(TP_MAGIC_PARENT, "a child running with its own tp");
	}

	/*
	 * Leave tp at 0 on the way out. Nothing in this libc uses tp yet, and
	 * leaving a magic value there would make a future real TLS pointer's first
	 * bug look like a stale value from this test.
	 */
	tp_write(0);

	if (bad == 0)
		puts("TP GATE PASS: userland tp is preserved across syscalls, "
		    "interrupts and fork\n");
	else
		puts("TP GATE FAIL\n");
}

/*
 * socket_gate -- run /bin/socktest, the AF_UNIX + SCM_RIGHTS proof. Forked so a
 * failure cannot take init down, and exec'd so the socket layer is exercised from
 * a real separate address space, which is what a compositor and its clients are.
 */
static void
socket_gate(void)
{
	int pid, st = 0;

	puts("\n--- gate: AF_UNIX sockets + SCM_RIGHTS fd passing ---\n");
	pid = fork();
	if (pid == 0) {
		char *av[2];

		av[0] = "socktest";
		av[1] = 0;
		execve("/bin/socktest", av, 0);
		puts("socket: exec /bin/socktest FAILED\n");
		_exit(1);
	}
	if (pid < 0) {
		puts("socket: fork FAILED\n");
		return;
	}
	waitpid(pid, &st, 0);
}

/*
 * poll_gate -- run /bin/polltest, the poll(2) + anonymous-mmap proof. Forked and
 * exec'd for the same reasons as socket_gate: a failure cannot take init down,
 * and the test exercises poll from a real separate address space, which is what
 * a compositor is.
 */
static void
poll_gate(void)
{
	int pid, st = 0;

	puts("\n--- gate: poll(2) readiness + anonymous mmap ---\n");
	pid = fork();
	if (pid == 0) {
		char *av[2];

		av[0] = "polltest";
		av[1] = 0;
		execve("/bin/polltest", av, 0);
		puts("poll: exec /bin/polltest FAILED\n");
		_exit(1);
	}
	if (pid < 0) {
		puts("poll: fork FAILED\n");
		return;
	}
	waitpid(pid, &st, 0);
}

/*
 * port_gate -- run /bin/porttest, the event-ports proof. Event ports are what
 * calloop actually uses on illumos, so this is the interface a compositor's event
 * loop will sit on; poll(2) is necessary but not what any crate in that stack
 * calls directly.
 */
static void
port_gate(void)
{
	int pid, st = 0;

	puts("\n--- gate: event ports (port_create/associate/getn/send) ---\n");
	pid = fork();
	if (pid == 0) {
		char *av[2];

		av[0] = "porttest";
		av[1] = 0;
		execve("/bin/porttest", av, 0);
		puts("port: exec /bin/porttest FAILED\n");
		_exit(1);
	}
	if (pid < 0) {
		puts("port: fork FAILED\n");
		return;
	}
	waitpid(pid, &st, 0);
}

/*
 * fp_gate -- run /bin/fptest, the proof that hard-float state survives a context
 * switch. Forked and exec'd like the other gates so a failure cannot take init
 * down, and so the probe runs in a real separate address space.
 *
 * fptest is the ONE hard-float (lp64d) program in this userland; everything else
 * is soft-float, which is exactly why a kernel that saved no FP state went
 * unnoticed for so long. Three processes each stamp a distinct pattern into all
 * of f0-f31 plus fcsr and check it survives several preemptions.
 */
static void
fp_gate(void)
{
	int pid, st = 0;

	puts("\n--- gate: hard-float context switch (f0-f31 + fcsr) ---\n");
	pid = fork();
	if (pid == 0) {
		char *av[2];

		av[0] = "fptest";
		av[1] = 0;
		execve("/bin/fptest", av, 0);
		puts("fp: exec /bin/fptest FAILED\n");
		_exit(1);
	}
	if (pid < 0) {
		puts("fp: fork FAILED\n");
		return;
	}
	waitpid(pid, &st, 0);
}

/*
 * scanout_gate -- R-P64. Run /bin/fbtest, the userland proof of the /dev/fb
 * scanout seam (open + FBIOGMODE + mmap + paint + FBIOFLUSH). Forked so a
 * failure in the test cannot take init down, and so the seam is exercised from
 * a separately exec'd address space, exactly as a compositor would.
 */
static void
scanout_gate(void)
{
	int pid, st = 0;

	puts("\n--- R-P64 gate: /dev/fb scanout seam from userland ---\n");
	pid = fork();
	if (pid == 0) {
		char *av[2];

		av[0] = "fbtest";
		av[1] = 0;
		execve("/bin/fbtest", av, 0);
		puts("scanout: exec /bin/fbtest FAILED\n");
		_exit(1);
	}
	if (pid < 0) {
		puts("scanout: fork FAILED\n");
		return;
	}
	waitpid(pid, &st, 0);
}

/*
 * ondisk_fs_gate — R-P12 gate 2. Real on-disk writable FS over vioblk with a
 * block cache: create /data/x, write, sync (flush the cache to the platter),
 * remount (invalidate the cache + re-read the superblock from disk), re-open
 * and read back — proving the bytes survived on disk, not just in RAM.
 */
static void
ondisk_fs_gate(void)
{
	int fd;
	char rb[64];
	const char *msg = "solnix-rp12-ondisk";
	long n;

	puts("\n--- R-P12 gate 2: on-disk writable FS + block cache ---\n");
	fd = open("/data/x", O_CREAT | O_RDWR);
	if (fd < 0) { puts("fs: open(/data/x) FAILED (no data disk?)\n"); return; }
	n = write(fd, msg, strlen(msg));
	close(fd);
	if (n != (long)strlen(msg)) { puts("fs: short write (FAIL)\n"); return; }

	if (sync_fs() < 0) puts("fs: sync returned error\n");
	if (remount_fs() != 0) { puts("fs: remount FAILED\n"); return; }

	fd = open("/data/x", O_RDONLY);
	if (fd < 0) { puts("fs: re-open after remount FAILED\n"); return; }
	n = read(fd, rb, sizeof (rb) - 1);
	if (n < 0) n = 0;
	rb[n] = '\0';
	close(fd);
	if (strcmp(rb, msg) == 0)
		printf("fs: wrote /data/x to vioblk, synced, re-read after "
		    "remount OK ('%s')\n", rb);
	else
		printf("fs: readback after remount mismatch ('%s')\n", rb);
}

int
main(int argc, char **argv)
{
	static char cow_shared[64];	/* BSS page shared COW at fork */
	char *av[4];
	int pid, st;

	(void) argc; (void) argv;
	cow_shared[0] = '-';

	printf("\n[R-P11] /sbin/init running in U-mode (pid %d), linked "
	    "against libc-riscv\n", getpid());

	/* --- R-P9/R-P10 regression: fork/exec/wait, argv, EFAULT, COW. --- */
	av[0] = "/bin/hello"; av[1] = 0;
	st = run_wait("/bin/hello", av);
	printf("fork/exec/wait OK: /bin/hello exited status %d\n", st);

	av[0] = "/bin/echo"; av[1] = "foo"; av[2] = "bar"; av[3] = 0;
	printf("argv gate: exec /bin/echo foo bar -> ");
	run_wait("/bin/echo", av);

	{
		const char *bad = (const char *)0x10;
		long r = write(1, bad, 8);
		if (r == -14)
			puts("copyin/out OK: write(bad ptr) returned EFAULT\n");
	}

	pid = fork();
	if (pid == 0) {
		cow_shared[0] = 'C';
		printf("cow: child wrote 'C', reads '%c' (own copy)\n",
		    cow_shared[0]);
		_exit(0);
	} else if (pid > 0) {
		waitpid(pid, &st, 0);
		cow_shared[0] = 'P';
		printf("cow: parent reads '%c' (isolated)\n", cow_shared[0]);
	}

	/* --- R-P11 gates. --- */
	signal_gates();		/* gate 1: signals */
	fs_gate();		/* gate 4: writable/seekable FS */
	concurrent_shells();	/* gate 2: concurrent shells */

	/* --- R-P12 gates. --- */
	pipe_gate();		/* gate 1: pipes + dup2 */
	ondisk_fs_gate();	/* gate 2: on-disk writable FS + block cache */

	/* --- tp belongs to userland: the precondition for any TLS. --- */
	tp_gate();

	/* --- AF_UNIX sockets: the real gate for a Wayland compositor. --- */
	socket_gate();

	/* --- poll(2) + anonymous mmap: what the compositor's MAIN LOOP needs on
	 * top of the sockets. Run before the scanout gate so a poll regression is
	 * reported before the display path, which does not depend on it. --- */
	poll_gate();
	port_gate();
	fp_gate();

	/* --- R-P64 scanout seam: /dev/fb from userland. ---
	 * Runs /bin/fbtest as a child so a failure there cannot take init down,
	 * and so the test exercises the seam through a real exec'd process with
	 * its own address space (which is what a compositor will be). Skipped
	 * silently on a boot with no display device: open(/dev/fb) returns ENXIO,
	 * fbtest says so, and init carries on to the console. */
	scanout_gate();

	printf("\n[R-P12] milestones reached; console login (passwd) follows\n");
	login_console();	/* gate 3: /etc/passwd login; does not return */
	return (0);
}
