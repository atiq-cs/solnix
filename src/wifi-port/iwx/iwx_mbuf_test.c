/*
 * Unit checks for the iwx mbuf -> mblk_t translation layer.
 *
 * Runs in userland against iwx_mbuf_test_stubs.h. Every case models a REAL
 * call shape in openbsd-orig/if_iwx.c, cited by line, so a pass means the
 * translation matches what the driver actually does rather than what an
 * mblk_t can do in general.
 *
 * NEGATIVE CONTROLS: run by run-mbuf-tests.sh, which rebuilds this same suite
 * against sabotaged copies of iwx_mbuf.c and requires it to FAIL. Without that,
 * a passing suite proves nothing. Do not trust a green run of this file alone.
 *
 * KNOWN LIMIT, stated rather than hidden: the stubs reimplement stream.h
 * semantics; they are not the kernel. They are the right instrument for the
 * pointer-arithmetic and ownership bugs this layer exists to prevent, and the
 * wrong instrument for anything about real allocator behaviour under pressure.
 */

#include <stdio.h>
#include <string.h>
#include "iwx_mbuf.h"

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

/*
 * if_iwx.c:4614-4640 -- m_gethdr + MCLGET + "m->m_len = m->m_pkthdr.len =
 * m->m_ext.ext_size", then bus_dmamap_load_mbuf over the whole cluster. The
 * driver requires the write window OPEN to the full cluster at this point,
 * because the device is about to DMA into it.
 */
static void
test_alloc_opens_full_cluster(void)
{
	mblk_t *m = iwx_m_alloc(4096);

	CHECK(m != NULL, "iwx_m_alloc(4096) returned NULL");
	if (m == NULL)
		return;
	CHECK(iwx_m_clustersize(m) >= 4096, "cluster smaller than requested");
	CHECK(iwx_m_len(m) == iwx_m_clustersize(m),
	    "RX alloc must expose the whole cluster as length (if_iwx.c:4633)");
	CHECK(iwx_m_pktlen(m) == iwx_m_len(m),
	    "single-segment pktlen must equal seglen");
	CHECK(iwx_mtod(m) == DB_BASE(m), "mtod must be the cluster base");
	iwx_m_free(m);
}

/*
 * if_iwx.c:5235-5236 -- "m->m_data = pktdata + desc_size; m->m_pkthdr.len =
 * m->m_len = len". Re-windowing an RX cluster onto one sub-frame. This is the
 * site where a naive m_data->b_rptr mapping corrupts: moving the read pointer
 * without moving the write pointer leaves the old, larger length in place.
 */
static void
test_set_window_moves_both_pointers(void)
{
	mblk_t *m = iwx_m_alloc(4096);
	unsigned char *base;
	size_t i;

	if (m == NULL) {
		CHECK(0, "alloc failed");
		return;
	}
	base = DB_BASE(m);
	for (i = 0; i < 4096; i++)
		base[i] = (unsigned char)(i & 0xff);

	/* desc_size = 32, frame length 100, as the RX path computes them. */
	CHECK(iwx_m_set_window(m, base + 32, 100), "in-bounds window rejected");
	CHECK(iwx_m_len(m) == 100, "length must be exactly the frame length");
	CHECK(iwx_mtod(m) == base + 32, "mtod must follow the new window");
	CHECK(((unsigned char *)iwx_mtod(m))[0] == 32,
	    "window must expose the frame, not the descriptor");
	CHECK(m->b_wptr == base + 132,
	    "write pointer must move with the read pointer, else MBLKL is stale");
	CHECK(iwx_m_pktlen(m) == 100, "pktlen must agree with seglen");
	iwx_m_free(m);
}

/*
 * The check a #define cannot perform. If firmware reports a bogus mpdu_len the
 * unchecked form produces a window past the DMA buffer and the 802.11 stack
 * parses adjacent memory. All four out-of-range shapes must be refused AND
 * must leave the buffer untouched.
 */
static void
test_set_window_rejects_out_of_bounds(void)
{
	mblk_t *m = iwx_m_alloc(256);
	unsigned char *base, *saved_r, *saved_w;

	if (m == NULL) {
		CHECK(0, "alloc failed");
		return;
	}
	base = DB_BASE(m);
	saved_r = m->b_rptr;
	saved_w = m->b_wptr;

	CHECK(!iwx_m_set_window(m, base + 200, 100),
	    "window running past db_lim must be refused");
	CHECK(!iwx_m_set_window(m, base - 1, 10),
	    "window starting before db_base must be refused");
	CHECK(!iwx_m_set_window(m, base + 512, 1),
	    "base outside the cluster must be refused");
	CHECK(!iwx_m_set_window(m, base, (size_t)-1),
	    "length overflow must be refused, not wrap");
	CHECK(m->b_rptr == saved_r && m->b_wptr == saved_w,
	    "a refused window must not modify the buffer");

	/* Exact-fit boundary must still be ACCEPTED, or the guard is too strict. */
	CHECK(iwx_m_set_window(m, base, iwx_m_clustersize(m)),
	    "exact-fit window must be accepted");
	CHECK(iwx_m_set_window(m, DB_LIM(m), 0),
	    "empty window at the limit is legal");
	iwx_m_free(m);
}

/*
 * if_iwx.c:5264-5265 -- "memmove(m->m_data + 2, m->m_data, hdrlen);
 * m_adj(m, 2);" removing the 2-byte alignment pad the hardware inserts after
 * the frame header. The bytes that remain must be the shifted header.
 */
static void
test_adj_head_removes_pad(void)
{
	mblk_t *m = iwx_m_alloc(256);
	unsigned char *p;
	size_t i;

	if (m == NULL) {
		CHECK(0, "alloc failed");
		return;
	}
	(void) iwx_m_set_window(m, DB_BASE(m), 64);
	p = iwx_mtod(m);
	for (i = 0; i < 64; i++)
		p[i] = (unsigned char)i;

	CHECK(iwx_m_adj(m, 2), "trimming 2 of 64 bytes must succeed");
	CHECK(iwx_m_len(m) == 62, "head trim must shorten by exactly 2");
	CHECK(((unsigned char *)iwx_mtod(m))[0] == 2,
	    "head trim must advance past the pad");
	iwx_m_free(m);
}

static void
test_adj_tail_and_overlong(void)
{
	mblk_t *m = iwx_m_alloc(256);

	if (m == NULL) {
		CHECK(0, "alloc failed");
		return;
	}
	(void) iwx_m_set_window(m, DB_BASE(m), 64);
	CHECK(iwx_m_adj(m, -8), "tail trim must succeed");
	CHECK(iwx_m_len(m) == 56, "tail trim must shorten by exactly 8");

	/*
	 * DIVERGENCE, deliberately asserted rather than emulated: OpenBSD's
	 * m_adj empties the mbuf when asked to trim more than it holds;
	 * adjmsg() refuses and changes nothing. Pinning the illumos behaviour
	 * here so a future change to iwx_m_adj that silently adopts the BSD
	 * behaviour breaks a test instead of a laptop.
	 */
	CHECK(!iwx_m_adj(m, 1000), "over-long trim must be refused");
	CHECK(iwx_m_len(m) == 56, "a refused trim must not modify the buffer");
	CHECK(iwx_m_adj(m, 0), "zero trim is a no-op success");
	CHECK(iwx_m_len(m) == 56, "zero trim must not modify the buffer");
	iwx_m_free(m);
}

/*
 * if_iwx.c:10305-10306 -- "if (m->m_len < sizeof(*eh) && (m = m_pullup(m,
 * sizeof(*eh))) == NULL)". Contract: on success the first len bytes are
 * contiguous; on failure m is consumed and NULL returned.
 */
static void
test_pullup_makes_header_contiguous(void)
{
	mblk_t *a = iwx_m_alloc(64), *b = iwx_m_alloc(64);
	mblk_t *r;
	int i;

	if (a == NULL || b == NULL) {
		CHECK(0, "alloc failed");
		return;
	}
	(void) iwx_m_set_window(a, DB_BASE(a), 4);
	(void) iwx_m_set_window(b, DB_BASE(b), 10);
	for (i = 0; i < 4; i++)
		((unsigned char *)iwx_mtod(a))[i] = (unsigned char)i;
	for (i = 0; i < 10; i++)
		((unsigned char *)iwx_mtod(b))[i] = (unsigned char)(4 + i);
	linkb(a, b);
	CHECK(iwx_m_pktlen(a) == 14, "two-segment chain must total 14");
	CHECK(iwx_m_len(a) != 14, "precondition: header must start split");

	r = iwx_m_pullup(a, 14);
	CHECK(r != NULL, "pullup of an available length must succeed");
	if (r == NULL)
		return;
	CHECK(iwx_m_len(r) >= 14, "pullup must make 14 bytes contiguous");
	for (i = 0; i < 14; i++) {
		if (((unsigned char *)iwx_mtod(r))[i] != (unsigned char)i) {
			CHECK(0, "pullup must preserve byte order across the join");
			break;
		}
	}
	iwx_m_free(r);
}

static void
test_pullup_consumes_on_failure(void)
{
	mblk_t *m = iwx_m_alloc(64);
	long frees_before;

	if (m == NULL) {
		CHECK(0, "alloc failed");
		return;
	}
	(void) iwx_m_set_window(m, DB_BASE(m), 4);
	frees_before = iwx_test_frees;
	/* Ask for more than the chain holds: must fail AND free m. */
	CHECK(iwx_m_pullup(m, 100) == NULL, "impossible pullup must return NULL");
	CHECK(iwx_test_frees > frees_before,
	    "m_pullup contract: the chain is consumed on failure (no leak)");
}

/*
 * if_iwx.c:6378 -- "if (m_defrag(m, M_DONTWAIT))". Note the POINTER MOVES here
 * where OpenBSD's did not; the call site must be rewritten, and this test pins
 * the returned-head contract so that rewrite is checkable.
 */
static void
test_defrag_collapses_chain(void)
{
	mblk_t *a = iwx_m_alloc(32), *b = iwx_m_alloc(32), *c = iwx_m_alloc(32);
	mblk_t *r;
	int i;

	if (a == NULL || b == NULL || c == NULL) {
		CHECK(0, "alloc failed");
		return;
	}
	(void) iwx_m_set_window(a, DB_BASE(a), 3);
	(void) iwx_m_set_window(b, DB_BASE(b), 3);
	(void) iwx_m_set_window(c, DB_BASE(c), 3);
	for (i = 0; i < 3; i++) {
		((unsigned char *)iwx_mtod(a))[i] = (unsigned char)i;
		((unsigned char *)iwx_mtod(b))[i] = (unsigned char)(3 + i);
		((unsigned char *)iwx_mtod(c))[i] = (unsigned char)(6 + i);
	}
	linkb(a, b);
	linkb(a, c);
	CHECK(iwx_m_pktlen(a) == 9, "three-segment chain must total 9");

	r = iwx_m_defrag(a);
	CHECK(r != NULL, "defrag must succeed");
	if (r == NULL)
		return;
	CHECK(r->b_cont == NULL, "defrag must leave exactly one segment");
	CHECK(iwx_m_len(r) == 9, "defrag must preserve the total length");
	for (i = 0; i < 9; i++) {
		if (((unsigned char *)iwx_mtod(r))[i] != (unsigned char)i) {
			CHECK(0, "defrag must preserve byte order");
			break;
		}
	}
	iwx_m_free(r);
}

/*
 * if_iwx.c:10943 -- "m = m_copym(m0, 0, M_COPYALL, M_DONTWAIT)" then m_adj on
 * the copy while m0 stays on the RX ring. The copy MUST be deep: if it shares
 * the cluster, adjusting one changes the other and the RX ring is corrupted.
 * This is the ownership difference in item 3 of iwx_mbuf.h, made testable.
 */
static void
test_copy_is_deep_not_shared(void)
{
	mblk_t *m = iwx_m_alloc(128), *dup;
	unsigned char *p;

	if (m == NULL) {
		CHECK(0, "alloc failed");
		return;
	}
	(void) iwx_m_set_window(m, DB_BASE(m), 16);
	p = iwx_mtod(m);
	memset(p, 0xAA, 16);

	dup = iwx_m_copy(m);
	CHECK(dup != NULL, "copy must succeed");
	if (dup == NULL) {
		iwx_m_free(m);
		return;
	}
	CHECK(iwx_m_len(dup) == 16, "copy must have the same length");
	CHECK(DB_BASE(dup) != DB_BASE(m),
	    "copy must NOT share the cluster, or trimming it corrupts the RX ring");
	memset(iwx_mtod(dup), 0x55, 16);
	CHECK(((unsigned char *)iwx_mtod(m))[0] == 0xAA,
	    "writing the copy must not change the original");
	CHECK(iwx_m_adj(dup, 4) && iwx_m_len(m) == 16,
	    "trimming the copy must not change the original's length");
	iwx_m_free(dup);
	iwx_m_free(m);
}

/*
 * freemsg() honours db_ref, so a shared block survives one free. iwx does not
 * dup today, but the layer above it may; pinning this means a future refcount
 * assertion has a baseline.
 */
static void
test_free_honours_refcount(void)
{
	mblk_t *m = iwx_m_alloc(64), *d;

	if (m == NULL) {
		CHECK(0, "alloc failed");
		return;
	}
	(void) iwx_m_set_window(m, DB_BASE(m), 8);
	memset(iwx_mtod(m), 0x5A, 8);
	d = dupb(m);
	CHECK(d != NULL, "dupb must succeed");
	if (d == NULL) {
		iwx_m_free(m);
		return;
	}
	CHECK(DB_REF(m) == 2, "dupb must raise the reference count");
	iwx_m_free(m);
	/* The data must still be readable through d. */
	CHECK(((unsigned char *)iwx_mtod(d))[0] == 0x5A,
	    "a shared cluster must survive one free");
	CHECK(DB_REF(d) == 1, "the free must have dropped one reference");
	iwx_m_free(d);
}

/*
 * if_iwx.c:5264 -- memmove(m->m_data + 2, m->m_data, hdrlen) shifts the 802.11
 * header right over the hardware's 2-byte alignment pad, and the caller then
 * does m_adj(m, 2). Two things must hold and only one of them is obvious.
 */
static void
test_shift_right_moves_header_and_length(void)
{
	mblk_t *m = iwx_m_alloc(64);
	unsigned char *p;
	size_t before;
	int i;

	CHECK(m != NULL, "alloc");
	if (m == NULL)
		return;
	/* A 24-byte 802.11 header of recognisable bytes in a 40-byte frame. */
	CHECK(iwx_m_set_window(m, DB_BASE(m), 40), "set_window");
	p = iwx_mtod(m);
	for (i = 0; i < 40; i++)
		p[i] = (unsigned char)(i + 1);
	before = iwx_m_len(m);

	CHECK(iwx_m_shift_right(m, 24, 2) == B_TRUE,
	    "shift of 24 bytes by 2 must fit in a 64-byte cluster");
	p = iwx_mtod(m);
	CHECK(p[2] == 1 && p[25] == 24,
	    "the 24 header bytes must appear 2 further along");
	/*
	 * THE NON-OBVIOUS HALF. The frame is 2 bytes longer, so the write window
	 * must grow with it. If it does not, the caller's following m_adj(m, 2)
	 * trims 2 bytes off a length that never accounted for them and the tail
	 * of every padded frame is silently lost.
	 */
	CHECK(iwx_m_len(m) == before + 2,
	    "shift must extend the write window (else m_adj(m,2) eats payload)");

	/* And after the caller's m_adj(m, 2) the frame is back to its length. */
	CHECK(iwx_m_adj(m, 2) == B_TRUE, "m_adj(m,2) after the shift");
	CHECK(iwx_m_len(m) == before,
	    "shift-then-adj must be length-neutral (if_iwx.c:5264-5265)");
	p = iwx_mtod(m);
	CHECK(p[0] == 1 && p[23] == 24,
	    "after adj the header must start at the read pointer again");
	iwx_m_free(m);
}

/*
 * The bounds check OpenBSD gets for free from oversized clusters. hdrlen comes
 * from ieee80211_get_hdrlen() on a header the DEVICE supplied, so a frame that
 * fills its cluster must not be shifted past the end.
 */
static void
test_shift_right_rejects_overflow(void)
{
	mblk_t *m = iwx_m_alloc(32);
	unsigned char *base;
	size_t len;

	CHECK(m != NULL, "alloc");
	if (m == NULL)
		return;
	base = DB_BASE(m);
	len = iwx_m_clustersize(m);
	/* Window covering the entire cluster: there is no slack to shift into. */
	CHECK(iwx_m_set_window(m, base, len), "set_window full");
	CHECK(iwx_m_shift_right(m, len, 2) == B_FALSE,
	    "shifting a full cluster right by 2 must be refused");
	CHECK(iwx_m_len(m) == len, "refused shift must leave the length alone");
	CHECK(iwx_mtod(m) == base, "refused shift must leave the window alone");

	/* A shift whose SOURCE is longer than the readable window is also bogus. */
	CHECK(iwx_m_set_window(m, base, 4), "set_window short");
	CHECK(iwx_m_shift_right(m, 8, 2) == B_FALSE,
	    "shifting more bytes than are readable must be refused");
	iwx_m_free(m);
}

/*
 * if_iwx.c:10882 / :10927 -- "(struct iwx_rx_packet *)(m0->m_data + offset)"
 * walks several firmware responses packed into one RX buffer, where offset
 * advances by a length the device reported.
 */
static void
test_at_bounds_checks_offset(void)
{
	mblk_t *m = iwx_m_alloc(128);

	CHECK(m != NULL, "alloc");
	if (m == NULL)
		return;
	CHECK(iwx_m_set_window(m, DB_BASE(m), 64), "set_window");

	CHECK(iwx_m_at(m, 0, 8) == iwx_mtod(m), "offset 0 is the read pointer");
	CHECK(iwx_m_at(m, 16, 8) == (unsigned char *)iwx_mtod(m) + 16,
	    "in-range offset must be rptr + offset");
	CHECK(iwx_m_at(m, 56, 8) != NULL, "a read ending exactly at the end is ok");
	CHECK(iwx_m_at(m, 57, 8) == NULL,
	    "a read running 1 byte past the frame must be refused");
	CHECK(iwx_m_at(m, 65, 1) == NULL,
	    "an offset past the frame must be refused, not wrapped");
	/*
	 * The cluster is 128 but only 64 bytes are readable. Offsets between the
	 * two are the interesting case: allocated but not received. OpenBSD's
	 * pointer arithmetic accepts them silently.
	 */
	CHECK(iwx_m_at(m, 100, 4) == NULL,
	    "an offset inside the cluster but past the DATA must be refused");
	/* Overflow: offset + need must not wrap to something in range. */
	CHECK(iwx_m_at(m, 8, (size_t)-1) == NULL,
	    "a need that overflows offset+need must be refused");
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
	test_alloc_opens_full_cluster();
	test_set_window_moves_both_pointers();
	test_set_window_rejects_out_of_bounds();
	test_adj_head_removes_pad();
	test_adj_tail_and_overlong();
	test_pullup_makes_header_contiguous();
	test_pullup_consumes_on_failure();
	test_defrag_collapses_chain();
	test_copy_is_deep_not_shared();
	test_free_honours_refcount();
	test_shift_right_moves_header_and_length();
	test_shift_right_rejects_overflow();
	test_at_bounds_checks_offset();
	test_no_leaks();

	(void) printf("%s: %d checks, %d failures\n",
	    failures == 0 ? "PASS" : "FAIL", checks, failures);
	return (failures == 0 ? 0 : 1);
}
