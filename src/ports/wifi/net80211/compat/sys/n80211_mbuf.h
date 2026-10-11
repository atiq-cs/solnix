/*
 * net80211 mbuf-allocation adapter: the OpenBSD mbuf ALLOCATION/COPY API that
 * net80211 uses beyond what iwx/iwx_mbuf_adapter.h maps for the driver
 * (MGET/MGETHDR/MCLGET/M_PREPEND/m_copydata/m_dup_pkthdr/m_trailingspace).
 *
 * This is the head of the 8.4x mbuf wall FINDINGS.md Finding 1 measures. The
 * macros are function-shaped (they assign a fresh chain to their mbuf argument
 * or return a scalar), so they are SAFE in the sense the adapter defines: no
 * FIELD is ever aliased. The backing functions are DECLARED ONLY -- they fail
 * at LINK by name until a tested n80211_mbuf.c implements the allocb-backed
 * translation with negative controls, exactly as iwx_mbuf.c did for the
 * driver's 12 primitives. Declaring them lets net80211 reach a real .o with
 * these as undefined symbols (the honest state) rather than blocking the whole
 * file on codegen.
 *
 * NOT a port: these are the boundary, tagged DECL. What they do NOT resolve are
 * the ~313 direct mbuf-FIELD reads (m->m_len, m->m_pkthdr, ...) which cannot be
 * macros and must be rewritten per-site in a patch against orig/, the same
 * discipline as iwx/patches/if_iwx.illumos.patch.
 */
#ifndef _N80211_MBUF_H
#define _N80211_MBUF_H

#include <sys/types.h>
#include <sys/stream.h>
#include "iwx_mbuf.h"		/* iwx_m_alloc / iwx_m_free / iwx_m_len */

/*
 * OpenBSD mbuf size constants. On illumos an mblk is not a fixed-size mbuf, so
 * these are the OpenBSD values net80211 compares against to decide inline vs
 * clustered storage; the backing n80211_m_* functions honour the same
 * thresholds against allocb. REAL constants.
 */
#ifndef MLEN
#define MLEN		256		/* bytes an OpenBSD mbuf holds inline */
#endif
#ifndef MHLEN
#define MHLEN		(MLEN - 8)	/* with a pkthdr */
#endif
#ifndef MCLBYTES
#define MCLBYTES	2048		/* an mbuf cluster */
#endif
#ifndef MINCLSIZE
#define MINCLSIZE	(MHLEN + 1)	/* above this, use a cluster */
#endif

/* Allocation flags / mbuf types (OpenBSD <sys/mbuf.h>). */
#ifndef M_DONTWAIT
#define M_DONTWAIT	0x0002
#define M_WAIT		0x0001
#endif
#ifndef MT_DATA
#define MT_DATA		1
#define MT_HEADER	2
#endif

/*
 * Backing functions -- DECL. Implemented (with tests) in a future n80211_mbuf.c.
 * Signatures chosen so the OpenBSD statement-macros below map cleanly.
 */
extern mblk_t *n80211_m_get(int how, int type);		/* MGET */
extern mblk_t *n80211_m_gethdr(int how, int type);	/* MGETHDR */
extern int     n80211_m_clget(mblk_t *m, int how);	/* MCLGET: 0 ok, else fail */
extern mblk_t *n80211_m_prepend(mblk_t *m, int len, int how);	/* M_PREPEND */
extern int     n80211_m_copydata(mblk_t *m, int off, int len, void *dst);
extern int     n80211_m_dup_pkthdr(mblk_t *to, mblk_t *from, int how);
extern int     n80211_m_trailingspace(mblk_t *m);
extern mblk_t *n80211_m_copym(mblk_t *m, int off, int len, int how);
extern mblk_t *n80211_m_copyback(mblk_t *m, int off, int len, const void *src, int how);
extern mblk_t *n80211_m_split(mblk_t *m, int len, int how);	/* m_split */
extern mblk_t *n80211_m_dup_pkt(mblk_t *m, int align, int how);	/* m_dup_pkt */

/*
 * The OpenBSD statement-macros. MGET/MGETHDR/MCLGET assign to their first arg;
 * MCLGET's OpenBSD form sets m_flags on failure -- here the backing function's
 * non-zero return signals failure and callers check (m->b_datap) as OpenBSD
 * checks M_EXT. Function-shaped, no field alias.
 */
#define MGET(m, how, type)	((m) = n80211_m_get((how), (type)))
#define MGETHDR(m, how, type)	((m) = n80211_m_gethdr((how), (type)))
#define MCLGET(m, how)		((void) n80211_m_clget((m), (how)))
#define MCLGETL(m, how, len)	((void) n80211_m_clget((m), (how)))
#define M_PREPEND(m, plen, how)	((m) = n80211_m_prepend((m), (plen), (how)))
#define m_copydata(m, off, len, dst) \
	((void) n80211_m_copydata((m), (off), (len), (dst)))
#define m_dup_pkthdr(to, from, how) \
	n80211_m_dup_pkthdr((to), (from), (how))
#define m_trailingspace(m)	n80211_m_trailingspace(m)
#define m_copym(m, off, len, how) \
	n80211_m_copym((m), (off), (len), (how))
#define m_copyback(m, off, len, src, how) \
	n80211_m_copyback((m), (off), (len), (src), (how))

/*
 * m_split (chain split at an offset) and m_dup_pkt (deep-copy a packet with a
 * leading alignment pad -- the RX-to-host bounce in ieee80211_inputm). Both
 * return a fresh chain; no field alias. DECL, resolved at LINK against
 * n80211_mbuf.c. m_dup_pkt's `align` is ETHER_ALIGN (2), the 802.3 header pad.
 */
#define m_split(m, len, how)		n80211_m_split((m), (len), (how))
#define m_dup_pkt(m, align, how)	n80211_m_dup_pkt((m), (align), (how))

/*
 * m_cat(dst, src) -- append src's chain to the tail of dst. illumos linkb()
 * does exactly this (links via b_cont), and the resulting chain's derived
 * length (iwx_m_pktlen, b_wptr-b_rptr summed) already includes src -- so the
 * OpenBSD idiom "m_cat(a,b); a->m_pkthdr.len += b->m_pkthdr.len" drops its
 * second statement here (the length is derived, never stored). No field alias;
 * linkb is a real illumos STREAMS entry point. REAL.
 */
#define m_cat(dst, src)		linkb((dst), (src))
extern void linkb(mblk_t *, mblk_t *);

/*
 * m_tag -- OpenBSD's per-mbuf metadata tags. net80211 uses exactly ONE tag,
 * PACKET_TAG_DLT, to detect a raw 802.11 frame injected via a bpf write
 * (ieee80211_output / ieee80211_encap). illumos has no bpf write-injection
 * path on this driver (NBPFILTER=0, see iwx/compat/net/bpf.h), so no frame
 * ever carries this tag: m_tag_find HONESTLY returns NULL and the injection
 * block is skipped. struct m_tag must be COMPLETE (the `mtag + 1` payload read
 * needs a known size) but is never populated. KNOWN GAP, tagged -- frame
 * injection does not work, and nothing here pretends it does. m_tag_find is
 * DECL (resolves to a NULL-returning shim in n80211_mbuf.c).
 */
#define PACKET_TAG_DLT	0x0040		/* OpenBSD's data-link-type tag id */
struct m_tag {
	uint16_t	m_tag_id;
	uint16_t	m_tag_len;
};
extern struct m_tag *m_tag_find(mblk_t *, int, struct m_tag *);

/*
 * m_free(m) -- OpenBSD frees one mbuf and returns m->m_next (the rest of the
 * chain). net80211 uses it only as `return m_free(m)` on a freshly-allocated
 * SINGLE mgmt mbuf whose m_next is NULL, i.e. "free this and return NULL". On
 * illumos freemsg() frees the whole chain and returns void, so the single-mbuf
 * case is (freemsg(m), NULL). Verified: both call sites (ieee80211_output.c,
 * ieee80211_pae_output.c) are exactly this pattern on a one-mbuf frame. REAL.
 */
#define m_free(m)	((freemsg((m)), (mblk_t *)NULL))

/*
 * m_align(m, len) -- OpenBSD right-aligns m_data so `len` bytes sit at the tail
 * of the buffer, leaving the maximum LEADING headroom for later header
 * prepends. net80211 builds every management frame as MGETHDR + m_align(body)
 * + fill, then ieee80211_mgmt_output M_PREPENDs the 24-byte 802.11 header in
 * front; ieee80211_output.c:720 prepends a data header the same way. If m_align
 * leaves the body at db_base (no leading room) the prepend underflows and the
 * frame is freed (ENOMEM), which silently drops every auth/assoc/probe frame
 * and makes association impossible. So this MUST reserve leading headroom, not
 * be a no-op. Implemented in n80211_mbuf.c against DB_LIM/DB_BASE.
 */
extern void n80211_m_align(mblk_t *m, size_t len);
#define m_align(m, len)	(n80211_m_align((m), (size_t)(len)))

/*
 * n80211_m_reserve(m, n) -- reserve n bytes of leading header space by advancing
 * the read pointer (OpenBSD "m->m_data += n"). REAL: moves b_rptr; the frame
 * body is then written from the new mtod(m) and iwx_m_set_window sets b_wptr.
 */
static __inline void
n80211_m_reserve(mblk_t *m, size_t n)
{
	m->b_rptr += n;
	if (m->b_wptr < m->b_rptr)
		m->b_wptr = m->b_rptr;
}

#endif /* _N80211_MBUF_H */
