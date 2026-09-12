/*
 * m_pkthdr.ph_cookie -> illumos: carrying the ieee80211_node * with a queued
 * management frame.
 *
 * THE PROBLEM. OpenBSD's net80211 builds a management frame, stashes the
 * destination node pointer in m->m_pkthdr.ph_cookie, and queues the frame on
 * ic->ic_mgtq. The driver dequeues it and reads the cookie back:
 *
 *     m = mq_dequeue(&ic->ic_mgtq);          if_iwx.c:10292
 *     if (m) { ni = m->m_pkthdr.ph_cookie;   if_iwx.c:10294
 *
 * illumos's mblk_t has no packet header and therefore no ph_cookie. There is
 * exactly ONE producer and ONE consumer (measured: `grep -n ph_cookie` over the
 * vendored source returns a single line, and the producer is net80211's
 * ieee80211_mgmt_output, not the driver).
 *
 * THE CANDIDATE, AND WHY IT NEEDS AN ARGUMENT RATHER THAN A SHRUG. mblk_t has a
 * b_prev that is unused while a message is not on a STREAMS queue. Reusing it is
 * NOT free: the kernel asserts it is NULL on three paths
 *
 *     uts/common/io/stream.c:642   freeb()      ASSERT(b_next == NULL && b_prev == NULL)
 *     uts/common/io/stream.c:659   freemsg()    ASSERT(b_next == NULL && b_prev == NULL)
 *     uts/common/io/stream.c:1586  pullupmsg()  ASSERT(b_next == NULL && b_prev == NULL)
 *
 * so a cookie left in place reaches a real assertion failure on a DEBUG kernel
 * and, worse, is SILENT on a non-DEBUG one where ASSERT compiles away.
 *
 * WHY IT IS NEVERTHELESS SOUND HERE. The cookie's live window is exactly
 * enqueue -> dequeue on ic_mgtq, and ic_mgtq is a `struct mbuf_queue` that this
 * port implements (iwx_mlist.h). It links with b_next ONLY -- that is stated and
 * tested there, because conflating b_next with b_cont was one of the eleven
 * sabotages. So inside the window:
 *
 *   - nothing in illumos STREAMS sees the message at all: it is on a private
 *     queue, not a queue_t, so none of the three asserting paths can run;
 *   - the field is not aliased with the queue's own linkage (b_next);
 *   - the consumer CLEARS the cookie as it reads it, so the message leaves the
 *     window clean and the three ASSERTs above become a loud backstop rather
 *     than a hazard.
 *
 * The remaining risk is a frame that is queued and then FREED without being
 * dequeued -- the purge path. ml_purge() in iwx_mlist.h therefore must clear the
 * cookie before freemsg(), and it does.
 *
 * REJECTED ALTERNATIVES, and why:
 *   - A side table keyed by mblk address: needs a lock on the TX path and a
 *     policy for a duplicate key. More code, and the lifetime bug it prevents
 *     is the same bug the clear-on-read discipline prevents.
 *   - A prepended control mblk (b_cont): changes the frame's segment structure,
 *     so iwx_m_len() and every hdrlen computation downstream would be reading
 *     the control block. That is the class of bug this whole layer exists to
 *     avoid.
 *   - db_struioun / db_cksumstart: dblk fields owned by the checksum and
 *     stream-io machinery, shared across dupb() siblings.
 *
 * NOTE: single-carrier design. If a second cookie ever has to ride along, this
 * becomes a side table; do not add a second stolen field.
 *
 * STATUS: REAL. Checked by iwx_mcookie_test.c, including the negative control
 * that a cookie left set is detected.
 */
#ifndef _IWX_MCOOKIE_H
#define _IWX_MCOOKIE_H

#ifdef _KERNEL
#include <sys/types.h>
#include <sys/stream.h>
#else
#include "iwx_mbuf_test_stubs.h"
#endif

/*
 * Attach a cookie to a message that is about to be queued on a private queue.
 * Must be paired with iwx_m_take_cookie() or iwx_m_clear_cookie() before the
 * message is freed or handed to any STREAMS function.
 */
static __inline void
iwx_m_set_cookie(mblk_t *m, void *cookie)
{
	m->b_prev = (mblk_t *)cookie;
}

/*
 * Read the cookie AND clear it in one step, so the "leaves the window clean"
 * invariant cannot be forgotten at a call site. This is the only read accessor
 * on purpose: a peek that left the field set would be the bug.
 */
static __inline void *
iwx_m_take_cookie(mblk_t *m)
{
	void *cookie = (void *)m->b_prev;

	m->b_prev = NULL;
	return (cookie);
}

/* For the purge path, which frees without consuming. */
static __inline void
iwx_m_clear_cookie(mblk_t *m)
{
	m->b_prev = NULL;
}

/* True if this message is safe to hand to freemsg()/pullupmsg(). */
static __inline int
iwx_m_cookie_clear(const mblk_t *m)
{
	return (m->b_prev == NULL);
}

#endif /* _IWX_MCOOKIE_H */
