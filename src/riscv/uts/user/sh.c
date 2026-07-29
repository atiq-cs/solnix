/*
 * sh.c — solnix riscv64 /bin/sh, minimal interactive shell.
 *
 * R-P10: linked against the real libc slice (libc-riscv.a) — uses libc printf,
 * malloc, strcmp, not the header-only libu stubs. Proves the libc links and its
 * printf/malloc work in a real process.
 *
 * Prompt: "solnix-riscv# ". Commands: echo/xecho/hello/cat/help/exit.
 */
#include "libc.h"

/* Read one line (up to n-1 bytes) from fd 0 into buf; NUL-terminate. */
static long
readline(char *buf, size_t n)
{
	size_t i = 0;

	while (i < n - 1) {
		char c;
		long r = read(0, &c, 1);

		if (r <= 0)
			return (i > 0 ? (long)i : -1);
		if (c == '\n')
			break;
		buf[i++] = c;
	}
	buf[i] = '\0';
	return ((long)i);
}

/* fork+exec `path` with up to two space-split args from `arg`. */
static void
run_argv(const char *path, char *arg)
{
	int pid;
	char *a1 = arg, *a2 = 0;
	size_t i = 0;

	while (arg[i] && arg[i] != ' ')
		i++;
	if (arg[i] == ' ') {
		arg[i] = '\0';
		a2 = &arg[i + 1];
	}
	pid = fork();
	if (pid == 0) {
		char *av[4];
		int n = 0;
		av[n++] = (char *)path;
		if (a1 && a1[0])
			av[n++] = a1;
		if (a2 && a2[0])
			av[n++] = a2;
		av[n] = 0;
		execve(path, av, 0);
		puts("sh: exec failed\n");
		_exit(127);
	} else if (pid > 0) {
		int st;
		(void) waitpid(pid, &st, 0);
	} else {
		puts("sh: fork failed\n");
	}
}

int
main(int argc, char **argv)
{
	/* malloc the line buffer to exercise malloc-over-brk from the libc. */
	char *line = malloc(128);

	(void) argc; (void) argv;
	if (line == 0) { puts("sh: malloc failed\n"); _exit(1); }

	printf("\n[R-P10] /bin/sh (pid %d) linked against libc-riscv "
	    "(printf/malloc OK)\n", getpid());
	puts("type 'help' for commands; 'exit' to leave.\n");

	for (;;) {
		char *cmd, *arg;
		size_t i;

		puts("solnix-riscv# ");
		if (readline(line, 128) < 0) {
			puts("\n");
			continue;
		}

		cmd = line;
		i = 0;
		while (line[i] && line[i] != ' ')
			i++;
		if (line[i] == ' ') {
			line[i] = '\0';
			arg = &line[i + 1];
		} else {
			arg = &line[i];
		}

		if (cmd[0] == '\0')
			continue;

		if (strcmp(cmd, "exit") == 0) {
			puts("sh: exit\n");
			_exit(0);
		} else if (strcmp(cmd, "help") == 0) {
			puts("commands: echo <text>, xecho <text>, hello, cat, help, exit\n");
		} else if (strcmp(cmd, "echo") == 0) {
			printf("%s\n", arg);
		} else if (strcmp(cmd, "xecho") == 0) {
			run_argv("/bin/echo", arg);
		} else if (strcmp(cmd, "hello") == 0) {
			run_argv("/bin/hello", (char *)"");
		} else if (strcmp(cmd, "cat") == 0) {
			run_argv("/bin/cat", arg);	/* cat <file> (or /etc/motd) */
		} else {
			printf("sh: not found: %s\n", cmd);
		}
	}
	return (0);
}
