/*
 * signal.c -- solnix riscv64 libc signal(2)/sigaction(2)/kill(2)/raise(3).
 * sigaction() installs the handler through SYS_sigaction(sig, handler,
 * restorer, flags), supplying __sigrestorer -- a naked trampoline the kernel
 * sets as the handler's return address; when the handler returns, it ecalls
 * SYS_sigreturn and the kernel restores the interrupted frame.  signal() is the
 * classic sigaction() wrapper (SA_RESTART, no old-handler recovery from the
 * reduced kernel, so the previous handler is reported as SIG_DFL).
 *
 * CRIB PROVENANCE: signal() implemented over sigaction() + a libc-supplied
 * sa_restorer that traps sigreturn is the illumos/glibc libc signal path
 * (usr/src/lib/libc/port/sys/signal.c + the sigacthandler/setcontext restorer);
 * kill()/raise() are the thin SYS_kill wrappers.
 */
#include <signal.h>
#include <unistd.h>
#include <sys/systrap.h>

extern int errno;

/*
 * __sigrestorer -- the sa_restorer trampoline.  A signal handler returns here
 * (the kernel set ra to this address); it ecalls SYS_sigreturn, which restores
 * the interrupted frame (this stub never returns to C).
 */
__attribute__((naked)) static void
__sigrestorer(void)
{
	__asm__ __volatile__(
	    "li a7, %0\n"
	    "ecall\n"
	    :: "i"(SYS_sigreturn) : "memory");
}

int
sigaction(int sig, const struct sigaction *act, struct sigaction *old)
{
	long rc;
	if (old != 0) {
		old->sa_handler = SIG_DFL;	/* reduced kernel: no old recovery */
		old->sa_flags = 0;
		old->sa_restorer = 0;
	}
	if (act == 0)
		return (0);
	rc = __systrap4(SYS_sigaction, sig, (long)act->sa_handler,
	    (long)__sigrestorer, (long)act->sa_flags);
	if (rc < 0 && rc > -256) {
		errno = (int)(-rc);
		return (-1);
	}
	return (0);
}

sighandler_t
signal(int sig, sighandler_t handler)
{
	struct sigaction sa;
	sa.sa_handler = handler;
	sa.sa_mask = 0;
	sa.sa_flags = SA_RESTART;
	sa.sa_restorer = 0;
	if (sigaction(sig, &sa, 0) < 0)
		return (SIG_ERR);
	return (SIG_DFL);	/* reduced kernel does not report the old handler */
}

int
kill(pid_t pid, int sig)
{
	long rc = __systrap2(SYS_kill, pid, sig);
	if (rc < 0 && rc > -256) {
		errno = (int)(-rc);
		return (-1);
	}
	return ((int)rc);
}

int
raise(int sig)
{
	return (kill(getpid(), sig));
}
