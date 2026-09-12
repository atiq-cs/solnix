/*
 * OpenBSD mbuf_list / mbuf_queue -> illumos mblk chains linked through b_next.
 *
 * OpenBSD's RX path accumulates frames in a mbuf_list (ml_*) and hands the whole
 * batch to the stack once, and uses a mbuf_queue (mq_*) with its own lock for
 * cross-context handoff. illumos GLDv3 mac_rx() takes precisely such a batch: a
 * chain of mblk_t linked by b_next, each element itself a b_cont chain. So the
 * concept survives; only the plumbing changes.
 *
 * ⚠ THE TWO POINTERS ARE NOT INTERCHANGEABLE and conflating them is the bug this
 * file exists to prevent:
 *     b_cont  links SEGMENTS OF ONE PACKET      (a fragmented frame)
 *     b_next  links SEPARATE PACKETS            (a batch)
 * A list implementation that walks b_cont concatenates two frames into one; one
 * that builds with b_cont produces a single corrupt oversized frame. The
 * functions below touch b_next ONLY, and ml_len counts PACKETS.
 *
 * STATUS: REAL, header-only, no allocation. Checked by iwx_mlist_test.c.
 */
#ifndef _IWX_MLIST_H
#define _IWX_MLIST_H

#ifdef _KERNEL
#include <sys/types.h>
#include <sys/stream.h>
#include <sys/ksynch.h>
#else
#include "iwx_mbuf_test_stubs.h"
#endif

/*
 * Same layout as compat/sys/mbuf.h declares, so the two agree. Members keep
 * OpenBSD's names because if_iwx.c reads ml_len directly.
 */
struct mbuf_list {
	mblk_t		*ml_head;
	mblk_t		*ml_tail;
	unsigned int	ml_len;		/* PACKETS, not bytes, not segments */
};

#define MBUF_LIST_INITIALIZER()		{ NULL, NULL, 0 }

static __inline void
ml_init(struct mbuf_list *ml)
{
	ml->ml_head = ml->ml_tail = NULL;
	ml->ml_len = 0;
}

static __inline int
ml_empty(const struct mbuf_list *ml)
{
	return (ml->ml_head == NULL);
}

static __inline unsigned int
ml_len(const struct mbuf_list *ml)
{
	return (ml->ml_len);
}

static __inline void
ml_enqueue(struct mbuf_list *ml, mblk_t *m)
{
	if (m == NULL)
		return;
	/*
	 * b_next, never b_cont: m may itself be a multi-segment frame and its
	 * b_cont chain must be left exactly as it is.
	 */
	m->b_next = NULL;
	if (ml->ml_tail == NULL)
		ml->ml_head = m;
	else
		ml->ml_tail->b_next = m;
	ml->ml_tail = m;
	ml->ml_len++;
}

static __inline mblk_t *
ml_dequeue(struct mbuf_list *ml)
{
	mblk_t *m = ml->ml_head;

	if (m == NULL)
		return (NULL);
	ml->ml_head = m->b_next;
	if (ml->ml_head == NULL)
		ml->ml_tail = NULL;
	m->b_next = NULL;	/* detach, or the caller frees the whole batch */
	ml->ml_len--;
	return (m);
}

/* Hand the whole batch over at once and reset. This is what mac_rx() wants. */
static __inline mblk_t *
ml_dechain(struct mbuf_list *ml)
{
	mblk_t *m = ml->ml_head;

	ml->ml_head = ml->ml_tail = NULL;
	ml->ml_len = 0;
	return (m);
}

static __inline void
ml_purge(struct mbuf_list *ml)
{
	mblk_t *m, *n;

	for (m = ml->ml_head; m != NULL; m = n) {
		n = m->b_next;
		m->b_next = NULL;
		/*
		 * b_prev too, not only b_next. A queued management frame may be
		 * carrying an ieee80211_node * in b_prev (see iwx_mcookie.h), and
		 * freemsg() ASSERTs b_prev == NULL
		 * (uts/common/io/stream.c:659). On a DEBUG kernel that is a panic
		 * on any interface-down with a frame still queued; on a non-DEBUG
		 * kernel the ASSERT is compiled out and it is silent. This is the
		 * one path that frees without going through
		 * iwx_m_take_cookie(), so it must clear the field itself.
		 */
		m->b_prev = NULL;
		freemsg(m);	/* frees this packet's whole b_cont chain */
	}
	ml_init(ml);
}

#ifdef _KERNEL
/*
 * mbuf_queue: a mbuf_list plus a lock. OpenBSD's mq_* are the locked variants,
 * and iwx uses only mq_dequeue, on the deferred-RX path.
 */
struct mbuf_queue {
	kmutex_t		mq_mtx;
	struct mbuf_list	mq_list;
	unsigned int		mq_maxlen;
	unsigned int		mq_drops;
};

static __inline void
mq_init(struct mbuf_queue *mq, unsigned int maxlen)
{
	mutex_init(&mq->mq_mtx, NULL, MUTEX_DRIVER, NULL);
	ml_init(&mq->mq_list);
	mq->mq_maxlen = maxlen;
	mq->mq_drops = 0;
}

static __inline void
mq_destroy(struct mbuf_queue *mq)
{
	ml_purge(&mq->mq_list);
	mutex_destroy(&mq->mq_mtx);
}

static __inline int
mq_enqueue(struct mbuf_queue *mq, mblk_t *m)
{
	int dropped = 0;

	mutex_enter(&mq->mq_mtx);
	if (mq->mq_maxlen != 0 && mq->mq_list.ml_len >= mq->mq_maxlen) {
		mq->mq_drops++;
		dropped = 1;
	} else {
		ml_enqueue(&mq->mq_list, m);
	}
	mutex_exit(&mq->mq_mtx);
	if (dropped) {
		/* Same reason as ml_purge: freemsg() ASSERTs b_prev == NULL. */
		m->b_prev = NULL;
		freemsg(m);
	}
	return (dropped);
}

static __inline mblk_t *
mq_dequeue(struct mbuf_queue *mq)
{
	mblk_t *m;

	mutex_enter(&mq->mq_mtx);
	m = ml_dequeue(&mq->mq_list);
	mutex_exit(&mq->mq_mtx);
	return (m);
}

static __inline unsigned int
mq_len(struct mbuf_queue *mq)
{
	unsigned int n;

	mutex_enter(&mq->mq_mtx);
	n = mq->mq_list.ml_len;
	mutex_exit(&mq->mq_mtx);
	return (n);
}

static __inline int
mq_empty(struct mbuf_queue *mq)
{
	return (mq_len(mq) == 0);
}

static __inline void
mq_purge(struct mbuf_queue *mq)
{
	mutex_enter(&mq->mq_mtx);
	ml_purge(&mq->mq_list);
	mutex_exit(&mq->mq_mtx);
}
#endif /* _KERNEL */

#endif /* _IWX_MLIST_H */
