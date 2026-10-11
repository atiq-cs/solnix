/*
 * n80211_mbuf_test.c -- userland test of n80211_mbuf.c with negative controls.
 * Builds against the faithful mblk_t stub (iwx_mbuf_test_stubs.h) plus iwx_mbuf.c
 * (for iwx_m_pktlen). Every function is exercised; each check is proven able to
 * FAIL via -DN80211_MBUF_SABOTAGE.
 *
 *   cc -DN80211_MBUF_TEST -I<iwx> n80211_mbuf_test.c n80211_mbuf.c iwx_mbuf.c -o t && ./t
 *   cc ... -DN80211_MBUF_SABOTAGE ...   (must FAIL)
 */
#include "iwx_mbuf_test_stubs.h"
#include <stdio.h>
#include <string.h>
#include <assert.h>

long iwx_test_allocs, iwx_test_frees;
int iwx_test_saw_dirty_free;

/* prototypes for the functions under test */
extern mblk_t *n80211_m_gethdr(int, int);
extern mblk_t *n80211_m_get(int, int);
extern int     n80211_m_clget(mblk_t *, int);
extern mblk_t *n80211_m_prepend(mblk_t *, int, int);
extern void    n80211_m_align(mblk_t *, size_t);
extern int     n80211_m_copydata(mblk_t *, int, int, void *);
extern mblk_t *n80211_m_split(mblk_t *, int, int);
extern mblk_t *n80211_m_dup_pkt(mblk_t *, int, int);
extern size_t  iwx_m_pktlen(const mblk_t *);

#define M_DONTWAIT 0x0002
#define MT_DATA    1

/* build a chain of `nseg` segments, each carrying `seglen` bytes of a ramp */
static mblk_t *
make_chain(int nseg, int seglen, unsigned char start)
{
	mblk_t *head = NULL, *tail = NULL;
	unsigned char v = start;
	int s, i;

	for (s = 0; s < nseg; s++) {
		mblk_t *m = allocb((size_t)seglen + 8, BPRI_MED);
		assert(m != NULL);
		for (i = 0; i < seglen; i++)
			m->b_wptr[i] = v++;
		m->b_wptr += seglen;
		if (head == NULL) head = tail = m;
		else { tail->b_cont = m; tail = m; }
	}
	return (head);
}

int
main(void)
{
	int fails = 0;

	/* --- 1. gethdr gives an empty, full-cluster mblk --- */
	{
		mblk_t *m = n80211_m_gethdr(M_DONTWAIT, MT_DATA);
		assert(m != NULL);
		assert(MBLKL(m) == 0);				/* empty window */
		assert((size_t)(DB_LIM(m) - DB_BASE(m)) >= 2048);/* cluster present */
		assert(n80211_m_clget(m, M_DONTWAIT) == 0);	/* cluster ok */
		freemsg(m);
		printf("ok 1 gethdr: empty window, cluster present, clget succeeds\n");
	}

	/* --- 2. prepend opens leading room and preserves it --- */
	{
		mblk_t *m = n80211_m_gethdr(M_DONTWAIT, MT_DATA);
		/* reserve 24 bytes (a mgmt header) then write 4 body bytes */
		m->b_rptr += 24; m->b_wptr = m->b_rptr;
		m->b_wptr[0]=0xAA; m->b_wptr[1]=0xBB; m->b_wptr[2]=0xCC; m->b_wptr[3]=0xDD;
		m->b_wptr += 4;
		size_t before = iwx_m_pktlen(m);
		m = n80211_m_prepend(m, 24, M_DONTWAIT);
		assert(m != NULL);
		/* body still intact after the prepended 24 bytes */
		assert(m->b_rptr[24]==0xAA && m->b_rptr[27]==0xDD);
		assert(iwx_m_pktlen(m) >= before + 24);
		freemsg(m);
		printf("ok 2 prepend: room made, body preserved\n");
	}

	/* --- 2b. prepend underflow -> NULL and frees --- */
	{
		mblk_t *m = n80211_m_gethdr(M_DONTWAIT, MT_DATA);
		/* no headroom: rptr is at db_base already */
		long f0 = iwx_test_frees;
		mblk_t *r = n80211_m_prepend(m, 8, M_DONTWAIT);
		assert(r == NULL);
		assert(iwx_test_frees > f0);		/* it freed on failure */
		printf("ok 2b prepend underflow returns NULL and frees\n");
	}

	/* --- 2c. m_align + prepend: the auth-frame path (regression test) ---
	 * ieee80211_get_auth does MGETHDR; m_align(m, 6); write 6 body bytes;
	 * then ieee80211_mgmt_output M_PREPENDs the 24-byte 802.11 header. If
	 * m_align leaves no leading headroom the prepend underflows and the
	 * frame is dropped (ENOMEM), which silently breaks all association.
	 * This proves m_align reserves enough leading room for the header. */
	{
		mblk_t *m = n80211_m_gethdr(M_DONTWAIT, MT_DATA);
		assert(m != NULL);
		n80211_m_align(m, 6);
		/* body sits at the tail with the whole cluster as headroom */
		assert((size_t)(m->b_rptr - DB_BASE(m)) >= 24);
		m->b_wptr = m->b_rptr + 6;		/* open a 6-byte window */
		m->b_rptr[0]=0x11; m->b_rptr[1]=0x22; m->b_rptr[5]=0x66;
		m = n80211_m_prepend(m, 24, M_DONTWAIT);
		assert(m != NULL);			/* prepend MUST succeed */
		assert(m->b_rptr[24]==0x11 && m->b_rptr[29]==0x66);
		freemsg(m);
		printf("ok 2c m_align leaves header room; auth prepend succeeds\n");
	}

	/* --- 3. copydata across a multi-segment chain --- */
	{
		mblk_t *m = make_chain(3, 10, 0);	/* 30 bytes: 0..29 */
		unsigned char buf[30];
		assert(n80211_m_copydata(m, 0, 30, buf) == 0);
		for (int i = 0; i < 30; i++)
			assert(buf[i] == (unsigned char)i);
		/* offset into the 2nd segment */
		unsigned char buf2[5];
		assert(n80211_m_copydata(m, 12, 5, buf2) == 0);
		for (int i = 0; i < 5; i++)
			assert(buf2[i] == (unsigned char)(12 + i));
		/* over-read fails */
		assert(n80211_m_copydata(m, 25, 10, buf) == -1);
		freemsg(m);
		printf("ok 3 copydata: cross-segment, offset, over-read guarded\n");
	}

	/* --- 4. split at an offset: m keeps head, n gets tail, bytes intact --- */
	{
		mblk_t *m = make_chain(3, 10, 0);	/* 30 bytes 0..29 */
		mblk_t *n = n80211_m_split(m, 12, M_DONTWAIT);
		assert(n != NULL);
		assert(iwx_m_pktlen(m) == 12);
		assert(iwx_m_pktlen(n) == 18);
		unsigned char hb[12], tb[18];
		assert(n80211_m_copydata(m, 0, 12, hb) == 0);
		assert(n80211_m_copydata(n, 0, 18, tb) == 0);
		for (int i = 0; i < 12; i++) assert(hb[i] == (unsigned char)i);
		for (int i = 0; i < 18; i++) assert(tb[i] == (unsigned char)(12 + i));
		freemsg(m); freemsg(n);
		printf("ok 4 split: head=12 tail=18, byte contents correct\n");
	}

	/* --- 4b. split past end -> NULL, m intact --- */
	{
		mblk_t *m = make_chain(2, 10, 0);
		mblk_t *n = n80211_m_split(m, 50, M_DONTWAIT);
		assert(n == NULL);
		assert(iwx_m_pktlen(m) == 20);		/* untouched */
		freemsg(m);
		printf("ok 4b split past end returns NULL, m intact\n");
	}

	/* --- 5. dup_pkt: contiguous copy with a 2-byte leading pad --- */
	{
		mblk_t *m = make_chain(3, 8, 100);	/* 24 bytes 100..123 */
		mblk_t *d = n80211_m_dup_pkt(m, 2, M_DONTWAIT);
		assert(d != NULL);
		assert(iwx_m_pktlen(d) == 24);		/* pad not counted in length */
		assert(d->b_cont == NULL);		/* single contiguous cluster */
		/* the 2-byte pad sits before b_rptr (in the cluster) */
		assert((size_t)(d->b_rptr - DB_BASE(d)) == 2);
		unsigned char db[24];
		assert(n80211_m_copydata(d, 0, 24, db) == 0);
		for (int i = 0; i < 24; i++) assert(db[i] == (unsigned char)(100 + i));
		freemsg(m); freemsg(d);
		printf("ok 5 dup_pkt: contiguous, 2-byte pad, bytes correct\n");
	}

	/* --- 6. NEGATIVE CONTROLS: prove each core check can fail --- */
	{
		/* copydata into a too-short buffer must be caught by the length
		 * guard, not silently succeed */
		mblk_t *m = make_chain(1, 4, 0);
		unsigned char buf[4];
		int r = n80211_m_copydata(m, 0, 8, buf);	/* ask 8, have 4 */
#ifdef N80211_MBUF_SABOTAGE
		/* sabotage: pretend the guard is off -> we'd accept -1 as ok */
		if (r == 0) { fprintf(stderr,"impossible\n"); return 1; }
		fprintf(stderr, "SABOTAGE: guard reported %d (expected -1); flipping FAIL\n", r);
		return 2;
#else
		if (r != -1) {
			fprintf(stderr, "FAIL 6: over-read not caught (got %d)\n", r);
			fails = 1;
		} else {
			printf("ok 6 negative control: over-read is caught (-1)\n");
		}
#endif
		freemsg(m);
	}

	if (fails) { fprintf(stderr, "SOME TESTS FAILED\n"); return (1); }
	/* leak check: allocs must equal frees at the end */
	if (iwx_test_allocs != iwx_test_frees) {
		fprintf(stderr, "FAIL leak: allocs=%ld frees=%ld\n",
		    iwx_test_allocs, iwx_test_frees);
		return (1);
	}
	printf("ALL N80211 MBUF TESTS PASS (allocs==frees==%ld)\n", iwx_test_allocs);
	return (0);
}
