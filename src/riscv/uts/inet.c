/*
 * inet.c -- AF_INET (IPv4) for the illumos riscv64 uts kernel: lwIP over vionet.
 *
 * WHY lwIP. The kernel had a NIC that could move a frame (vionet.c) and no IP
 * stack. Writing ARP + IPv4 + ICMP + UDP + DHCP + an RFC 793 TCP from scratch is
 * thousands of lines of protocol corner cases; lwIP 2.2.1 (BSD-3-Clause, the
 * stack in most embedded RTOSes, uts/lwip/COPYING) already has all of it and is
 * built to run with no OS underneath. It is vendored unmodified under uts/lwip/
 * (core + ipv4 + netif/ethernet); only uts/lwip/port/ is ours.
 *
 * SHAPE. NO_SYS=1: lwIP's raw callback API, no lwIP threads. One spinlock,
 * netlock, serializes every entry into lwIP from any hart (sockets on any cpu,
 * the netd poller), with interrupts off while held so a timer-trap preemption
 * cannot strand it. netd is one kernel thread: it polls vionet's RX ring into
 * lwIP and runs lwIP's timers (TCP retransmit, ARP, DHCP), yielding between
 * passes, so it runs on whichever hart the dispatcher gives it.
 *
 * SOCKETS. An AF_INET socket is a slot in inettab; the fd table stores its index
 * in fd_sock with INET_SI_FLAG set (uproc.c and unixsock.c route on the flag),
 * so fork/dup/close/read/write/poll reuse the AF_UNIX plumbing unchanged.
 * SOCK_STREAM = an lwIP tcp_pcb plus a receive ring filled by the recv callback;
 * a listener keeps a small accept queue of new pcbs. SOCK_DGRAM = a udp_pcb plus
 * a datagram queue. Blocking calls sleep_on() the slot and are woken by the
 * callbacks (which run under netlock on netd's hart); see net_sleep for why the
 * wait is a yield loop for now. sockaddr_in is the illumos/BSD layout (family u16, port be16, addr
 * be32, 8 zero bytes) and is copied raw.
 *
 * NOTE (ceilings, documented, not hidden): NINET sockets; INET_RXBUF bytes of
 * unread TCP data per socket (the advertised window is only opened as the app
 * reads, so a slow reader throttles the sender rather than losing data);
 * INET_NDGRAM queued datagrams per UDP socket; no O_NONBLOCK, no socket options
 * (setsockopt answers 0), no IPv6, one NIC.
 */

#include "sbi.h"
#include "riscv_regs.h"

#include "lwip/init.h"
#include "lwip/netif.h"
#include "lwip/etharp.h"
#include "lwip/dhcp.h"
#include "lwip/tcp.h"
#include "lwip/udp.h"
#include "lwip/timeouts.h"
#include "lwip/prot/dhcp.h"
#include "netif/ethernet.h"

extern void kputdec(unsigned long v);
extern void kputhex(unsigned long v);
extern unsigned long gethrtime(void);
extern void *thread_create(void (*entry)(void *), void *arg);
extern void thread_yield(void);
extern void wakeup(void *chan);
extern long copyin(const void *uaddr, void *kaddr, unsigned long n);
extern long copyout(const void *kaddr, void *uaddr, unsigned long n);
extern void *unsock_curproc(void);
extern void unsock_setcurproc(void *p);

/* vionet.c */
extern int vionet_present(void);
extern int vionet_net_start(void);
extern void vionet_get_mac(unsigned char *mac);
extern unsigned int vionet_rx_poll(unsigned char *buf, unsigned int max);
extern int vionet_tx(const unsigned char *frame, unsigned int len);

#define	INET_SI_FLAG	0x4000		/* fd_sock bit: an inettab index */
#define	NINET		40
#define	INET_RXBUF	(16 * 1024)
#define	INET_NDGRAM	8
#define	INET_NACCEPT	16	/* 8 dropped the 9th+10th of 10 simultaneous SYNs */

#define	AF_INET_V	2
#define	SOCK_STREAM_V	2
#define	SOCK_DGRAM_V	1

/* Linux errno values: the syscall ABI this kernel speaks (unixsock.c's set). */
#define	EBADF		9
#define	EAGAIN		11
#define	ENOMEM		12
#define	EFAULT		14
#define	EINVAL		22
#define	EMFILE		24
#define	EPIPE		32
#define	EAFNOSUPPORT	97
#define	EADDRINUSE	98
#define	ENETUNREACH	101
#define	ECONNRESET	104
#define	EISCONN		106
#define	ENOTCONN	107
#define	ETIMEDOUT	110
#define	ECONNREFUSED	111
#define	EOPNOTSUPP	95
#define	EPROTONOSUPPORT	93

#define	INPOLL_RD	0x1
#define	INPOLL_WR	0x2
#define	INPOLL_HUP	0x4

struct sockaddr_in_k {
	unsigned short	sin_family;
	unsigned short	sin_port;	/* network order */
	unsigned int	sin_addr;	/* network order */
	unsigned char	sin_zero[8];
};

struct dgram {
	unsigned int	g_addr;		/* network order */
	unsigned short	g_port;		/* host order */
	unsigned short	g_len;
	unsigned char	g_data[1472];
};

struct inetsock {
	int		i_used;
	int		i_type;
	int		i_refs;
	int		i_listening;
	int		i_connected;
	int		i_connecting;
	int		i_err;		/* sticky negative errno (reset, refused) */
	int		i_peer_closed;	/* FIN seen: drain then EOF */
	struct tcp_pcb	*i_tcp;
	struct udp_pcb	*i_udp;
	/* TCP receive ring */
	unsigned long	i_rpos, i_wpos;
	unsigned char	*i_rx;
	/* listener accept queue: slots made in tcp_accept_cb, not yet accepted */
	int		i_acq[INET_NACCEPT];
	int		i_nacq;
	/* UDP datagram queue */
	struct dgram	*i_dg;
	int		i_dgh, i_dgn;
};

static struct inetsock inettab[NINET];
static volatile int netlock;
static struct netif inet_netif;
static int inet_up;		/* netif added (NIC present) */
static int inet_have_lease;
static volatile unsigned long inet_rx_frames, inet_tx_frames;
static unsigned char inet_rxframe[1600];

extern void *kmem_alloc(unsigned long n);

/* ---- lwIP arch hooks ---------------------------------------------------- */

void
inet_diag(const char *msg)
{
	sbi_console_puts(msg);
}

void
inet_assert(const char *msg, const char *file, int line)
{
	sbi_console_puts("\n[lwip] PANIC: assertion \"");
	sbi_console_puts(msg);
	sbi_console_puts("\" at ");
	sbi_console_puts(file);
	sbi_console_puts(":");
	kputdec((unsigned long)line);
	sbi_console_puts("\n");
	for (;;)
		__asm__ __volatile__("wfi");
}

/* xorshift seeded from the time CSR: TCP ISNs and DHCP xids, not crypto. */
static unsigned long rnd_state;

unsigned int
inet_rand(void)
{
	if (rnd_state == 0)
		rnd_state = gethrtime() | 1;
	rnd_state ^= rnd_state << 13;
	rnd_state ^= rnd_state >> 7;
	rnd_state ^= rnd_state << 17;
	return ((unsigned int)rnd_state);
}

u32_t
sys_now(void)
{
	return ((u32_t)(gethrtime() / 1000000UL));
}

/* ---- the one lock ----------------------------------------------------- */

static unsigned long
net_enter(void)
{
	unsigned long prev;
	int old;

	__asm__ __volatile__("csrrc %0, sstatus, %1"
	    : "=r"(prev) : "r"((unsigned long)SSTATUS_SIE) : "memory");
	do {
		__asm__ __volatile__("amoswap.w.aq %0, %2, (%1)"
		    : "=&r"(old) : "r"(&netlock), "r"(1) : "memory");
	} while (old != 0);
	return (prev & SSTATUS_SIE);
}

static void
net_exit(unsigned long sie)
{
	__asm__ __volatile__("amoswap.w.rl zero, zero, (%0)"
	    :: "r"(&netlock) : "memory");
	if (sie != 0)
		__asm__ __volatile__("csrs sstatus, %0" :: "r"(sie) : "memory");
}

/*
 * Wait for `chan`'s state to change, with netlock dropped; returns with it
 * re-taken (the caller re-checks its condition).
 * shortcut: yields instead of sleep_on(). proc.c's sleep_on queues the thread
 * only after the caller's lock is gone, so a wakeup() from netd on another
 * hart in that window is lost and the socket would hang forever. Yielding
 * costs cpu while blocked; switch to sleep_on once proc.c has a sleep that
 * drops a caller-held lock atomically (a cv_wait analog).
 */
static int inet_poll_locked(void);

static unsigned long
net_sleep(void *chan, unsigned long sie)
{
	void *self = unsock_curproc();

	(void) chan;
	net_exit(sie);
	thread_yield();
	unsock_setcurproc(self);
	return (net_enter());
}

/* ---- netif over vionet ------------------------------------------------ */

static unsigned char inet_txframe[1536];	/* netlock-serialized */

static err_t
inet_linkoutput(struct netif *nif, struct pbuf *p)
{
	unsigned char *frame = inet_txframe;
	u16_t n;

	(void) nif;
	if (p->tot_len > sizeof (inet_txframe))
		return (ERR_BUF);
	n = pbuf_copy_partial(p, frame, p->tot_len, 0);
	if (!vionet_tx(frame, n))
		return (ERR_IF);
	inet_tx_frames++;
	return (ERR_OK);
}

static err_t
inet_netif_init(struct netif *nif)
{
	nif->name[0] = 'v';
	nif->name[1] = 'n';
	nif->output = etharp_output;
	nif->linkoutput = inet_linkoutput;
	nif->mtu = 1500;
	nif->hwaddr_len = 6;
	vionet_get_mac(nif->hwaddr);
	nif->flags = NETIF_FLAG_BROADCAST | NETIF_FLAG_ETHARP |
	    NETIF_FLAG_ETHERNET | NETIF_FLAG_LINK_UP;
	return (ERR_OK);
}

/* One poll pass, netlock held: drain RX into lwIP, run its timers. */
static int
inet_poll_locked(void)
{
	unsigned int len;
	int n = 0;

	while ((len = vionet_rx_poll(inet_rxframe, sizeof (inet_rxframe))) > 0) {
		struct pbuf *p = pbuf_alloc(PBUF_RAW, (u16_t)len, PBUF_POOL);

		inet_rx_frames++;
		n++;
		if (p == 0)
			continue;	/* out of pbufs: drop, TCP retransmits */
		pbuf_take(p, inet_rxframe, (u16_t)len);
		if (inet_netif.input(p, &inet_netif) != ERR_OK)
			pbuf_free(p);
	}
	sys_check_timeouts();
	if (!inet_have_lease && dhcp_supplied_address(&inet_netif)) {
		inet_have_lease = 1;
		sbi_console_puts("[inet] DHCP lease: ");
		sbi_console_puts(ip4addr_ntoa(netif_ip4_addr(&inet_netif)));
		sbi_console_puts(" mask ");
		sbi_console_puts(ip4addr_ntoa(netif_ip4_netmask(&inet_netif)));
		sbi_console_puts(" gw ");
		sbi_console_puts(ip4addr_ntoa(netif_ip4_gw(&inet_netif)));
		sbi_console_puts("\n");
		wakeup(&inet_have_lease);
	}
	return (n);
}

static void
netd_body(void *arg)
{
	(void) arg;
	for (;;) {
		unsigned long sie = net_enter();
		(void) inet_poll_locked();
		net_exit(sie);
		thread_yield();
	}
}

/*
 * inet_init -- bring lwIP up on vionet and start DHCP. Called from
 * startup_root after vionet_attach. With no NIC the stack still initializes
 * (socket() works) but there is no route, so connect/sendto fail cleanly.
 */
void
inet_init(void)
{
	unsigned long t0;
	unsigned long sie;

	lwip_init();
	if (!vionet_present() || !vionet_net_start()) {
		sbi_console_puts("[inet] lwIP 2.2.1 up, NO NIC: AF_INET sockets "
		    "work, nothing is routable\n");
		return;
	}
	netif_add_noaddr(&inet_netif, 0, inet_netif_init, ethernet_input);
	netif_set_default(&inet_netif);
	netif_set_up(&inet_netif);
	inet_up = 1;
	(void) dhcp_start(&inet_netif);
	sbi_console_puts("[inet] lwIP 2.2.1 up on vionet (IPv4: ARP ICMP UDP "
	    "TCP DHCP); DHCP discover sent\n");

	/* Wait (bounded, ~3 s) for the lease right here, so the gates and the
	 * user init see an address; netd keeps polling afterwards. */
	t0 = gethrtime();
	while (!inet_have_lease && gethrtime() - t0 < 3000000000UL) {
		sie = net_enter();
		(void) inet_poll_locked();
		net_exit(sie);
	}
	if (!inet_have_lease)
		sbi_console_puts("[inet] no DHCP lease within 3 s (netd keeps "
		    "trying)\n");
	(void) thread_create(netd_body, 0);
}

/* ---- socket slots ------------------------------------------------------ */

static struct inetsock *
isock(int si)
{
	if ((si & INET_SI_FLAG) == 0)
		return (0);
	si &= ~INET_SI_FLAG;
	if (si < 0 || si >= NINET || !inettab[si].i_used)
		return (0);
	return (&inettab[si]);
}

int
inet_is(int si)
{
	return (si >= 0 && (si & INET_SI_FLAG) != 0);
}

static int
islot_alloc(int type)
{
	int i;

	for (i = 0; i < NINET; i++) {
		struct inetsock *s = &inettab[i];

		if (s->i_used)
			continue;
		if (type == SOCK_STREAM_V && s->i_rx == 0)
			s->i_rx = kmem_alloc(INET_RXBUF);
		if (type == SOCK_DGRAM_V && s->i_dg == 0)
			s->i_dg = kmem_alloc(INET_NDGRAM * sizeof (struct dgram));
		if ((type == SOCK_STREAM_V && s->i_rx == 0) ||
		    (type == SOCK_DGRAM_V && s->i_dg == 0))
			return (-ENOMEM);
		s->i_used = 1;
		s->i_type = type;
		s->i_refs = 1;
		s->i_listening = s->i_connected = s->i_connecting = 0;
		s->i_err = s->i_peer_closed = 0;
		s->i_tcp = 0;
		s->i_udp = 0;
		s->i_rpos = s->i_wpos = 0;
		s->i_nacq = 0;
		s->i_dgh = s->i_dgn = 0;
		return (i | INET_SI_FLAG);
	}
	return (-EMFILE);
}

static int
lwip_errno(err_t e)
{
	switch (e) {
	case ERR_OK:	return (0);
	case ERR_MEM:	return (-ENOMEM);
	case ERR_RTE:	return (-ENETUNREACH);
	case ERR_USE:	return (-EADDRINUSE);
	case ERR_ISCONN: return (-EISCONN);
	case ERR_CONN:	return (-ENOTCONN);
	case ERR_RST:	return (-ECONNRESET);
	case ERR_ABRT:	return (-ECONNREFUSED);
	case ERR_TIMEOUT: return (-ETIMEDOUT);
	default:	return (-EINVAL);
	}
}

/* ---- TCP callbacks (netlock held: they run inside lwIP) --------------- */

static err_t
tcp_recv_cb(void *arg, struct tcp_pcb *pcb, struct pbuf *p, err_t err)
{
	struct inetsock *s = arg;
	struct pbuf *q;

	(void) pcb;
	if (s == 0) {
		if (p != 0)
			pbuf_free(p);
		return (ERR_OK);
	}
	if (p == 0 || err != ERR_OK) {		/* FIN */
		s->i_peer_closed = 1;
		if (p != 0)
			pbuf_free(p);
		wakeup(s);
		return (ERR_OK);
	}
	if (p->tot_len > INET_RXBUF - (s->i_wpos - s->i_rpos))
		return (ERR_MEM);	/* lwIP keeps it and redelivers */
	for (q = p; q != 0; q = q->next) {
		unsigned char *d = q->payload;
		u16_t i;

		for (i = 0; i < q->len; i++)
			s->i_rx[(s->i_wpos++) % INET_RXBUF] = d[i];
	}
	pbuf_free(p);
	wakeup(s);
	return (ERR_OK);
}

static err_t
tcp_sent_cb(void *arg, struct tcp_pcb *pcb, u16_t len)
{
	(void) pcb;
	(void) len;
	if (arg != 0)
		wakeup(arg);
	return (ERR_OK);
}

static void
tcp_err_cb(void *arg, err_t err)
{
	struct inetsock *s = arg;

	if (s == 0)
		return;
	s->i_tcp = 0;			/* lwIP already freed the pcb */
	s->i_err = (err == ERR_RST) ? -ECONNRESET :
	    (s->i_connecting ? -ECONNREFUSED : lwip_errno(err));
	s->i_connecting = 0;
	s->i_connected = 0;
	s->i_peer_closed = 1;
	wakeup(s);
}

static void
tcp_attach(struct inetsock *s, struct tcp_pcb *pcb)
{
	s->i_tcp = pcb;
	tcp_arg(pcb, s);
	tcp_recv(pcb, tcp_recv_cb);
	tcp_sent(pcb, tcp_sent_cb);
	tcp_err(pcb, tcp_err_cb);
}

/*
 * A new connection gets its socket slot HERE, not at accept(), so data or a FIN
 * that arrives before the application accepts is buffered in the slot rather
 * than lost (a pcb with no socket has nowhere to put it).
 */
static err_t
tcp_accept_cb(void *arg, struct tcp_pcb *newpcb, err_t err)
{
	struct inetsock *s = arg;
	int ci;

	if (err != ERR_OK || newpcb == 0)
		return (ERR_VAL);
	if (s == 0 || s->i_nacq >= INET_NACCEPT ||
	    (ci = islot_alloc(SOCK_STREAM_V)) < 0) {
		tcp_abort(newpcb);
		return (ERR_ABRT);
	}
	tcp_attach(isock(ci), newpcb);
	isock(ci)->i_connected = 1;
	s->i_acq[s->i_nacq++] = ci;
	wakeup(s);
	return (ERR_OK);
}

static err_t
tcp_connected_cb(void *arg, struct tcp_pcb *pcb, err_t err)
{
	struct inetsock *s = arg;

	(void) pcb;
	s->i_connecting = 0;
	if (err == ERR_OK)
		s->i_connected = 1;
	else
		s->i_err = lwip_errno(err);
	wakeup(s);
	return (ERR_OK);
}

/* ---- UDP callback ------------------------------------------------------ */

static void
udp_recv_cb(void *arg, struct udp_pcb *pcb, struct pbuf *p,
    const ip_addr_t *addr, u16_t port)
{
	struct inetsock *s = arg;
	struct dgram *g;

	(void) pcb;
	if (s == 0 || s->i_dgn >= INET_NDGRAM) {
		pbuf_free(p);		/* queue full: drop, as UDP may */
		return;
	}
	g = &s->i_dg[(s->i_dgh + s->i_dgn) % INET_NDGRAM];
	g->g_addr = ip4_addr_get_u32(ip_2_ip4(addr));
	g->g_port = port;
	g->g_len = pbuf_copy_partial(p, g->g_data,
	    p->tot_len < sizeof (g->g_data) ? p->tot_len : sizeof (g->g_data), 0);
	s->i_dgn++;
	pbuf_free(p);
	wakeup(s);
}

/* ---- the syscall layer (called from uproc.c, kernel addresses) -------- */

int
inet_socket(int type, int protocol)
{
	unsigned long sie;
	struct inetsock *s;
	int si;

	(void) protocol;
	if (type != SOCK_STREAM_V && type != SOCK_DGRAM_V)
		return (-EPROTONOSUPPORT);
	sie = net_enter();
	si = islot_alloc(type);
	if (si >= 0 && type == SOCK_DGRAM_V) {
		s = isock(si);
		s->i_udp = udp_new();
		if (s->i_udp == 0) {
			s->i_used = 0;
			si = -ENOMEM;
		} else {
			udp_recv(s->i_udp, udp_recv_cb, s);
		}
	}
	net_exit(sie);
	return (si);
}

static int
sin_get(const void *ksa, unsigned int len, ip_addr_t *a, u16_t *port)
{
	const struct sockaddr_in_k *sin = ksa;

	if (len < sizeof (*sin) || sin->sin_family != AF_INET_V)
		return (-EAFNOSUPPORT);
	ip_addr_set_ip4_u32(a, sin->sin_addr);
	*port = lwip_ntohs(sin->sin_port);
	return (0);
}

static void
sin_put(struct sockaddr_in_k *sin, const ip_addr_t *a, u16_t port)
{
	int i;

	sin->sin_family = AF_INET_V;
	sin->sin_port = lwip_htons(port);
	sin->sin_addr = ip4_addr_get_u32(ip_2_ip4(a));
	for (i = 0; i < 8; i++)
		sin->sin_zero[i] = 0;
}

int
inet_bind(int si, const void *ksa, unsigned int len)
{
	struct inetsock *s;
	ip_addr_t a;
	u16_t port;
	unsigned long sie;
	int r;
	err_t e;

	if ((r = sin_get(ksa, len, &a, &port)) != 0)
		return (r);
	sie = net_enter();
	if ((s = isock(si)) == 0) {
		net_exit(sie);
		return (-EBADF);
	}
	if (s->i_type == SOCK_DGRAM_V) {
		e = udp_bind(s->i_udp, &a, port);
	} else {
		if (s->i_tcp == 0) {
			struct tcp_pcb *pcb = tcp_new();

			if (pcb == 0) {
				net_exit(sie);
				return (-ENOMEM);
			}
			tcp_attach(s, pcb);
		}
		e = tcp_bind(s->i_tcp, &a, port);
	}
	net_exit(sie);
	return (lwip_errno(e));
}

int
inet_listen(int si, int backlog)
{
	struct inetsock *s;
	struct tcp_pcb *lp;
	unsigned long sie = net_enter();

	(void) backlog;
	if ((s = isock(si)) == 0 || s->i_type != SOCK_STREAM_V) {
		net_exit(sie);
		return (s == 0 ? -EBADF : -EOPNOTSUPP);
	}
	if (s->i_tcp == 0) {			/* listen without bind: any port */
		struct tcp_pcb *pcb = tcp_new();

		if (pcb == 0 || tcp_bind(pcb, IP_ANY_TYPE, 0) != ERR_OK) {
			net_exit(sie);
			return (-ENOMEM);
		}
		tcp_attach(s, pcb);
	}
	lp = tcp_listen_with_backlog(s->i_tcp, INET_NACCEPT);
	if (lp == 0) {
		net_exit(sie);
		return (-ENOMEM);
	}
	s->i_tcp = lp;
	s->i_listening = 1;
	tcp_arg(lp, s);
	tcp_accept(lp, tcp_accept_cb);
	net_exit(sie);
	return (0);
}

/* Returns a new socket index (accepted connection) or a negative errno. */
int
inet_accept(int si, void *ksa_out)
{
	struct inetsock *s, *c;
	unsigned long sie = net_enter();
	int ci, i;

	for (;;) {
		if ((s = isock(si)) == 0 || !s->i_listening) {
			net_exit(sie);
			return (s == 0 ? -EBADF : -EINVAL);
		}
		if (s->i_nacq > 0)
			break;
		sie = net_sleep(s, sie);
	}
	ci = s->i_acq[0];
	for (i = 1; i < s->i_nacq; i++)
		s->i_acq[i - 1] = s->i_acq[i];
	s->i_nacq--;
	c = isock(ci);
	if (ksa_out != 0) {
		if (c->i_tcp != 0)
			sin_put(ksa_out, &c->i_tcp->remote_ip,
			    c->i_tcp->remote_port);
		else
			sin_put(ksa_out, IP4_ADDR_ANY, 0);	/* reset already */
	}
	net_exit(sie);
	return (ci);
}

int
inet_connect(int si, const void *ksa, unsigned int len)
{
	struct inetsock *s;
	ip_addr_t a;
	u16_t port;
	unsigned long sie;
	int r;
	err_t e;

	if ((r = sin_get(ksa, len, &a, &port)) != 0)
		return (r);
	sie = net_enter();
	if ((s = isock(si)) == 0) {
		net_exit(sie);
		return (-EBADF);
	}
	if (s->i_type == SOCK_DGRAM_V) {
		e = udp_connect(s->i_udp, &a, port);
		net_exit(sie);
		return (lwip_errno(e));
	}
	if (s->i_connected || s->i_listening) {
		net_exit(sie);
		return (-EISCONN);
	}
	if (!inet_up) {		/* no NIC: nothing is routable */
		net_exit(sie);
		return (-ENETUNREACH);
	}
	if (s->i_tcp == 0) {
		struct tcp_pcb *pcb = tcp_new();

		if (pcb == 0) {
			net_exit(sie);
			return (-ENOMEM);
		}
		tcp_attach(s, pcb);
	}
	s->i_err = 0;
	s->i_connecting = 1;
	e = tcp_connect(s->i_tcp, &a, port, tcp_connected_cb);
	if (e != ERR_OK) {
		s->i_connecting = 0;
		net_exit(sie);
		return (lwip_errno(e));
	}
	while (s->i_connecting)
		sie = net_sleep(s, sie);
	r = s->i_connected ? 0 : (s->i_err != 0 ? s->i_err : -ECONNREFUSED);
	net_exit(sie);
	return (r);
}

/* send/write: `kbuf` is a kernel bounce buffer (uproc.c copies in). */
long
inet_send(int si, const unsigned char *kbuf, unsigned long n,
    const void *ksa, unsigned int salen)
{
	struct inetsock *s;
	unsigned long sie = net_enter();
	unsigned long done = 0;

	if ((s = isock(si)) == 0) {
		net_exit(sie);
		return (-EBADF);
	}
	if (s->i_type == SOCK_DGRAM_V) {
		struct pbuf *p;
		ip_addr_t a;
		u16_t port;
		err_t e;

		if (n > 1472) {
			net_exit(sie);
			return (-EINVAL);
		}
		if (!inet_up) {
			net_exit(sie);
			return (-ENETUNREACH);
		}
		p = pbuf_alloc(PBUF_TRANSPORT, (u16_t)n, PBUF_RAM);
		if (p == 0) {
			net_exit(sie);
			return (-ENOMEM);
		}
		pbuf_take(p, kbuf, (u16_t)n);
		if (ksa != 0) {
			int r = sin_get(ksa, salen, &a, &port);

			if (r != 0) {
				pbuf_free(p);
				net_exit(sie);
				return (r);
			}
			e = udp_sendto(s->i_udp, p, &a, port);
		} else {
			e = udp_send(s->i_udp, p);
		}
		pbuf_free(p);
		net_exit(sie);
		return (e == ERR_OK ? (long)n : lwip_errno(e));
	}
	while (done < n) {
		u16_t room;
		unsigned long chunk;
		err_t e;

		if (s->i_err != 0 || s->i_tcp == 0 || !s->i_connected) {
			long r = done > 0 ? (long)done :
			    (s->i_err != 0 ? s->i_err : -EPIPE);
			net_exit(sie);
			return (r);
		}
		room = tcp_sndbuf(s->i_tcp);
		if (room == 0 || tcp_sndqueuelen(s->i_tcp) >= TCP_SND_QUEUELEN) {
			(void) tcp_output(s->i_tcp);
			sie = net_sleep(s, sie);
			continue;
		}
		chunk = n - done < room ? n - done : room;
		e = tcp_write(s->i_tcp, kbuf + done, (u16_t)chunk,
		    TCP_WRITE_FLAG_COPY);
		if (e == ERR_MEM) {
			(void) tcp_output(s->i_tcp);
			sie = net_sleep(s, sie);
			continue;
		}
		if (e != ERR_OK) {
			net_exit(sie);
			return (done > 0 ? (long)done : lwip_errno(e));
		}
		done += chunk;
	}
	(void) tcp_output(s->i_tcp);
	net_exit(sie);
	return ((long)done);
}

/* recv/read into a kernel bounce buffer; for UDP, the source goes to ksa_out. */
long
inet_recv(int si, unsigned char *kbuf, unsigned long n, void *ksa_out)
{
	struct inetsock *s;
	unsigned long sie = net_enter();
	unsigned long got = 0, avail;

	for (;;) {
		if ((s = isock(si)) == 0) {
			net_exit(sie);
			return (-EBADF);
		}
		if (s->i_type == SOCK_DGRAM_V) {
			if (s->i_dgn > 0)
				break;
		} else {
			if (s->i_wpos != s->i_rpos)
				break;
			if (s->i_peer_closed || s->i_err != 0) {
				long r = s->i_err == -ECONNRESET ? s->i_err : 0;
				net_exit(sie);
				return (r);	/* EOF */
			}
			if (!s->i_connected) {
				net_exit(sie);
				return (-ENOTCONN);
			}
		}
		sie = net_sleep(s, sie);
	}
	if (s->i_type == SOCK_DGRAM_V) {
		struct dgram *g = &s->i_dg[s->i_dgh];
		ip_addr_t a;

		got = g->g_len < n ? g->g_len : n;
		for (avail = 0; avail < got; avail++)
			kbuf[avail] = g->g_data[avail];
		if (ksa_out != 0) {
			ip_addr_set_ip4_u32(&a, g->g_addr);
			sin_put(ksa_out, &a, g->g_port);
		}
		s->i_dgh = (s->i_dgh + 1) % INET_NDGRAM;
		s->i_dgn--;
		net_exit(sie);
		return ((long)got);
	}
	avail = s->i_wpos - s->i_rpos;
	got = avail < n ? avail : n;
	for (avail = 0; avail < got; avail++)
		kbuf[avail] = s->i_rx[(s->i_rpos++) % INET_RXBUF];
	if (s->i_tcp != 0)
		tcp_recved(s->i_tcp, (u16_t)got);	/* reopen the window */
	net_exit(sie);
	return ((long)got);
}

int
inet_poll(int si)
{
	struct inetsock *s;
	unsigned long sie = net_enter();
	int m = 0;

	if ((s = isock(si)) == 0) {
		net_exit(sie);
		return (INPOLL_HUP);
	}
	if (s->i_type == SOCK_DGRAM_V) {
		m = INPOLL_WR | (s->i_dgn > 0 ? INPOLL_RD : 0);
	} else if (s->i_listening) {
		m = s->i_nacq > 0 ? INPOLL_RD : 0;
	} else {
		if (s->i_wpos != s->i_rpos || s->i_peer_closed || s->i_err)
			m |= INPOLL_RD;
		if (s->i_peer_closed || s->i_err)
			m |= INPOLL_HUP;
		else if (s->i_connected && s->i_tcp != 0 &&
		    tcp_sndbuf(s->i_tcp) > 0)
			m |= INPOLL_WR;
	}
	net_exit(sie);
	return (m);
}

void
inet_ref(int si)
{
	unsigned long sie = net_enter();
	struct inetsock *s = isock(si);

	if (s != 0)
		s->i_refs++;
	net_exit(sie);
}

static void
inet_close_locked(struct inetsock *s)
{
	int i;

	if (s->i_udp != 0) {
		udp_remove(s->i_udp);
		s->i_udp = 0;
	}
	for (i = 0; i < s->i_nacq; i++) {	/* never-accepted connections */
		struct inetsock *c = isock(s->i_acq[i]);

		if (c != 0 && --c->i_refs <= 0)
			inet_close_locked(c);
	}
	s->i_nacq = 0;
	if (s->i_tcp != 0) {
		tcp_arg(s->i_tcp, 0);
		if (!s->i_listening) {
			tcp_recv(s->i_tcp, 0);
			tcp_sent(s->i_tcp, 0);
			tcp_err(s->i_tcp, 0);
		}
		if (tcp_close(s->i_tcp) != ERR_OK)
			tcp_abort(s->i_tcp);
		s->i_tcp = 0;
	}
	s->i_used = 0;
}

void
inet_close(int si)
{
	unsigned long sie = net_enter();
	struct inetsock *s = isock(si);

	if (s != 0 && --s->i_refs <= 0)
		inet_close_locked(s);
	net_exit(sie);
}

int
inet_getsockname(int si, void *ksa_out, int peer)
{
	unsigned long sie = net_enter();
	struct inetsock *s = isock(si);
	int r = 0;

	if (s == 0) {
		r = -EBADF;
	} else if (s->i_type == SOCK_DGRAM_V) {
		if (peer)
			sin_put(ksa_out, &s->i_udp->remote_ip,
			    s->i_udp->remote_port);
		else if (ip_addr_isany(&s->i_udp->local_ip) && inet_up)
			sin_put(ksa_out, &inet_netif.ip_addr,	/* one NIC */
			    s->i_udp->local_port);
		else
			sin_put(ksa_out, &s->i_udp->local_ip,
			    s->i_udp->local_port);
	} else if (s->i_tcp == 0) {
		r = peer ? -ENOTCONN : -EINVAL;
	} else if (peer) {
		if (!s->i_connected)
			r = -ENOTCONN;
		else
			sin_put(ksa_out, &s->i_tcp->remote_ip,
			    s->i_tcp->remote_port);
	} else {
		sin_put(ksa_out, &s->i_tcp->local_ip, s->i_tcp->local_port);
	}
	net_exit(sie);
	return (r);
}

/* The netif's IPv4 address (network order) or 0, for the boot banner/tests. */
unsigned int
inet_ipaddr(void)
{
	return (inet_have_lease ? ip4_addr_get_u32(netif_ip4_addr(&inet_netif)) : 0);
}
