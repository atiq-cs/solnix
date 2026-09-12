/*
 * iwx mbuf -> mblk_t translation layer, interface.
 *
 * OpenBSD's struct mbuf and illumos's mblk_t are NOT interchangeable, and the
 * failure mode of pretending otherwise is silent packet corruption rather than
 * a compile error. The three differences that matter to iwx:
 *
 *  1. LENGTH HAS TWO SOURCES OF TRUTH IN OPENBSD, ONE IN ILLUMOS.
 *     OpenBSD carries m_len (this segment) and m_pkthdr.len (whole chain) as
 *     separate stored fields; if_iwx.c writes both in one statement
 *     (if_iwx.c:5236 "m->m_pkthdr.len = m->m_len = len"). illumos derives the
 *     segment length from b_wptr - b_rptr and the chain length from msgdsize().
 *     A #define that maps m_len to a stored field creates a second source of
 *     truth that drifts from b_wptr, and every later MBLKL() disagrees with it.
 *
 *  2. OPENBSD REASSIGNS m_data TO POINT INTO THE MIDDLE OF ITS OWN CLUSTER.
 *     if_iwx.c:5235 does "m->m_data = pktdata + desc_size" -- it re-windows an
 *     already-allocated RX cluster onto a sub-frame. The mblk_t equivalent
 *     moves b_rptr, but b_wptr must move with it or MBLKL() goes negative and
 *     the frame is read past its end. Mapping m_data to b_rptr alone compiles
 *     and then corrupts. iwx_m_set_window() is the checked replacement, and it
 *     is the reason this file exists as code rather than as macros.
 *
 *  3. OWNERSHIP. freemsg() honours db_ref, so a dupb()'d block survives a free
 *     that OpenBSD's m_freem() would have completed. iwx itself never dups, but
 *     anything layered above it may, so the free path is a function that can
 *     grow a refcount assertion rather than a macro that cannot.
 *
 * Currency is a plain mblk_t *; no wrapper struct, no extra allocation. The
 * value added is checked semantics at the ~12 call shapes iwx actually uses.
 */

#ifndef _IWX_MBUF_H
#define _IWX_MBUF_H

#ifdef _KERNEL
#include <sys/types.h>
#include <sys/stream.h>
#include <sys/strsun.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#else
/* Userland unit-test harness supplies a faithful mblk_t/dblk pair. */
#include "iwx_mbuf_test_stubs.h"
#endif

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Allocate a packet buffer of at least size bytes with the write window
 * opened to the full allocation, matching the OpenBSD idiom
 *   m = m_gethdr(); MCLGET(m, size); m->m_len = m->m_pkthdr.len =
 *   m->m_ext.ext_size;
 * used at if_iwx.c:4614-4633. Returns NULL on failure (ENOBUFS at the caller).
 */
extern mblk_t *iwx_m_alloc(size_t size);

/* m_freem: free an entire chain. NULL-tolerant, like m_freem. */
extern void iwx_m_free(mblk_t *m);

/* mtod(m, T *): first byte of the readable window. */
extern void *iwx_mtod(const mblk_t *m);

/* m->m_len: bytes readable in THIS segment. */
extern size_t iwx_m_len(const mblk_t *m);

/* m->m_pkthdr.len: bytes readable across the whole chain. */
extern size_t iwx_m_pktlen(const mblk_t *m);

/* m->m_ext.ext_size: capacity of the backing cluster, not the used length. */
extern size_t iwx_m_clustersize(const mblk_t *m);

/*
 * The checked form of "m->m_data = base; m->m_pkthdr.len = m->m_len = len".
 * Fails (B_FALSE, buffer untouched) if [base, base+len) is not inside the
 * backing cluster -- the bounds test a macro mapping cannot perform.
 */
extern boolean_t iwx_m_set_window(mblk_t *m, const void *base, size_t len);

/*
 * m_adj(m, len): len > 0 trims from the head, len < 0 from the tail. Same sign
 * convention as OpenBSD and as adjmsg(9F). Returns B_FALSE and leaves the
 * buffer untouched when the chain is shorter than the requested trim, which is
 * adjmsg()'s behaviour; OpenBSD's m_adj instead empties the mbuf, so callers
 * that relied on that must be inspected rather than assumed equivalent. Both
 * iwx sites (if_iwx.c:5265, :6367) trim less than they have already validated.
 */
extern boolean_t iwx_m_adj(mblk_t *m, int len);

/*
 * m_pullup(m, len): make the first len bytes contiguous. Consumes m on
 * failure, like m_pullup, and returns NULL.
 */
extern mblk_t *iwx_m_pullup(mblk_t *m, size_t len);

/*
 * m_defrag(m, M_DONTWAIT): collapse a chain into one segment. Unlike OpenBSD's
 * m_defrag, which rewrites m in place and returns an errno, this returns the
 * (possibly new) head and NULL on failure with m consumed -- the shape illumos
 * msgpullup() forces. Call site if_iwx.c:6378 must be written as
 *   if ((m = iwx_m_defrag(m)) == NULL) { ... }
 * not as OpenBSD's "if (m_defrag(m, ...))", because the pointer can move.
 */
extern mblk_t *iwx_m_defrag(mblk_t *m);

/* m_copym(m, 0, M_COPYALL, M_DONTWAIT): deep copy of the whole chain. */
extern mblk_t *iwx_m_copy(const mblk_t *m);

/*
 * The checked form of "memmove(m->m_data + n, m->m_data, len)" at
 * if_iwx.c:5264, which shifts the 802.11 header right over the hardware's
 * 2-byte alignment pad. OpenBSD relies on the cluster having slack at the tail;
 * allocb() makes no such promise at the same offset, so the destination end
 * (n + len) is checked against the cluster limit first. The write window is
 * extended by n, because the frame just got n bytes longer -- omitting that is
 * the subtle half of this bug: the memmove would succeed and the caller's
 * following m_adj(m, 2) would then trim real header bytes.
 *
 * Returns B_FALSE with the buffer untouched if the shift does not fit.
 */
extern boolean_t iwx_m_shift_right(mblk_t *m, size_t len, size_t n);

/*
 * The checked form of "(struct T *)(m->m_data + offset)" at if_iwx.c:10882 and
 * :10927, which steps through several firmware responses packed into one RX
 * buffer. offset comes from a length the DEVICE reported, so it is bounds
 * checked against the readable window; need is the number of bytes the caller
 * is about to dereference. Returns NULL rather than a wild pointer.
 */
extern void *iwx_m_at(const mblk_t *m, size_t offset, size_t need);

#ifdef __cplusplus
}
#endif

#endif /* _IWX_MBUF_H */
