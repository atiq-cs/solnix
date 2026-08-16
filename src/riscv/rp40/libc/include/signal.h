/*
 * signal.h -- solnix riscv64 libc signal handling.  signal()/sigaction() install
 * a handler through the kernel's SYS_sigaction(sig, handler, restorer, flags);
 * the libc supplies the sa_restorer trampoline (a naked stub that ecalls
 * SYS_sigreturn so a returning handler restores the interrupted frame).
 *
 * CRIB PROVENANCE: the sig number set + SIG_DFL/SIG_IGN + struct sigaction +
 * the signal()->sigaction() wrapping is the illumos/POSIX <signal.h> contract;
 * the sa_restorer-ecalls-SYS_sigreturn idiom matches the kernel's R-P33/34
 * signal delivery (the kernel sets the handler's ra to sa_restorer).
 */
#ifndef _SIGNAL_H
#define _SIGNAL_H
#include <sys/types.h>

#define SIGHUP   1
#define SIGINT   2
#define SIGQUIT  3
#define SIGILL   4
#define SIGKILL  9
#define SIGSEGV  11
#define SIGPIPE  13
#define SIGALRM  14
#define SIGTERM  15
#define SIGUSR1  16
#define SIGUSR2  17
#define SIGCHLD  18
#define SIGCONT  25
#define SIGSTOP  23
#define SIGTSTP  24
#define NSIG     32

#define SIG_DFL ((void (*)(int))0)
#define SIG_IGN ((void (*)(int))1)
#define SIG_ERR ((void (*)(int))-1)

#define SA_RESTART 0x2

typedef unsigned long sigset_t;

struct sigaction {
	void	(*sa_handler)(int);
	sigset_t sa_mask;
	int	sa_flags;
	void	(*sa_restorer)(void);
};

typedef void (*sighandler_t)(int);

sighandler_t signal(int sig, sighandler_t handler);
int sigaction(int sig, const struct sigaction *act, struct sigaction *old);
int kill(pid_t pid, int sig);
int raise(int sig);

#endif /* _SIGNAL_H */
