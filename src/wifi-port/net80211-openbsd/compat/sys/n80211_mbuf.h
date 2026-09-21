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

#endif /* _N80211_MBUF_H */
