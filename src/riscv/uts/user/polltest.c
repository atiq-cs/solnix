/*
 * polltest.c -- the poll(2) + anonymous mmap gate: readiness that CHANGES when
 * the peer acts, a timeout that ACTUALLY blocks, and a negative control that
 * proves the harness can fail.
 *
 * WHY EACH CHECK IS HERE. A poll(2) that returned "everything is ready" would
 * pass a naive test and then make a compositor's main loop spin at 100% cpu; one
 * that returned "nothing is ready" would pass a different naive test and hang
 * forever. So no check here asks only "did poll return a number":
 *
 *   1. READINESS TRANSITIONS. The same descriptor is polled before and after the
 *      peer writes, and the answer must CHANGE (not-ready -> POLLIN). A constant
 *      answer, of either kind, fails.
 *   2. LEVEL-TRIGGERED. Data is buffered BEFORE poll is ever called, and the
 *      first poll must report readable. This is the case that has repeatedly
 *      bitten this project on illumos (nested-poll / calloop readiness bugs): an
 *      edge-triggered implementation reports nothing here because it missed the
 *      arrival edge, and the event loop deadlocks with data sitting in the
 *      socket. Polled TWICE, because level-triggered also means the second poll
 *      still reports readable while the data is unconsumed.
 *   3. THE TIMEOUT REALLY BLOCKS. Measured with a monotonic clock across the
 *      call. A poll that returned instantly with 0 would otherwise look
 *      identical to one that waited, and a compositor built on it would burn a
 *      core.
 *   4. POLLOUT / POLLHUP / POLLNVAL / POLLERR are each provoked deliberately: a
 *      writable socket, a peer that closed, a descriptor that was never opened,
 *      a pipe whose readers all went away.
 *   5. ANONYMOUS MMAP is written and read back, across more than one page, and
 *      checked ZEROED first -- MAP_ANON requires zero-fill, and a mapping that
 *      handed back somebody's old page would pass a write-then-read test while
 *      leaking data.
 *   6. THE NEGATIVE CONTROL (poll_negative_control). The mechanism is sabotaged
 *      -- poll is asked about a socket with NO data and NO writer -- and the
 *      check asserts that a "readable" answer would be WRONG. If poll ever
 *      starts claiming readiness unconditionally, this flips to FAIL while every
 *      positive check still passes. Without it the whole file could pass
 *      vacuously against a poll that says yes to everything.
 */

#include "libc.h"

static int failures;
static int checks;

static void
check(int ok, const char *what)
{
	checks++;
	printf("  [%s] %s\n", ok ? "ok" : "FAIL", what);
	if (!ok)
		failures++;
}

/* Poll one fd for `events` with the given timeout; return revents (0 = none). */
static short
poll1(int fd, short events, int timeout)
{
	struct pollfd pfd;
	int r;

	pfd.fd = fd;
	pfd.events = events;
	pfd.revents = 0;
	r = poll(&pfd, 1, timeout);
	if (r < 0)
		return (-1);
	return (pfd.revents);
}

/*
 * readiness_transitions -- the core property: poll's answer must FOLLOW the
 * socket's state. Uses socketpair so no namespace or fork is involved and a
 * failure localizes to poll itself rather than to bind/connect.
 */
static void
readiness_transitions(void)
{
	int sv[2];
	short rv;
	char buf[16];

	puts("\n-- readiness follows the socket's state --\n");
	if (socketpair_un(sv) != 0) {
		check(0, "socketpair for the readiness test");
		return;
	}

	/* Empty socket: NOT readable. An implementation that says readable here
	 * makes an event loop spin; one that never says readable hangs. */
	rv = poll1(sv[0], POLLIN, 0);
	check(rv == 0, "an empty socket is NOT reported readable (timeout 0)");
	if (rv != 0)
		printf("      (revents=0x%x)\n", (unsigned)(rv & 0xffff));

	/* A connected socket with a free ring IS writable. */
	rv = poll1(sv[0], POLLOUT, 0);
	check((rv & POLLOUT) != 0, "a connected socket with ring space is POLLOUT");

	/* Peer writes -> the SAME descriptor becomes readable. This transition,
	 * not either endpoint value, is the property under test. */
	if (write(sv[1], "X", 1) != 1) {
		check(0, "peer write for the transition test");
	} else {
		rv = poll1(sv[0], POLLIN, 0);
		check((rv & POLLIN) != 0,
		    "after the peer writes, the SAME fd becomes POLLIN");
	}

	/* Drain it, and readiness must go back down -- a latched "ready" bit
	 * would leave the loop spinning on an empty socket forever. */
	if (read(sv[0], buf, 1) == 1) {
		rv = poll1(sv[0], POLLIN, 0);
		check(rv == 0, "after the data is consumed, POLLIN clears again");
	} else {
		check(0, "read back the transition byte");
	}

	close(sv[0]);
	close(sv[1]);
}

/*
 * level_triggered -- the case that keeps biting this project. Bytes are already
 * sitting in the socket before poll is ever called; the FIRST poll must see
 * them. Then poll again without consuming: level-triggered means the answer
 * repeats.
 */
static void
level_triggered(void)
{
	int sv[2];
	short rv1, rv2;
	char buf[32];

	puts("\n-- level-triggered: already-buffered data is visible to the "
	    "FIRST poll --\n");
	if (socketpair_un(sv) != 0) {
		check(0, "socketpair for the level-trigger test");
		return;
	}

	/* Write BEFORE any poll call. Nothing has had a chance to observe an
	 * "arrival edge", so only a level-triggered implementation can answer. */
	if (write(sv[1], "BUFFERED", 8) != 8) {
		check(0, "buffer data before polling");
		close(sv[0]);
		close(sv[1]);
		return;
	}

	rv1 = poll1(sv[0], POLLIN, 0);
	check((rv1 & POLLIN) != 0,
	    "THE LEVEL-TRIGGERED CASE: data buffered before poll is reported "
	    "readable on the first call");

	/* Do NOT read. Poll again: still readable, because the condition still
	 * holds. An edge-triggered answer would be 0 here. */
	rv2 = poll1(sv[0], POLLIN, 0);
	check((rv2 & POLLIN) != 0,
	    "still readable on a second poll with the data unconsumed");

	/* And the data must still be intact -- poll must not consume. */
	{
		long n = read(sv[0], buf, sizeof (buf) - 1);
		buf[n > 0 ? n : 0] = '\0';
		check(n == 8 && strcmp(buf, "BUFFERED") == 0,
		    "poll did not consume the bytes it reported");
	}

	close(sv[0]);
	close(sv[1]);
}

/*
 * timeout_blocks -- prove the timeout path waits. Measured across the call with
 * a monotonic clock, because "returned 0" is identical for a poll that waited
 * 200 ms and one that returned instantly, and the difference is a spinning
 * compositor.
 */
static void
timeout_blocks(void)
{
	int sv[2];
	unsigned long t0, t1, dt;
	int r;

	puts("\n-- the timeout path actually blocks --\n");
	if (socketpair_un(sv) != 0) {
		check(0, "socketpair for the timeout test");
		return;
	}

	/* timeout 0 on a not-ready fd: returns 0 and must NOT wait. */
	t0 = monotonic_ms();
	r = poll1(sv[0], POLLIN, 0) == 0 ? 0 : 1;
	t1 = monotonic_ms();
	dt = t1 - t0;
	check(r == 0, "timeout 0 on a not-ready fd returns no events");
	check(dt < 50, "timeout 0 returns immediately (did not block)");
	printf("      (timeout 0 took %d ms)\n", (int)dt);

	/* timeout 200 on a not-ready fd: must return 0 after ~200 ms. The lower
	 * bound is the real check; the upper bound catches a wait that never
	 * ends (a hung poll would trip the harness timeout instead, so the
	 * bound is generous). */
	{
		struct pollfd pfd;

		pfd.fd = sv[0];
		pfd.events = POLLIN;
		pfd.revents = 0;
		t0 = monotonic_ms();
		r = poll(&pfd, 1, 200);
		t1 = monotonic_ms();
		dt = t1 - t0;
		check(r == 0, "a 200 ms timeout with nothing ready returns 0");
		check(dt >= 150,
		    "THE TIMEOUT REALLY WAITED (>=150 ms elapsed, not an "
		    "instant return)");
		check(dt < 2000, "and it did not overshoot wildly");
		printf("      (200 ms poll took %d ms)\n", (int)dt);
	}

	close(sv[0]);
	close(sv[1]);
}

/*
 * blocking_wait_is_woken -- timeout -1 (block forever) must return when a peer
 * makes the fd ready. Set up so the data is written by a CHILD process while the
 * parent is blocked, which is the compositor's actual situation: the readiness
 * comes from another address space scheduled independently.
 */
static void
blocking_wait_is_woken(void)
{
	int sv[2];
	int pid, st = 0;
	short rv;
	char buf[16];

	puts("\n-- timeout -1 blocks until a SEPARATE PROCESS makes it ready --\n");
	if (socketpair_un(sv) != 0) {
		check(0, "socketpair for the blocking test");
		return;
	}

	pid = fork();
	if (pid == 0) {
		/* Child: spin a little so the parent is genuinely inside poll
		 * when the write lands, then write and exit. */
		close(sv[0]);
		spin(3000000);
		write(sv[1], "WOKE", 4);
		close(sv[1]);
		_exit(0);
	}
	if (pid < 0) {
		check(0, "fork for the blocking test");
		close(sv[0]);
		close(sv[1]);
		return;
	}

	rv = poll1(sv[0], POLLIN, -1);		/* block until ready */
	check((rv & POLLIN) != 0,
	    "poll(timeout=-1) returned POLLIN when the child wrote");
	{
		long n = read(sv[0], buf, sizeof (buf) - 1);
		buf[n > 0 ? n : 0] = '\0';
		check(n == 4 && strcmp(buf, "WOKE") == 0,
		    "and the bytes poll promised are really there");
	}
	waitpid(pid, &st, 0);
	close(sv[0]);
	close(sv[1]);
}

/*
 * hangup_and_errors -- POLLHUP, POLLNVAL, POLLERR provoked on purpose. Each has
 * a distinct cause, and reporting one for another would mislead an event loop
 * into retrying a dead descriptor forever.
 */
static void
hangup_and_errors(void)
{
	int sv[2], fds[2];
	short rv;

	puts("\n-- POLLHUP / POLLNVAL / POLLERR --\n");

	/* POLLHUP: peer closes. read() then returns 0 immediately, so POLLIN is
	 * also correct ("will not block" includes EOF) -- an event loop watching
	 * only POLLIN must still learn the client left. */
	if (socketpair_un(sv) == 0) {
		close(sv[1]);
		rv = poll1(sv[0], POLLIN, 0);
		check((rv & POLLHUP) != 0,
		    "a socket whose peer closed reports POLLHUP");
		check((rv & POLLIN) != 0,
		    "and POLLIN too, because read() returns EOF without "
		    "blocking");
		close(sv[0]);
	} else {
		check(0, "socketpair for the hangup test");
	}

	/* POLLNVAL: a descriptor that was never opened. Must be reported, and
	 * must count toward poll's return value, even though the caller did not
	 * ask for it in events. */
	{
		struct pollfd pfd;
		int r;

		pfd.fd = 6;		/* nothing opened here */
		pfd.events = POLLIN;
		pfd.revents = 0;
		r = poll(&pfd, 1, 0);
		check(r == 1 && (pfd.revents & POLLNVAL) != 0,
		    "an unopened fd reports POLLNVAL and counts as ready");
	}

	/* Negative fd: POSIX says ignore it entirely (revents 0, not counted).
	 * calloop and friends park unused slots this way. */
	{
		struct pollfd pfd;
		int r;

		pfd.fd = -1;
		pfd.events = POLLIN;
		pfd.revents = 0x7fff;		/* must be overwritten */
		r = poll(&pfd, 1, 0);
		check(r == 0 && pfd.revents == 0,
		    "a negative fd is ignored with revents cleared");
	}

	/* POLLERR: a pipe write end whose reader is gone -- a write would fail,
	 * which is a real error the kernel can see. */
	if (pipe(fds) == 0) {
		close(fds[0]);			/* drop the only reader */
		rv = poll1(fds[1], POLLOUT, 0);
		check((rv & POLLERR) != 0,
		    "a pipe write end with no readers reports POLLERR");
		close(fds[1]);
	} else {
		check(0, "pipe for the POLLERR test");
	}

	/* A pipe read end whose writers are gone: readable at EOF + POLLHUP. */
	if (pipe(fds) == 0) {
		close(fds[1]);
		rv = poll1(fds[0], POLLIN, 0);
		check((rv & POLLIN) != 0 && (rv & POLLHUP) != 0,
		    "a pipe read end with no writers reports POLLIN|POLLHUP "
		    "(EOF is readable)");
		close(fds[0]);
	} else {
		check(0, "pipe for the EOF test");
	}
}

/*
 * multi_fd -- poll several descriptors at once and check that ONLY the ready one
 * is flagged. A poll that flagged every entry would pass all the single-fd
 * checks above and still be useless.
 */
static void
multi_fd(void)
{
	int a[2], b[2];
	struct pollfd pfd[3];
	int r;

	puts("\n-- many fds at once: only the ready one is flagged --\n");
	if (socketpair_un(a) != 0 || socketpair_un(b) != 0) {
		check(0, "socketpairs for the multi-fd test");
		return;
	}

	write(b[1], "Z", 1);		/* make exactly ONE of them readable */

	pfd[0].fd = a[0]; pfd[0].events = POLLIN; pfd[0].revents = 0;
	pfd[1].fd = b[0]; pfd[1].events = POLLIN; pfd[1].revents = 0;
	pfd[2].fd = a[1]; pfd[2].events = POLLIN; pfd[2].revents = 0;

	r = poll(pfd, 3, 0);
	check(r == 1, "exactly one of three descriptors is reported ready");
	check(pfd[1].revents & POLLIN, "and it is the one with data");
	check(pfd[0].revents == 0 && pfd[2].revents == 0,
	    "the two empty descriptors are not flagged");
	if (r != 1)
		printf("      (r=%d revents %x/%x/%x)\n", r,
		    (unsigned)(pfd[0].revents & 0xffff),
		    (unsigned)(pfd[1].revents & 0xffff),
		    (unsigned)(pfd[2].revents & 0xffff));

	close(a[0]); close(a[1]); close(b[0]); close(b[1]);
}

/*
 * regular_file_and_fb -- POSIX says a regular file is always ready. A compositor
 * puts config files and the framebuffer in the same poll set as its sockets, and
 * a poll that blocked on a regular file would deadlock the whole loop.
 */
static void
regular_file_and_fb(void)
{
	int fd;
	short rv;

	puts("\n-- regular files are always ready; /dev/fb is writable only --\n");
	fd = open("/tmp/polltest.dat", O_RDWR | O_CREAT);
	if (fd < 0) {
		check(0, "open a regular file for the readiness test");
		return;
	}
	rv = poll1(fd, POLLIN | POLLOUT, 0);
	check((rv & POLLIN) != 0 && (rv & POLLOUT) != 0,
	    "a regular file is POLLIN|POLLOUT (POSIX: never blocks)");
	close(fd);

	/* /dev/fb: writable, and NOT readable -- read() on it returns 0 forever,
	 * so claiming POLLIN would make a compositor spin. Skipped without a
	 * display device rather than failed. */
	fd = open("/dev/fb", O_RDWR);
	if (fd < 0) {
		puts("  [skip] no /dev/fb on this boot\n");
		return;
	}
	rv = poll1(fd, POLLIN | POLLOUT, 0);
	check((rv & POLLOUT) != 0 && (rv & POLLIN) == 0,
	    "/dev/fb is POLLOUT and deliberately NOT POLLIN");
	close(fd);
}

/*
 * poll_negative_control -- THE NEGATIVE CONTROL. Sabotage the mechanism and
 * assert the sabotage is detected.
 *
 * The sabotage: ask poll about a socket that has no data, no queued rights and a
 * live peer that has written nothing. The correct answer is "not readable". If
 * poll is ever changed to report readiness unconditionally -- the single most
 * likely way this subsystem regresses into uselessness, and the way that makes a
 * compositor burn a core -- then it answers POLLIN here and THIS CHECK FLIPS TO
 * FAIL while every positive check in the file still passes.
 *
 * The second half sabotages in the other direction: a socket that DOES have data
 * must not be reported unready. Together they pin the answer from both sides, so
 * neither a constant-yes nor a constant-no implementation can pass this file.
 */
static void
poll_negative_control(void)
{
	int sv[2];
	short rv_empty, rv_full;

	puts("\n-- NEGATIVE CONTROL: a constant answer must fail --\n");
	if (socketpair_un(sv) != 0) {
		check(0, "socketpair for the negative control");
		return;
	}

	rv_empty = poll1(sv[0], POLLIN, 0);
	write(sv[1], "D", 1);
	rv_full = poll1(sv[0], POLLIN, 0);

	check((rv_empty & POLLIN) == 0,
	    "CONTROL A: an empty socket is not POLLIN (fails if poll ever "
	    "reports readiness unconditionally)");
	check((rv_full & POLLIN) != 0,
	    "CONTROL B: a socket with data IS POLLIN (fails if poll ever "
	    "reports unreadiness unconditionally)");
	check(rv_empty != rv_full,
	    "CONTROL C: the two answers DIFFER -- poll is reading real state, "
	    "not returning a constant");

	close(sv[0]);
	close(sv[1]);
}

/*
 * anon_mmap_gate -- anonymous mmap: what Rust std and every allocator want, and
 * until now only /dev/fb was mappable here.
 */
static void
anon_mmap_gate(void)
{
	unsigned long len = 3 * 4096;	/* deliberately multi-page */
	unsigned char *m, *m2;
	unsigned long i;
	int zeroed = 1, ok = 1;

	puts("\n-- anonymous mmap (MAP_ANON = 0x100, the illumos value) --\n");

	m = (unsigned char *)mmap_anon(len);
	if (m == (unsigned char *)MAP_FAILED) {
		check(0, "mmap(MAP_ANON) returns a mapping");
		return;
	}
	check(1, "mmap(MAP_ANON|MAP_PRIVATE) returns a mapping");

	/* MAP_ANON REQUIRES zero-fill. A mapping that handed back a recycled
	 * page would pass a write-then-read test while leaking data. */
	for (i = 0; i < len; i++)
		if (m[i] != 0) { zeroed = 0; break; }
	check(zeroed, "the mapping is zero-filled (MAP_ANON requires it, and a "
	    "recycled page would leak)");

	/* Write across every page and read back. Touching all three pages is
	 * what catches a mapping that only really installed the first one. */
	for (i = 0; i < len; i++)
		m[i] = (unsigned char)((i * 31 + 7) & 0xff);
	for (i = 0; i < len; i++)
		if (m[i] != (unsigned char)((i * 31 + 7) & 0xff)) {
			ok = 0;
			break;
		}
	check(ok, "every byte of all 3 pages writes and reads back correctly");
	if (!ok)
		printf("      (first mismatch at offset %d)\n", (int)i);

	/* A second mapping must be DISTINCT, not the same arena VA handed out
	 * twice -- which would silently corrupt whichever allocator got it
	 * second. Prove it by writing a different pattern and re-checking the
	 * first mapping. */
	m2 = (unsigned char *)mmap_anon(4096);
	if (m2 == (unsigned char *)MAP_FAILED) {
		check(0, "a second mmap(MAP_ANON) succeeds");
	} else {
		check(m2 != m, "the second mapping is at a different address");
		for (i = 0; i < 4096; i++)
			m2[i] = 0xa5;
		check(m[0] == (unsigned char)7,
		    "writing the second mapping did not disturb the first");
	}

	/* The Linux MAP_ANON value must be REFUSED, not misread as a file
	 * mapping of fd 0x20. This is the exact mistake a prior Rust binary
	 * made, and a silent wrong mapping is far worse than an error. */
	{
		void *bad = mmap(0, 4096, PROT_READ | PROT_WRITE,
		    0x20 /* Linux MAP_ANONYMOUS */, -1, 0);

		check(bad == MAP_FAILED,
		    "Linux's MAP_ANON value (0x20) is REFUSED, not silently "
		    "treated as a file mapping");
	}

	/* Zero length must fail rather than return a 0-page mapping. */
	check(mmap_anon(0) == MAP_FAILED, "mmap(MAP_ANON, len=0) fails");

	/*
	 * munmap + ARENA REUSE. The arena used to be a bump allocator with no
	 * reuse, so this is the check that matters: map, unmap, map the same size
	 * again, and the SAME VA must come back. If it does not, the arena is
	 * still leaking on every unmap and a long-running compositor exhausts it.
	 */
	{
		unsigned char *m3 = mmap_anon(8192);
		unsigned char *m4;
		long ur;

		check(m3 != (unsigned char *)MAP_FAILED, "mmap 8K for the reuse test");
		if (m3 != (unsigned char *)MAP_FAILED) {
			m3[0] = 0x5a;
			m3[8191] = 0xa5;
			check(m3[0] == 0x5a && m3[8191] == 0xa5,
			    "the mapping is writable end to end");
			ur = __sys(215 /*SYS_munmap*/, (long)m3, 8192, 0, 0);
			check(ur == 0, "munmap(8K) succeeds");
			m4 = mmap_anon(8192);
			check(m4 == m3,
			    "ARENA REUSE: the same VA comes back after munmap");
			if (m4 != (unsigned char *)MAP_FAILED) {
				check(m4[0] == 0 && m4[8191] == 0,
				    "the reused mapping is ZEROED (no stale data leak)");
			}
		}
		/* Negative: unmapping something never mapped must fail. */
		check(__sys(215, 0xD0000000L - 4096, 4096, 0, 0) != 0,
		    "NEGATIVE: munmap of an unmapped VA fails");
		check(__sys(215, 0xD0001001L, 4096, 0, 0) != 0,
		    "NEGATIVE: munmap of a misaligned addr fails");
	}
}

int
main(int argc, char **argv)
{
	(void) argc;
	(void) argv;
	puts("POLLTEST: poll(2) readiness + timeouts + anonymous mmap\n");

	readiness_transitions();
	level_triggered();
	timeout_blocks();
	blocking_wait_is_woken();
	hangup_and_errors();
	multi_fd();
	regular_file_and_fb();
	poll_negative_control();
	anon_mmap_gate();

	printf("\n%d checks run, %d failed\n", checks, failures);
	if (failures == 0)
		puts("POLLTEST PASS\n");
	else
		printf("POLLTEST FAIL (%d checks failed)\n", failures);
	return (failures == 0 ? 0 : 1);
}
