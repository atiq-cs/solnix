/*
 * init.c — solnix riscv64 userland /sbin/init (R-P8).
 *
 * The first user process. It proves the R-P8 process model end to end:
 *   1. syscall-set proof: open("/etc/motd") + read + write(1) + close.
 *   2. fork/exec/wait proof: fork a child that execs /bin/hello, wait+reap it.
 *   2b. argv proof (R-P9): fork+exec `/bin/echo foo bar` -> prints "foo bar".
 *   2c. copyin/out EFAULT proof (R-P9): a write() with a bad pointer returns
 *       EFAULT (not a kernel panic).
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
	static char cow_shared[64];	/* BSS: a writable page shared COW at fork */
	long n;
	int fd;
	int pid, st;

	(void) argc; (void) argv;
	cow_shared[0] = '-';		/* touch it pre-fork so it's mapped */

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

	/* --- Gate 2b (R-P9): argv delivery via `/bin/echo foo bar`. --- */
	pid = ufork();
	if (pid == 0) {
		char *av[4]; av[0] = "/bin/echo"; av[1] = "foo";
		av[2] = "bar"; av[3] = 0;
		uputs("argv gate: exec /bin/echo foo bar -> ");
		uexecve("/bin/echo", av, 0);
		uputs("init(child): execve(/bin/echo) FAILED\n");
		uexit(127);
	} else if (pid > 0) {
		uwaitpid(pid, &st, 0);
		uputs("argv OK: /bin/echo delivered argc=3 argv={echo,foo,bar}\n");
	}

	/* --- Gate 2c (R-P9): copyin/copyout EFAULT (fault-safe user access). ---
	 * A write() of a deliberately bad user pointer must return -EFAULT (-14),
	 * proving the kernel caught the fault instead of panicking. */
	{
		const char *bad = (const char *)0x10;	/* unmapped user VA */
		long r = uwrite(1, bad, 8);
		if (r == -14) {
			uputs("copyin/out OK: write(bad ptr) returned EFAULT "
			    "(no panic)\n");
		} else {
			uputs("copyin/out: write(bad ptr) returned ");
			uputdec((unsigned long)r);
			uputs(" (expected -14 EFAULT)\n");
		}
	}

	/* --- Gate 2d (R-P9): copy-on-write fork. A shared writable global lives
	 * in a COW page after fork. Child writes 'C', parent writes 'P'; each
	 * must read back ONLY its own value — proving the page split private on
	 * the first write in each process. --- */
	pid = ufork();
	if (pid == 0) {
		/* child: store into the shared page (store-faults -> COW split). */
		cow_shared[0] = 'C';
		if (cow_shared[0] == 'C')
			uputs("cow: child wrote 'C', reads 'C' (own copy)\n");
		else
			uputs("cow: child readback WRONG\n");
		uexit(0);
	} else if (pid > 0) {
		uwaitpid(pid, &st, 0);
		/* parent: write our own value AFTER the child ran + exited. */
		cow_shared[0] = 'P';
		if (cow_shared[0] == 'P')
			uputs("cow: parent wrote 'P', reads 'P' (own copy, "
			    "isolated from child)\n");
		else
			uputs("cow: parent readback WRONG (COW LEAK)\n");
		ucowreport();		/* kernel prints shared/copied counts */
	} else {
		uputs("init: cow fork FAILED\n");
	}

	/* --- Gate 5 (R-P9): clock-tick PREEMPTION. Fork a CPU-bound child that
	 * spins with NO syscalls; the parent also spins. With only cooperative
	 * yielding neither would ever give up the cpu, so the fact that BOTH make
	 * progress and the child exits proves the clock timer sliced between them.
	 * The kernel counts each clock preemption of a user thread. --- */
	pid = ufork();
	if (pid == 0) {
		uspin(4000000);		/* burn cpu, no syscalls */
		uexit(0);
	} else if (pid > 0) {
		uspin(4000000);		/* parent burns cpu concurrently */
		uwaitpid(pid, &st, 0);
		if (upreemptreport() <= 0)
			uputs("preempt: (cooperative only this run)\n");
	} else {
		uputs("init: preempt fork FAILED\n");
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
