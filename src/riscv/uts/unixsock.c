/*
 * unixsock.c -- AF_UNIX / SOCK_STREAM sockets for the illumos riscv64 kernel.
 *
 * WHY THIS EXISTS. A Wayland compositor is a UNIX-socket server before it is
 * anything else: it binds a filesystem-named socket, accepts clients, and passes
 * buffer file descriptors over it with SCM_RIGHTS. So AF_UNIX -- not TCP/IP -- is
 * what gates a compositor, and it needs no IP stack at all. This is the
 * kernel half of the seven __xnet_* entry points that libsocket exports (see
 * docs/riscv64-libc-rust-abi-gap.md section 2, which named this as the
 * nearest-term of the set precisely because the pipe machinery already exists).
 *
 * WHAT A STREAM SOCKET IS HERE. A connected AF_UNIX stream is two independent
 * byte rings -- one per direction -- plus, per direction, a queue of in-flight
 * file descriptors sent with SCM_RIGHTS. That is deliberately the same shape as
 * uproc.c's pipe (a ring with a read cursor, a write cursor and endpoint
 * reference counts); a stream socket is a bidirectional pipe with an fd queue
 * bolted on. Reusing that shape rather than inventing a second buffering scheme
 * is why this file is small.
 *
 * CRIB PROVENANCE. The design follows the BSD unpcb model (NetBSD/FreeBSD
 * uipc_usrreq.c): a per-socket protocol control block, a bound-name table
 * resolved through the filesystem namespace, a backlog queue of pending
 * connections drained by accept(), and rights (fd) passing modeled as a
 * per-message attachment that the receiver installs into its own fd table.
 * Reimplemented in the illumos idiom (sleep_on/wakeup for blocking, the existing
 * proc_t fd table, copyin/copyout for user memory); no BSD source was copied.
 *
 * NOTE (ceilings, all deliberate and all documented rather than hidden):
 *   - fixed tables (NUNSOCK sockets, NUNBIND names, SOBUF bytes/direction,
 *     NSCMFD queued fds/direction); no dynamic growth. A real implementation
 *     hangs these off a vnode and a kmem cache.
 *   - the bound-name table is a flat array of path strings compared with strcmp,
 *     NOT real filesystem nodes, so a socket path does not appear in the
 *     directory listing. Wayland only needs bind/connect to agree on the string,
 *     which this satisfies. Upgrade path: a sockfs vnode.
 *   - SOCK_STREAM only. SOCK_DGRAM is unimplemented (a compositor does not need
 *     it) and is refused with EPROTONOSUPPORT rather than silently downgraded.
 *   - no O_NONBLOCK, no poll/select, no SO_PEERCRED, no socket timeouts.
 *     A compositor's main loop wants poll(2); that is named as the next item in
 *     the AF_UNIX design notes, not quietly assumed to work.
 */

#include "sbi.h"

/* uproc.c: the fd-table + process plumbing this layer sits on. */
extern long copyin(const void *uaddr, void *kaddr, unsigned long n);
extern long copyout(const void *kaddr, void *uaddr, unsigned long n);
/* proc.c: the real sleep queue -- a blocked accept/read costs no cpu. */
extern void sleep_on(void *chan);
extern void wakeup(void *chan);

/*
 * uproc.c owns the rights table (it is fd-table business); this layer only needs
 * to release entries that die unclaimed when a socket is torn down.
 */
extern void unsock_rights_drop(int ri);

/* The fd-table accessors uproc.c exports for this layer (see uproc.c). */
extern int unsock_fd_alloc(int si);
extern int unsock_fd_socket(int fd);
extern int unsock_fd_install_raw(int fd);
extern int unsock_fd_dup_into(int fd);
extern void *unsock_curproc(void);
extern void unsock_setcurproc(void *p);

#define	EBADF		9
#define	EAGAIN		11
#define	EFAULT		14
#define	EINVAL		22
#define	EMFILE		24
#define	EPIPE		32
#define	EADDRINUSE	125
#define	ECONNREFUSED	146
#define	EISCONN		133
#define	ENOTCONN	134
#define	EPROTONOSUPPORT	120
#define	EOPNOTSUPP	122
#define	ENOENT		2
#define	ENOSPC		28

/* The AF_UNIX / SOCK_* constants userland passes (illumos values). */
#define	AF_UNIX_V	1
#define	SOCK_STREAM_V	2
#define	SOCK_DGRAM_V	1

#define	NUNSOCK		16	/* sockets in flight (listeners + endpoints) */
#define	NUNBIND		8	/* bound names */
#define	SOBUF		4096	/* bytes buffered per direction */
#define	NSCMFD		8	/* SCM_RIGHTS fds queued per direction */
#define	UNPATHMAX	104	/* sun_path, the BSD/illumos sockaddr_un size */
#define	BACKLOG_MAX	4

/*
 * A byte ring plus an fd queue: ONE direction of a connected stream.
 *
 * The fd queue records, for each in-flight descriptor, the byte offset in the
 * stream at which it was sent (sc_at). recvmsg only hands over the descriptors
 * whose offset has already been consumed by the reader, which is what makes fd
 * passing ordered with respect to the bytes -- a Wayland client that sends a
 * buffer fd alongside a request must not receive the fd before the request.
 */
struct sodir {
	unsigned long	d_rpos;		/* total bytes read */
	unsigned long	d_wpos;		/* total bytes written */
	unsigned char	d_buf[SOBUF];
	struct {
		int		sc_kfd;	/* the kernel-side fd reference */
		unsigned long	sc_at;	/* stream offset it was attached at */
	} d_scm[NSCMFD];
	int		d_nscm;
};

/*
 * A socket. One struct serves all three roles a stream socket takes on
 * (unbound, listening, connected) because the BSD unpcb does the same and the
 * state transitions are what distinguish them:
 *   fresh    -> s_bound=0, s_listening=0, s_peer=-1
 *   bound    -> s_bound=1                      (bind)
 *   listening-> s_listening=1                  (listen)
 *   connected-> s_peer >= 0                    (connect / accept)
 */
struct unsock {
	int	s_used;
	int	s_type;			/* SOCK_STREAM_V */
	int	s_bound;		/* has a name in the bind table */
	int	s_bindslot;		/* index into bindtab, or -1 */
	int	s_listening;
	int	s_peer;			/* connected peer socket index, or -1 */
	int	s_refs;			/* fd references (fork/dup bump this) */
	int	s_shutdown;		/* peer gone: reads drain then EOF */
	/*
	 * tx is what THIS socket writes and the peer reads; rx is the reverse.
	 * A connected pair shares nothing: each socket owns its own tx, and
	 * reads out of its peer's tx. Keeping both here (rather than one shared
	 * object) is what makes close/shutdown accounting per-endpoint.
	 */
	struct sodir s_tx;
	/* Pending connections on a listener, as socket indices. */
	int	s_backlog[BACKLOG_MAX];
	int	s_nbacklog;
	int	s_backlog_max;
};

static struct unsock socktab[NUNSOCK];

/* The bound-name table: the AF_UNIX namespace, flattened. */
static struct {
	int	b_used;
	int	b_sock;			/* socket index listening on this name */
	char	b_path[UNPATHMAX];
} bindtab[NUNBIND];

static int
sstrcmp(const char *a, const char *b)
{
	while (*a != '\0' && *a == *b) {
		a++;
		b++;
	}
	return ((int)((unsigned char)*a) - (int)((unsigned char)*b));
}

static void
sstrcpy(char *d, const char *s, unsigned long max)
{
	unsigned long i;

	for (i = 0; i + 1 < max && s[i] != '\0'; i++)
		d[i] = s[i];
	d[i] = '\0';
}

static struct unsock *
sock_at(int si)
{
	if (si < 0 || si >= NUNSOCK || !socktab[si].s_used)
		return (0);
	return (&socktab[si]);
}

static void
dir_init(struct sodir *d)
{
	d->d_rpos = 0;
	d->d_wpos = 0;
	d->d_nscm = 0;
}

static int
sock_alloc(int type)
{
	int i;

	for (i = 0; i < NUNSOCK; i++) {
		if (socktab[i].s_used)
			continue;
		socktab[i].s_used = 1;
		socktab[i].s_type = type;
		socktab[i].s_bound = 0;
		socktab[i].s_bindslot = -1;
		socktab[i].s_listening = 0;
		socktab[i].s_peer = -1;
		socktab[i].s_refs = 1;
		socktab[i].s_shutdown = 0;
		socktab[i].s_nbacklog = 0;
		socktab[i].s_backlog_max = 0;
		dir_init(&socktab[i].s_tx);
		return (i);
	}
	return (-1);
}

/*
 * unsock_socket -- socket(2) for AF_UNIX. Returns a socket index (NOT an fd);
 * the caller (uproc.c) binds it to a descriptor, because the fd table is the
 * process's business and this file deliberately does not reach into proc_t.
 */
int
unsock_socket(int domain, int type, int protocol)
{
	(void) protocol;

	if (domain != AF_UNIX_V)
		return (-EINVAL);
	if (type == SOCK_DGRAM_V)
		return (-EPROTONOSUPPORT);	/* honest: not implemented */
	if (type != SOCK_STREAM_V)
		return (-EPROTONOSUPPORT);
	{
		int si = sock_alloc(type);

		return (si < 0 ? -EMFILE : si);
	}
}

/*
 * unsock_bind -- bind(2). Records the path in the flat name table. `kpath` is
 * already a kernel copy (the syscall layer does the copyin, so a bad user
 * pointer becomes EFAULT before we are called).
 */
int
unsock_bind(int si, const char *kpath)
{
	struct unsock *s = sock_at(si);
	int i, free = -1;

	if (s == 0)
		return (-EBADF);
	if (s->s_bound)
		return (-EINVAL);
	if (kpath == 0 || kpath[0] == '\0')
		return (-EINVAL);

	for (i = 0; i < NUNBIND; i++) {
		if (bindtab[i].b_used) {
			if (sstrcmp(bindtab[i].b_path, kpath) == 0)
				return (-EADDRINUSE);
		} else if (free < 0) {
			free = i;
		}
	}
	if (free < 0)
		return (-ENOSPC);

	bindtab[free].b_used = 1;
	bindtab[free].b_sock = si;
	sstrcpy(bindtab[free].b_path, kpath, UNPATHMAX);
	s->s_bound = 1;
	s->s_bindslot = free;
	return (0);
}

/*
 * unsock_listen -- listen(2). Marks the socket as a listener and sizes its
 * backlog. A listener never transfers bytes itself; it only queues peers for
 * accept() to claim.
 */
int
unsock_listen(int si, int backlog)
{
	struct unsock *s = sock_at(si);

	if (s == 0)
		return (-EBADF);
	if (!s->s_bound)
		return (-EINVAL);	/* nothing to listen on */
	if (s->s_peer >= 0)
		return (-EISCONN);
	if (backlog <= 0)
		backlog = 1;
	if (backlog > BACKLOG_MAX)
		backlog = BACKLOG_MAX;
	s->s_listening = 1;
	s->s_backlog_max = backlog;
	return (0);
}

/*
 * unsock_connect -- connect(2). Resolves the name, allocates the SERVER-side
 * endpoint of the new connection, cross-links it with the caller, and queues it
 * on the listener's backlog for accept() to claim. Then blocks until a server
 * has accepted, so a client that writes immediately after connect cannot race
 * ahead of the server's accept.
 *
 * Returns 0, or a negative errno. This is where the two-process handshake
 * actually happens, so the wakeup targets matter: the listener is the channel
 * accept() sleeps on, and the new endpoint pair is the channel connect() sleeps
 * on.
 */
int
unsock_connect(int si, const char *kpath)
{
	struct unsock *s = sock_at(si);
	int i, li = -1, peer;
	struct unsock *l;
	void *self;

	if (s == 0)
		return (-EBADF);
	if (s->s_peer >= 0)
		return (-EISCONN);
	if (kpath == 0)
		return (-EINVAL);

	for (i = 0; i < NUNBIND; i++)
		if (bindtab[i].b_used && sstrcmp(bindtab[i].b_path, kpath) == 0) {
			li = bindtab[i].b_sock;
			break;
		}
	l = sock_at(li);
	if (l == 0 || !l->s_listening)
		return (-ECONNREFUSED);
	if (l->s_nbacklog >= l->s_backlog_max)
		return (-EAGAIN);	/* backlog full: caller retries */

	/*
	 * Allocate the server's end now (rather than in accept) so the
	 * connection is fully formed and cross-linked before accept runs. accept
	 * then just claims it, which keeps accept from having to fail halfway.
	 */
	peer = sock_alloc(SOCK_STREAM_V);
	if (peer < 0)
		return (-EMFILE);
	socktab[peer].s_peer = si;
	s = sock_at(si);			/* sock_alloc may not move it, but be explicit */
	s->s_peer = peer;

	l->s_backlog[l->s_nbacklog++] = peer;
	wakeup(l);				/* a blocked accept() can proceed */

	/*
	 * Wait for accept to claim it. The server marks acceptance by giving the
	 * endpoint a real fd reference (s_refs>1 means accept installed it).
	 * curproc must be restored after every sleep: the dispatcher switches
	 * threads while we are off-cpu.
	 */
	self = unsock_curproc();
	while (socktab[peer].s_used && socktab[peer].s_refs < 2) {
		sleep_on(&socktab[peer]);
		unsock_setcurproc(self);
		if (!socktab[peer].s_used)
			return (-ECONNREFUSED);	/* listener died mid-handshake */
	}
	return (0);
}

/*
 * unsock_accept -- accept(2). Claims the head of the backlog and returns its
 * socket index; blocks on the listener while the backlog is empty. The caller
 * installs the returned index into an fd, and that installation is what tells
 * the blocked connect() the handshake is complete (see s_refs above).
 */
int
unsock_accept(int si)
{
	struct unsock *l = sock_at(si);
	void *self;
	int peer, i;

	if (l == 0)
		return (-EBADF);
	if (!l->s_listening)
		return (-EINVAL);

	self = unsock_curproc();
	while (l->s_nbacklog == 0) {
		sleep_on(l);
		unsock_setcurproc(self);
		l = sock_at(si);
		if (l == 0)
			return (-EBADF);	/* closed under us */
	}
	peer = l->s_backlog[0];
	for (i = 1; i < l->s_nbacklog; i++)
		l->s_backlog[i - 1] = l->s_backlog[i];
	l->s_nbacklog--;
	return (peer);
}

/*
 * unsock_accepted -- called by the fd layer once the accepted socket has a real
 * descriptor. Bumps the reference (which is the "accept completed" signal
 * connect() waits on) and wakes the connector.
 */
void
unsock_accepted(int si)
{
	struct unsock *s = sock_at(si);

	if (s == 0)
		return;
	s->s_refs++;
	wakeup(s);
}

/* The direction THIS socket reads from: its peer's tx. */
static struct sodir *
rx_of(struct unsock *s)
{
	struct unsock *p = sock_at(s->s_peer);

	return (p == 0 ? 0 : &p->s_tx);
}

/*
 * unsock_send -- the sendmsg/write path. Copies bytes from the user buffer into
 * this socket's tx ring, and attaches any SCM_RIGHTS descriptors at the current
 * stream offset so the receiver gets them in order with the bytes.
 *
 * `kfds`/`nfds` are already-duplicated KERNEL-side fd references (the syscall
 * layer duplicates the sender's descriptors before calling, so the sender may
 * close its copy immediately after sendmsg -- which is exactly what Wayland
 * clients do with buffer fds).
 */
long
unsock_send(int si, const char *ubuf, unsigned long n, const int *kfds, int nfds)
{
	struct unsock *s = sock_at(si);
	struct sodir *d;
	void *self;
	unsigned long put = 0;
	int i;

	if (s == 0)
		return (-EBADF);
	if (s->s_peer < 0)
		return (-ENOTCONN);
	d = &s->s_tx;

	/*
	 * Attach the rights FIRST, at the offset the following bytes will start
	 * at. A receiver that reads those bytes then knows the fds are already
	 * queued; the reverse order would let it consume the bytes and miss the
	 * attachment.
	 */
	if (nfds > 0) {
		if (nfds > NSCMFD - d->d_nscm)
			return (-ENOSPC);	/* fd queue full: do not drop silently */
		for (i = 0; i < nfds; i++) {
			d->d_scm[d->d_nscm].sc_kfd = kfds[i];
			d->d_scm[d->d_nscm].sc_at = d->d_wpos;
			d->d_nscm++;
		}
	}

	self = unsock_curproc();
	while (put < n) {
		unsigned long space, idx, run, i2;
		char ch;

		if (sock_at(s->s_peer) == 0 || s->s_shutdown)
			return (put > 0 ? (long)put : -EPIPE);
		space = SOBUF - (d->d_wpos - d->d_rpos);
		if (space == 0) {
			wakeup(d);		/* nudge the reader */
			sleep_on(d);
			unsock_setcurproc(self);
			s = sock_at(si);
			if (s == 0)
				return (put > 0 ? (long)put : -EBADF);
			d = &s->s_tx;
			continue;
		}
		idx = d->d_wpos % SOBUF;
		run = SOBUF - idx;
		if (run > space)
			run = space;
		if (run > n - put)
			run = n - put;
		for (i2 = 0; i2 < run; i2++) {
			if (copyin(ubuf + put + i2, &ch, 1) != 0)
				return (put + i2 > 0 ? (long)(put + i2) : -EFAULT);
			d->d_buf[idx + i2] = (unsigned char)ch;
		}
		d->d_wpos += run;
		put += run;
		wakeup(d);			/* data available */
	}
	return ((long)put);
}

/*
 * unsock_recv -- the recvmsg/read path. Copies bytes out of the peer's tx ring,
 * blocking while it is empty and the peer is still open, and reports any
 * SCM_RIGHTS descriptors whose stream offset has now been consumed.
 *
 * `outfds` receives the KERNEL-side fd references; the syscall layer installs
 * them into the receiver's fd table and copies the resulting numbers out. Doing
 * the install above this layer keeps the fd table in one place.
 *
 * Returns bytes read (0 = EOF, peer closed), or a negative errno. *noutfds is
 * set even on a 0-byte return, so a message consisting only of rights is not
 * lost at EOF.
 */
long
unsock_recv(int si, char *ubuf, unsigned long n, int *outfds, int *noutfds)
{
	struct unsock *s = sock_at(si);
	struct sodir *d;
	void *self;
	unsigned long avail, got = 0;
	int nout = 0;

	if (noutfds != 0)
		*noutfds = 0;
	if (s == 0)
		return (-EBADF);
	if (s->s_peer < 0 && !s->s_shutdown)
		return (-ENOTCONN);

	self = unsock_curproc();
	for (;;) {
		d = rx_of(s);
		if (d == 0) {
			/*
			 * Peer is gone. Anything it left buffered was in ITS tx,
			 * which died with it, so this is EOF. A real
			 * implementation keeps the buffer alive until drained;
			 * that needs the ring to outlive the endpoint (a shared
			 * refcounted object), which is the named upgrade.
			 */
			return (0);
		}
		avail = d->d_wpos - d->d_rpos;
		if (avail > 0)
			break;
		if (d->d_nscm > 0)
			break;			/* rights with no payload bytes */
		if (s->s_shutdown || sock_at(s->s_peer) == 0)
			return (0);		/* EOF */
		sleep_on(d);
		unsock_setcurproc(self);
		s = sock_at(si);
		if (s == 0)
			return (-EBADF);
	}

	if (n > avail)
		n = avail;
	while (got < n) {
		unsigned long idx = d->d_rpos % SOBUF;
		unsigned long run = SOBUF - idx;
		unsigned long i;
		char ch;

		if (run > n - got)
			run = n - got;
		for (i = 0; i < run; i++) {
			ch = (char)d->d_buf[idx + i];
			if (copyout(&ch, ubuf + got + i, 1) != 0)
				return (got + i > 0 ? (long)(got + i) : -EFAULT);
		}
		d->d_rpos += run;
		got += run;
	}

	/*
	 * Hand over every descriptor attached at or before the offset we have
	 * now consumed. Descriptors attached further along the stream stay
	 * queued for a later recv, which is what keeps fds ordered with bytes.
	 */
	if (outfds != 0 && d->d_nscm > 0) {
		int i, keep = 0;

		for (i = 0; i < d->d_nscm; i++) {
			if (d->d_scm[i].sc_at <= d->d_rpos && nout < NSCMFD) {
				outfds[nout++] = d->d_scm[i].sc_kfd;
			} else {
				d->d_scm[keep++] = d->d_scm[i];
			}
		}
		d->d_nscm = keep;
	}
	if (noutfds != 0)
		*noutfds = nout;

	wakeup(d);				/* space freed: wake the sender */
	return ((long)got);
}

/*
 * unsock_socketpair -- socketpair(2). Two endpoints cross-linked with no name
 * and no listener, which is the one AF_UNIX call reachable with no namespace at
 * all. Returns 0 and writes the two socket indices, or a negative errno.
 */
int
unsock_socketpair(int domain, int type, int *sa, int *sb)
{
	int a, b;

	if (domain != AF_UNIX_V)
		return (-EINVAL);
	if (type != SOCK_STREAM_V)
		return (-EPROTONOSUPPORT);
	a = sock_alloc(SOCK_STREAM_V);
	if (a < 0)
		return (-EMFILE);
	b = sock_alloc(SOCK_STREAM_V);
	if (b < 0) {
		socktab[a].s_used = 0;
		return (-EMFILE);
	}
	socktab[a].s_peer = b;
	socktab[b].s_peer = a;
	*sa = a;
	*sb = b;
	return (0);
}

/*
 * unsock_ref / unsock_close -- endpoint reference counting. fork and dup share a
 * socket between descriptors; the socket is torn down only when the last
 * descriptor goes. Closing one end marks the peer shutdown so its reader sees
 * EOF instead of blocking forever.
 */
void
unsock_ref(int si)
{
	struct unsock *s = sock_at(si);

	if (s != 0)
		s->s_refs++;
}

void
unsock_close(int si)
{
	struct unsock *s = sock_at(si);
	struct unsock *p;

	if (s == 0)
		return;
	if (s->s_refs > 1) {
		s->s_refs--;
		return;
	}

	/* Last reference: tell the peer, release the name, wake every waiter. */
	p = sock_at(s->s_peer);
	/*
	 * Any rights still queued in OUR tx were never received. Drop them so the
	 * objects they hold are not leaked for the life of the boot.
	 */
	while (s->s_tx.d_nscm > 0)
		unsock_rights_drop(s->s_tx.d_scm[--s->s_tx.d_nscm].sc_kfd);
	if (p != 0) {
		p->s_shutdown = 1;
		p->s_peer = -1;
		wakeup(&p->s_tx);	/* a blocked sender must see EPIPE */
		wakeup(&s->s_tx);	/* a blocked reader must see EOF */
		wakeup(p);
	}
	if (s->s_bindslot >= 0 && s->s_bindslot < NUNBIND) {
		bindtab[s->s_bindslot].b_used = 0;
		bindtab[s->s_bindslot].b_sock = -1;
	}
	/*
	 * A listener that dies with queued connections must not leave its
	 * pending peers wedged in connect(): free them and wake them so they
	 * return ECONNREFUSED.
	 */
	while (s->s_nbacklog > 0) {
		int q = s->s_backlog[--s->s_nbacklog];

		if (q >= 0 && q < NUNSOCK && socktab[q].s_used) {
			socktab[q].s_used = 0;
			wakeup(&socktab[q]);
		}
	}
	wakeup(s);
	s->s_used = 0;
	s->s_peer = -1;
	s->s_listening = 0;
	s->s_bound = 0;
	s->s_bindslot = -1;
}

/* Report: how many sockets/names are live (the gate banner prints this). */
void
unsock_stats(int *nsock, int *nbind)
{
	int i, ns = 0, nb = 0;

	for (i = 0; i < NUNSOCK; i++)
		if (socktab[i].s_used)
			ns++;
	for (i = 0; i < NUNBIND; i++)
		if (bindtab[i].b_used)
			nb++;
	if (nsock != 0)
		*nsock = ns;
	if (nbind != 0)
		*nbind = nb;
}
