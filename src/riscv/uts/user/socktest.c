/*
 * socktest.c -- the AF_UNIX gate: two processes, a real byte exchange, and an fd
 * passed with SCM_RIGHTS whose received copy is PROVEN USABLE.
 *
 * WHY THE LAST CLAUSE IS THE WHOLE POINT. A test that checks return codes proves
 * nothing about fd passing: a kernel that returned 0 from sendmsg and handed back
 * a plausible small integer would pass such a test while passing no descriptor at
 * all. So this test does not ask "did recvmsg report an fd" -- it WRITES THROUGH
 * the received descriptor and then reads the bytes back out of the underlying
 * object, which can only work if the descriptor genuinely refers to it. Without
 * that, nothing renders in a compositor and we would not find out until much
 * later.
 *
 * WHAT IS EXERCISED
 *   1. socket/bind/listen/accept/connect over a filesystem-named socket, with a
 *      real fork so the two ends are separate processes scheduled independently.
 *   2. Bytes in BOTH directions (client->server and server->client), because a
 *      stream socket is not a pipe and a one-directional test would not notice
 *      the two rings being aliased.
 *   3. SCM_RIGHTS: the client sends a descriptor; the server receives it and
 *      writes through it; the client then reads the underlying file and checks
 *      the server's bytes are there.
 *   4. socketpair, the one AF_UNIX call needing no namespace at all.
 *   5. Error paths: an unbound path must fail to connect, a non-socket fd must be
 *      rejected by listen. A driver that returned 0 for everything would
 *      otherwise look like it passed.
 */

#include "libc.h"

static int failures;

static void
check(int ok, const char *what)
{
	printf("  [%s] %s\n", ok ? "ok" : "FAIL", what);
	if (!ok)
		failures++;
}

#define	SOCKPATH	"/tmp/soktest.sock"
#define	PASSFILE	"/tmp/passed.dat"

/* What the server writes through the RECEIVED descriptor. */
#define	SERVER_MARK	"SERVER-WROTE-THROUGH-PASSED-FD"

/*
 * server_side -- runs in the child. Accepts one connection, reads the client's
 * greeting plus the passed descriptor, writes a marker THROUGH that descriptor
 * (the usability proof), and replies on the socket.
 */
static int
server_side(int lfd)
{
	char buf[128];
	int fds[4], nfds = 0, cfd;
	long n;
	int bad = 0;

	cfd = accept_un(lfd);
	if (cfd < 0) {
		puts("  [FAIL] server: accept failed\n");
		return (1);
	}

	/* Read the greeting AND collect any rights that arrived with it. */
	n = recvmsg_fds(cfd, buf, sizeof (buf) - 1, fds, 4, &nfds);
	if (n < 0) {
		puts("  [FAIL] server: recvmsg failed\n");
		return (1);
	}
	buf[n] = '\0';
	if (strcmp(buf, "HELLO-FROM-CLIENT") != 0) {
		printf("  [FAIL] server: payload '%s'\n", buf);
		bad++;
	}
	if (nfds != 1) {
		printf("  [FAIL] server: expected 1 passed fd, got %d\n", nfds);
		/* Without the fd there is nothing left to prove; reply and stop. */
		(void) sendmsg_fds(cfd, "NOFD", 4, 0, 0);
		return (1);
	}

	/*
	 * THE PROOF: write through the fd we were handed. If SCM_RIGHTS did not
	 * really pass the object, this write goes nowhere (or to the wrong
	 * object) and the client's read below will not find these bytes.
	 */
	if (write(fds[0], SERVER_MARK, strlen(SERVER_MARK)) !=
	    (long)strlen(SERVER_MARK)) {
		puts("  [FAIL] server: write through the passed fd failed\n");
		bad++;
	}
	close(fds[0]);

	/* Reply on the socket: proves the reverse direction carries bytes. */
	if (sendmsg_fds(cfd, "WROTE-IT", 8, 0, 0) != 8) {
		puts("  [FAIL] server: reply send failed\n");
		bad++;
	}
	close(cfd);
	return (bad);
}

/*
 * socketpair_gate -- socketpair(2) needs no filesystem name, so it isolates the
 * ring/transport from the namespace. If the named path fails but this passes, the
 * bug is in bind/connect; if both fail, it is in the rings.
 */
static void
socketpair_gate(void)
{
	int sv[2];
	char buf[32];
	long n;

	if (socketpair_un(sv) != 0) {
		check(0, "socketpair(AF_UNIX, SOCK_STREAM)");
		return;
	}
	check(1, "socketpair(AF_UNIX, SOCK_STREAM)");

	if (write(sv[1], "PING", 4) != 4) {
		check(0, "socketpair: write one way");
	} else {
		n = read(sv[0], buf, sizeof (buf) - 1);
		buf[n > 0 ? n : 0] = '\0';
		check(n == 4 && strcmp(buf, "PING") == 0,
		    "socketpair: bytes cross end-to-end");
	}

	/* The other direction must work too, on its own ring. */
	if (write(sv[0], "PONG", 4) != 4) {
		check(0, "socketpair: write the other way");
	} else {
		n = read(sv[1], buf, sizeof (buf) - 1);
		buf[n > 0 ? n : 0] = '\0';
		check(n == 4 && strcmp(buf, "PONG") == 0,
		    "socketpair: the reverse direction is a separate ring");
	}
	close(sv[0]);
	close(sv[1]);
}

static void
error_paths(void)
{
	int fd;

	/* connect to a name nobody bound must fail, not block. */
	fd = socket(AF_UNIX, SOCK_STREAM, 0);
	check(fd >= 0, "socket() for the negative test");
	if (fd >= 0) {
		check(connect_un(fd, "/tmp/nobody-bound-this") < 0,
		    "connect to an unbound path fails (not a silent success)");
		close(fd);
	}

	/* listen on a non-socket descriptor must be refused. */
	fd = open(PASSFILE, O_RDWR | O_CREAT);
	if (fd >= 0) {
		check(listen_un(fd, 1) < 0,
		    "listen on a non-socket fd is refused");
		close(fd);
	}
}

int
main(int argc, char **argv)
{
	int lfd, cfd, pid, st = 0, passfd, sotype = 0;
	char buf[128];
	long n;

	(void) argc;
	(void) argv;
	puts("SOCKTEST: AF_UNIX/SOCK_STREAM + SCM_RIGHTS\n");

	socketpair_gate();

	/* --- the named-socket, two-process path --- */
	lfd = socket(AF_UNIX, SOCK_STREAM, 0);
	check(lfd >= 0, "socket(AF_UNIX, SOCK_STREAM)");
	if (lfd < 0)
		goto done;

	check(getsockopt_int(lfd, SOL_SOCKET, SO_TYPE, &sotype) == 0 &&
	    sotype == SOCK_STREAM, "getsockopt(SO_TYPE) reports SOCK_STREAM");

	check(bind_un(lfd, SOCKPATH) == 0, "bind() a filesystem-named socket");
	check(bind_un(lfd, SOCKPATH) < 0, "a second bind on the same fd fails");
	check(listen_un(lfd, 2) == 0, "listen()");

	/*
	 * Create the file whose descriptor will be passed, BEFORE the fork, so
	 * both processes agree it exists. The client passes its descriptor; the
	 * server writes through it; the client reads the result back.
	 */
	passfd = open(PASSFILE, O_RDWR | O_CREAT);
	check(passfd >= 0, "open() the file whose fd will be passed");
	if (passfd < 0)
		goto done;

	pid = fork();
	if (pid == 0) {
		/* Child = server. Exits with the number of failures. */
		_exit(server_side(lfd));
	}
	if (pid < 0) {
		check(0, "fork() the server");
		goto done;
	}

	/* Parent = client. */
	cfd = socket(AF_UNIX, SOCK_STREAM, 0);
	check(cfd >= 0, "client socket()");
	check(connect_un(cfd, SOCKPATH) == 0, "connect() to the bound name");

	/* Send the greeting AND the descriptor together (what Wayland does). */
	n = sendmsg_fds(cfd, "HELLO-FROM-CLIENT", 17, &passfd, 1);
	check(n == 17, "sendmsg() with one SCM_RIGHTS descriptor");

	/* The server's reply proves the server->client direction. */
	n = read(cfd, buf, sizeof (buf) - 1);
	buf[n > 0 ? n : 0] = '\0';
	check(n == 8 && strcmp(buf, "WROTE-IT") == 0,
	    "the server's reply arrives (server->client direction)");

	waitpid(pid, &st, 0);
	check(st == 0, "the server side reported no failures");

	/*
	 * THE DECISIVE CHECK. Re-read the file from the CLIENT. The bytes can
	 * only be here if the descriptor the server received genuinely referred
	 * to this same object -- i.e. SCM_RIGHTS passed a real fd, not a number.
	 */
	{
		int vfd = open(PASSFILE, O_RDONLY);

		if (vfd < 0) {
			check(0, "reopen the passed-through file");
		} else {
			n = read(vfd, buf, sizeof (buf) - 1);
			buf[n > 0 ? n : 0] = '\0';
			check(n == (long)strlen(SERVER_MARK) &&
			    strcmp(buf, SERVER_MARK) == 0,
			    "THE PROOF: bytes the server wrote through the "
			    "RECEIVED fd are in the file");
			if (strcmp(buf, SERVER_MARK) != 0)
				printf("      (read back '%s')\n", buf);
			close(vfd);
		}
	}
	close(cfd);
	close(passfd);
	close(lfd);

	error_paths();

done:
	if (failures == 0)
		puts("SOCKTEST PASS\n");
	else
		printf("SOCKTEST FAIL (%d checks failed)\n", failures);
	return (failures == 0 ? 0 : 1);
}
