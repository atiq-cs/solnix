/* poll(2): REAL in the solnix riscv64 kernel (uts/syscall.c SYS_poll = 73, ms timeout). */
#ifndef _POLL_H
#define	_POLL_H
struct pollfd { int fd; short events, revents; };
typedef unsigned long nfds_t;
#define	POLLIN 0x001
#define	POLLPRI 0x002
#define	POLLOUT 0x004
#define	POLLERR 0x008
#define	POLLHUP 0x010
#define	POLLNVAL 0x020
int poll(struct pollfd *, nfds_t, int);
#endif
