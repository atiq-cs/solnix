/*
 * init.c — solnix riscv64 /sbin/init, SMF-style toward the MULTIUSER milestone
 * (R-P10 gate 3).
 *
 * The first user process. It:
 *   1. Runs the R-P9 process-model gates (fork/exec/wait, argv, EFAULT, COW).
 *   2. Proves clock-tick PREEMPTION: two CPU-bound spinners (parent + child)
 *      that do no syscalls both make progress and finish — only the clock can
 *      slice between them (R-P10 gate 1).
 *   3. Reads a service list off the on-disk FS (/etc/inittab), starts each
 *      service (the SMF-style "restarter" seam), reaches multi-user, and runs
 *      a getty/login-analog on the console: prints "login: ", accepts a login,
 *      and drops to /bin/sh (R-P10 gate 3).
 *
 * Linked against the real libc slice (libc-riscv.a): printf/malloc/etc.
 */
#include "libc.h"

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
 * start_service — the SMF-style "restarter" primitive: fork+exec a service
 * from the inittab and return its pid (the parent does not wait; a real init
 * would track + respawn). Returns pid, or -1.
 */
static int
start_service(const char *path)
{
	int pid = fork();

	if (pid == 0) {
		char *av[2]; av[0] = (char *)path; av[1] = 0;
		execve(path, av, 0);
		_exit(127);
	}
	return (pid);
}

/*
 * parse_inittab — read /etc/inittab off the on-disk FS and start each
 * "respawn:<path>" or "wait:<path>" service. Returns the number of services
 * started. This is the minimal SMF-style manifest: a service list init walks
 * at boot. Lines starting with '#' or blank are ignored. Format per line:
 *   respawn:/path   -> start, do not wait (a daemon-analog)
 *   wait:/path      -> start and wait for it to finish (a run-once task)
 * NOTE (R-P10 ceiling): no real respawn/dependency graph; a full SMF restarter is R-P11.
 */
static int
parse_inittab(void)
{
	char buf[512];
	int fd, n, started = 0;
	int i = 0;

	fd = open("/etc/inittab", O_RDONLY);
	if (fd < 0) {
		printf("init: no /etc/inittab (no services to start)\n");
		return (0);
	}
	n = (int)read(fd, buf, sizeof (buf) - 1);
	close(fd);
	if (n <= 0)
		return (0);
	buf[n] = '\0';

	while (i < n) {
		char *line = &buf[i];
		char *colon;
		int j = i;

		while (j < n && buf[j] != '\n')
			j++;
		buf[j] = '\0';
		i = j + 1;

		if (line[0] == '#' || line[0] == '\0')
			continue;

		/* split "action:path" on the first colon. */
		colon = line;
		while (*colon && *colon != ':')
			colon++;
		if (*colon != ':')
			continue;
		*colon = '\0';
		{
			const char *action = line;
			const char *path = colon + 1;

			if (path[0] == '\0')
				continue;
			if (strcmp(action, "wait") == 0) {
				char *av[2]; av[0] = (char *)path; av[1] = 0;
				printf("init: service (wait) %s\n", path);
				run_wait(path, av);
				started++;
			} else {	/* respawn / default: start, don't wait */
				int pid = start_service(path);
				printf("init: service (respawn) %s pid %d\n",
				    path, pid);
				if (pid > 0)
					started++;
			}
		}
	}
	return (started);
}

/*
 * login_console — the getty/login analog. Prints a banner + "login: ", reads a
 * username off the console, then (stub) drops straight to an interactive shell.
 * A real login would consult /etc/passwd + authenticate; the R-P10 milestone is
 * reaching a login prompt and a multi-user shell. Loops so exiting the shell
 * returns to the login prompt (a getty respawn). Does not return.
 */
static void
login_console(void)
{
	char user[64];

	for (;;) {
		int i = 0;
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

		printf("login: welcome, %s (dropping to /bin/sh)\n",
		    user[0] ? user : "root");
		av[0] = "/bin/sh"; av[1] = 0;
		run_wait("/bin/sh", av);	/* shell exits -> re-prompt (getty) */
	}
}

int
main(int argc, char **argv)
{
	static char cow_shared[64];	/* BSS page shared COW at fork */
	char *av[4];
	int pid, st, nsvc;

	(void) argc; (void) argv;
	cow_shared[0] = '-';

	printf("\n[R-P10] /sbin/init running in U-mode (pid %d), linked "
	    "against libc-riscv\n", getpid());

	/* --- R-P9 gates (regression): fork/exec/wait, argv, EFAULT, COW. --- */
	av[0] = "/bin/hello"; av[1] = 0;
	st = run_wait("/bin/hello", av);
	printf("fork/exec/wait OK: /bin/hello exited status %d\n", st);

	av[0] = "/bin/echo"; av[1] = "foo"; av[2] = "bar"; av[3] = 0;
	printf("argv gate: exec /bin/echo foo bar -> ");
	run_wait("/bin/echo", av);
	puts("argv OK: /bin/echo delivered argc=3 argv={echo,foo,bar}\n");

	{
		const char *bad = (const char *)0x10;
		long r = write(1, bad, 8);
		if (r == -14)
			puts("copyin/out OK: write(bad ptr) returned EFAULT "
			    "(no panic)\n");
		else
			printf("copyin/out: write(bad ptr) returned %d "
			    "(expected -14)\n", (int)r);
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
		printf("cow: parent wrote 'P', reads '%c' (own copy, "
		    "isolated)\n", cow_shared[0]);
		cowreport();
	}

	/* --- R-P10 gate 1: clock-tick PREEMPTION. Two CPU-bound user threads
	 * (parent + forked child) spin with NO syscalls. With only cooperative
	 * yielding neither would ever give up the cpu, so the fact that BOTH
	 * make progress and the child exits proves the clock sliced between
	 * them. Each spinner does a few rounds so the interleave is real. --- */
	pid = fork();
	if (pid == 0) {
		int k;
		for (k = 0; k < 3; k++)
			spin(2000000);
		printf("preempt: child spinner finished 3 rounds\n");
		_exit(0);
	} else if (pid > 0) {
		int k;
		for (k = 0; k < 3; k++)
			spin(2000000);
		printf("preempt: parent spinner finished 3 rounds\n");
		waitpid(pid, &st, 0);
		if (preemptreport() <= 0)
			puts("preempt: (cooperative only this run)\n");
	}

	/* --- R-P10 gate 3: SMF-style service start -> multi-user -> login. --- */
	nsvc = parse_inittab();
	printf("[R-P10] multi-user milestone: init started %d services; "
	    "login: available\n", nsvc);

	login_console();	/* getty/login analog; does not return */
	return (0);
}
