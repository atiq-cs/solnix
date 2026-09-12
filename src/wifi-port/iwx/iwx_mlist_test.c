/*
 * Unit checks for the mbuf_list -> mblk b_next batch translation.
 *
 * The bug this exists to catch is invisible to a compiler and fatal at runtime:
 * confusing b_next (separate packets) with b_cont (segments of one packet). A
 * list built or walked through b_cont concatenates frames.
 *
 * Negative-controlled by run-mbuf-tests.sh.
 */

#include <stdio.h>
#include <string.h>
#include "iwx_mbuf.h"
#include "iwx_mlist.h"

long iwx_test_allocs;
long iwx_test_frees;

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

/* A one-segment packet holding a recognisable byte. */
static mblk_t *
pkt(unsigned char tag, size_t len)
{
	mblk_t *m = iwx_m_alloc(256);

	if (m == NULL)
		return (NULL);
	(void) iwx_m_set_window(m, DB_BASE(m), len);
	memset(iwx_mtod(m), tag, len);
	return (m);
}

static void
test_fifo_order_and_count(void)
{
	struct mbuf_list ml = MBUF_LIST_INITIALIZER();
	mblk_t *a, *b, *c, *r;

	ml_init(&ml);
	CHECK(ml_empty(&ml), "fresh list must be empty");
	CHECK(ml_len(&ml) == 0, "fresh list length must be 0");

	a = pkt(0xA1, 10); b = pkt(0xB2, 20); c = pkt(0xC3, 30);
	if (a == NULL || b == NULL || c == NULL) {
		CHECK(0, "alloc failed");
		return;
	}
	ml_enqueue(&ml, a);
	ml_enqueue(&ml, b);
	ml_enqueue(&ml, c);
	CHECK(ml_len(&ml) == 3, "three enqueues must count 3 PACKETS");
	CHECK(!ml_empty(&ml), "non-empty list must not report empty");

	r = ml_dequeue(&ml);
	CHECK(r == a, "dequeue must be FIFO (OpenBSD ml_ semantics)");
	CHECK(((unsigned char *)iwx_mtod(r))[0] == 0xA1, "wrong packet returned");
	CHECK(r->b_next == NULL,
	    "a dequeued packet must be DETACHED, or freeing it frees the batch");
	CHECK(ml_len(&ml) == 2, "dequeue must decrement the count");
	iwx_m_free(r);

	r = ml_dequeue(&ml);
	CHECK(r == b, "second dequeue must return the second packet");
	iwx_m_free(r);
	r = ml_dequeue(&ml);
	CHECK(r == c, "third dequeue must return the third packet");
	iwx_m_free(r);
	CHECK(ml_dequeue(&ml) == NULL, "dequeue from an empty list must be NULL");
	CHECK(ml_empty(&ml) && ml_len(&ml) == 0, "drained list must be empty");
}

/*
 * THE CENTRAL CHECK. A packet already fragmented across two b_cont segments is
 * enqueued alongside another packet. Afterwards the b_cont chain must be intact
 * and the b_next chain must link the two PACKETS -- not four segments.
 */
static void
test_bnext_and_bcont_do_not_mix(void)
{
	struct mbuf_list ml;
	mblk_t *p1a, *p1b, *p2, *batch;
	int n;

	ml_init(&ml);
	p1a = pkt(0x11, 8);
	p1b = pkt(0x22, 8);
	p2 = pkt(0x33, 8);
	if (p1a == NULL || p1b == NULL || p2 == NULL) {
		CHECK(0, "alloc failed");
		return;
	}
	linkb(p1a, p1b);		/* p1 is ONE packet in TWO segments */
	CHECK(iwx_m_pktlen(p1a) == 16, "fragmented packet must total 16 bytes");

	ml_enqueue(&ml, p1a);
	ml_enqueue(&ml, p2);
	CHECK(ml_len(&ml) == 2,
	    "a 2-segment packet plus a 1-segment packet is TWO packets, not three");

	batch = ml_dechain(&ml);
	CHECK(batch == p1a, "dechain must return the head");
	CHECK(batch->b_cont == p1b,
	    "enqueue must NOT disturb b_cont -- the fragmented frame must survive");
	CHECK(batch->b_next == p2,
	    "b_next must link the two packets");
	CHECK(batch->b_cont->b_next == NULL,
	    "an inner SEGMENT must never carry a b_next -- that would fork the batch");
	CHECK(ml_empty(&ml) && ml_len(&ml) == 0, "dechain must reset the list");

	/* Walking b_next must see 2 packets; walking b_cont must see 2 segments. */
	for (n = 0, p2 = batch; p2 != NULL; p2 = p2->b_next)
		n++;
	CHECK(n == 2, "the b_next walk must find exactly 2 packets");
	for (n = 0, p2 = batch; p2 != NULL; p2 = p2->b_cont)
		n++;
	CHECK(n == 2, "the b_cont walk must find exactly 2 segments of packet 1");

	freemsg(batch->b_next);
	batch->b_next = NULL;
	freemsg(batch);
}

/* ml_purge must free every packet AND every segment of every packet. */
static void
test_purge_frees_everything(void)
{
	struct mbuf_list ml;
	long before = iwx_test_frees;
	mblk_t *a, *b, *c;

	ml_init(&ml);
	a = pkt(1, 4); b = pkt(2, 4); c = pkt(3, 4);
	if (a == NULL || b == NULL || c == NULL) {
		CHECK(0, "alloc failed");
		return;
	}
	linkb(a, b);			/* 2-segment packet */
	ml_enqueue(&ml, a);
	ml_enqueue(&ml, c);
	ml_purge(&ml);
	CHECK(iwx_test_frees - before == 3,
	    "purge must free all 3 blocks (2 segments + 1 packet)");
	CHECK(ml_empty(&ml) && ml_len(&ml) == 0, "purge must leave the list empty");
}

static void
test_enqueue_null_is_ignored(void)
{
	struct mbuf_list ml;

	ml_init(&ml);
	ml_enqueue(&ml, NULL);
	CHECK(ml_len(&ml) == 0, "enqueueing NULL must not count a packet");
	CHECK(ml_empty(&ml), "enqueueing NULL must leave the list empty");
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
	test_fifo_order_and_count();
	test_bnext_and_bcont_do_not_mix();
	test_purge_frees_everything();
	test_enqueue_null_is_ignored();
	test_no_leaks();

	(void) printf("%s: %d checks, %d failures\n",
	    failures == 0 ? "PASS" : "FAIL", checks, failures);
	return (failures == 0 ? 0 : 1);
}
