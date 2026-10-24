/*
 * pkginit.c -- /sbin/init for the riscv64 package checks. Reads /etc/rvpkg.tests,
 * one check per line, fields separated by '|':
 *
 *     name|want_exit|/path/to/prog|argv0|argv1|...
 *
 * '|' is the separator, so a literal '|' inside an argument is written %7C.
 *
 * and for each: fork, execve(path, argv, env), waitpid, then print
 *
 *     RVPKG BEGIN <name>
 *     ...whatever the program writes (always the console: see below)...
 *     RVPKG END <name> exit=<n> want=<m> <PASS|FAIL>
 *
 * The host side (run-checks.sh) also greps for expected output between BEGIN and
 * END, so a check passes only if BOTH the exit status and the output are right.
 *
 * Output capture is not possible in-guest: the kernel routes fd 1/2 to the
 * console unconditionally (uts/syscall.c sys_write) and clears the whole fd
 * table on exec (uts/uproc.c load_elf_into). So the console log IS the record.
 */
#include <stdio.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>

static char *env[] = { "PATH=/bin", "HOME=/", "TERM=vt100", "SHELL=/bin/dash", "LESSCHARSET=ascii", NULL };

int
main(void)
{
	static char line[1024];
	FILE *f = fopen("/etc/rvpkg.tests", "r");
	int n = 0, pass = 0;

	printf("RVPKG INIT pid=%d\n", getpid());
	if (f == NULL) {
		printf("RVPKG FATAL no /etc/rvpkg.tests\n");
		return (1);
	}
	/* the checks' programs must not inherit the list now that the kernel
	 * keeps fds across exec (rvsh): close-on-exec, as init should */
	(void) fcntl(fileno(f), F_SETFD, FD_CLOEXEC);
	while (fgets(line, sizeof (line), f) != NULL) {
		char *fld[40], *p = line, *s;
		int nf = 0, want, st = 0, pid, code;

		line[strcspn(line, "\n")] = '\0';
		if (line[0] == '#' || line[0] == '\0')
			continue;
		while ((s = strsep(&p, "|")) != NULL && nf < 39) {
			char *e;

			while ((e = strstr(s, "%7C")) != NULL) {
				*e = '|';
				memmove(e + 1, e + 3, strlen(e + 3) + 1);
			}
			fld[nf++] = s;
		}
		fld[nf] = NULL;
		if (nf < 4) {
			printf("RVPKG BADLINE %s\n", line);
			continue;
		}
		want = atoi(fld[1]);
		printf("RVPKG BEGIN %s\n", fld[0]);
		fflush(stdout);
		pid = fork();
		if (pid == 0) {
			execve(fld[2], &fld[3], env);
			printf("RVPKG EXECFAIL %s\n", fld[2]);
			_exit(127);
		}
		if (pid < 0 || waitpid(pid, &st, 0) != pid)
			code = -1;
		else
			code = WEXITSTATUS(st);
		n++;
		if (code == want)
			pass++;
		printf("\nRVPKG END %s exit=%d want=%d %s\n", fld[0], code, want,
		    code == want ? "PASS" : "FAIL");
		fflush(stdout);
	}
	printf("RVPKG DONE %d/%d exit-status checks matched\n", pass, n);
	return (0);
}
