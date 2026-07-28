/*
 * init.c — solnix riscv64 userland /sbin/init (R-P8).
 *
 * The first user process. It proves the R-P8 process model end to end:
 *   1. syscall-set proof: open("/etc/motd") + read + write(1) + close.
 *   2. fork/exec/wait proof: fork a child that execs /bin/hello, wait+reap it.
 *   3. hand off to the interactive shell: exec /bin/sh (replaces init).
 *
 * Built static/freestanding with the riscv64 cross toolchain; syscalls via the
 * shared libu.h ecall stubs.
 */
#include "libu.h"

int
main(int argc, char **argv)
{
	char buf[128];
	long n;
	int fd;
	int pid, st;

	(void) argc; (void) argv;

	uputs("\n[R-P8] /sbin/init running in U-mode (pid ");
	uputdec((unsigned long)ugetpid());
	uputs(")\n");

	/* --- Gate 1: syscall set (open/read/write/close). --- */
	fd = (int)uopen("/etc/motd", O_RDONLY);
	if (fd >= 0) {
		n = uread(fd, buf, sizeof (buf));
		if (n > 0)
			uwrite(1, buf, (unsigned long)n);
		uclose(fd);
		uputs("syscall set OK: open/read/write/close\n");
	} else {
		uputs("init: open(/etc/motd) FAILED\n");
	}

	/* --- Gate 2: fork + exec + wait. --- */
	pid = ufork();
	if (pid == 0) {
		/* child: exec /bin/hello (never returns on success). */
		char *av[2]; av[0] = "/bin/hello"; av[1] = 0;
		uexecve("/bin/hello", av, 0);
		uputs("init(child): execve(/bin/hello) FAILED\n");
		uexit(127);
	} else if (pid > 0) {
		int rpid = uwaitpid(pid, &st, 0);
		uputs("fork/exec/wait OK: child pid ");
		uputdec((unsigned long)rpid);
		uputs(" exited status ");
		uputdec((unsigned long)st);
		uputs("\n");
	} else {
		uputs("init: fork FAILED\n");
	}

	/* --- Gate 3: hand off to the interactive shell. --- */
	{
		char *av[2]; av[0] = "/bin/sh"; av[1] = 0;
		uputs("[R-P8] init: exec /bin/sh (interactive shell)\n");
		uexecve("/bin/sh", av, 0);
		uputs("init: execve(/bin/sh) FAILED\n");
	}
	return (0);
}
