/*
 * mbuf.h: the subset of NetBSD mbuf(9) the netbt HCI core uses, for userland
 * (solnix, new code). Plain BSD semantics: the core writes m_len and
 * m_pkthdr.len itself and chains through m_next (bluetooth-phase1-plan.md 2.2).
 * MLEN is small on purpose so real HCI events span chains in the tests.
 */
#ifndef _SOLNIX_NETBT_MBUF_H
#define	_SOLNIX_NETBT_MBUF_H

#include <stddef.h>

#define	MLEN		64
#define	MHLEN		MLEN	/* the packet header lives outside m_buf */

#define	M_PKTHDR	0x0001
#define	M_LINK0		0x1000	/* netbt: incoming packet */
#define	M_PROTO1	0x0010	/* netbt: first L2CAP fragment */
#define	M_DONTWAIT	1
#define	M_WAIT		0
#define	MT_DATA		1

struct mbuf {
	struct mbuf	*m_next;	/* next mbuf of this packet */
	struct mbuf	*m_nextpkt;	/* next packet on an MBUFQ */
	char		*m_data;
	int		m_len;
	int		m_flags;
	struct {
		int	len;		/* whole packet, valid with M_PKTHDR */
		void	*ctx;		/* M_GETCTX/M_SETCTX */
	} m_pkthdr;
	char		m_buf[MLEN];
};

#define	mtod(m, t)		((t)((m)->m_data))
#define	M_GETCTX(m, t)		((t)(m)->m_pkthdr.ctx)
#define	M_SETCTX(m, c)		((void)((m)->m_pkthdr.ctx = (void *)(c)))
#define	M_LEADINGSPACE(m)	((int)((m)->m_data - (m)->m_buf))
#define	M_TRAILINGSPACE(m)	\
	((int)(((m)->m_buf + MLEN) - ((m)->m_data + (m)->m_len)))

struct mbuf *m_get(int, int);
struct mbuf *m_gethdr(int, int);
void m_freem(struct mbuf *);
int m_length(const struct mbuf *);
void m_copydata(struct mbuf *, int, int, void *);
void m_copyback(struct mbuf *, int, int, const void *);
void m_adj(struct mbuf *, int);
void m_cat(struct mbuf *, struct mbuf *);
struct mbuf *m_split(struct mbuf *, int, int);
struct mbuf *m_prepend(struct mbuf *, int, int);
#define	M_PREPEND(m, plen, how)	((m) = m_prepend((m), (plen), (how)))
/* solnix: one packet = type byte + buf, as ubt_mbufload builds it */
struct mbuf *m_frombuf(unsigned char, const void *, int);

/* MBUFQ: a packet queue through m_nextpkt (NetBSD sys/mbuf.h) */
#define	MBUFQ_HEAD(name)						\
	struct name { struct mbuf *mq_first; struct mbuf **mq_last; }
#define	MBUFQ_INIT(q)	do {						\
	(q)->mq_first = NULL;						\
	(q)->mq_last = &(q)->mq_first;					\
} while (0)
#define	MBUFQ_ENQUEUE(q, m)	do {					\
	(m)->m_nextpkt = NULL;						\
	*(q)->mq_last = (m);						\
	(q)->mq_last = &(m)->m_nextpkt;					\
} while (0)
#define	MBUFQ_DEQUEUE(q, m)	do {					\
	if (((m) = (q)->mq_first) != NULL) {				\
		if (((q)->mq_first = (m)->m_nextpkt) == NULL)		\
			(q)->mq_last = &(q)->mq_first;			\
		else							\
			(m)->m_nextpkt = NULL;				\
	}								\
} while (0)
#define	MBUFQ_DRAIN(q)	do {						\
	struct mbuf *__m0;						\
	while ((__m0 = (q)->mq_first) != NULL) {			\
		(q)->mq_first = __m0->m_nextpkt;			\
		m_freem(__m0);						\
	}								\
	(q)->mq_last = &(q)->mq_first;					\
} while (0)
#define	MBUFQ_FIRST(q)		((q)->mq_first)
#define	MBUFQ_NEXT(m)		((m)->m_nextpkt)

#endif
