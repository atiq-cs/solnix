/*
 * net.c -- rvlogin: the BSD socket API, select, readv/writev, a numeric-only resolver
 * and the inet_* helpers, over the solnix riscv64 kernel (uts/uproc.c + inet.c, lwIP).
 * Tags as in glue.c: [REAL] = the kernel call, [DERIVED] = built from kernel calls,
 * [STUB] = fixed answer, [ENOSYS] = fails. Compiled into libsolnix.a.
 */
#include <errno.h>
#include <poll.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/uio.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <syslog.h>
#include <grp.h>

static long
ks(long n, long a, long b, long c, long d, long e, long f)
{
	register long a0 __asm__("a0") = a, a1 __asm__("a1") = b, a2 __asm__("a2") = c,
	    a3 __asm__("a3") = d, a4 __asm__("a4") = e, a5 __asm__("a5") = f, a7 __asm__("a7") = n;
	__asm__ __volatile__("ecall" : "+r"(a0) : "r"(a1), "r"(a2), "r"(a3), "r"(a4), "r"(a5),
	    "r"(a7) : "memory");
	return (a0);
}

static long
kr(long r)
{
	if (r < 0 && r > -4096) {
		errno = (int)-r;	/* Linux errno numbers = newlib's for the ones used here */
		return (-1);
	}
	return (r);
}

/* [REAL] */
int socket(int d, int t, int p) { return ((int)kr(ks(198, d, t & 0xf, p, 0, 0, 0))); }
int socketpair(int d, int t, int p, int sv[2]) { return ((int)kr(ks(199, d, t & 0xf, p, (long)sv, 0, 0))); }
int bind(int s, const struct sockaddr *a, socklen_t l) { return ((int)kr(ks(200, s, (long)a, l, 0, 0, 0))); }
int listen(int s, int b) { return ((int)kr(ks(201, s, b, 0, 0, 0, 0))); }
int connect(int s, const struct sockaddr *a, socklen_t l) { return ((int)kr(ks(203, s, (long)a, l, 0, 0, 0))); }
int getsockname(int s, struct sockaddr *a, socklen_t *l) { return ((int)kr(ks(204, s, (long)a, (long)l, 0, 0, 0))); }
int getpeername(int s, struct sockaddr *a, socklen_t *l) { return ((int)kr(ks(205, s, (long)a, (long)l, 0, 0, 0))); }
int setsockopt(int s, int lv, int n, const void *v, socklen_t l) { return ((int)kr(ks(208, s, lv, n, (long)v, l, 0))); }
int getsockopt(int s, int lv, int n, void *v, socklen_t *l) { return ((int)kr(ks(209, s, lv, n, (long)v, (long)l, 0))); }
ssize_t sendto(int s, const void *b, size_t n, int f, const struct sockaddr *a, socklen_t l)
{ return ((ssize_t)kr(ks(206, s, (long)b, (long)n, f, (long)a, l))); }
ssize_t recvfrom(int s, void *b, size_t n, int f, struct sockaddr *a, socklen_t *l)
{ return ((ssize_t)kr(ks(520, s, (long)b, (long)n, f, (long)a, (long)l))); }
ssize_t send(int s, const void *b, size_t n, int f) { (void) f; return (write(s, b, n)); }	/* [DERIVED] */
ssize_t recv(int s, void *b, size_t n, int f) { (void) f; return (read(s, b, n)); }	/* [DERIVED] */

/* [REAL] accept: the kernel copies out a 16-byte sockaddr_in only if *l >= 16. */
int
accept(int s, struct sockaddr *a, socklen_t *l)
{
	socklen_t want = l ? *l : 0;
	int r = (int)kr(ks(202, s, (long)a, (long)l, 0, 0, 0));

	if (r >= 0 && l != NULL && want < 16)
		*l = 0;
	return (r);
}

/* [ENOSYS] no shutdown in the kernel; dropbear only needs it for socket channels (off). */
int shutdown(int s, int h) { (void) s; (void) h; errno = ENOSYS; return (-1); }

/* [DERIVED] readv/writev: one call per iovec, stop at a short transfer (not atomic). */
ssize_t
writev(int fd, const struct iovec *v, int n)
{
	ssize_t t = 0, r;
	int i;

	for (i = 0; i < n; i++) {
		if (v[i].iov_len == 0)
			continue;
		if ((r = write(fd, v[i].iov_base, v[i].iov_len)) < 0)
			return (t > 0 ? t : -1);
		t += r;
		if ((size_t)r < v[i].iov_len)
			break;
	}
	return (t);
}

ssize_t
readv(int fd, const struct iovec *v, int n)
{
	ssize_t t = 0, r;
	int i;

	for (i = 0; i < n; i++) {
		if ((r = read(fd, v[i].iov_base, v[i].iov_len)) < 0)
			return (t > 0 ? t : -1);
		t += r;
		if ((size_t)r < v[i].iov_len)
			break;
	}
	return (t);
}

/* [DERIVED] select over the kernel's poll (32 fds, ms timeout). */
int
select(int nfds, fd_set *rd, fd_set *wr, fd_set *ex, struct timeval *tv)
{
	struct pollfd pf[32];
	int n = 0, i, r, ms;

	if (nfds > 32)
		nfds = 32;
	for (i = 0; i < nfds; i++) {
		short ev = (rd && FD_ISSET(i, rd) ? POLLIN : 0) | (wr && FD_ISSET(i, wr) ? POLLOUT : 0);
		if (ev || (ex && FD_ISSET(i, ex))) {
			pf[n].fd = i; pf[n].events = ev; pf[n].revents = 0; n++;
		}
	}
	ms = tv == NULL ? -1 : (int)(tv->tv_sec * 1000 + (tv->tv_usec + 999) / 1000);
	if ((r = poll(pf, (nfds_t)n, ms)) < 0)
		return (-1);
	if (rd) FD_ZERO(rd);
	if (wr) FD_ZERO(wr);
	if (ex) FD_ZERO(ex);
	for (r = 0, i = 0; i < n; i++) {
		short v = pf[i].revents;
		if (v & POLLNVAL) {
			errno = EBADF;
			return (-1);
		}
		if (rd && (v & (POLLIN | POLLHUP | POLLERR))) { FD_SET(pf[i].fd, rd); r++; }
		if (wr && (v & (POLLOUT | POLLERR))) { FD_SET(pf[i].fd, wr); r++; }
	}
	return (r);
}

/* [REAL] inet helpers (IPv4 only). */
int
inet_pton(int af, const char *s, void *dst)
{
	unsigned int a[4], i;
	char tail;

	if (af != AF_INET) {
		errno = EAFNOSUPPORT;
		return (-1);
	}
	if (sscanf(s, "%u.%u.%u.%u%c", &a[0], &a[1], &a[2], &a[3], &tail) != 4)
		return (0);
	for (i = 0; i < 4; i++)
		if (a[i] > 255)
			return (0);
	((unsigned char *)dst)[0] = a[0]; ((unsigned char *)dst)[1] = a[1];
	((unsigned char *)dst)[2] = a[2]; ((unsigned char *)dst)[3] = a[3];
	return (1);
}

const char *
inet_ntop(int af, const void *src, char *dst, socklen_t n)
{
	const unsigned char *b = src;

	if (af != AF_INET) {
		errno = EAFNOSUPPORT;
		return (NULL);
	}
	if (snprintf(dst, n, "%u.%u.%u.%u", b[0], b[1], b[2], b[3]) >= (int)n) {
		errno = ENOSPC;
		return (NULL);
	}
	return (dst);
}

in_addr_t
inet_addr(const char *s)
{
	in_addr_t a;
	return (inet_pton(AF_INET, s, &a) == 1 ? a : INADDR_NONE);
}

char *
inet_ntoa(struct in_addr a)
{
	static char b[INET_ADDRSTRLEN];
	return ((char *)inet_ntop(AF_INET, &a, b, sizeof (b)));
}

/* [DERIVED] numeric-only getaddrinfo: no DNS in the guest. host NULL = any / loopback. */
int
getaddrinfo(const char *host, const char *serv, const struct addrinfo *h, struct addrinfo **res)
{
	struct { struct addrinfo ai; struct sockaddr_in sin; } *r;
	char *end;
	long port = 0;
	in_addr_t a;

	if (h != NULL && h->ai_family != AF_UNSPEC && h->ai_family != AF_INET)
		return (EAI_FAMILY);
	if (serv != NULL) {
		port = strtol(serv, &end, 10);
		if (*serv == 0 || *end != 0 || port < 0 || port > 65535)
			return (EAI_SERVICE);
	}
	if (host == NULL)
		a = (h != NULL && (h->ai_flags & AI_PASSIVE)) ? htonl(INADDR_ANY) : htonl(INADDR_LOOPBACK);
	else if (inet_pton(AF_INET, host, &a) != 1)
		return (EAI_NONAME);
	if ((r = calloc(1, sizeof (*r))) == NULL)
		return (EAI_MEMORY);
	r->sin.sin_family = AF_INET;
	r->sin.sin_port = htons((unsigned short)port);
	r->sin.sin_addr.s_addr = a;
	r->ai.ai_family = AF_INET;
	r->ai.ai_socktype = (h != NULL && h->ai_socktype) ? h->ai_socktype : SOCK_STREAM;
	r->ai.ai_protocol = (h != NULL) ? h->ai_protocol : 0;
	r->ai.ai_addrlen = sizeof (r->sin);
	r->ai.ai_addr = (struct sockaddr *)&r->sin;
	*res = &r->ai;
	return (0);
}

void freeaddrinfo(struct addrinfo *a) { free(a); }	/* one allocation per result */

const char *
gai_strerror(int e)
{
	return (e == EAI_NONAME ? "name not numeric (no resolver)" : e == EAI_SERVICE ?
	    "bad service" : e == EAI_FAMILY ? "IPv4 only" : e == EAI_MEMORY ? "no memory" : "error");
}

int
getnameinfo(const struct sockaddr *sa, socklen_t sl, char *host, socklen_t hl, char *serv,
    socklen_t svl, int fl)
{
	const struct sockaddr_in *s = (const struct sockaddr_in *)sa;

	(void) fl;
	if (sa == NULL || sl < sizeof (*s) || s->sin_family != AF_INET)
		return (EAI_FAMILY);
	if (host != NULL && hl > 0 && inet_ntop(AF_INET, &s->sin_addr, host, hl) == NULL)
		return (EAI_FAIL);
	if (serv != NULL && svl > 0 && snprintf(serv, svl, "%u", ntohs(s->sin_port)) >= (int)svl)
		return (EAI_FAIL);
	return (0);
}

struct hostent *gethostbyname(const char *n) { (void) n; errno = ENOENT; return (NULL); }	/* [ENOSYS] */

/* [DERIVED] syslog: to stderr (the console), no daemon. */
static const char *sl_ident = "";
void openlog(const char *id, int o, int f) { (void) o; (void) f; sl_ident = id ? id : ""; }
void closelog(void) { }
void
vsyslog(int pri, const char *fmt, va_list ap)
{
	(void) pri;
	fprintf(stderr, "%s: ", sl_ident);
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
}
void
syslog(int pri, const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vsyslog(pri, fmt, ap);
	va_end(ap);
}

/* [STUB] groups: one gid per process, no supplementary groups. */
int initgroups(const char *u, gid_t g) { (void) u; (void) g; return (0); }
int setgroups(int n, const gid_t *g) { (void) g; if (n > 1) { errno = EPERM; return (-1); } return (0); }
int getgroups(int n, gid_t *g) { if (n > 0) g[0] = getgid(); return (1); }

/* [STUB] /etc/shells: none, so getusershell lists the two shells the images ship. */
static int us_i;
static char *us_list[] = { "/bin/sh", "/bin/dash", NULL };
char *getusershell(void) { return (us_list[us_i] ? us_list[us_i++] : NULL); }
void setusershell(void) { us_i = 0; }
void endusershell(void) { us_i = 0; }

/* [STUB] rlimits: none in the kernel (see include/sys/resource.h). */
#include <sys/resource.h>
int
getrlimit(int r, struct rlimit *l)
{
	l->rlim_cur = l->rlim_max = (r == RLIMIT_NOFILE) ? 32 : RLIM_INFINITY;
	return (0);
}
int
setrlimit(int r, const struct rlimit *l)
{
	(void) l;
	if (r == RLIMIT_CORE)
		return (0);
	errno = EPERM;
	return (-1);
}
