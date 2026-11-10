/*
 * test-poll-nested-wake.c: does an event on a socket inside an INNER epoll wake a thread sleeping in the OUTER
 * epoll that holds the inner epoll fd? This is cosmic-comp's shape (calloop epoll -> wayland-server epoll -> client
 * socket). Kernel patch scripts/patches/0012-poll-nested-wake.patch; runner scripts/test-poll-nested-wake.sh.
 *
 * usage: test-poll-nested-wake nested|flat <iters> [max_delay_us]
 *   nested: outer{inner{sock}}   flat: outer{sock} (one epoll level, which never lost a wake)
 * A writer thread writes one byte 0..max_delay_us-1 us after the reader has drained the last one, i.e. while the
 * reader re-enters epoll_wait. A LOST wake = epoll_wait(outer, 200 ms) timed out with the byte unread (FIONREAD > 0).
 * Prints one line "mode=... iters=N lost=L ..."; exits 0 if L == 0, 1 if L > 0, 2 on a setup error.
 */
#include <sys/epoll.h>
#include <sys/socket.h>
#include <sys/filio.h>
#include <sys/ioctl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <errno.h>

static int sv[2], iters, maxd = 1;
static atomic_int acked = 1;
static atomic_long wtime;

static long now_us(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (t.tv_sec * 1000000L + t.tv_nsec / 1000);
}

static void *writer(void *a)
{
	unsigned s = 12345;
	for (int i = 0; i < iters; i++) {
		while (!atomic_load(&acked))
			;			/* until the reader drained and re-entered */
		atomic_store(&acked, 0);
		s = s * 1103515245 + 12345;
		long d = (s >> 8) % maxd, t0 = now_us();
		while (now_us() - t0 < d)
			;
		atomic_store(&wtime, now_us());
		if (write(sv[1], "x", 1) != 1) { perror("write"); exit(2); }
	}
	return (a);
}

int main(int argc, char **argv)
{
	if (argc < 3 || (strcmp(argv[1], "nested") != 0 && strcmp(argv[1], "flat") != 0)) {
		fprintf(stderr, "usage: %s nested|flat iters [max_delay_us]\n", argv[0]);
		return (2);
	}
	int nested = strcmp(argv[1], "nested") == 0, outer, inner = -1;
	iters = atoi(argv[2]);
	if (argc > 3) maxd = atoi(argv[3]);
	if (iters < 1 || maxd < 1) { fprintf(stderr, "iters and max_delay_us must be >= 1\n"); return (2); }
	if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0) { perror("socketpair"); return (2); }
	struct epoll_event ev = { .events = EPOLLIN };
	if ((outer = epoll_create1(EPOLL_CLOEXEC)) < 0) { perror("epoll_create1"); return (2); }
	if (nested) {
		if ((inner = epoll_create1(EPOLL_CLOEXEC)) < 0) { perror("epoll_create1"); return (2); }
		ev.data.fd = sv[0];
		if (epoll_ctl(inner, EPOLL_CTL_ADD, sv[0], &ev)) { perror("epoll_ctl inner"); return (2); }
		ev.data.fd = inner;
		if (epoll_ctl(outer, EPOLL_CTL_ADD, inner, &ev)) { perror("epoll_ctl outer"); return (2); }
	} else {
		ev.data.fd = sv[0];
		if (epoll_ctl(outer, EPOLL_CTL_ADD, sv[0], &ev)) { perror("epoll_ctl outer"); return (2); }
	}
	pthread_t w;
	if (pthread_create(&w, NULL, writer, NULL) != 0) { perror("pthread_create"); return (2); }
	int got = 0, lost = 0;
	long worst = 0, sum = 0;
	while (got < iters) {
		struct epoll_event e[4];
		int n = epoll_wait(outer, e, 4, 200), avail = 0;
		if (n < 0) {
			if (errno == EINTR) continue;
			perror("epoll_wait"); return (2);
		}
		if (ioctl(sv[0], FIONREAD, &avail) < 0) { perror("FIONREAD"); return (2); }
		if (n == 0) {
			if (avail == 0) continue;	/* writer not there yet */
			lost++;				/* the byte sat unread for the whole 200 ms */
		}
		if (nested) { struct epoll_event ie[4]; (void) epoll_wait(inner, ie, 4, 0); }
		char b[64];
		int r = read(sv[0], b, sizeof (b));
		if (r <= 0) continue;
		long l = now_us() - atomic_load(&wtime);
		if (l > worst) worst = l;
		sum += l; got += r;
		atomic_store(&acked, 1);
	}
	pthread_join(w, NULL);
	printf("mode=%s iters=%d maxd_us=%d lost=%d worst_us=%ld mean_us=%ld\n",
	    argv[1], iters, maxd, lost, worst, sum / got);
	return (lost == 0 ? 0 : 1);
}
