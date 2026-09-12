/*
 * The mbuf call-site adapter: routes OpenBSD's mbuf API in if_iwx.c to the real
 * mblk_t translation layer in iwx_mbuf.c.
 *
 * ⚠ READ THIS BEFORE CHANGING ANYTHING HERE. There is exactly one thing this
 * file must never do, and it is the thing that would make it shorter:
 *
 *     #define mbuf mblk_t            <-- NEVER
 *     #define m_len b_wptr           <-- NEVER
 *     #define m_data b_rptr          <-- NEVER
 *
 * A field-level #define compiles cleanly and then corrupts packets, because
 * OpenBSD stores m_len while illumos derives it from b_wptr - b_rptr. Assigning
 * "m->m_len = len" through a macro writes the LENGTH into the POINTER. The
 * driver does exactly that at if_iwx.c:5236 and :4633.
 *
 * So `struct mbuf` is left an INCOMPLETE TYPE in compat/sys/mbuf.h. Every field
 * access is a hard compile error at its own line, and the 30 sites that need a
 * decision are enumerated below with the decision recorded. That list IS the
 * work; nothing here hides a site.
 *
 * The FUNCTION calls map cleanly, because a function call cannot be an lvalue
 * and therefore cannot suffer the assignment bug. Those are macro-mapped and
 * that is safe. The FIELD accesses do not map and are listed as REWRITE SITES.
 */
#ifndef _IWX_MBUF_ADAPTER_H
#define _IWX_MBUF_ADAPTER_H

#include "iwx_mbuf.h"

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
 * REWRITE SITES -- the 30 places where a macro cannot preserve semantics.
 * Deliberately NOT defined, so each remains a compile error naming its line.
 * Recorded here so the count is auditable and no site is quietly skipped.
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
 *             -> memmove((uint8_t *)iwx_mtod(m) + 2, iwx_mtod(m), hdrlen), and
 *                the destination end (2 + hdrlen) must be checked against
 *                iwx_m_len(m) first: OpenBSD relies on cluster slack that
 *                allocb() does not promise at the same offset.
 *
 * B3. m_pullup USED AS AN ASSIGNMENT. :10306 "(m = m_pullup(m, ...)) == NULL".
 *    The m_pullup macro maps to iwx_m_pullup and the shape is already correct,
 *    but the ASSIGNMENT TARGET is a `struct mbuf *` local, which is an
 *    incomplete type, so the declaration of that local must change to mblk_t *
 *    together with the enclosing function's signature. Type-level, not call-level.
 *
 * B4. bus_dmamap_load_mbuf (:4634) is the ONE call that couples the DMA and mbuf
 *    layers: it walks the mbuf chain building a DMA segment list. It cannot be a
 *    macro because it needs both the ddi_dma_handle_t and the b_cont walk, so it
 *    is declared in iwx_dma.h and takes an mblk_t. Left undefined here so the
 *    coupling stays visible.
 *
 * C. CLUSTER ALLOCATION. :4614 m_gethdr + :4619/:4621 MCLGET/MCLGETL +
 *    :4623 (m->m_flags & M_EXT) test collapse into a single
 *    iwx_m_alloc(size) returning NULL on failure.
 *
 * D. POINTER-MOVING DEFRAG. :6378 "if (m_defrag(m, M_DONTWAIT))" must become
 *    "if ((m = iwx_m_defrag(m)) == NULL)" -- the head can MOVE on illumos where
 *    it could not on OpenBSD. Left undefined precisely so this is not missed;
 *    a macro here would compile and leak or use-after-free.
 *
 * E. RAW BUFFER WALKS. :10882 and :10927 compute "m0->m_data + offset" to step
 *    through several firmware responses packed in one RX buffer. These want the
 *    cluster base, not the read pointer, and must use
 *    (uint8_t *)iwx_mtod(m0) + offset with the offset bounds-checked against
 *    iwx_m_clustersize(m0).
 *
 * F. DEEP COPY. :10943 m_copym(m0, 0, M_COPYALL, M_DONTWAIT) -> iwx_m_copy(m0).
 *    Must stay a DEEP copy: m0 remains on the RX ring and the copy is trimmed.
 *
 * G. mbuf_list / mbuf_queue (:2061 :3344 :5008 :5147 :5157 :5881 :10292 :10294
 *    :10302 :12693 and the ml_ and mq_ calls). OpenBSD batches received frames in
 *    a mbuf_list and hands the batch up once. illumos GLDv3 mac_rx() takes an
 *    mblk chain linked through b_next, which is the SAME idea with different
 *    plumbing -- see iwx_mlist.h.
 *
 * H. m_pkthdr.ph_cookie (:10294) carries the ieee80211_node pointer alongside
 *    the frame. illumos mblk_t has no ph_cookie. This needs a side table or a
 *    prepended control block; NOT solvable by a macro, and it is the one site
 *    here with no mechanical answer. Flagged, not faked.
 */

#endif /* _IWX_MBUF_ADAPTER_H */
