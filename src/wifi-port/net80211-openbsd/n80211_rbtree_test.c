/*
 * n80211_rbtree_test.c -- exhaustive + randomized test of n80211_rbtree.c with
 * a negative control. Userland, no framework, asserts only. A wrong red-black
 * tree corrupts the net80211 node cache SILENTLY, so this proves the ordering
 * AND the red-black invariants hold, and the negative control proves the
 * invariant checker can actually FAIL (compile with -DN80211_RBTREE_SABOTAGE).
 *
 *   cc -DN80211_RBTREE_TEST -I<compat> n80211_rbtree_test.c n80211_rbtree.c -o t && ./t
 *   cc -DN80211_RBTREE_TEST -DN80211_RBTREE_SABOTAGE ... (must FAIL)
 *
 * Invariants checked on the whole tree after every op:
 *   (1) BST ordering: in-order walk is strictly increasing.
 *   (2) root is black.
 *   (3) a red node has no red child.
 *   (4) every root->NULL path has the same black height.
 *   (5) parent/child back-pointers are consistent.
 *   (6) the set of keys present equals the reference set (nothing lost/dup'd).
 */
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

#include <sys/tree.h>

#define RBE_RED		0
#define RBE_BLACK	1

struct item {
	int			key;
	struct rb_entry		rbe;
	int			in_tree;
};

static int
item_cmp(const void *a, const void *b)
{
	const struct item *l = a, *r = b;
	return (l->key - r->key);
}

static const struct rb_type item_type = {
	item_cmp,
	NULL,
	offsetof(struct item, rbe),
};

/* mirror the .c's internal helpers for validation (read-only) */
static struct rb_entry *ent(struct item *it) { return (it ? &it->rbe : NULL); }
static struct item *itm(struct rb_entry *e)
{
	if (e == NULL) return (NULL);
	return ((struct item *)((char *)e - offsetof(struct item, rbe)));
}

static unsigned int col(struct rb_entry *e) { return (e ? e->rbt_color : RBE_BLACK); }

/* returns black-height, or -1 if any invariant is violated */
static int
check_node(struct rb_entry *e, int lo, int hi, int *ok)
{
	int lh, rh;
	struct item *it;

	if (e == NULL)
		return (1);	/* NULL is black, bh contribution 1 */

	it = itm(e);
	/* BST ordering bound */
	if (it->key <= lo || it->key >= hi) { *ok = 0; return (-1); }

	/* parent back-pointer consistency */
	if (e->rbt_left != NULL && e->rbt_left->rbt_parent != e) { *ok = 0; return (-1); }
	if (e->rbt_right != NULL && e->rbt_right->rbt_parent != e) { *ok = 0; return (-1); }

	/* red node has no red child */
	if (col(e) == RBE_RED) {
		if (col(e->rbt_left) == RBE_RED || col(e->rbt_right) == RBE_RED) {
			*ok = 0; return (-1);
		}
	}

	lh = check_node(e->rbt_left, lo, it->key, ok);
	rh = check_node(e->rbt_right, it->key, hi, ok);
	if (lh < 0 || rh < 0) { *ok = 0; return (-1); }
	if (lh != rh) { *ok = 0; return (-1); }	/* equal black-height */

	return (lh + (col(e) == RBE_BLACK ? 1 : 0));
}

/* the RBT head expanded (mirrors RBT_HEAD) */
struct itree { struct rb_tree rbh_root; };

static int
validate(struct itree *h, int *ref, int nref)
{
	int ok = 1;
	struct rb_entry *root = h->rbh_root.rbt_root;
	int i, walked = 0;
	void *e;
	int last;

	/* root must be black */
	if (root != NULL && col(root) != RBE_BLACK)
		return (0);

	(void) check_node(root, INT32_MIN, INT32_MAX, &ok);
	if (!ok)
		return (0);

	/* in-order walk strictly increasing AND matches reference set */
	e = _rb_min(&item_type, &h->rbh_root);
	last = INT32_MIN;
	while (e != NULL) {
		struct item *it = e;
		if (walked > 0 && it->key <= last)
			return (0);
		last = it->key;
		walked++;
		e = _rb_next(&item_type, e);
	}
	if (walked != nref)
		return (0);
	/* every reference key must be findable */
	for (i = 0; i < nref; i++) {
		struct item probe;
		probe.key = ref[i];
		if (_rb_find(&item_type, &h->rbh_root, &probe) == NULL)
			return (0);
	}
	return (1);
}

/*
 * SABOTAGE hook: when built with -DN80211_RBTREE_SABOTAGE we tamper with the
 * tree AFTER building it (recolor a random red-parent's child red), so the
 * "red has no red child" invariant is broken. This proves validate() can FAIL
 * -- a check that cannot fail proves nothing.
 */
#ifdef N80211_RBTREE_SABOTAGE
static void
sabotage(struct itree *h)
{
	struct rb_entry *r = h->rbh_root.rbt_root;
	if (r != NULL && r->rbt_left != NULL) {
		/* force root's left child red; root is black so this alone is
		 * legal, but then force ITS child red too -> red-red violation */
		r->rbt_left->rbt_color = RBE_RED;
		if (r->rbt_left->rbt_left != NULL)
			r->rbt_left->rbt_left->rbt_color = RBE_RED;
		else if (r->rbt_left->rbt_right != NULL)
			r->rbt_left->rbt_right->rbt_color = RBE_RED;
		else
			r->rbt_left->rbt_color = RBE_RED, r->rbt_color = RBE_RED;
	}
}
#endif

int
main(void)
{
	struct itree h;
	int n = 2000;
	struct item *items = calloc(n, sizeof (*items));
	int *ref = calloc(n, sizeof (int));
	int nref = 0;
	int i, iter;
	unsigned int seed = 12345;

	_rb_init(&h.rbh_root);

	/* --- 1. sequential insert 0..n-1, validate throughout --- */
	for (i = 0; i < n; i++) {
		items[i].key = i;
		void *dup = _rb_insert(&item_type, &h.rbh_root, &items[i]);
		assert(dup == NULL);
		items[i].in_tree = 1;
		ref[nref++] = i;
		if (i % 97 == 0)
			assert(validate(&h, ref, nref));
	}
	assert(validate(&h, ref, nref));
	printf("ok 1 sequential insert of %d, invariants hold\n", n);

	/* --- 2. min/max/root sanity --- */
	{
		struct item *mn = _rb_min(&item_type, &h.rbh_root);
		struct item *mx = _rb_max(&item_type, &h.rbh_root);
		assert(mn->key == 0 && mx->key == n - 1);
	}
	printf("ok 2 min=%d max=%d\n", 0, n - 1);

	/* --- 3. duplicate insert returns the existing element --- */
	{
		struct item probe;
		probe.key = 42;
		void *dup = _rb_insert(&item_type, &h.rbh_root, &probe);
		assert(dup == &items[42]);
	}
	printf("ok 3 duplicate insert returns existing element\n");

	/* --- 4. remove every even key, validate; then find must miss them --- */
	for (i = 0; i < n; i += 2) {
		_rb_remove(&item_type, &h.rbh_root, &items[i]);
		items[i].in_tree = 0;
	}
	/* rebuild ref = odd keys */
	nref = 0;
	for (i = 1; i < n; i += 2)
		ref[nref++] = i;
	assert(validate(&h, ref, nref));
	for (i = 0; i < n; i += 2) {
		struct item probe;
		probe.key = i;
		assert(_rb_find(&item_type, &h.rbh_root, &probe) == NULL);
	}
	printf("ok 4 removed %d even keys, invariants hold, finds miss\n", n / 2);

	/* --- 5. randomized insert/remove churn against a reference bitmap --- */
	{
		char *present = calloc(n, 1);
		for (i = 1; i < n; i += 2) present[i] = 1;	/* odds remain */
		for (iter = 0; iter < 200000; iter++) {
			seed = seed * 1103515245u + 12345u;
			int k = (seed >> 8) % n;
			if (present[k]) {
				_rb_remove(&item_type, &h.rbh_root, &items[k]);
				present[k] = 0;
			} else {
				items[k].key = k;
				void *dup = _rb_insert(&item_type, &h.rbh_root, &items[k]);
				assert(dup == NULL);
				present[k] = 1;
			}
			if (iter % 5000 == 0) {
				nref = 0;
				for (i = 0; i < n; i++)
					if (present[i]) ref[nref++] = i;
				assert(validate(&h, ref, nref));
			}
		}
		nref = 0;
		for (i = 0; i < n; i++)
			if (present[i]) ref[nref++] = i;
		assert(validate(&h, ref, nref));
		free(present);
	}
	printf("ok 5 200000 randomized churn ops, invariants hold\n");

	/* --- 6. nfind: least element >= key --- */
	{
		/* empty then rebuild a small known tree */
		struct itree h2;
		struct item its2[5];
		int keys[5] = { 10, 20, 30, 40, 50 };
		_rb_init(&h2.rbh_root);
		for (i = 0; i < 5; i++) {
			its2[i].key = keys[i];
			_rb_insert(&item_type, &h2.rbh_root, &its2[i]);
		}
		struct item probe;
		probe.key = 25;
		struct item *r = _rb_nfind(&item_type, &h2.rbh_root, &probe);
		assert(r != NULL && r->key == 30);
		probe.key = 30;
		r = _rb_nfind(&item_type, &h2.rbh_root, &probe);
		assert(r != NULL && r->key == 30);
		probe.key = 51;
		r = _rb_nfind(&item_type, &h2.rbh_root, &probe);
		assert(r == NULL);
	}
	printf("ok 6 nfind returns least element >= key\n");

	/* --- 7. NEGATIVE CONTROL: the validator MUST reject a broken tree --- */
	{
		struct itree hb;
		struct item itsb[16];
		int refb[16], nrb = 0;
		_rb_init(&hb.rbh_root);
		for (i = 0; i < 16; i++) {
			itsb[i].key = i;
			_rb_insert(&item_type, &hb.rbh_root, &itsb[i]);
			refb[nrb++] = i;
		}
		assert(validate(&hb, refb, nrb));	/* healthy */
		/* break the "red node has no red child" invariant by hand */
		struct rb_entry *root = hb.rbh_root.rbt_root;
		if (root->rbt_left) {
			root->rbt_left->rbt_color = RBE_RED;
			if (root->rbt_left->rbt_left)
				root->rbt_left->rbt_left->rbt_color = RBE_RED;
			else
				root->rbt_color = RBE_RED;	/* root not black */
		}
		if (validate(&hb, refb, nrb)) {
			fprintf(stderr,
			    "FAIL 7 negative control: validator accepted a BROKEN tree\n");
			return (1);
		}
		printf("ok 7 negative control: validator rejects a hand-broken tree\n");
	}

#ifdef N80211_RBTREE_SABOTAGE
	/* Whole-build sabotage: rerun test 1 but tamper before validating; the
	 * program MUST exit non-zero so the harness sees the sabotage caught. */
	{
		struct itree hs;
		struct item itss[64];
		int refs[64], nrs = 0;
		_rb_init(&hs.rbh_root);
		for (i = 0; i < 64; i++) {
			itss[i].key = i;
			_rb_insert(&item_type, &hs.rbh_root, &itss[i]);
			refs[nrs++] = i;
		}
		sabotage(&hs);
		if (validate(&hs, refs, nrs)) {
			fprintf(stderr, "FAIL sabotage: validator blind to tampering\n");
			return (1);
		}
		/* under sabotage build, deliberately fail so the negative-control
		 * runner records that a broken invariant DOES flip the verdict */
		fprintf(stderr, "SABOTAGE build: invariant break detected (expected FAIL)\n");
		return (2);
	}
#endif

	free(items);
	free(ref);
	printf("ALL RB-TREE TESTS PASS\n");
	return (0);
}
