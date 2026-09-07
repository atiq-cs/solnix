/*
 * port.c - illumos event ports, the interface a Wayland compositor's event loop
 * actually uses on this platform.
 *
 * WHY THIS AND NOT poll(2). Tracing the real dependency chain out of the vendored
 * crate sources (docs/riscv64-event-ports-sizing.md) corrected a working
 * assumption: nothing in the compositor stack calls poll(2) directly.
 *
 *   smithay/smallvil -> calloop -> polling (illumos => mod port) -> rustix
 *                    -> port_create / port_associate / port_getn / port_send
 *
 * poll(2) remains necessary -- libc and hand-written loops need it, and this file
 * is built on the same readiness core -- but it is not sufficient. Hence this.
 *
 * WHAT MAKES THIS SMALL. Two findings from that study:
 *
 *   1. ONESHOT ONLY. polling's event-ports backend rejects anything but
 *      PollMode::Oneshot, because event ports are inherently oneshot: an
 *      association fires once, is automatically dissociated, and the consumer
 *      re-associates. So there are no level- or edge-triggered association modes
 *      to implement -- only the simplest of the three.
 *   2. THE READINESS POLICY IS ALREADY DONE. port_associate's `flags` arrive as
 *      literal PollFlags (POLLIN|POLLHUP|POLLERR|POLLPRI for readable,
 *      POLLOUT|POLLHUP|POLLERR for writable), which is exactly the bit set
 *      fd_ready() already computes for poll(2). No translation layer.
 *
 * So port_getn is proc_poll's loop with a different output shape, and the hard,
 * bug-prone part (what "ready" means per fd kind) is shared rather than
 * reimplemented -- which also means a readiness bug gets fixed once.
 *
 * NOTE: calloop keeps its own software level-triggering emulation for this
 * backend (supports_level() is false for event ports), re-arming sources itself.
 * That emulation is only correct if the kernel's readiness answers are genuinely
 * level-triggered at the source. They are: fd_ready() reports a socket with
 * already-buffered data as readable on the FIRST poll, with a negative control
 * proving the check is not vacuous. This is the same class of gap the project's
 * existing calloop-wayland-source and wayland-client timer-dispatch patches work
 * around.
 */

#include "port.h"

/*
 * Fixed tables, matching how this kernel does pipes and sockets. A port is
 * identified by its index; an fd holding one carries that index in fd_port.
 *
 * PORT_NASSOC is per port. Eight is enough for a compositor's own loop (a
 * wayland socket, a few clients, a ping fd) and matches p_fd[]'s own width, so a
 * port cannot be asked to watch more fds than a process can hold open.
 */
#define	PORT_NPORT	4
#define	PORT_NASSOC	8
#define	PORT_NUSER	8

typedef struct port_assoc {
	int		pa_used;
	int		pa_fd;		/* the watched fd, in the owner's table */
	int		pa_events;	/* wanted PollFlags */
	unsigned long	pa_user;	/* opaque cookie handed back verbatim */
} port_assoc_t;

typedef struct port {
	int		p_used;
	void		*p_owner;	/* proc_t *: only the owner may use it */
	port_assoc_t	p_assoc[PORT_NASSOC];
	/*
	 * User-generated events (port_send). calloop's Ping/LoopSignal wakeup
	 * rides on these, so they are not optional, and they are drained AHEAD of
	 * the fd scan: a wakeup posted to break a blocking port_getn must win
	 * even when no fd is ready, or the loop sleeps through its own signal.
	 */
	unsigned long	p_uevent[PORT_NUSER];
	int		p_nuser;
} port_t;

static port_t porttab[PORT_NPORT];

/*
 * port_create() -- allocate a port. Returns its index, or -1.
 */
int
port_alloc(void *owner)
{
	int i, j;

	for (i = 0; i < PORT_NPORT; i++) {
		if (porttab[i].p_used)
			continue;
		porttab[i].p_used = 1;
		porttab[i].p_owner = owner;
		porttab[i].p_nuser = 0;
		for (j = 0; j < PORT_NASSOC; j++)
			porttab[i].p_assoc[j].pa_used = 0;
		return (i);
	}
	return (-1);
}

void
port_free(int port)
{
	if (port < 0 || port >= PORT_NPORT)
		return;
	porttab[port].p_used = 0;
	porttab[port].p_owner = 0;
	porttab[port].p_nuser = 0;
}

/*
 * port_associate(port, PORT_SOURCE_FD, fd, events, user).
 *
 * Re-associating an fd that is already present UPDATES it rather than adding a
 * second entry: that is what a oneshot consumer does every time round its loop,
 * so treating it as an insert would exhaust the table almost immediately.
 */
int
port_assoc_add(int port, int fd, int events, unsigned long user)
{
	port_t *pt;
	int i, free = -1;

	if (port < 0 || port >= PORT_NPORT || !porttab[port].p_used)
		return (-1);
	pt = &porttab[port];

	for (i = 0; i < PORT_NASSOC; i++) {
		if (pt->p_assoc[i].pa_used && pt->p_assoc[i].pa_fd == fd) {
			pt->p_assoc[i].pa_events = events;
			pt->p_assoc[i].pa_user = user;
			return (0);
		}
		if (!pt->p_assoc[i].pa_used && free < 0)
			free = i;
	}
	if (free < 0)
		return (-1);		/* table full */
	pt->p_assoc[free].pa_used = 1;
	pt->p_assoc[free].pa_fd = fd;
	pt->p_assoc[free].pa_events = events;
	pt->p_assoc[free].pa_user = user;
	return (0);
}

/*
 * port_dissociate(). Absent is NOT an error to the caller: polling explicitly
 * tolerates ENOENT here, because a oneshot association may already have fired
 * and removed itself between the consumer deciding to drop it and doing so.
 */
int
port_assoc_del(int port, int fd)
{
	port_t *pt;
	int i;

	if (port < 0 || port >= PORT_NPORT || !porttab[port].p_used)
		return (-1);
	pt = &porttab[port];
	for (i = 0; i < PORT_NASSOC; i++) {
		if (pt->p_assoc[i].pa_used && pt->p_assoc[i].pa_fd == fd) {
			pt->p_assoc[i].pa_used = 0;
			return (0);
		}
	}
	return (0);			/* ENOENT is tolerated by design */
}

/*
 * port_send(port, PORT_SOURCE_USER, user) -- queue a user event.
 */
int
port_user_send(int port, unsigned long user)
{
	port_t *pt;

	if (port < 0 || port >= PORT_NPORT || !porttab[port].p_used)
		return (-1);
	pt = &porttab[port];
	if (pt->p_nuser >= PORT_NUSER)
		return (-1);
	pt->p_uevent[pt->p_nuser++] = user;
	return (0);
}

/*
 * One scan pass: fill up to `max` events from the port. Returns the count.
 *
 * User events first (see the p_uevent comment), then the fd associations. A
 * firing association is REMOVED, because event ports are oneshot -- forgetting
 * this is the classic way to build a busy loop that reports the same fd forever.
 */
int
port_scan(int port, port_event_t *out, int max, int (*ready)(void *, int))
{
	port_t *pt;
	int n = 0, i;

	if (port < 0 || port >= PORT_NPORT || !porttab[port].p_used)
		return (-1);
	pt = &porttab[port];

	while (n < max && pt->p_nuser > 0) {
		int k;

		out[n].pe_source = PORT_SOURCE_USER;
		out[n].pe_events = 0;
		out[n].pe_fd = -1;
		out[n].pe_user = pt->p_uevent[0];
		n++;
		for (k = 1; k < pt->p_nuser; k++)
			pt->p_uevent[k - 1] = pt->p_uevent[k];
		pt->p_nuser--;
	}

	for (i = 0; i < PORT_NASSOC && n < max; i++) {
		int r;

		if (!pt->p_assoc[i].pa_used)
			continue;
		r = ready(pt->p_owner, pt->p_assoc[i].pa_fd);
		/*
		 * Mask against what was asked for, but ALWAYS report HUP/ERR/NVAL:
		 * a consumer that asked only for POLLIN still needs to learn its
		 * peer hung up, or it waits forever on an fd that will never be
		 * readable again.
		 */
		r &= (pt->p_assoc[i].pa_events | POLLHUP | POLLERR | POLLNVAL);
		if (r == 0)
			continue;
		out[n].pe_source = PORT_SOURCE_FD;
		out[n].pe_events = r;
		out[n].pe_fd = pt->p_assoc[i].pa_fd;
		out[n].pe_user = pt->p_assoc[i].pa_user;
		n++;
		pt->p_assoc[i].pa_used = 0;	/* oneshot: fires once */
	}
	return (n);
}

/* Does this port have any user event queued? Used to shortcut a blocking wait. */
int
port_has_user(int port)
{
	if (port < 0 || port >= PORT_NPORT || !porttab[port].p_used)
		return (0);
	return (porttab[port].p_nuser > 0);
}
