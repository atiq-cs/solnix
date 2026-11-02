/*
 * mbuf_ops.c: m_adj, m_cat, m_split, m_prepend and m_frombuf for the netbt
 * core in userland (solnix, new code). NetBSD uipc_mbuf.c semantics for the
 * cases netbt uses: trimmed mbufs stay in the chain with m_len 0, m_cat does
 * not touch m_pkthdr.len (hci_acl_recv sets it), m_split moves the header.
 */
#include <stdlib.h>
#include <string.h>
#include "mbuf.h"

/* Positive: trim from the head; negative: trim from the tail. */
void
m_adj(struct mbuf *mp, int req)
{
	struct mbuf *m;
	int len, total, n;

	if (mp == NULL)
		return;
	len = req < 0 ? -req : req;
	if (req >= 0) {
		for (m = mp; m != NULL && len > 0; m = m->m_next) {
			n = m->m_len < len ? m->m_len : len;
			m->m_len -= n;
			m->m_data += n;
			len -= n;
		}
		if (mp->m_flags & M_PKTHDR)
			mp->m_pkthdr.len -= req - len;
		return;
	}
	total = m_length(mp);
	if (len > total)
		len = total;
	n = total - len;		/* bytes to keep */
	for (m = mp; m != NULL; m = m->m_next) {
		if (m->m_len >= n) {
			m->m_len = n;
			n = 0;
		} else {
			n -= m->m_len;
		}
	}
	if (mp->m_flags & M_PKTHDR)
		mp->m_pkthdr.len = total - len;
}

/* Append chain n to chain m, copying into trailing space where it fits. */
void
m_cat(struct mbuf *m, struct mbuf *n)
{
	struct mbuf *next;

	while (m->m_next != NULL)
		m = m->m_next;
	while (n != NULL) {
		if (n->m_len > M_TRAILINGSPACE(m)) {
			m->m_next = n;
			return;
		}
		memcpy(m->m_data + m->m_len, n->m_data, n->m_len);
		m->m_len += n->m_len;
		next = n->m_next;
		free(n);
		n = next;
	}
}

/* Split after len0 bytes; the tail comes back with its own packet header. */
struct mbuf *
m_split(struct mbuf *m0, int len0, int how)
{
	struct mbuf *m, *n;
	int off = len0;

	for (m = m0; m != NULL && off > m->m_len; m = m->m_next)
		off -= m->m_len;
	if (m == NULL || len0 < 0)
		return (NULL);
	if ((n = (m0->m_flags & M_PKTHDR) ? m_gethdr(how, MT_DATA) :
	    m_get(how, MT_DATA)) == NULL)
		return (NULL);
	n->m_len = m->m_len - off;
	memcpy(n->m_data, m->m_data + off, n->m_len);
	n->m_next = m->m_next;
	m->m_len = off;
	m->m_next = NULL;
	if (m0->m_flags & M_PKTHDR) {
		n->m_pkthdr.len = m0->m_pkthdr.len - len0;
		m0->m_pkthdr.len = len0;
	}
	return (n);
}

/* Make room for plen bytes in front; on failure the chain is freed. */
struct mbuf *
m_prepend(struct mbuf *m, int plen, int how)
{
	struct mbuf *mn;

	if (M_LEADINGSPACE(m) >= plen) {
		m->m_data -= plen;
		m->m_len += plen;
	} else {
		if (plen > MLEN || (mn = m_get(how, MT_DATA)) == NULL) {
			m_freem(m);
			return (NULL);
		}
		mn->m_flags = m->m_flags & M_PKTHDR;
		mn->m_pkthdr = m->m_pkthdr;
		m->m_flags &= ~M_PKTHDR;
		mn->m_data = mn->m_buf + MLEN - plen;
		mn->m_len = plen;
		mn->m_next = m;
		m = mn;
	}
	if (m->m_flags & M_PKTHDR)
		m->m_pkthdr.len += plen;
	return (m);
}

/* One HCI packet: the type byte then count bytes (as ubt_mbufload builds it). */
struct mbuf *
m_frombuf(unsigned char type, const void *buf, int count)
{
	struct mbuf *m = m_gethdr(M_DONTWAIT, MT_DATA);

	if (m == NULL)
		return (NULL);
	m->m_buf[0] = (char)type;
	m->m_len = m->m_pkthdr.len = 1;
	m_copyback(m, 1, count, buf);
	if (m->m_pkthdr.len != count + 1 || m_length(m) != count + 1) {
		m_freem(m);
		return (NULL);
	}
	return (m);
}
