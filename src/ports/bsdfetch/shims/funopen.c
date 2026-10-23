/*
 * funopen.c -- BSD funopen(3) for illumos, which has neither funopen nor fopencookie.
 *
 * libfetch returns its HTTP/FTP streams as FILE * built with funopen(cookie, read, write,
 * seek, close). illumos stdio cannot route a FILE through user callbacks, so this builds the
 * FILE over one end of a socketpair and runs a thread that pumps bytes between the other end
 * and the callbacks:
 *   - read-only stream (readfn set, writefn NULL): the thread calls readfn and writes what it
 *     returns into the pair; the caller's fread() reads it. readfn <= 0 ends the stream.
 *   - write-only stream (writefn set, readfn NULL): the thread reads from the pair and hands
 *     the bytes to writefn; the caller's fclose() closes its end, the thread sees EOF.
 * Streams with both callbacks (none in libfetch's GET/PUT paths) are opened read-only.
 * seekfn is unsupported (libfetch passes NULL for HTTP; FTP's seek is only used for restarts
 * that fetch(1) does not request through the stream). fclose() returns at once; the thread
 * finishes the transfer, then calls closefn.
 *
 * shortcut: fclose() on a read stream that the caller abandons early leaves the pump blocked
 * in readfn until the peer closes; fine for fetch(1), which reads to EOF. Upgrade to a
 * stdio-level hook if libfetch is ever used by a long-running program.
 */
#include <sys/types.h>
#include <sys/socket.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

typedef int (*rdfn_t)(void *, char *, int);
typedef int (*wrfn_t)(void *, const char *, int);
typedef int (*clfn_t)(void *);

struct fo {
	void	*cookie;
	rdfn_t	rd;
	wrfn_t	wr;
	clfn_t	cl;
	int	fd;		/* the pump's end of the socketpair */
};

static int
writeall(int fd, const char *p, size_t n)
{
	while (n > 0) {
		ssize_t w = write(fd, p, n);
		if (w < 0) {
			if (errno == EINTR)
				continue;
			return (-1);
		}
		p += w;
		n -= (size_t)w;
	}
	return (0);
}

static void *
pump(void *arg)
{
	struct fo *f = arg;
	char buf[16384];

	if (f->rd != NULL) {
		for (;;) {
			int r = f->rd(f->cookie, buf, (int)sizeof (buf));
			if (r <= 0 || writeall(f->fd, buf, (size_t)r) != 0)
				break;
		}
	} else {
		for (;;) {
			ssize_t r = read(f->fd, buf, sizeof (buf));
			if (r < 0 && errno == EINTR)
				continue;
			if (r <= 0)
				break;
			for (ssize_t off = 0; off < r; ) {
				int w = f->wr(f->cookie, buf + off, (int)(r - off));
				if (w <= 0)
					goto done;
				off += w;
			}
		}
	}
done:
	(void) close(f->fd);
	if (f->cl != NULL)
		(void) f->cl(f->cookie);
	free(f);
	return (NULL);
}

FILE *
funopen(const void *cookie, rdfn_t readfn, wrfn_t writefn,
    fpos_t (*seekfn)(void *, fpos_t, int), clfn_t closefn)
{
	int sv[2];
	struct fo *f;
	pthread_t t;
	pthread_attr_t a;
	FILE *fp;
	int reading = (readfn != NULL);

	(void) seekfn;
	if (readfn == NULL && writefn == NULL) {
		errno = EINVAL;
		return (NULL);
	}
	if ((f = calloc(1, sizeof (*f))) == NULL)
		return (NULL);
	if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) {
		free(f);
		return (NULL);
	}
	f->cookie = (void *)cookie;
	f->rd = reading ? readfn : NULL;
	f->wr = reading ? NULL : writefn;
	f->cl = closefn;
	f->fd = sv[1];
	if ((fp = fdopen(sv[0], reading ? "r" : "w")) == NULL) {
		(void) close(sv[0]);
		(void) close(sv[1]);
		free(f);
		return (NULL);
	}
	/* A pump writing to a reader that closed early must not kill the process. */
	(void) sigignore(SIGPIPE);
	(void) pthread_attr_init(&a);
	(void) pthread_attr_setdetachstate(&a, PTHREAD_CREATE_DETACHED);
	if (pthread_create(&t, &a, pump, f) != 0) {
		(void) pthread_attr_destroy(&a);
		(void) fclose(fp);
		(void) close(sv[1]);
		free(f);
		errno = EAGAIN;
		return (NULL);
	}
	(void) pthread_attr_destroy(&a);
	return (fp);
}
