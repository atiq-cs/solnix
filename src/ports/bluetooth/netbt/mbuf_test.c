/*
 * mbuf_test.c: unit test for mbuf.c + mbuf_ops.c over chain boundaries
 * (solnix, new code). Run by `hcitest -t`; negative-controls.sh breaks
 * m_copydata and m_adj one byte off and requires this to fail.
 */
#include <stdio.h>
#include <string.h>
#include "mbuf.h"

int mbuf_test(void);

static int fails;
#define	CHECK(c, what) do {						\
	if (!(c)) {							\
		fprintf(stderr, "selftest FAIL: mbuf: %s\n", what);	\
		fails++;						\
	}								\
} while (0)

int
mbuf_test(void)
{
	unsigned char src[200], out[200];
	struct mbuf *m, *n;
	int i;

	for (i = 0; i < (int)sizeof (src); i++)
		src[i] = (unsigned char)(i * 7 + 3);

	/* 200 bytes = 4 mbufs of 64 (1 type byte + 199) */
	m = m_frombuf(0x04, src, 199);
	CHECK(m != NULL && m->m_pkthdr.len == 200 && m_length(m) == 200,
	    "frombuf length");
	CHECK(m->m_next != NULL && m->m_next->m_next != NULL, "frombuf chains");
	memset(out, 0, sizeof (out));
	m_copydata(m, 60, 10, out);		/* across the 64-byte boundary */
	CHECK(memcmp(out, src + 59, 10) == 0, "copydata across a boundary");
	m_copydata(m, 64, 1, out);		/* first byte of mbuf 2 */
	CHECK(out[0] == src[63], "copydata at a boundary");

	m_adj(m, 64);				/* drops exactly mbuf 1 */
	CHECK(m->m_pkthdr.len == 136 && m->m_len == 0, "adj a whole mbuf");
	m_copydata(m, 0, 1, out);
	CHECK(out[0] == src[63], "adj then copydata");
	m_adj(m, -8);
	CHECK(m->m_pkthdr.len == 128 && m_length(m) == 128, "adj from the tail");
	m_copydata(m, 127, 1, out);
	CHECK(out[0] == src[63 + 127], "tail byte after adj");

	n = m_split(m, 70, M_DONTWAIT);
	CHECK(n != NULL && m->m_pkthdr.len == 70 && n->m_pkthdr.len == 58 &&
	    m_length(m) == 70 && m_length(n) == 58, "split lengths");
	m_copydata(n, 0, 1, out);
	CHECK(out[0] == src[63 + 70], "split tail first byte");

	m_cat(m, n);
	m->m_pkthdr.len = 128;			/* m_cat leaves it to the caller */
	CHECK(m_length(m) == 128, "cat length");
	m_copydata(m, 0, 128, out);
	CHECK(memcmp(out, src + 63, 128) == 0, "cat contents");

	m = m_prepend(m, 4, M_DONTWAIT);
	CHECK(m != NULL && m->m_pkthdr.len == 132 && m_length(m) == 132 &&
	    (m->m_flags & M_PKTHDR), "prepend");
	memcpy(m->m_data, "abcd", 4);
	m_copydata(m, 3, 2, out);
	CHECK(out[0] == 'd' && out[1] == src[63], "prepend contents");

	/* copyback over existing bytes and past the end (extends) */
	m_copyback(m, 130, 10, src);
	CHECK(m->m_pkthdr.len == 140 && m_length(m) == 140, "copyback extends");
	m_copydata(m, 130, 10, out);
	CHECK(memcmp(out, src, 10) == 0, "copyback contents");
	m_freem(m);

	{
		MBUFQ_HEAD() q;
		struct mbuf *a = m_gethdr(0, 0), *b = m_gethdr(0, 0), *x;

		MBUFQ_INIT(&q);
		MBUFQ_ENQUEUE(&q, a);
		MBUFQ_ENQUEUE(&q, b);
		MBUFQ_DEQUEUE(&q, x);
		CHECK(x == a && MBUFQ_FIRST(&q) == b, "mbufq fifo");
		m_freem(x);
		MBUFQ_DRAIN(&q);
		CHECK(MBUFQ_FIRST(&q) == NULL, "mbufq drain");
	}
	return (fails);
}
