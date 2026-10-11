/*
 * net80211 mbuf-cookie access: the m_pkthdr.ph_cookie -> b_prev carry, for
 * net80211's power-save queue purge (ieee80211_node.c:3381).
 *
 * WHY A SEPARATE HEADER FROM iwx/iwx_mcookie.h, AND A DELIBERATE PEEK.
 * iwx_mcookie.h documents that its ONLY read accessor is take-and-clear, on the
 * argument that "a peek that left the field set would be the bug" -- true for
 * the driver's ic_mgtq, where the consumer owns the frame after dequeue.
 *
 * net80211's ieee80211_clean_node power-save purge is DIFFERENT: it walks
 * ic_pwrsaveq testing each frame's node cookie, FREES the frames belonging to
 * the departing node, and RE-QUEUES the rest -- which must keep their cookie
 * intact for the next purge. So here a peek is the CORRECT primitive, not a
 * bug: the non-matching frame is put back on the queue still needing its
 * ph_cookie. Reusing iwx_m_take_cookie would clear the cookie on every frame it
 * inspected and corrupt the survivors.
 *
 * This is the mechanism FINDINGS.md predicts for the 8.4x mbuf wall: the same
 * OpenBSD field, a genuinely different illumos rewrite per call site. The frame
 * still leaves via m_freem/mq_enqueue, and the b_prev==NULL ASSERT backstop in
 * freemsg still applies to the FREED branch (which clears via take semantics in
 * the matching case is unnecessary because m_freem drops it -- but freemsg
 * ASSERTs b_prev==NULL, so the freed frame's cookie MUST be cleared first).
 * n80211_m_purge_cookie handles both: peek, and clear only when freeing.
 */
#ifndef _N80211_MCOOKIE_H
#define _N80211_MCOOKIE_H

#include <sys/types.h>
#include <sys/stream.h>

/* Peek the node cookie without clearing -- for the re-queue survivors. */
static __inline void *
n80211_m_peek_cookie(const mblk_t *m)
{
	return ((void *)m->b_prev);
}

/*
 * Set the node cookie -- the PRODUCER side (ieee80211_output.c queues a mgmt
 * frame with its destination ieee80211_node * in m_pkthdr.ph_cookie, consumed
 * by iwx's mq_dequeue at if_iwx.c:10294). Mirrors iwx_m_set_cookie; b_prev is
 * the carrier, sound only inside the enqueue->dequeue window (see the b_prev
 * ASSERT argument in iwx/iwx_mcookie.h).
 */
static __inline void
n80211_m_set_cookie(mblk_t *m, void *cookie)
{
	m->b_prev = (mblk_t *)cookie;
}

/*
 * Clear the cookie before freeing: freemsg() ASSERTs b_prev==NULL on a DEBUG
 * kernel (uts/common/io/stream.c:659) and silently corrupts on a non-DEBUG one.
 * Call this on the branch that is about to m_freem the frame.
 */
static __inline void
n80211_m_clear_cookie(mblk_t *m)
{
	m->b_prev = NULL;
}

#endif /* _N80211_MCOOKIE_H */
