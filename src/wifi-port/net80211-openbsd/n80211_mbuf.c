/*
 * n80211_mbuf.c -- the mbuf-ALLOCATION half of the net80211 mbuf adapter
 * (compat/sys/n80211_mbuf.h declares these; they are the "DECL" boundary that
 * FINDINGS.md Finding 1 names as the head of the 8.4x mbuf wall).
 *
 * These are the ALLOCATION / COPY / SPLIT primitives net80211 uses beyond what
 * iwx_mbuf.c already implements for the driver. Measured undefined in the
 * net80211 ld -r object: n80211_m_gethdr, n80211_m_clget, n80211_m_prepend,
 * n80211_m_copydata, n80211_m_split, n80211_m_dup_pkt, and m_tag_find.
 *
 * illumos vs OpenBSD, the difference that dictates the implementation:
 *   - An OpenBSD mbuf is a fixed ~256-byte cell; a big frame is a CHAIN of
 *     cells, or a cell pointing at a 2 KB external cluster (M_EXT). MGET makes
 *     a bare cell, MCLGET upgrades it to a cluster.
 *   - An illumos allocb() returns ONE contiguous cluster of any size, so the
 *     cell/cluster distinction collapses: we allocate a cluster big enough that
 *     the later reserve/prepend/fill all fit, and there is never a second cell
 *     to chain for a management frame. This is the SAME reduction iwx_mbuf.c
 *     and n80211_cipher.h already make (single contiguous cluster, length set
 *     once via the derived b_wptr-b_rptr, no mbuf FIELD ever aliased).
 *
 * NO mbuf field is aliased or written as a stored length here -- the invariant
 * iwx_mbuf.h states. Length is always derived (b_wptr - b_rptr). Where OpenBSD
 * would set m_len/m_pkthdr.len, we move b_wptr.
 *
 * TESTED: n80211_mbuf_test.c (userland, negative-controlled). Every function is
 * exercised and each check is proven able to fail.
 */

#ifdef _KERNEL
#include <sys/types.h>
#include <sys/stream.h>
#include <sys/strsun.h>		/* MBLKL, DB_BASE, DB_LIM */
#include <sys/ddi.h>
#include <sys/sunddi.h>
#else
#include "iwx_mbuf_test_stubs.h"
#include <string.h>
#endif

#include "iwx_mbuf.h"		/* iwx_m_alloc / iwx_m_len / iwx_m_pktlen */

/*
 * The default cluster size for an allocated management/EAPOL frame. OpenBSD's
 * MCLBYTES is 2048; net80211 panics if a mgmt frame exceeds MCLBYTES, so a
 * cluster of MCLBYTES + a small slop for a leading prepend/reserve covers every
 * allocation path. Using one size means a MGETHDR'd frame never needs a second
 * cell, matching the single-contiguous-cluster reduction.
 */
#define N80211_MCLBYTES		2048
#define N80211_ALLOC_SLOP	128		/* headroom for reserve/prepend */

/*
 * MGET / MGETHDR: allocate a fresh single-cluster mblk with an EMPTY write
 * window (b_wptr == b_rptr == db_base). OpenBSD's MGET gives a zero-length
 * mbuf; callers fill it and the length is derived. We allocate the full
 * cluster up front so subsequent n80211_m_reserve / M_PREPEND / body writes
 * all fit contiguously. `how` and `type` are the OpenBSD wait-flag and mbuf
 * type; on illumos allocb never blocks, so `how` is advisory and `type` is
 * unused (illumos mblks are untyped).
 */
mblk_t *
n80211_m_gethdr(int how, int type)
{
	mblk_t *m;

	(void) how;
	(void) type;
	m = allocb(N80211_MCLBYTES + N80211_ALLOC_SLOP, BPRI_MED);
	if (m == NULL)
		return (NULL);
	/* empty window: length 0, the whole cluster ahead for writing */
	m->b_wptr = m->b_rptr;
	return (m);
}

mblk_t *
n80211_m_get(int how, int type)
{
	/* No pkthdr distinction on illumos; a plain cell is the same cluster. */
	return (n80211_m_gethdr(how, type));
}

/*
 * MCLGET: OpenBSD attaches a 2 KB external cluster and sets M_EXT. Our mblk is
 * ALREADY a full cluster (n80211_m_gethdr allocated N80211_MCLBYTES), so this
 * is a no-op success. Returns 0 on success (caller checks != 0 for failure);
 * we only fail if the mblk somehow has no backing cluster of the needed size.
 */
int
n80211_m_clget(mblk_t *m, int how)
{
	(void) how;
	if (m == NULL)
		return (1);
	/* the cluster is present iff the backing buffer spans >= MCLBYTES */
	if ((size_t)(DB_LIM(m) - DB_BASE(m)) < N80211_MCLBYTES)
		return (1);
	return (0);
}

/*
 * M_PREPEND: make room for `len` bytes at the FRONT of the frame and leave the
 * write window opened over them. OpenBSD may allocate a new leading mbuf; here
 * the frame lives in one cluster with headroom, so we move b_rptr back by len
 * (into the slop we allocated ahead of the data) and extend the window.
 *
 * Contract: net80211 calls M_PREPEND on a freshly MGETHDR'd + reserved frame,
 * so there is always headroom. If the prepend would underflow db_base, the
 * frame is freed and NULL returned -- OpenBSD's failure behaviour (it frees on
 * allocation failure). This never aliases a field: the length is the derived
 * b_wptr - b_rptr.
 */
mblk_t *
n80211_m_prepend(mblk_t *m, int len, int how)
{
	(void) how;
	if (m == NULL || len < 0)
		return (NULL);
	if (m->b_rptr - (size_t)len < DB_BASE(m)) {
		/* not enough headroom -- OpenBSD would alloc a new head; on the
		 * mgmt/EAPOL paths this cannot happen because the frame was
		 * allocated with slop, so a shortfall is a real error. */
		freemsg(m);
		return (NULL);
	}
	m->b_rptr -= (size_t)len;
	/* the new bytes are part of the frame; keep the write window covering
	 * at least the prepended region so mtod()+len is writable. */
	if (m->b_wptr < m->b_rptr + (size_t)len)
		m->b_wptr = m->b_rptr + (size_t)len;
	return (m);
}

/*
 * m_align: right-align a `len`-byte body at the end of the cluster, so there is
 * maximal LEADING headroom for the header prepends net80211 does right after
 * (ieee80211_mgmt_output M_PREPENDs the 24-byte 802.11 header; the data path
 * prepends a header too). OpenBSD's m_align/MH_ALIGN does the same on a fresh
 * mbuf. b_rptr and b_wptr both move to db_lim - len (an empty window at the
 * aligned position); the caller then writes `len` body bytes from mtod(m),
 * advancing b_wptr, and the later M_PREPEND moves b_rptr back into the
 * reserved headroom. If len exceeds the cluster, clamp to db_base (no room,
 * but never underflow); the mgmt paths use len <= 6 so this never clamps.
 */
void
n80211_m_align(mblk_t *m, size_t len)
{
	unsigned char *base, *lim;

	if (m == NULL)
		return;
	base = DB_BASE(m);
	lim = DB_LIM(m);
	if ((size_t)(lim - base) < len)
		m->b_rptr = base;
	else
		m->b_rptr = lim - len;
	m->b_wptr = m->b_rptr;
}

/*
 * m_copydata: copy `len` bytes starting at byte `off` from the chain into dst.
 * Walks the b_cont chain, honouring each segment's derived length. Returns 0 on
 * success, -1 if the chain is shorter than off+len (OpenBSD panics; returning
 * -1 is the safer illumos behaviour and callers on this path already validated
 * the length).
 */
int
n80211_m_copydata(mblk_t *m, int off, int len, void *dst)
{
	unsigned char *d = dst;
	mblk_t *p = m;

	if (off < 0 || len < 0)
		return (-1);

	/* skip to the starting offset */
	while (p != NULL && off >= (int)MBLKL(p)) {
		off -= (int)MBLKL(p);
		p = p->b_cont;
	}
	/* copy across segments */
	while (len > 0 && p != NULL) {
		int avail = (int)MBLKL(p) - off;
		int n = (avail < len) ? avail : len;
		if (n > 0) {
			bcopy(p->b_rptr + off, d, (size_t)n);
			d += n;
			len -= n;
		}
		off = 0;
		p = p->b_cont;
	}
	return (len == 0 ? 0 : -1);
}

/*
 * m_split: detach the tail of the chain at byte offset `len`, returning a NEW
 * chain holding [len, end) and leaving `m` holding [0, len). Used by the A-MSDU
 * de-aggregation path (ieee80211_input.c) to peel one subframe off a chain.
 *
 * Implementation: copy the tail into a fresh cluster (the subframes are small,
 * bounded by the A-MSDU limit), then trim `m` to `len` by moving the last
 * segment's b_wptr. Returns NULL on allocation failure or a bad offset (leaving
 * m intact), matching OpenBSD's m_split failure contract. No field aliased.
 */
mblk_t *
n80211_m_split(mblk_t *m, int len, int how)
{
	mblk_t *n;
	int total, taillen;

	(void) how;
	if (m == NULL || len < 0)
		return (NULL);
	total = (int)iwx_m_pktlen(m);
	if (len > total)
		return (NULL);
	taillen = total - len;

	n = allocb((size_t)taillen + N80211_ALLOC_SLOP, BPRI_MED);
	if (n == NULL)
		return (NULL);
	n->b_wptr = n->b_rptr;
	if (taillen > 0) {
		if (n80211_m_copydata(m, len, taillen, n->b_rptr) != 0) {
			freemsg(n);
			return (NULL);
		}
		n->b_wptr = n->b_rptr + taillen;
	}

	/* trim m to exactly len bytes across its segments */
	{
		mblk_t *p = m;
		int rem = len;
		while (p != NULL) {
			int seg = (int)MBLKL(p);
			if (rem >= seg) {
				rem -= seg;
				if (rem == 0) {
					/* drop everything after p */
					freemsg(p->b_cont);
					p->b_cont = NULL;
					break;
				}
				p = p->b_cont;
			} else {
				/* truncate this segment and drop the rest */
				p->b_wptr = p->b_rptr + rem;
				freemsg(p->b_cont);
				p->b_cont = NULL;
				break;
			}
		}
	}
	return (n);
}

/*
 * m_dup_pkt: deep-copy the whole packet into a fresh SINGLE cluster with a
 * leading `align`-byte pad (ETHER_ALIGN==2, so the IP header after the 14-byte
 * 802.3 header is word-aligned). Used on the HOSTAP multicast-loopback and the
 * RX-to-host bounce paths. Returns a new contiguous chain, NULL on failure.
 * No field aliased; the window length is set via b_wptr.
 */
mblk_t *
n80211_m_dup_pkt(mblk_t *m, int align, int how)
{
	mblk_t *n;
	int total;

	(void) how;
	if (m == NULL || align < 0)
		return (NULL);
	total = (int)iwx_m_pktlen(m);
	n = allocb((size_t)(total + align) + N80211_ALLOC_SLOP, BPRI_MED);
	if (n == NULL)
		return (NULL);
	/* leave `align` bytes of leading pad, then the copied body */
	n->b_rptr += align;
	n->b_wptr = n->b_rptr;
	if (total > 0) {
		if (n80211_m_copydata(m, 0, total, n->b_rptr) != 0) {
			freemsg(n);
			return (NULL);
		}
		n->b_wptr = n->b_rptr + total;
	}
	return (n);
}

/*
 * m_tag_find: OpenBSD per-mbuf metadata tag lookup. net80211 uses exactly one
 * tag (PACKET_TAG_DLT) to detect a bpf-injected raw 802.11 frame. This driver
 * has NO bpf write-injection path (NBPFILTER=0, iwx/compat/net/bpf.h), so no
 * frame ever carries a tag: this HONESTLY returns NULL and the injection block
 * is skipped. KNOWN GAP (frame injection does not work), tagged, not pretended.
 */
struct m_tag *
m_tag_find(mblk_t *m, int type, struct m_tag *t)
{
	(void) m;
	(void) type;
	(void) t;
	return (NULL);
}
