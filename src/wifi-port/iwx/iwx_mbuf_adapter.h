/*
 * The mbuf call-site adapter: routes OpenBSD's mbuf API in if_iwx.c to the real
 * mblk_t translation layer in iwx_mbuf.c.
 *
 * TWO KINDS OF MAPPING, and the distinction is the whole safety property:
 *
 *   TYPE alias      `#define mbuf msgb` (compat/sys/mbuf.h)     SAFE
 *   FUNCTION macro  `#define m_freem(m) iwx_m_free(m)`           SAFE
 *   FIELD macro     `#define m_len b_wptr`                       NEVER
 *
 * A field-level #define compiles cleanly and then corrupts packets, because
 * OpenBSD stores m_len while illumos derives it from b_wptr - b_rptr. Assigning
 * "m->m_len = len" through a macro writes the LENGTH into the POINTER. The
 * driver does exactly that at if_iwx.c:5236 and :4633.
 *
 * So no field name is ever defined here. `struct mbuf` is aliased to illumos's
 * `struct msgb`, which has none of OpenBSD's field names, so every field access
 * is still a hard compile error at its own line. The sites that need a decision
 * are enumerated below with the decision recorded, and the patch that applies
 * those decisions is patches/if_iwx.illumos.patch -- openbsd-orig/ is read-only,
 * so the rewrite lives in a diff and gen-illumos-src.sh materialises it.
 */
#ifndef _IWX_MBUF_ADAPTER_H
#define _IWX_MBUF_ADAPTER_H

#include "iwx_mbuf.h"
#include "iwx_mcookie.h"
#include "iwx_dma.h"

/*
 * SAFE: function-shaped, no lvalue possible. Each maps to a checked
 * implementation in iwx_mbuf.c that has unit tests and negative controls.
 */
#define m_freem(m)		iwx_m_free((mblk_t *)(m))
#define m_free(m)		iwx_m_free((mblk_t *)(m))
#define mtod(m, t)		((t)iwx_mtod((const mblk_t *)(m)))
#define m_pullup(m, n)		iwx_m_pullup((mblk_t *)(m), (size_t)(n))

/*
 * m_adj: OpenBSD returns void, so the boolean result is discarded HERE and only
 * here. Both iwx sites trim a length they have already validated, so a refusal
 * is impossible at these two sites -- verified by reading if_iwx.c:5265 (trims 2
 * after checking hdrlen) and :6367 (trims hdrlen after ieee80211_get_hdrlen).
 * A THIRD site appearing must not silently inherit this discard.
 */
#define m_adj(m, n)		((void) iwx_m_adj((mblk_t *)(m), (int)(n)))

/*
 * REWRITE SITES -- the places where a macro cannot preserve semantics. Each is
 * applied by patches/if_iwx.illumos.patch, and the decision is recorded here so
 * the diff can be read against a stated intent rather than trusted.
 *
 * A. WRITES TO A LENGTH FIELD (the corrupting class). Must become
 *    iwx_m_set_window(m, base, len).
 *      :4633  m->m_len = m->m_pkthdr.len = m->m_ext.ext_size
 *             -> iwx_m_alloc() already opens the full window; DELETE the line.
 *      :5235  m->m_data = pktdata + desc_size
 *      :5236  m->m_pkthdr.len = m->m_len = len
 *             -> ONE call: iwx_m_set_window(m, pktdata + desc_size, len),
 *                and CHECK the return -- len came from the device.
 *
 * B. READS OF A LENGTH FIELD. Mechanical, but must pick the right one:
 *    m_len -> iwx_m_len (this segment), m_pkthdr.len -> iwx_m_pktlen (chain).
 *      :5290 :5295  m->m_len >= sizeof(qosframe...)   -> iwx_m_len
 *      :6335        totlen = m->m_pkthdr.len          -> iwx_m_pktlen
 *      :10305       m->m_len < sizeof(*eh)            -> iwx_m_len
 *
 * B2. READS OF m_data AS A BARE POINTER, inside a memmove that shifts the frame
 *    header over the hardware's 2-byte pad.
 *      :5264  memmove(m->m_data + 2, m->m_data, hdrlen)
 *             -> iwx_m_shift_right(m, hdrlen, 2), which performs the bounds
 *                check OpenBSD gets for free from cluster slack: allocb() does
 *                not promise headroom at the same offset, so 2 + hdrlen must be
 *                checked against the cluster limit BEFORE the memmove.
 *
 * B3. m_pullup USED AS AN ASSIGNMENT. :10306 "(m = m_pullup(m, ...)) == NULL".
 *    Resolved by the TYPE alias: the local is `struct mbuf *` which now IS
 *    `mblk_t *`, so the assignment type-checks with no source change.
 *
 * B4. bus_dmamap_load_mbuf (:4634, :6369, :6382) is the ONE call that couples
 *    the DMA and mbuf layers: it walks the mbuf chain building a DMA segment
 *    list. It cannot be a macro because it needs both the ddi_dma_handle_t and
 *    the b_cont walk, so it is declared in iwx_dma.h and takes an mblk_t. Left
 *    undefined here so the coupling stays visible, and it fails at LINK with
 *    its own name rather than compiling into something plausible.
 *
 * C. CLUSTER ALLOCATION. :4614 m_gethdr + :4619/:4621 MCLGET/MCLGETL +
 *    :4623 (m->m_flags & M_EXT) test collapse into a single
 *    iwx_m_alloc(size) returning NULL on failure. :5881 MCLGETL(NULL, ...)
 *    is the same allocation spelled as a one-liner.
 *
 * D. POINTER-MOVING DEFRAG. :6378 "if (m_defrag(m, M_DONTWAIT))" must become
 *    "if ((m = iwx_m_defrag(m)) == NULL)" -- the head can MOVE on illumos where
 *    it could not on OpenBSD. Deliberately NOT macro-mapped: a macro here would
 *    compile and then leak or use-after-free, so it is a patched site.
 *
 * E. RAW BUFFER WALKS. :10882 and :10927 compute "m0->m_data + offset" to step
 *    through several firmware responses packed in one RX buffer. These want the
 *    read pointer with the offset bounds-checked, which is iwx_m_at(m0, offset).
 *
 * F. DEEP COPY. :10943 m_copym(m0, 0, M_COPYALL, M_DONTWAIT) -> iwx_m_copy(m0).
 *    Must stay a DEEP copy: m0 remains on the RX ring and the copy is trimmed.
 *
 * G. mbuf_list / mbuf_queue (ml_* and mq_* calls). OpenBSD batches received
 *    frames in a mbuf_list and hands the batch up once. illumos GLDv3 mac_rx()
 *    takes an mblk chain linked through b_next, which is the SAME idea with
 *    different plumbing -- see iwx_mlist.h. Resolved by the type alias plus that
 *    header; no patched site remains.
 *
 * H. m_pkthdr.ph_cookie (:10294) carries the ieee80211_node * alongside the
 *    frame from ieee80211_mgmt_output() to iwx_start(). illumos mblk_t has no
 *    ph_cookie. Resolved in iwx_mcookie.h, whose reasoning is that the cookie's
 *    live window is exactly enqueue -> dequeue inside ic_mgtq, a queue this port
 *    owns. Read that file before touching this: the obvious answer (b_prev) is
 *    only safe because of a bound the kernel asserts, and the assert is compiled
 *    out on a non-DEBUG kernel.
 */

#endif /* _IWX_MBUF_ADAPTER_H */
