/*
 * inettest.c -- rvsrv: AF_INET over the uts kernel's lwIP stack, driven from the
 * HOST through qemu user-net hostfwd (or a tap). Raw ecalls for the socket
 * calls (newlib has no socket API), newlib for printf/fork.
 *
 *   inettest udpecho PORT N    bind UDP PORT, echo N datagrams back to sender
 *   inettest tcpecho PORT N    listen on TCP PORT; fork one child per accepted
 *                              connection that echoes until EOF; parent reaps;
 *                              exits after N connections have finished
 *   inettest nonic             control (no NIC): socket() must work, connect()
 *                              and sendto() must fail with a clean errno
 *   inettest selfconnect PORT  in-guest TCP loopback over the stack: listen +
 *                              connect to our own DHCP address
 *   inettest addr              print the DHCP-assigned address (getsockname of a
 *                              UDP socket connected to the gateway)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>

#define	K_socket	198
#define	K_bind		200
#define	K_listen	201
#define	K_accept	202
#define	K_connect	203
#define	K_getsockname	204
#define	K_sendto	206
#define	K_recvfrom	520
#define	K_read		63
#define	K_write		64
#define	K_close		57

static long
ks(long n, long a, long b, long c, long d, long e, long f)
{
	register long a0 __asm__("a0") = a, a1 __asm__("a1") = b,
	    a2 __asm__("a2") = c, a3 __asm__("a3") = d, a4 __asm__("a4") = e,
	    a5 __asm__("a5") = f, a7 __asm__("a7") = n;
	__asm__ __volatile__("ecall" : "+r"(a0) : "r"(a1), "r"(a2), "r"(a3),
	    "r"(a4), "r"(a5), "r"(a7) : "memory");
	return (a0);
}

struct sin {
	unsigned short	family;
	unsigned short	port;	/* network order */
	unsigned int	addr;	/* network order */
	unsigned char	zero[8];
};

static unsigned short
hs(unsigned short v)
{
	return ((unsigned short)((v >> 8) | (v << 8)));
}

static void
mksin(struct sin *s, unsigned int addr_be, int port)
{
	memset(s, 0, sizeof (*s));
	s->family = 2;
	s->port = hs((unsigned short)port);
	s->addr = addr_be;
}

static unsigned int
ip(int a, int b, int c, int d)
{
	return ((unsigned int)a | ((unsigned int)b << 8) | ((unsigned int)c << 16) |
	    ((unsigned int)d << 24));
}

static void
pip(const char *tag, unsigned int a)
{
	printf("%s %u.%u.%u.%u\n", tag, a & 0xff, (a >> 8) & 0xff,
	    (a >> 16) & 0xff, a >> 24);
}

static int
udpecho(int port, int n)
{
	struct sin me, from;
	unsigned int flen;
	char buf[1500];
	long fd, r, i;

	fd = ks(K_socket, 2, 1, 0, 0, 0, 0);
	mksin(&me, 0, port);
	r = ks(K_bind, fd, (long)&me, sizeof (me), 0, 0, 0);
	printf("INET udp socket=%ld bind(%d)=%ld\n", fd, port, r);
	printf("INET READY udp %d\n", port);
	fflush(stdout);
	for (i = 0; i < n; i++) {
		flen = sizeof (from);
		r = ks(K_recvfrom, fd, (long)buf, sizeof (buf), 0, (long)&from,
		    (long)&flen);
		if (r < 0) {
			printf("INET udp recvfrom=%ld\n", r);
			return (1);
		}
		r = ks(K_sendto, fd, (long)buf, r, 0, (long)&from, sizeof (from));
		if (r < 0) {
			printf("INET udp sendto=%ld\n", r);
			return (1);
		}
	}
	printf("INET udp echoed %ld datagrams\n", i);
	return (0);
}

static void
echo_conn(long c)
{
	char buf[1460];
	long r, w, off;
	unsigned long tot = 0;

	for (;;) {
		r = ks(K_read, c, (long)buf, sizeof (buf), 0, 0, 0);
		if (r <= 0)
			break;
		for (off = 0; off < r; off += w) {
			w = ks(K_write, c, (long)buf + off, r - off, 0, 0, 0);
			if (w <= 0)
				_exit(3);
		}
		tot += (unsigned long)r;
	}
	ks(K_close, c, 0, 0, 0, 0, 0);
	_exit(r < 0 ? 2 : 0);
}

static int
tcpecho(int port, int n)
{
	struct sin me, peer;
	unsigned int plen;
	long fd, c, r;
	int done = 0, live = 0, bad = 0, st, accepted = 0;

	fd = ks(K_socket, 2, 2, 0, 0, 0, 0);
	mksin(&me, 0, port);
	r = ks(K_bind, fd, (long)&me, sizeof (me), 0, 0, 0);
	printf("INET tcp socket=%ld bind(%d)=%ld listen=%ld\n", fd, port, r,
	    ks(K_listen, fd, 8, 0, 0, 0, 0));
	printf("INET READY tcp %d\n", port);
	fflush(stdout);
	while (done < n) {
		/* reap without blocking when possible; cap live children */
		while (live > 0 && (live >= 12 || accepted >= n)) {
			if (wait(&st) > 0) {
				live--;
				done++;
				if (!WIFEXITED(st) || WEXITSTATUS(st) != 0)
					bad++;
			}
		}
		if (accepted >= n)
			continue;
		plen = sizeof (peer);
		c = ks(K_accept, fd, (long)&peer, (long)&plen, 0, 0, 0);
		if (c < 0) {
			printf("INET tcp accept=%ld\n", c);
			return (1);
		}
		accepted++;
		if (fork() == 0) {
			ks(K_close, fd, 0, 0, 0, 0, 0);
			echo_conn(c);
		}
		ks(K_close, c, 0, 0, 0, 0, 0);
		live++;
	}
	printf("INET tcp served %d connections, %d bad\n", done, bad);
	return (bad != 0);
}

static int
nonic(void)
{
	struct sin to;
	long fd, u, r1, r2;

	fd = ks(K_socket, 2, 2, 0, 0, 0, 0);
	u = ks(K_socket, 2, 1, 0, 0, 0, 0);
	mksin(&to, ip(10, 0, 2, 2), 80);
	r1 = ks(K_connect, fd, (long)&to, sizeof (to), 0, 0, 0);
	r2 = ks(K_sendto, u, (long)"x", 1, 0, (long)&to, sizeof (to));
	printf("INET nonic socket(tcp)=%ld socket(udp)=%ld connect=%ld sendto=%ld\n",
	    fd, u, r1, r2);
	printf("INET nonic close=%ld,%ld\n", ks(K_close, fd, 0, 0, 0, 0, 0),
	    ks(K_close, u, 0, 0, 0, 0, 0));
	return (fd >= 0 && u >= 0 && r1 < 0 && r2 < 0 ? 0 : 1);
}

static int
myaddr(unsigned int *a)
{
	struct sin to, me;
	unsigned int len = sizeof (me);
	long u = ks(K_socket, 2, 1, 0, 0, 0, 0), r;

	mksin(&to, ip(10, 0, 2, 2), 9);
	r = ks(K_connect, u, (long)&to, sizeof (to), 0, 0, 0);
	if (r == 0)
		r = ks(K_getsockname, u, (long)&me, (long)&len, 0, 0, 0);
	ks(K_close, u, 0, 0, 0, 0, 0);
	*a = me.addr;
	return ((int)r);
}

static int
selfconnect(int port)
{
	struct sin me, to;
	unsigned int a = 0, plen;
	long l, c, s, r;
	char b[16];

	myaddr(&a);
	l = ks(K_socket, 2, 2, 0, 0, 0, 0);
	mksin(&me, 0, port);
	ks(K_bind, l, (long)&me, sizeof (me), 0, 0, 0);
	ks(K_listen, l, 4, 0, 0, 0, 0);
	c = ks(K_socket, 2, 2, 0, 0, 0, 0);
	mksin(&to, a, port);
	r = ks(K_connect, c, (long)&to, sizeof (to), 0, 0, 0);
	plen = sizeof (me);
	s = ks(K_accept, l, (long)&me, (long)&plen, 0, 0, 0);
	ks(K_write, c, (long)"loopback", 8, 0, 0, 0);
	memset(b, 0, sizeof (b));
	ks(K_read, s, (long)b, 8, 0, 0, 0);
	printf("INET self connect=%ld accept=%ld read=[%s]\n", r, s, b);
	return (strcmp(b, "loopback") != 0);
}

int
main(int argc, char **argv)
{
	const char *m = argc > 1 ? argv[1] : "addr";
	unsigned int a = 0;

	if (strcmp(m, "udpecho") == 0)
		return (udpecho(atoi(argv[2]), atoi(argv[3])));
	if (strcmp(m, "tcpecho") == 0)
		return (tcpecho(atoi(argv[2]), atoi(argv[3])));
	if (strcmp(m, "nonic") == 0)
		return (nonic());
	if (strcmp(m, "selfconnect") == 0)
		return (selfconnect(atoi(argv[2])));
	printf("INET getsockname=%d\n", myaddr(&a));
	pip("INET addr", a);
	return (a == 0);
}
