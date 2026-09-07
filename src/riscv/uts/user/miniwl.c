/*
 * miniwl.c - a miniature compositor: the integration test.
 *
 * WHY THIS EXISTS. Every Gate A subsystem has its own passing gate -- AF_UNIX +
 * SCM_RIGHTS, poll(2), event ports, FP context switch, /dev/fb scanout, munmap,
 * nanosleep. Each was verified in isolation with a negative control. None of that
 * proves they work TOGETHER in the shape smallvil actually uses them, and
 * interaction bugs are precisely what per-feature tests cannot see: an event port
 * that is fine alone may mis-report an fd that a *different* subsystem just
 * closed; a timer that sleeps correctly may starve the socket that a compositor
 * needs to answer.
 *
 * So this is deliberately structured as the real thing in miniature:
 *
 *   server (parent)                        client (child)
 *   ---------------                        --------------
 *   socketpair as the "wayland socket"     connect (inherited fd)
 *   port_associate the socket              send a request
 *   port_getn as the event loop            send a buffer fd (SCM_RIGHTS)
 *   on readable: read the request          exit
 *   map /dev/fb, paint a frame             |
 *   flush the damage rect                  |
 *   nanosleep as the frame timer           |
 *   re-associate (oneshot) and loop        |
 *   port_send to break the loop            |
 *   munmap the scratch buffer              |
 *
 * The pass condition is that a FRAME IS PRESENTED as a consequence of a CLIENT
 * REQUEST that arrived through an EVENT PORT -- i.e. the causal chain a compositor
 * depends on, not four independent successes.
 *
 * NEGATIVE CONTROL: the loop must NOT report the socket readable before the client
 * writes. Without that, a port implementation returning "everything is ready
 * always" would drive this test to a perfect pass while being useless.
 */

#include "libc.h"
#include "../../../riscv-port/rp64/kernel/fbio.h"

#define	SYS_nanosleep		101
#define	SYS_munmap		215
#define	SYS_port_create		510
#define	SYS_port_associate	511
#define	SYS_port_getn		513
#define	SYS_port_send		514

#define	PORT_SOURCE_USER	3
#define	PORT_SOURCE_FD		4
#define	POLLIN_			0x0001

/* Must match the kernel's port_event_t. */
typedef struct port_event {
	int		pe_source;
	int		pe_events;
	int		pe_fd;
	unsigned long	pe_user;
} port_event_t;

struct ts { long tv_sec; long tv_nsec; };

/*
 * fbtest's pattern, duplicated verbatim so the restore below is identical BY
 * CONSTRUCTION rather than by a hand-copied byte layout (my first attempt guessed
 * the byte order and was wrong -- fbtest writes 32-bit words).
 */
#define	PX_WHITE	0x00ffffffu
#define	PX_RED		0x00ff0000u
#define	PX_GREEN	0x0000ff00u
#define	PX_BLUE		0x000000ffu

static unsigned int
pattern_pixel(unsigned int x, unsigned int y, unsigned int w, unsigned int h)
{
	if (x * h == y * w)			/* the diagonal */
		return (PX_WHITE);
	if (y < h / 2)
		return (x < w / 2 ? PX_RED : PX_GREEN);
	return (x < w / 2 ? PX_BLUE : PX_WHITE);
}

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
port_assoc(int p, int fd, unsigned long user)
{
	return ((int)__sys6(SYS_port_associate, p, PORT_SOURCE_FD, fd, POLLIN_,
	    (long)user, 0));
}

static int
port_wait(int p, port_event_t *ev, int max, unsigned int *n, int ms)
{
	return ((int)__sys6(SYS_port_getn, p, (long)ev, max, (long)n, ms, 0));
}

/*
 * Paint a recognisable pattern into the framebuffer and flush it. Returns 0 on
 * success. Kept separate so the event loop below reads as a loop.
 */
static int
present_frame(unsigned char *fb, unsigned int stride, unsigned int w,
    unsigned int h, int fbfd, unsigned int seq)
{
	unsigned int x, y;

	/*
	 * A different colour per frame, so "a frame was presented" cannot be
	 * satisfied by a stale buffer that was already the right colour.
	 */
	for (y = 0; y < h; y++) {
		unsigned char *row = fb + (unsigned long)y * stride;

		for (x = 0; x < w; x++) {
			row[x * 4 + 0] = (unsigned char)(seq * 60);	/* B */
			row[x * 4 + 1] = (unsigned char)(x & 0xff);	/* G */
			row[x * 4 + 2] = (unsigned char)(y & 0xff);	/* R */
			row[x * 4 + 3] = 0xff;
		}
	}
	return (ioctl(fbfd, FBIOFLUSH, 0));
}

int
main(int argc, char **argv)
{
	port_event_t ev[8];
	struct fb_mode mode;
	unsigned char *fb;
	unsigned int n, frames = 0;
	int p, sv[2], fbfd, pid, st = 0, i;
	int saw_client_request = 0, saw_wakeup = 0;

	(void) argc; (void) argv;

	printf("=== miniwl: compositor-shaped integration test ===\n");

	/* --- the "wayland socket" and the event loop's port --- */
	check(socketpair_un(sv) == 0, "socketpair as the wayland socket");
	p = (int)__sys(SYS_port_create, 0, 0, 0, 0);
	check(p >= 0, "port_create for the event loop");
	if (p < 0 || sv[0] < 0) {
		printf("MINIWL FAIL: no socket or no port\n");
		return (1);
	}

	/* --- the display --- */
	fbfd = open("/dev/fb", 2 /* O_RDWR */);
	check(fbfd >= 0, "open /dev/fb");
	if (fbfd < 0) {
		printf("MINIWL FAIL: no framebuffer\n");
		return (1);
	}
	check(ioctl(fbfd, FBIOGMODE, &mode) == 0, "ioctl(FBIOGMODE)");
	fb = (unsigned char *)mmap(0, mode.size, PROT_READ | PROT_WRITE,
	    MAP_SHARED, fbfd, 0);
	check(fb != (unsigned char *)MAP_FAILED, "mmap the framebuffer");
	if (fb == (unsigned char *)MAP_FAILED) {
		printf("MINIWL FAIL: framebuffer not mappable\n");
		return (1);
	}

	/*
	 * Prove the mapping is writable BEFORE any fork. This discriminates "the
	 * fb mapping never worked" from "the fork/exit cycle destroyed it" -- two
	 * bugs that look identical from a store fault after the fork.
	 */
	fb[0] = 0x11;
	check(fb[0] == 0x11, "the fb mapping is writable BEFORE any fork");

	/*
	 * NEGATIVE CONTROL, before the client exists: the loop must NOT see the
	 * socket as readable. If it does, every "we reacted to a client" result
	 * below is meaningless.
	 */
	check(port_assoc(p, sv[0], 0x1001) == 0, "associate the wayland socket");
	n = 99;
	check(port_wait(p, ev, 8, &n, 0) == 0 && n == 0,
	    "NEGATIVE CONTROL: no event before any client writes");

	/* --- fork the client --- */
	pid = fork();
	if (pid == 0) {
		/* The client: a request, then a buffer fd over SCM_RIGHTS. */
		int bfd[2];

		close(sv[0]);
		write(sv[1], "FRAME", 5);
		if (socketpair_un(bfd) == 0) {
			int one = bfd[0];

			(void) sendmsg_fds(sv[1], "F", 1, &one, 1);
			close(bfd[0]);
			close(bfd[1]);
		}
		close(sv[1]);
		_exit(0);
	}
	check(pid > 0, "fork the client");
	close(sv[1]);		/* the server does not hold the client end */

	/*
	 * --- THE EVENT LOOP ---
	 * This is the shape that matters: block in port_getn, react to what the
	 * port reports, present a frame, arm a timer, re-associate (oneshot), and
	 * keep going until a user event breaks us out.
	 */
	for (i = 0; i < 12; i++) {
		struct ts req;

		n = 0;
		if (port_wait(p, ev, 8, &n, 200) != 0)
			break;

		for (unsigned int k = 0; k < n; k++) {
			if (ev[k].pe_source == PORT_SOURCE_USER) {
				saw_wakeup = 1;
				continue;
			}
			if (ev[k].pe_source == PORT_SOURCE_FD &&
			    ev[k].pe_fd == sv[0]) {
				char buf[32];
				long got = read(sv[0], buf, sizeof (buf));

				if (got > 0)
					saw_client_request = 1;
				/*
				 * A client request is what makes a compositor
				 * draw. Present here, so a presented frame is
				 * CAUSED by the request rather than merely
				 * co-occurring with it.
				 */
				if (present_frame(fb, mode.stride,
				    mode.width, mode.height, fbfd,
				    ++frames) == 0 && frames == 1) {
					/* Break the loop once we have drawn. */
					(void) __sys(SYS_port_send, p,
					    0xB0B0, 0, 0);
				}
				/* ONESHOT: re-arm, as a real loop must. */
				(void) port_assoc(p, sv[0], 0x1001);
			}
		}

		/* The frame timer -- calloop arms exactly this. */
		req.tv_sec = 0;
		req.tv_nsec = 8000000L;			/* ~8 ms */
		(void) __sys(SYS_nanosleep, (long)&req, 0, 0, 0);

		if (saw_wakeup)
			break;
	}

	check(saw_client_request,
	    "the loop received the client's request THROUGH the port");
	check(frames >= 1,
	    "a frame was PRESENTED as a consequence of that request");
	check(saw_wakeup, "port_send broke the blocking loop (calloop's wakeup)");

	waitpid(pid, &st, 0);
	check(st == 0, "the client exited cleanly");

	/*
	 * --- teardown, exercising munmap in the same process that mapped ---
	 * A compositor resizing a buffer pool does exactly this, and it is where
	 * the old bump-allocator arena would have leaked.
	 */
	{
		unsigned char *scratch = mmap_anon(16384);

		check(scratch != (unsigned char *)MAP_FAILED,
		    "mmap a scratch buffer (a resize would do this)");
		if (scratch != (unsigned char *)MAP_FAILED) {
			scratch[0] = 1;
			check(__sys(SYS_munmap, (long)scratch, 16384, 0, 0) == 0,
			    "munmap the scratch buffer");
			check(mmap_anon(16384) == scratch,
			    "the arena REUSED that VA (no leak per frame)");
		}
	}

	/*
	 * Repaint fbtest's pattern before leaving.
	 *
	 * The SCANOUT gate is verified from OUTSIDE the guest, by a QMP
	 * screendump of the host display, and it expects the pattern fbtest
	 * painted. We run after fbtest and legitimately drew our own frames over
	 * it, which would fail that gate for a bogus reason -- the display really
	 * did contain what the last writer wrote. Restore it so both gates can
	 * coexist in one boot; the frames we presented above are already proven by
	 * this test's own checks.
	 *
	 * Matches fbtest.c's pattern exactly (R=x, G=y, B=0x80, X=0xff).
	 */
	{
		unsigned int x, y;

		for (y = 0; y < mode.height; y++) {
			unsigned int *row = (unsigned int *)(fb +
			    (unsigned long)y * mode.stride);

			for (x = 0; x < mode.width; x++)
				row[x] = pattern_pixel(x, y, mode.width,
				    mode.height);
		}
		(void) ioctl(fbfd, FBIOFLUSH, 0);
	}

	close(fbfd);
	close(sv[0]);
	close(p);

	printf("%d checks, %d failed (frames presented: %u)\n", checks, bad,
	    frames);
	if (bad == 0)
		printf("MINIWL PASS: socket + port + timer + framebuffer work "
		    "TOGETHER\n");
	else
		printf("MINIWL FAIL: %d checks failed\n", bad);
	return (bad == 0 ? 0 : 1);
}
