/*
 * Userland stand-ins for the illumos STREAMS types, so iwx_mbuf.c can be
 * compiled and exercised on the build host without a kernel.
 *
 * These reimplement the SEMANTICS iwx_mbuf.c depends on, taken from
 * uts/common/sys/stream.h and uts/common/io/stream.c:
 *   - msgb carries b_rptr/b_wptr/b_cont/b_datap and NO stored length
 *   - datab carries db_base/db_lim/db_ref
 *   - freemsg() honours db_ref
 *   - adjmsg() returns 0 and changes nothing if the chain is shorter than len
 *   - pullupmsg() works in place and can fail; msgpullup() allocates
 *
 * If the real kernel semantics differ from these stubs, the test measures the
 * stub instead of the kernel -- so each behaviour above is cited to its source
 * and the risk is stated in iwx_mbuf_test.c rather than hidden here.
 */

#ifndef _IWX_MBUF_TEST_STUBS_H
#define _IWX_MBUF_TEST_STUBS_H

#include <stdlib.h>
#include <string.h>
#include <stddef.h>
#include <sys/types.h>

#ifndef B_TRUE
#define B_FALSE 0
#define B_TRUE  1
typedef int boolean_t;
#endif

#define BPRI_MED 1

typedef struct datab {
	unsigned char	*db_base;
	unsigned char	*db_lim;
	unsigned char	db_ref;
} dblk_t;

typedef struct msgb {
	struct msgb	*b_next;
	struct msgb	*b_prev;
	struct msgb	*b_cont;
	unsigned char	*b_rptr;
	unsigned char	*b_wptr;
	struct datab	*b_datap;
} mblk_t;

#define DB_BASE(mp)	((mp)->b_datap->db_base)
#define DB_LIM(mp)	((mp)->b_datap->db_lim)
#define DB_REF(mp)	((mp)->b_datap->db_ref)
#define MBLKL(mp)	((ptrdiff_t)((mp)->b_wptr - (mp)->b_rptr))

/* Counters so leaks are observable by the test. */
extern long iwx_test_allocs;
extern long iwx_test_frees;

static mblk_t *
allocb(size_t size, unsigned int pri)
{
	mblk_t *m;
	dblk_t *d;
	unsigned char *buf;

	(void) pri;
	m = calloc(1, sizeof (*m));
	d = calloc(1, sizeof (*d));
	buf = calloc(1, size == 0 ? 1 : size);
	if (m == NULL || d == NULL || buf == NULL) {
		free(m); free(d); free(buf);
		return (NULL);
	}
	d->db_base = buf;
	d->db_lim = buf + size;
	d->db_ref = 1;
	m->b_datap = d;
	m->b_rptr = m->b_wptr = buf;
	iwx_test_allocs++;
	return (m);
}

static void
freeb(mblk_t *m)
{
	if (--DB_REF(m) == 0) {
		free(DB_BASE(m));
		free(m->b_datap);
	}
	free(m);
	iwx_test_frees++;
}

static void
freemsg(mblk_t *m)
{
	mblk_t *n;

	while (m != NULL) {
		n = m->b_cont;
		freeb(m);
		m = n;
	}
}

static size_t
xmsgsize_stub(mblk_t *m)
{
	size_t n = 0;

	for (; m != NULL; m = m->b_cont)
		n += (size_t)MBLKL(m);
	return (n);
}

/* uts/common/io/stream.c:1699 adjmsg() -- returns 0 if chain shorter than len */
static int
adjmsg(mblk_t *m, ssize_t len)
{
	int fromhead = 1;
	size_t want;
	mblk_t *p;

	if (m == NULL)
		return (0);
	if (len < 0) {
		fromhead = 0;
		len = -len;
	}
	want = (size_t)len;
	if (xmsgsize_stub(m) < want)
		return (0);

	if (fromhead) {
		for (p = m; p != NULL && want > 0; p = p->b_cont) {
			size_t n = (size_t)MBLKL(p);
			if (n > want)
				n = want;
			p->b_rptr += n;
			want -= n;
		}
	} else {
		/* Trim from the tail: walk to the end, shrink backwards. */
		while (want > 0) {
			mblk_t *last = m, *prev = NULL;
			size_t n;
			while (last->b_cont != NULL) {
				prev = last;
				last = last->b_cont;
			}
			n = (size_t)MBLKL(last);
			if (n > want)
				n = want;
			last->b_wptr -= n;
			want -= n;
			if (MBLKL(last) == 0 && prev != NULL) {
				prev->b_cont = NULL;
				freeb(last);
			} else if (MBLKL(last) == 0) {
				break;
			}
		}
	}
	return (1);
}

/* In-place; fails (0) when the leading blocks cannot absorb len. */
static int
pullupmsg(mblk_t *m, ssize_t len)
{
	size_t want = (len < 0) ? xmsgsize_stub(m) : (size_t)len;
	size_t cap;

	if (m == NULL)
		return (0);
	if ((size_t)MBLKL(m) >= want)
		return (1);
	if (xmsgsize_stub(m) < want)
		return (0);
	cap = (size_t)(DB_LIM(m) - m->b_rptr);
	if (cap < want || DB_REF(m) > 1)
		return (0);		/* no room / shared: caller falls back */

	while ((size_t)MBLKL(m) < want && m->b_cont != NULL) {
		mblk_t *n = m->b_cont;
		size_t take = want - (size_t)MBLKL(m);
		if (take > (size_t)MBLKL(n))
			take = (size_t)MBLKL(n);
		memcpy(m->b_wptr, n->b_rptr, take);
		m->b_wptr += take;
		n->b_rptr += take;
		if (MBLKL(n) == 0) {
			m->b_cont = n->b_cont;
			n->b_cont = NULL;
			freeb(n);
		}
	}
	return ((size_t)MBLKL(m) >= want);
}

/* Allocates a fresh contiguous copy of the first len bytes (-1 = all). */
static mblk_t *
msgpullup(mblk_t *m, ssize_t len)
{
	size_t total = xmsgsize_stub(m);
	size_t want = (len < 0) ? total : (size_t)len;
	mblk_t *out, *p;
	size_t left;

	if (want > total)
		return (NULL);
	out = allocb(total, BPRI_MED);
	if (out == NULL)
		return (NULL);
	left = want;
	for (p = m; p != NULL; p = p->b_cont) {
		size_t n = (size_t)MBLKL(p);
		if (n > left)
			n = left;
		memcpy(out->b_wptr, p->b_rptr, n);
		out->b_wptr += n;
		left -= n;
		if (left == 0)
			break;
	}
	/* Real msgpullup appends the remainder; iwx never depends on it. */
	return (out);
}

static mblk_t *
copymsg(mblk_t *m)
{
	mblk_t *head = NULL, *tail = NULL, *p;

	for (p = m; p != NULL; p = p->b_cont) {
		size_t n = (size_t)MBLKL(p);
		mblk_t *c = allocb((size_t)(DB_LIM(p) - DB_BASE(p)), BPRI_MED);
		if (c == NULL) {
			freemsg(head);
			return (NULL);
		}
		/* Preserve the read offset, as copyb() does. */
		c->b_rptr = DB_BASE(c) + (size_t)(p->b_rptr - DB_BASE(p));
		c->b_wptr = c->b_rptr + n;
		memcpy(c->b_rptr, p->b_rptr, n);
		if (head == NULL)
			head = tail = c;
		else {
			tail->b_cont = c;
			tail = c;
		}
	}
	return (head);
}

static mblk_t *
dupb(mblk_t *m)
{
	mblk_t *n = calloc(1, sizeof (*n));

	if (n == NULL)
		return (NULL);
	n->b_datap = m->b_datap;
	n->b_rptr = m->b_rptr;
	n->b_wptr = m->b_wptr;
	DB_REF(m)++;
	iwx_test_allocs++;
	return (n);
}

/*
 * Shallow chain duplicate: shares every cluster, raising each db_ref. Present
 * so the negative-control build that swaps copymsg() for dupmsg() COMPILES --
 * a sabotage that fails to compile is not a negative control, it only proves
 * the compiler works.
 */
static mblk_t *
dupmsg(mblk_t *m)
{
	mblk_t *head = NULL, *tail = NULL, *p;

	for (p = m; p != NULL; p = p->b_cont) {
		mblk_t *c = dupb(p);
		if (c == NULL) {
			freemsg(head);
			return (NULL);
		}
		if (head == NULL)
			head = tail = c;
		else {
			tail->b_cont = c;
			tail = c;
		}
	}
	return (head);
}

static void
linkb(mblk_t *a, mblk_t *b)
{
	while (a->b_cont != NULL)
		a = a->b_cont;
	a->b_cont = b;
}

#endif /* _IWX_MBUF_TEST_STUBS_H */
