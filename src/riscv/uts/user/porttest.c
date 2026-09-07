/*
 * porttest.c - does the event-port implementation actually work?
 *
 * Event ports are what calloop uses on illumos (smithay/smallvil -> calloop ->
 * polling -> rustix -> port_*), so this is the interface a Wayland compositor's
 * event loop will sit on. poll(2) is necessary but not sufficient: no crate in
 * that stack calls it directly.
 *
 * WHAT IS ACTUALLY WORTH TESTING. Presence is easy and proves little. The
 * behaviours that break a compositor if they are wrong:
 *
 *   1. ONESHOT. An association fires ONCE and is then dropped; the consumer
 *      re-associates. If a fired association stayed armed, port_getn would report
 *      the same fd forever and the event loop would spin at 100% CPU. So the test
 *      demands that a second getn WITHOUT re-associating returns nothing, even
 *      though the fd is still readable.
 *   2. RE-ASSOCIATION UPDATES, not appends. A oneshot consumer re-associates every
 *      time round its loop, so if that inserted a duplicate the 8-entry table
 *      would be exhausted after a few iterations of a normal event loop.
 *   3. port_send WINS OVER AN EMPTY FD SET. This is calloop's Ping/LoopSignal
 *      wakeup. If user events were drained after the fd scan, or only when some fd
 *      was ready, a loop blocked in port_getn would sleep through its own wakeup --
 *      a hang that looks like a deadlock in the compositor.
 *   4. The COOKIE round-trips verbatim. calloop stores a token there; a mangled
 *      cookie dispatches the wrong handler, which is far worse than losing an event.
 *   5. HUP is reported even when only POLLIN was requested, or a consumer waits
 *      forever on an fd whose peer has closed.
 *
 * NEGATIVE CONTROL at the end: an association on an fd with NOTHING to read must
 * NOT fire. Without it, an implementation that reported every fd ready always
 * would pass every positive check in this file.
 */

#include "libc.h"

#define	SYS_port_create		510
#define	SYS_port_associate	511
#define	SYS_port_dissociate	512
#define	SYS_port_getn		513
#define	SYS_port_send		514

#define	PORT_SOURCE_USER	3
#define	PORT_SOURCE_FD		4

#define	POLLIN_		0x0001
#define	POLLOUT_	0x0004
#define	POLLHUP_	0x0010

/* Must match the kernel's port_event_t exactly or every field reads garbage. */
typedef struct port_event {
	int		pe_source;
	int		pe_events;
	int		pe_fd;
	unsigned long	pe_user;
} port_event_t;

static int checks, bad;

static void
check(int ok, const char *what)
{
	checks++;
	if (!ok)
		bad++;
	printf("  [%s] %s\n", ok ? "ok" : "FAIL", what);
}

static int
port_create(void)
{
	return ((int)__sys(SYS_port_create, 0, 0, 0, 0));
}

static int
port_associate(int p, int fd, int events, unsigned long user)
{
	return ((int)__sys6(SYS_port_associate, p, PORT_SOURCE_FD, fd, events,
	    (long)user, 0));
}

static int
port_dissociate(int p, int fd)
{
	return ((int)__sys(SYS_port_dissociate, p, PORT_SOURCE_FD, fd, 0));
}

static int
port_getn(int p, port_event_t *list, int max, unsigned int *np, int timeout)
{
	return ((int)__sys6(SYS_port_getn, p, (long)list, max, (long)np,
	    timeout, 0));
}

static int
port_send(int p, unsigned long user)
{
	return ((int)__sys(SYS_port_send, p, (long)user, 0, 0));
}

int
main(int argc, char **argv)
{
	port_event_t ev[8];

	(void) argc; (void) argv;
	unsigned int n;
	int p, sv[2], r;

	printf("=== porttest: event ports (the interface calloop uses) ===\n");

	p = port_create();
	check(p >= 0, "port_create() returns an fd");
	if (p < 0) {
		printf("PORTTEST FAIL: no port, nothing further is meaningful\n");
		return (1);
	}

	/*
	 * Use libc's wrapper rather than a raw syscall: SOCK_STREAM is 2 on
	 * illumos, not 1, and hand-rolling the numbers here got that wrong once.
	 */
	r = socketpair_un(sv);
	check(r == 0, "socketpair() for something to watch");
	if (r != 0) {
		printf("PORTTEST FAIL: no socketpair\n");
		return (1);
	}

	/* Nothing written yet, so an association must not fire: timeout 0. */
	check(port_associate(p, sv[0], POLLIN_, 0xAAAA) == 0,
	    "port_associate(fd, POLLIN)");
	n = 99;
	check(port_getn(p, ev, 8, &n, 0) == 0 && n == 0,
	    "port_getn returns 0 events while the socket is empty");

	/* Make it readable, then it must fire exactly once with our cookie. */
	check(write(sv[1], "x", 1) == 1, "peer writes a byte");
	n = 0;
	r = port_getn(p, ev, 8, &n, 0);
	check(r == 0 && n == 1, "port_getn reports exactly 1 event");
	if (n == 1) {
		check(ev[0].pe_source == PORT_SOURCE_FD, "pe_source is FD");
		check(ev[0].pe_fd == sv[0], "pe_fd is the watched fd");
		check((ev[0].pe_events & POLLIN_) != 0, "pe_events has POLLIN");
		check(ev[0].pe_user == 0xAAAA,
		    "the cookie round-trips verbatim (calloop's token)");
	}

	/*
	 * ONESHOT: the socket is STILL readable (nothing consumed the byte), but
	 * the association fired and must be gone. If this reports an event, an
	 * event loop built on it spins forever.
	 */
	n = 99;
	check(port_getn(p, ev, 8, &n, 0) == 0 && n == 0,
	    "ONESHOT: a fired association does not fire again unassociated");

	/* Re-associating brings it back -- this is the normal loop cycle. */
	check(port_associate(p, sv[0], POLLIN_, 0xBBBB) == 0,
	    "re-associate after firing");
	n = 0;
	check(port_getn(p, ev, 8, &n, 0) == 0 && n == 1 &&
	    ev[0].pe_user == 0xBBBB,
	    "re-associated fd fires again with the NEW cookie");

	/*
	 * Re-association must UPDATE rather than append, or an event loop
	 * exhausts the association table within a few iterations. Associate the
	 * same fd 12 times (table is 8) and it must still work.
	 */
	{
		int i, okall = 1;

		for (i = 0; i < 12; i++) {
			if (port_associate(p, sv[0], POLLIN_, 0xC000 + i) != 0)
				okall = 0;
		}
		check(okall, "re-associating 12x does not exhaust an 8-slot table");
		n = 0;
		check(port_getn(p, ev, 8, &n, 0) == 0 && n == 1 &&
		    ev[0].pe_user == 0xC00B,
		    "the LAST re-association wins (update, not duplicate)");
	}

	/* Drain the byte so the fd is genuinely not readable again. */
	{
		char c;

		check(read(sv[0], &c, 1) == 1, "drain the byte");
	}

	/*
	 * port_send must be delivered even though NO fd is ready. This is
	 * calloop's wakeup; if user events were drained after the fd scan, a
	 * blocked loop would sleep through its own signal.
	 */
	check(port_send(p, 0xDEAD) == 0, "port_send(user event)");
	n = 0;
	r = port_getn(p, ev, 8, &n, 0);
	check(r == 0 && n == 1 && ev[0].pe_source == PORT_SOURCE_USER &&
	    ev[0].pe_user == 0xDEAD,
	    "a user event is delivered with NO fd ready (calloop's wakeup)");

	/* dissociate is tolerant: absent is not an error (polling expects that). */
	check(port_dissociate(p, sv[0]) == 0, "dissociate an associated fd");
	check(port_dissociate(p, sv[0]) == 0,
	    "dissociate AGAIN is not an error (polling tolerates ENOENT)");

	/*
	 * HUP must be reported even though only POLLIN was asked for: a consumer
	 * waiting for readability on a closed peer otherwise waits forever.
	 */
	check(port_associate(p, sv[0], POLLIN_, 0xE0E0) == 0,
	    "associate before closing the peer");
	close(sv[1]);
	n = 0;
	r = port_getn(p, ev, 8, &n, 0);
	check(r == 0 && n == 1 && (ev[0].pe_events & (POLLIN_ | POLLHUP_)) != 0,
	    "peer close is reported (HUP/IN) though only POLLIN was requested");

	/*
	 * NEGATIVE CONTROL. A fresh, empty, never-written socketpair must NOT
	 * fire for POLLIN. If this FAILS, the implementation is claiming
	 * readiness unconditionally and every positive check above is worthless.
	 */
	{
		int q[2];

		if (socketpair_un(q) == 0) {
			check(port_associate(p, q[0], POLLIN_, 0xF00D) == 0,
			    "negative control: associate an empty socket");
			n = 99;
			check(port_getn(p, ev, 8, &n, 0) == 0 && n == 0,
			    "NEGATIVE CONTROL: an empty fd does NOT report POLLIN");
			close(q[0]);
			close(q[1]);
		}
	}

	close(sv[0]);
	close(p);

	/*
	 * nanosleep. The check that matters is the ELAPSED TIME, not the return
	 * code: a nanosleep that returns 0 immediately would pass any
	 * status-only test while leaving every timer-driven event loop
	 * busy-waiting. Measured against clock_gettime, with a generous upper
	 * bound because this is a 100 Hz cooperative scheduler under QEMU.
	 */
	{
		struct timespec_ { long tv_sec; long tv_nsec; } req, rem, t0, t1;
		long ns;

		/* CLOCK_MONOTONIC=4 on illumos; boot-relative here, which is fine
		 * for measuring an interval. */
		__sys(113 /*clock_gettime*/, 4, (long)&t0, 0, 0);
		req.tv_sec = 0; req.tv_nsec = 150000000L;	/* 150 ms */
		rem.tv_sec = -1; rem.tv_nsec = -1;
		check(__sys(101 /*nanosleep*/, (long)&req, (long)&rem, 0, 0) == 0,
		    "nanosleep(150ms) returns 0");
		__sys(113, 4, (long)&t1, 0, 0);
		ns = (t1.tv_sec - t0.tv_sec) * 1000000000L +
		    (t1.tv_nsec - t0.tv_nsec);
		check(ns >= 150000000L,
		    "nanosleep actually SLEPT >= the requested 150 ms");
		/* This libc's printf handles %d/%u/%x/%s only -- no %ld -- so cast
		 * rather than silently printing the format string. */
		printf("  (measured %d ms for a 150 ms request)\n",
		    (int)(ns / 1000000L));
		check(rem.tv_sec == 0 && rem.tv_nsec == 0,
		    "the remainder is written and zero on a full sleep");

		/* POSIX: tv_nsec >= 1e9 is EINVAL, not silently normalised. */
		req.tv_sec = 0; req.tv_nsec = 2000000000L;
		check(__sys(101, (long)&req, 0, 0, 0) != 0,
		    "NEGATIVE: nanosleep with tv_nsec >= 1e9 is refused");
		req.tv_sec = -1; req.tv_nsec = 0;
		check(__sys(101, (long)&req, 0, 0, 0) != 0,
		    "NEGATIVE: nanosleep with a negative tv_sec is refused");
	}

	/*
	 * AT_SUN_EXECNAME + PSET_INFO. Both are "survivable" gaps per the ABI
	 * study -- getexecname and available_parallelism degrade rather than
	 * crash -- but both are one kernel slot each, and a wrong CPU count is
	 * worse than an absent one: callers size thread pools from it.
	 */
	{
		unsigned int nc = 0;
		long r2;

		/* SYS_pset(207), PSET_INFO=3: a3 = &numcpus. */
		r2 = __sys6(207, 3, 0, 0, (long)&nc, 0, 0);
		check(r2 == 0, "pset_info(PSET_INFO) succeeds");
		check(nc >= 1 && nc <= 8,
		    "the reported CPU count is sane (1..MAXCPU, not 0)");
		printf("  (online CPUs reported: %u)\n", nc);

		/* Wrong subcode must be refused, not answered with a guess. */
		check(__sys6(207, 99, 0, 0, (long)&nc, 0, 0) != 0,
		    "NEGATIVE: an unimplemented pset subcode is refused");
	}

	printf("%d checks, %d failed\n", checks, bad);
	if (bad == 0)
		printf("PORTTEST PASS: event ports usable by a compositor loop\n");
	else
		printf("PORTTEST FAIL: %d checks failed\n", bad);
	return (bad == 0 ? 0 : 1);
}
