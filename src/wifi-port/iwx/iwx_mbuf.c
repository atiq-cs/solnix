/*
 * iwx mbuf -> mblk_t translation layer, implementation.
 *
 * See iwx_mbuf.h for why this is code and not macros. Every function here is
 * exercised by iwx_mbuf_test.c, which builds in userland against a faithful
 * mblk_t stub and includes negative controls (each check is proven able to
 * report failure).
 */

#include "iwx_mbuf.h"

/*
 * BSD-ism the driver relies on: an RX cluster is allocated at IWX_RBUF_SIZE
 * (4096) and then re-windowed per sub-frame. allocb() gives a db_lim-bounded
 * cluster, which is the same guarantee, so the window bounds check below is
 * against [db_base, db_lim).
 */

mblk_t *
iwx_m_alloc(size_t size)
{
	mblk_t *m;

	if (size == 0)
		return (NULL);

	m = allocb(size, BPRI_MED);
	if (m == NULL)
		return (NULL);

	/*
	 * OpenBSD opens the whole cluster for writing before handing it to
	 * bus_dmamap_load_mbuf; the DMA engine fills it and the length is
	 * corrected afterwards. Match that: b_wptr at the end of the
	 * allocation, so MBLKL() == the cluster size, matching
	 * m->m_len = m->m_ext.ext_size at if_iwx.c:4633.
	 *
	 * allocb() may over-allocate, so use the real limit rather than the
	 * requested size -- OpenBSD's ext_size is likewise the real cluster
	 * size, not the request.
	 */
	m->b_wptr = DB_LIM(m);
	return (m);
}

void
iwx_m_free(mblk_t *m)
{
	if (m != NULL)
		freemsg(m);
}

void *
iwx_mtod(const mblk_t *m)
{
	return ((void *)m->b_rptr);
}

size_t
iwx_m_len(const mblk_t *m)
{
	/*
	 * Derived, never stored. This is the whole point: there is exactly one
	 * source of truth for the segment length and it is the pointer pair.
	 */
	return ((size_t)(m->b_wptr - m->b_rptr));
}

size_t
iwx_m_pktlen(const mblk_t *m)
{
	const mblk_t *p;
	size_t n = 0;

	for (p = m; p != NULL; p = p->b_cont)
		n += (size_t)(p->b_wptr - p->b_rptr);
	return (n);
}

size_t
iwx_m_clustersize(const mblk_t *m)
{
	return ((size_t)(DB_LIM(m) - DB_BASE(m)));
}

boolean_t
iwx_m_set_window(mblk_t *m, const void *base, size_t len)
{
	unsigned char *p = (unsigned char *)base;

	/*
	 * The check a #define cannot do. OpenBSD's "m->m_data = pktdata +
	 * desc_size" (if_iwx.c:5235) trusts the driver's own arithmetic on a
	 * length field that came from the device. If firmware reports a bogus
	 * mpdu_len, the unchecked form silently produces a window past the end
	 * of the DMA buffer and the 802.11 stack parses adjacent memory.
	 */
	if (p < DB_BASE(m) || p > DB_LIM(m))
		return (B_FALSE);
	if (len > (size_t)(DB_LIM(m) - p))
		return (B_FALSE);

	m->b_rptr = p;
	m->b_wptr = p + len;
	return (B_TRUE);
}

boolean_t
iwx_m_adj(mblk_t *m, int len)
{
	if (len == 0)
		return (B_TRUE);
	/*
	 * adjmsg() and m_adj() share the sign convention (positive trims the
	 * head), so len passes through unchanged. adjmsg() returns 0 without
	 * modifying anything when the chain is too short; m_adj() would empty
	 * the mbuf instead. Reporting the difference rather than emulating it,
	 * because a caller that depends on "trim more than you have" needs
	 * inspecting, not papering over.
	 */
	return (adjmsg(m, (ssize_t)len) != 0 ? B_TRUE : B_FALSE);
}

mblk_t *
iwx_m_pullup(mblk_t *m, size_t len)
{
	mblk_t *n;

	if (m == NULL)
		return (NULL);

	if (iwx_m_len(m) >= len)
		return (m);		/* already contiguous, no copy */

	/*
	 * pullupmsg() works in place but can fail; msgpullup() allocates. Use
	 * pullupmsg() first so the common case does not allocate, and fall back
	 * to msgpullup(). On total failure the chain is freed and NULL returned,
	 * matching m_pullup's contract that it consumes m on failure -- the
	 * caller at if_iwx.c:10306 relies on exactly that.
	 */
	if (pullupmsg(m, (ssize_t)len) != 0)
		return (m);

	n = msgpullup(m, (ssize_t)len);
	freemsg(m);
	return (n);
}

mblk_t *
iwx_m_defrag(mblk_t *m)
{
	mblk_t *n;

	if (m == NULL)
		return (NULL);
	if (m->b_cont == NULL)
		return (m);		/* single segment already */

	n = msgpullup(m, -1);		/* -1: entire message */
	freemsg(m);
	return (n);
}

mblk_t *
iwx_m_copy(const mblk_t *m)
{
	if (m == NULL)
		return (NULL);
	/* copymsg() is a deep copy of the whole chain; dupmsg() would share. */
	return (copymsg((mblk_t *)m));
}

boolean_t
iwx_m_shift_right(mblk_t *m, size_t len, size_t n)
{
	unsigned char *src = m->b_rptr;

	if (n == 0)
		return (B_TRUE);

	/*
	 * OpenBSD's memmove(m->m_data + 2, m->m_data, hdrlen) writes hdrlen
	 * bytes starting 2 past the read pointer, i.e. it needs len + n bytes of
	 * cluster from b_rptr. On OpenBSD the RX cluster is oversized and that
	 * slack is implicit; allocb() does not promise it at the same offset, so
	 * check it. Overflow-safe form: compare against the remaining span
	 * rather than computing src + len + n.
	 */
	if (len > (size_t)(DB_LIM(m) - src))
		return (B_FALSE);
	if (n > (size_t)(DB_LIM(m) - src) - len)
		return (B_FALSE);

	/* The source bytes must actually be readable, not merely allocated. */
	if (len > (size_t)(m->b_wptr - src))
		return (B_FALSE);

	memmove(src + n, src, len);
	/*
	 * The frame is now n bytes longer. Without this the caller's following
	 * m_adj(m, n) (if_iwx.c:5265) trims the pad AND n bytes of real payload
	 * off the tail-derived length, and the corruption is silent.
	 */
	m->b_wptr += n;
	return (B_TRUE);
}

void *
iwx_m_at(const mblk_t *m, size_t offset, size_t need)
{
	size_t avail = (size_t)(m->b_wptr - m->b_rptr);

	if (offset > avail)
		return (NULL);
	if (need > avail - offset)
		return (NULL);
	return ((void *)(m->b_rptr + offset));
}

