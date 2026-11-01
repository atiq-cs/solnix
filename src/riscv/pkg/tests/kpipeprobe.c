/*
 * kpipeprobe.c -- isolates uts kernel pipe/fd behaviour with RAW syscalls (no
 * newlib glue fd table), one mode per run so a hang names the case.
 *
 *  ctl     control: pipe at kernel fds >=3, child writes + _exit, parent reads to
 *          EOF.  Expected to return EOF (proves the probe can pass).
 *  leak    child dup3(wfd, 1) then closes wfd and exits.  The pipe's only writer
 *          is the child's slot 1.  If proc_exit / close(1) released it, the
 *          parent's read returns EOF; if the ref leaks, read blocks forever.
 *  conout  child dup3(wfd, 1) then write(1, ...).  If sys_write honoured the
 *          dup2 the bytes reach the pipe; if fd 1 is hardwired, they appear on
 *          the console and the parent reads nothing (then EOF or a hang, see leak).
 *  execfd  fork, child execve("/bin/kpipeprobe", "execchild", wfd-as-string):
 *          the exec'd image writes to that fd number.  If exec kept the fd the
 *          write succeeds; if exec dropped the table it fails (EBADF/-1).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define	K_dup3 24
#define	K_close 57
#define	K_pipe2 59
#define	K_read 63
#define	K_write 64
#define	K_exit 93
#define	K_fork 220
#define	K_execve 221
#define	K_wait4 260

static long
ks(long n, long a, long b, long c)
{
	register long a0 __asm__("a0") = a, a1 __asm__("a1") = b,
	    a2 __asm__("a2") = c, a7 __asm__("a7") = n;
	__asm__ __volatile__("ecall" : "+r"(a0) : "r"(a1), "r"(a2), "r"(a7) : "memory");
	return (a0);
}

static void
say(const char *s)
{
	(void) ks(K_write, 2, (long)s, (long)strlen(s));
}

int
main(int argc, char **argv)
{
	int p[2];
	char b[64], m[128];
	long n, tot = 0, pid;
	int st;
	const char *mode = argc > 1 ? argv[1] : "ctl";

	if (strcmp(mode, "execchild") == 0) {
		n = ks(K_write, atoi(argv[2]), (long)"via-exec\n", 9);
		snprintf(m, sizeof (m), "kpipe execchild: write(fd %s) = %ld\n", argv[2], n);
		say(m);
		ks(K_exit, n == 9 ? 0 : 3, 0, 0);
	}
	if (ks(K_pipe2, (long)p, 0, 0) != 0) {
		say("kpipe: pipe2 failed\n");
		return (2);
	}
	snprintf(m, sizeof (m), "kpipe %s: pipe rfd=%d wfd=%d\n", mode, p[0], p[1]);
	say(m);
	pid = ks(K_fork, 0, 0, 0);
	if (pid == 0) {
		ks(K_close, p[0], 0, 0);
		if (strcmp(mode, "ctl") == 0) {
			ks(K_write, p[1], (long)"ctl-bytes\n", 10);
			ks(K_close, p[1], 0, 0);
		} else if (strcmp(mode, "leak") == 0) {
			ks(K_dup3, p[1], 1, 0);
			ks(K_close, p[1], 0, 0);
		} else if (strcmp(mode, "conout") == 0) {
			ks(K_dup3, p[1], 1, 0);
			ks(K_close, p[1], 0, 0);
			ks(K_write, 1, (long)"conout-bytes\n", 13);
		} else if (strcmp(mode, "execfd") == 0) {
			char fdb[8], *av[4] = { "kpipeprobe", "execchild", fdb, 0 };
			snprintf(fdb, sizeof (fdb), "%d", p[1]);
			ks(K_execve, (long)"/bin/kpipeprobe", (long)av, 0);
			say("kpipe: execve failed\n");
		}
		ks(K_exit, 0, 0, 0);
	}
	ks(K_close, p[1], 0, 0);
	while ((n = ks(K_read, p[0], (long)b, sizeof (b))) > 0)
		tot += n;
	ks(K_wait4, pid, (long)&st, 0);
	snprintf(m, sizeof (m), "kpipe %s: parent read %ld bytes then EOF (child status %d)\n",
	    mode, tot, st);
	say(m);
	printf("KPIPE %s EOF\n", mode);
	return (0);
}
