/*
 * Checks for the ph_cookie carrier (iwx_mcookie.h) and for the mbuf_queue
 * discipline it depends on.
 *
 * The claim under test is NOT "b_prev can hold a pointer" -- that is trivially
 * true. It is the narrow safety argument in iwx_mcookie.h:
 *
 *   1. the cookie survives the enqueue -> dequeue window on ic_mgtq;
 *   2. the queue's own linkage (b_next) does not collide with it;
 *   3. the message leaves the window with b_prev CLEAR, because the three
 *      STREAMS paths that assert b_prev == NULL (freeb, freemsg, pullupmsg in
 *      uts/common/io/stream.c) are compiled out on a non-DEBUG kernel and would
 *      then corrupt silently;
 *   4. the purge path, which frees without dequeueing, also leaves it clear.
 *
 * Point 3 is the one that matters and the one an implementation is most likely
 * to get wrong, so it is checked on every path a message can take out of the
 * queue, not just the happy one.
 *
 * NEGATIVE CONTROLS: run-mbuf-tests.sh rebuilds this against sabotaged copies
 * of iwx_mcookie.h and requires it to FAIL. A green run of this file alone
 * proves nothing.
 */

#include <stdio.h>
#include <string.h>
#include "iwx_mbuf.h"
#include "iwx_mlist.h"
#include "iwx_mcookie.h"

long iwx_test_allocs;
long iwx_test_frees;
int iwx_test_saw_dirty_free;

static int failures;
static int checks;

#define CHECK(cond, what)						\
	do {								\
		checks++;						\
		if (!(cond)) {						\
			failures++;					\
			(void) printf("FAIL %s:%d  %s\n",		\
			    __FILE__, __LINE__, (what));		\
		}							\
	} while (0)

/* Stand-in for a struct ieee80211_node *; only its address is ever used. */
static int fake_node_a;
static int fake_node_b;

/*
 * if_iwx.c:10292-10294. The only real call shape: net80211 sets the cookie and
 * queues, the driver dequeues and reads it back.
 */
static void
test_cookie_survives_the_queue(void)
{
	struct mbuf_list ml = MBUF_LIST_INITIALIZER();
	mblk_t *m = iwx_m_alloc(64);
	void *got;

	CHECK(m != NULL, "alloc");
	if (m == NULL)
		return;

	iwx_m_set_cookie(m, &fake_node_a);
	ml_enqueue(&ml, m);
	CHECK(ml_len(&ml) == 1, "one packet queued");

	m = ml_dequeue(&ml);
	CHECK(m != NULL, "dequeue returned the packet");
	if (m == NULL)
		return;

	got = iwx_m_take_cookie(m);
	CHECK(got == &fake_node_a,
	    "the node pointer must come back unchanged (if_iwx.c:10294)");
	CHECK(iwx_m_cookie_clear(m),
	    "take must CLEAR the field: freemsg/pullupmsg ASSERT b_prev == NULL");
	iwx_m_free(m);
}

/*
 * The collision test. ml_enqueue links with b_next; if the cookie shared that
 * field, a second packet would overwrite the first's node pointer. Two packets
 * with different cookies is the minimum case that can see it.
 */
static void
test_cookie_does_not_collide_with_queue_linkage(void)
{
	struct mbuf_list ml = MBUF_LIST_INITIALIZER();
	mblk_t *m1 = iwx_m_alloc(64);
	mblk_t *m2 = iwx_m_alloc(64);
	mblk_t *out;

	CHECK(m1 != NULL && m2 != NULL, "alloc");
	if (m1 == NULL || m2 == NULL)
		return;

	iwx_m_set_cookie(m1, &fake_node_a);
	iwx_m_set_cookie(m2, &fake_node_b);
	ml_enqueue(&ml, m1);
	ml_enqueue(&ml, m2);
	CHECK(ml_len(&ml) == 2, "two packets queued");

	out = ml_dequeue(&ml);
	CHECK(out == m1, "FIFO order");
	CHECK(iwx_m_take_cookie(out) == &fake_node_a,
	    "first cookie must not be clobbered by the second enqueue");
	iwx_m_free(out);

	out = ml_dequeue(&ml);
	CHECK(out == m2, "FIFO order");
	CHECK(iwx_m_take_cookie(out) == &fake_node_b,
	    "second cookie must be intact after the first dequeue");
	iwx_m_free(out);
}

/*
 * A frame queued and never dequeued: interface down, or the driver detaching.
 * ml_purge() frees directly, so it -- not the consumer -- is responsible for
 * clearing the cookie before freemsg().
 *
 * This cannot be observed after the free (the memory is gone), so the check is
 * made on a snapshot taken by a purge-equivalent walk. That is a weaker
 * instrument than the others here and is called out rather than glossed: it
 * verifies ml_purge's ORDER of operations by reimplementing the walk, so it
 * would not catch ml_purge freeing without walking at all. The
 * purge_leaks_batch sabotage in run-mbuf-tests.sh covers that separately.
 */
static void
test_purge_clears_cookies_before_free(void)
{
	struct mbuf_list ml = MBUF_LIST_INITIALIZER();
	mblk_t *m1 = iwx_m_alloc(64);
	mblk_t *m2 = iwx_m_alloc(64);
	long frees_before;

	CHECK(m1 != NULL && m2 != NULL, "alloc");
	if (m1 == NULL || m2 == NULL)
		return;
	iwx_m_set_cookie(m1, &fake_node_a);
	iwx_m_set_cookie(m2, &fake_node_b);
	ml_enqueue(&ml, m1);
	ml_enqueue(&ml, m2);
	CHECK(!iwx_m_cookie_clear(ml.ml_head),
	    "precondition: the queued frames really do carry cookies");

	iwx_test_saw_dirty_free = 0;
	frees_before = iwx_test_frees;
	ml_purge(&ml);
	CHECK(iwx_test_frees == frees_before + 2,
	    "purge must free every queued packet, not just the head");
	CHECK(iwx_test_saw_dirty_free == 0,
	    "purge must clear b_prev before freemsg (stream.c:659 ASSERTs it)");
	CHECK(ml_empty(&ml) && ml_len(&ml) == 0, "purge must empty the list");
}

/*
 * The consumer path must leave the message clean too, for the same reason: the
 * frame goes on to iwx_tx() and from there to freemsg().
 */
static void
test_consumed_frame_frees_clean(void)
{
	struct mbuf_list ml = MBUF_LIST_INITIALIZER();
	mblk_t *m = iwx_m_alloc(64);

	CHECK(m != NULL, "alloc");
	if (m == NULL)
		return;
	iwx_m_set_cookie(m, &fake_node_a);
	ml_enqueue(&ml, m);
	m = ml_dequeue(&ml);
	CHECK(m != NULL, "dequeue");
	if (m == NULL)
		return;
	(void) iwx_m_take_cookie(m);

	iwx_test_saw_dirty_free = 0;
	iwx_m_free(m);
	CHECK(iwx_test_saw_dirty_free == 0,
	    "a consumed frame must reach freemsg with b_prev clear");
}

/*
 * A cookie must not leak into a message that was never given one. allocb()
 * zeroes b_prev (uts/common/io/stream.c:437), and iwx_m_alloc relies on that
 * rather than clearing it again.
 */
static void
test_fresh_message_has_no_cookie(void)
{
	mblk_t *m = iwx_m_alloc(64);

	CHECK(m != NULL, "alloc");
	if (m == NULL)
		return;
	CHECK(iwx_m_cookie_clear(m),
	    "a freshly allocated message must have b_prev == NULL");
	CHECK(iwx_m_take_cookie(m) == NULL,
	    "taking an unset cookie must yield NULL, not garbage");
	iwx_m_free(m);
}

static void
test_no_leaks(void)
{
	CHECK(iwx_test_allocs == iwx_test_frees,
	    "every allocated block must be freed by the end of the suite");
	if (iwx_test_allocs != iwx_test_frees)
		(void) printf("     allocs=%ld frees=%ld\n",
		    iwx_test_allocs, iwx_test_frees);
}

int
main(void)
{
	test_cookie_survives_the_queue();
	test_cookie_does_not_collide_with_queue_linkage();
	test_purge_clears_cookies_before_free();
	test_consumed_frame_frees_clean();
	test_fresh_message_has_no_cookie();
	test_no_leaks();

	(void) printf("%s: %d checks, %d failures\n",
	    failures == 0 ? "PASS" : "FAIL", checks, failures);
	return (failures == 0 ? 0 : 1);
}
