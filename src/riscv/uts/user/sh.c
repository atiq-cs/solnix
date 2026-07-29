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

/*
 * exec_stage — inside a pipeline child (fds already wired): exec cmd/arg. The
 * shell builtin `echo` is inlined (writes to fd 1, which the child redirected
 * to the pipe) so `echo hello | cat` works without an /bin/echo dependency.
 */
static void exec_stage(char *word) __attribute__((noreturn));
static void
exec_stage(char *word)
{
	char *cmd, *arg;
	size_t i = 0;

	while (word[i] == ' ') i++;
	cmd = &word[i];
	while (word[i] && word[i] != ' ') i++;
	if (word[i] == ' ') { word[i] = '\0'; arg = &word[i + 1]; }
	else arg = &word[i];

	if (strcmp(cmd, "echo") == 0) {
		puts(arg); puts("\n"); _exit(0);
	}
	{
		char path[32]; char *av[4]; int n = 0, k;
		path[0]='/'; path[1]='b'; path[2]='i'; path[3]='n'; path[4]='/';
		for (k = 0; cmd[k] && k < 24; k++) path[5 + k] = cmd[k];
		path[5 + k] = '\0';
		av[n++] = path;
		if (arg && arg[0]) av[n++] = arg;
		av[n] = 0;
		execve(path, av, 0);
		puts("sh: exec failed in pipeline\n"); _exit(127);
	}
}

/*
 * run_pipeline — run "left | right": pipe(), fork left with stdout->write end,
 * fork right with stdin->read end, close both ends in the parent, wait both.
 * The R-P12 pipes gate: two processes wired by a kernel pipe + dup2.
 */
static void
run_pipeline(char *left, char *right)
{
	int fds[2], p1, p2, st;

	if (pipe(fds) != 0) { puts("sh: pipe failed\n"); return; }
	p1 = fork();
	if (p1 == 0) {
		dup2(fds[1], 1); close(fds[0]); close(fds[1]);
		exec_stage(left);
	}
	p2 = fork();
	if (p2 == 0) {
		dup2(fds[0], 0); close(fds[0]); close(fds[1]);
		exec_stage(right);
	}
	close(fds[0]); close(fds[1]);
	if (p1 > 0) (void) waitpid(p1, &st, 0);
	if (p2 > 0) (void) waitpid(p2, &st, 0);
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

		/* R-P12: a `|` runs a two-stage pipeline, then re-prompt. */
		{
			size_t b; int piped = 0;
			for (b = 0; line[b]; b++)
				if (line[b] == '|') {
					line[b] = '\0';
					run_pipeline(line, &line[b + 1]);
					piped = 1;
					break;
				}
			if (piped)
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
