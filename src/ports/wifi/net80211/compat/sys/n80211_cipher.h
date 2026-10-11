/*
 * net80211 cipher mbuf-cursor adapter.
 *
 * The four software ciphers (CCMP, TKIP, WEP, BIP) each REBUILD a frame into a
 * fresh output mbuf while walking the input frame segment by segment. On
 * OpenBSD that walk exists ONLY because an mbuf is a fixed ~256-byte cell, so
 * the output has to be grown one MGET(n->m_next) at a time, sizing each
 * segment's m_len against MHLEN / m_ext.ext_size. None of that models anything
 * on illumos: allocb() hands back a single contiguous cluster of ANY size, so
 * the output frame is one mblk and the segment allocator is noise.
 *
 * This header is the adapter the cipher patches route that idiom through. It is
 * two disjoint pieces:
 *
 *   READ side  (input frame m0):  a segment walker over the b_cont chain,
 *       replacing "moff == m->m_len -> m = m->m_next; moff = 0".
 *   WRITE side (output frame n0):  a linear cursor into ONE allocb'd cluster,
 *       replacing the MGET(n->m_next) / n->m_len = MLEN / ext_size dance and
 *       the "mtod(n)+n->m_len; n->m_len += LEN" tail appends.
 *
 * NO mbuf FIELD is aliased -- the same invariant iwx_mbuf_adapter.h states. The
 * output length lives in exactly one place (b_wptr, set once via
 * iwx_m_set_window at the end), never in a stored m_len that would drift.
 *
 * A self-check (n80211_cipher_selftest, compiled only for the userland test
 * harness) exercises the cursor round-trip and MUST fail if the bounds check or
 * the read walk is broken.
 */
#ifndef _N80211_CIPHER_H
#define _N80211_CIPHER_H

#include <sys/types.h>
#include <sys/stream.h>
#include "iwx_mbuf.h"		/* iwx_m_len / iwx_mtod / iwx_m_set_window */

/*
 * WRITE-side cursor over a single output cluster. `base` is mtod(n0); `cap` is
 * the cluster capacity; `off` is the write position. All cipher output is
 * bounded (one MSDU + cipher overhead << MCLBYTES), so one cluster always
 * suffices; the cursor's job is the bounds check the raw pointer arithmetic
 * lacked, not fragmentation.
 */
struct n80211_wcursor {
	u_int8_t	*base;
	size_t		 cap;
	size_t		 off;
};

/*
 * Allocate the output frame as ONE cluster of `total` bytes and open the write
 * window to `total` (the frame's final length is known up front: input length
 * +/- the cipher's fixed overhead). Returns NULL on allocation failure -- the
 * caller's `goto nospace` path. iwx_m_alloc opens the full window; the cursor
 * then writes into [base, base+total).
 */
static __inline mblk_t *
n80211_cipher_out(struct n80211_wcursor *c, size_t total)
{
	mblk_t *n0 = iwx_m_alloc(total);
	if (n0 == NULL)
		return (NULL);
	c->base = (u_int8_t *)iwx_mtod(n0);
	c->cap = total;
	c->off = 0;
	return (n0);
}

/*
 * Write `len` bytes from `src` at the cursor. Returns B_FALSE (and writes
 * nothing) if it would run past the cluster -- the bounds check the OpenBSD
 * segment walk got for free from MCLGET sizing. Advances the cursor on success.
 */
static __inline boolean_t
n80211_wput(struct n80211_wcursor *c, const void *src, size_t len)
{
	if (c->off + len > c->cap)
		return (B_FALSE);
	memcpy(c->base + c->off, src, len);
	c->off += len;
	return (B_TRUE);
}

/*
 * A writable window of `len` bytes at the cursor, for ciphers that XOR/encrypt
 * in place (dst = base+off). Returns NULL if it would overflow. Does NOT
 * advance -- call n80211_wadv after filling, so a short write is impossible to
 * mis-account.
 */
static __inline u_int8_t *
n80211_wat(struct n80211_wcursor *c, size_t len)
{
	if (c->off + len > c->cap)
		return (NULL);
	return (c->base + c->off);
}

static __inline void
n80211_wadv(struct n80211_wcursor *c, size_t len)
{
	c->off += len;
}

/* Bytes already written -- the running output length (replaces n->m_len reads). */
static __inline size_t
n80211_wlen(const struct n80211_wcursor *c)
{
	return (c->off);
}

/*
 * READ-side segment walker over the input frame's b_cont chain. Tracks the
 * current segment `seg` and the offset `off` within it, replacing the OpenBSD
 * "if (moff == m->m_len) { m = m->m_next; moff = 0; }" idiom. Call
 * n80211_rseek once to position at the first byte past the header, then
 * n80211_rspan/n80211_radv to consume.
 */
struct n80211_rcursor {
	mblk_t	*seg;
	size_t	 off;		/* offset within seg */
};

/* Position the reader `skip` bytes into the chain (skips the 802.11 header). */
static __inline void
n80211_rseek(struct n80211_rcursor *r, mblk_t *m0, size_t skip)
{
	r->seg = m0;
	r->off = 0;
	while (r->seg != NULL && skip > 0) {
		size_t seglen = iwx_m_len(r->seg);
		if (skip < seglen) {
			r->off = skip;
			break;
		}
		skip -= seglen;
		r->seg = r->seg->b_cont;
	}
}

/*
 * Bytes readable in the current segment from the cursor. Advances to the next
 * b_cont segment when the current one is exhausted. Returns 0 at end of chain.
 */
static __inline size_t
n80211_rspan(struct n80211_rcursor *r)
{
	while (r->seg != NULL) {
		size_t seglen = iwx_m_len(r->seg);
		if (r->off < seglen)
			return (seglen - r->off);
		r->seg = r->seg->b_cont;
		r->off = 0;
	}
	return (0);
}

/* Pointer to the current read position (valid for n80211_rspan bytes). */
static __inline const u_int8_t *
n80211_rptr(const struct n80211_rcursor *r)
{
	return ((const u_int8_t *)iwx_mtod(r->seg) + r->off);
}

static __inline void
n80211_radv(struct n80211_rcursor *r, size_t len)
{
	r->off += len;
}

/*
 * n80211_m_append(m, len): reserve `len` bytes at the TAIL of a single
 * contiguous frame (b_wptr..db_lim) and return a pointer to them, advancing
 * b_wptr. Returns NULL if the cluster lacks the trailing room. This is the
 * illumos form of OpenBSD's "if (m_trailingspace(m) < len) MGET(m->m_next); ...
 * p = mtod(m)+m->m_len; m->m_len += len" -- BIP's MMIE append onto a mgmt
 * frame. BIP frames are contiguous (KASSERT m0->m_len >= wh+MMIE upstream) and
 * the driver allocates them with tail slack, so the single-mblk append is the
 * whole story; a chained mgmt frame would need m_next, which BIP never builds.
 * No field is aliased: b_wptr is the one source of length.
 */
static __inline u_int8_t *
n80211_m_append(mblk_t *m, size_t len)
{
	if (m->b_wptr + len > m->b_datap->db_lim)
		return (NULL);
	u_int8_t *p = m->b_wptr;
	m->b_wptr += len;
	return (p);
}

#endif /* _N80211_CIPHER_H */
