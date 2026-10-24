/*
 * port.h - illumos event ports. See port.c for why this exists rather than
 * relying on poll(2), and why only oneshot association is needed.
 */

#ifndef	_PORT_H
#define	_PORT_H

/*
 * The poll bit values, guarded so this header can be included alongside the
 * copy in uproc.c without conflicting. These are ABI-fixed (illumos
 * sys/poll.h, and identical to Linux's, which is why no translation layer is
 * needed anywhere in this stack) -- port_associate receives them verbatim from
 * `polling` as PollFlags.
 */
#ifndef	POLLIN
#define	POLLIN		0x0001
#define	POLLPRI		0x0002
#define	POLLOUT		0x0004
#define	POLLERR		0x0008
#define	POLLHUP		0x0010
#define	POLLNVAL	0x0020
#endif

/*
 * Source types. Only these two are needed: PORT_SOURCE_FD is what `polling`
 * associates, and PORT_SOURCE_USER is calloop's Ping/LoopSignal wakeup. The
 * others illumos defines (TIMER, AIO, MQ, ALERT) have no consumer here, and
 * adding them speculatively would be untested code on a hot path.
 */
#define	PORT_SOURCE_FD		4
#define	PORT_SOURCE_USER	3

/*
 * The event as returned to userland. Field order and widths match what the
 * consumer expects to read out of a port_event: source, events, then the
 * object/cookie pair.
 */
typedef struct port_event {
	int		pe_source;
	int		pe_events;	/* PollFlags that fired */
	int		pe_fd;		/* PORT_SOURCE_FD: the fd; else -1 */
	unsigned long	pe_user;	/* the cookie, handed back verbatim */
} port_event_t;

/*
 * Kernel-side interface. The `ready` callback is fd_ready()'s shape, passed in
 * rather than called directly so port.c does not need proc_t's layout -- the
 * same encapsulation used for the FP context hooks.
 */
extern int port_alloc(void *owner);
extern void port_hold(int port);
extern void port_free(int port);
extern int port_assoc_add(int port, int fd, int events, unsigned long user);
extern int port_assoc_del(int port, int fd);
extern int port_user_send(int port, unsigned long user);
extern int port_scan(int port, port_event_t *out, int max,
    int (*ready)(void *, int));
extern int port_has_user(int port);

#endif	/* _PORT_H */
