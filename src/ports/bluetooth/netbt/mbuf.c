/*
 * mbuf.c: NetBSD mbuf(9) subset for the netbt core in userland (solnix, new
 * code). Semantics follow NetBSD uipc_mbuf.c for the cases netbt uses; the
 * unit test is mbuf_test.c.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "mbuf.h"

#define	MMIN(a, b)	((a) < (b) ? (a) : (b))

static void
m_fatal(const char *why)
{
	fprintf(stderr, "mbuf: %s\n", why);
	abort();
}

struct mbuf *
m_get(int how, int type)
{
	struct mbuf *m = calloc(1, sizeof (*m));

	(void) how;
	(void) type;
	if (m != NULL)
		m->m_data = m->m_buf;
	return (m);
}

struct mbuf *
m_gethdr(int how, int type)
{
	struct mbuf *m = m_get(how, type);

	if (m != NULL)
		m->m_flags = M_PKTHDR;
	return (m);
}

void
m_freem(struct mbuf *m)
{
	struct mbuf *n;

	for (; m != NULL; m = n) {
		n = m->m_next;
		free(m);
	}
}

int
m_length(const struct mbuf *m)
{
	int n = 0;

	for (; m != NULL; m = m->m_next)
		n += m->m_len;
	return (n);
}

/* Copy len bytes at off out of the chain; a short chain is a caller bug. */
void
m_copydata(struct mbuf *m, int off, int len, void *vp)
{
	char *p = vp;
	int n;

	if (off < 0 || len < 0)
		m_fatal("m_copydata: negative offset or length");
	for (; m != NULL && off >= m->m_len; m = m->m_next)
		off -= m->m_len;
	for (; m != NULL && len > 0; m = m->m_next, off = 0) {
		n = MMIN(len, m->m_len - off);
		memcpy(p, m->m_data + off, n);
		p += n;
		len -= n;
	}
	if (len > 0)
		m_fatal("m_copydata: chain too short");
}

/* Append len bytes at the end: trailing space first, then new mbufs. */
static int
m_append_tail(struct mbuf *m, int len, const char *p)
{
	int done = 0, n;

	while (m->m_next != NULL)
		m = m->m_next;
	while (done < len) {
		if (M_TRAILINGSPACE(m) == 0) {
			if ((m->m_next = m_get(M_DONTWAIT, MT_DATA)) == NULL)
				break;
			m = m->m_next;
		}
		n = MMIN(len - done, M_TRAILINGSPACE(m));
		memcpy(m->m_data + m->m_len, p + done, n);
		m->m_len += n;
		done += n;
	}
	return (done);
}

/*
 * Overwrite from off, extending the chain past its end as needed. As in
 * NetBSD, m_pkthdr.len grows to cover what was written; on allocation failure
 * it stays short, which the caller checks (hci_send_cmd does).
 * shortcut: off beyond the chain's end (zero padding) is unsupported; netbt never asks for it.
 */
void
m_copyback(struct mbuf *m0, int off, int len, const void *cp)
{
	const char *p = cp;
	struct mbuf *m;
	int o = off, done = 0, n;

	if (off < 0 || len < 0 || off > m_length(m0))
		m_fatal("m_copyback: offset past the end of the chain");
	for (m = m0; m != NULL && done < len; m = m->m_next) {
		if (o >= m->m_len) {
			o -= m->m_len;
			continue;
		}
		n = MMIN(len - done, m->m_len - o);
		memcpy(m->m_data + o, p + done, n);
		done += n;
		o = 0;
	}
	if (done < len)
		done += m_append_tail(m0, len - done, p + done);
	if ((m0->m_flags & M_PKTHDR) && m0->m_pkthdr.len < off + done)
		m0->m_pkthdr.len = off + done;
}
