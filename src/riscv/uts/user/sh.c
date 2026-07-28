/*
 * sh.c — solnix riscv64 /bin/sh, a minimal interactive shell (R-P8 milestone).
 *
 * Reads a line from the console (read(0) via the kernel UART path), parses the
 * first word as a command, and either runs a builtin (echo, help, exit) or
 * fork/execs a /bin util (hello, cat). This is the R-P8 interactive/multi-
 * process milestone: a real shell reading commands and spawning processes.
 *
 * Prompt: "solnix-riscv# ". Commands (R-P8 set):
 *   echo <text>   builtin: print <text>
 *   help          builtin: list commands
 *   hello         fork+exec /bin/hello
 *   cat           fork+exec /bin/cat  (cats /etc/motd)
 *   exit          leave the shell (init reaps it)
 *
 * NOTE: no argv across execve yet (R-P9), so `echo` is a builtin that prints
 * the remainder of the line itself; `hello`/`cat` are fork+exec'd with no args.
 * No pipes, redirection, globbing, or PATH search \u2014 a fixed command table.
 */
#include "libu.h"

/* Read one line (up to n-1 bytes) from fd 0 into buf; NUL-terminate. Returns
 * the length, or -1 on EOF/error. The kernel read echoes + stops at newline. */
static long
readline(char *buf, unsigned long n)
{
	unsigned long i = 0;

	while (i < n - 1) {
		char c;
		long r = uread(0, &c, 1);

		if (r <= 0)
			return (i > 0 ? (long)i : -1);
		if (c == '\n')
			break;
		buf[i++] = c;
	}
	buf[i] = '\0';
	return ((long)i);
}

/* Run a util at `path` in a forked child; wait for it and report the status. */
static void
run(const char *path)
{
	int pid = ufork();

	if (pid == 0) {
		char *av[2]; av[0] = (char *)path; av[1] = 0;
		uexecve(path, av, 0);
		uputs("sh: exec failed: ");
		uputs(path);
		uputs("\n");
		uexit(127);
	} else if (pid > 0) {
		int st;
		(void) uwaitpid(pid, &st, 0);
	} else {
		uputs("sh: fork failed\n");
	}
}

int
main(int argc, char **argv)
{
	char line[128];

	(void) argc; (void) argv;

	uputs("\n[R-P8] interactive shell: /bin/sh (pid ");
	uputdec((unsigned long)ugetpid());
	uputs(")\n");
	uputs("type 'help' for commands; 'exit' to leave.\n");

	for (;;) {
		char *cmd, *arg;
		unsigned long i;

		uputs("solnix-riscv# ");
		if (readline(line, sizeof (line)) < 0) {
			uputs("\n");
			continue;
		}

		/* Split first word (cmd) from the rest (arg). */
		cmd = line;
		i = 0;
		while (line[i] && line[i] != ' ')
			i++;
		if (line[i] == ' ') {
			line[i] = '\0';
			arg = &line[i + 1];
		} else {
			arg = &line[i];		/* empty */
		}

		if (cmd[0] == '\0')
			continue;

		if (ustreq(cmd, "exit")) {
			uputs("sh: exit\n");
			uexit(0);
		} else if (ustreq(cmd, "help")) {
			uputs("commands: echo <text>, hello, cat, help, exit\n");
		} else if (ustreq(cmd, "echo")) {
			uputs(arg);
			uputs("\n");
		} else if (ustreq(cmd, "hello")) {
			run("/bin/hello");
		} else if (ustreq(cmd, "cat")) {
			run("/bin/cat");
		} else {
			uputs("sh: not found: ");
			uputs(cmd);
			uputs("\n");
		}
	}
	return (0);
}
