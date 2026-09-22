/*
 * n80211_rbtree.c -- the _rb_* backing for the vendored OpenBSD RBT macros
 * (compat/sys/tree.h, OpenBSD sys/tree.h v1.31).
 *
 * WHY THIS FILE EXISTS: illumos sys/queue.h has TAILQ/LIST/SLIST but NO
 * red-black tree, and OpenBSD net80211 keys its node cache (ic->ic_tree) on
 * RBT_* -- so RBT_INSERT/REMOVE/MIN/NEXT/... in ieee80211_node.c expand to
 * calls into _rb_insert/_rb_remove/_rb_min/_rb_next/_rb_left/_rb_right/_rb_root
 * (measured: exactly these 7 are undefined in the net80211 ld -r object). Those
 * are the out-of-line half of the RBT macros; OpenBSD ships them in
 * sys/kern/subr_tree.c. It could not be fetched on the dev box, so this is a
 * from-scratch implementation of the SAME interface (the rb_type/rb_tree/
 * rb_entry layout tree.h declares), NOT a vendored copy -- tagged REAL, with a
 * negative-controlled exhaustive test (n80211_rbtree_test.c) because a wrong
 * red-black tree corrupts the node cache SILENTLY and takes the machine down at
 * a random later moment (exactly the hazard FINDINGS.md Finding 3 names for the
 * unserialised tree).
 *
 * The interface indirection: an element is any struct with a `struct rb_entry`
 * embedded at byte offset t->t_offset. This file only ever touches the entry
 * through that offset, so it is agnostic to the element type. Ordering is the
 * caller's t_compare(a, b) (<0, 0, >0). t_augment is a per-node recompute hook
 * (net80211 passes NULL; honoured when non-NULL for interface fidelity).
 *
 * Algorithm: standard CLRS red-black tree (insert-fixup / delete-fixup /
 * transplant), operating on rb_entry nodes with an explicit color field. This
 * is the classic parent/left/right/color node RB, which yields the SAME
 * ordering and the SAME O(log n) guarantees as OpenBSD's subr_tree.c; the two
 * differ only in internal representation, which is invisible across the _rb_*
 * boundary (net80211 never inspects rbt_color or the node internals -- it uses
 * only the returned element pointers).
 */

#ifdef _KERNEL
#include <sys/types.h>
#include <sys/systm.h>
#else
#include <stddef.h>
#include <stdint.h>
#endif

#include <sys/tree.h>

#define RBE_RED		0
#define RBE_BLACK	1

/* element pointer <-> its embedded rb_entry, via the type's offset */
static __inline struct rb_entry *
rbe_of(const struct rb_type *t, void *elm)
{
	if (elm == NULL)
		return (NULL);
	return ((struct rb_entry *)((char *)elm + t->t_offset));
}

static __inline void *
elm_of(const struct rb_type *t, struct rb_entry *rbe)
{
	if (rbe == NULL)
		return (NULL);
	return ((void *)((char *)rbe - t->t_offset));
}

static __inline unsigned int
rbe_color(struct rb_entry *rbe)
{
	return (rbe == NULL ? RBE_BLACK : rbe->rbt_color);
}

/* Optional per-node augmentation: recompute up the parent chain. NULL == none. */
static __inline void
rbe_augment(const struct rb_type *t, struct rb_entry *rbe)
{
	if (t->t_augment == NULL)
		return;
	while (rbe != NULL) {
		t->t_augment(elm_of(t, rbe));
		rbe = rbe->rbt_parent;
	}
}

static void
rbt_rotate_left(struct rb_tree *rbt, const struct rb_type *t, struct rb_entry *x)
{
	struct rb_entry *y = x->rbt_right;

	x->rbt_right = y->rbt_left;
	if (y->rbt_left != NULL)
		y->rbt_left->rbt_parent = x;
	y->rbt_parent = x->rbt_parent;
	if (x->rbt_parent == NULL)
		rbt->rbt_root = y;
	else if (x == x->rbt_parent->rbt_left)
		x->rbt_parent->rbt_left = y;
	else
		x->rbt_parent->rbt_right = y;
	y->rbt_left = x;
	x->rbt_parent = y;
	if (t->t_augment != NULL) {
		t->t_augment(elm_of(t, x));
		t->t_augment(elm_of(t, y));
	}
}

static void
rbt_rotate_right(struct rb_tree *rbt, const struct rb_type *t, struct rb_entry *x)
{
	struct rb_entry *y = x->rbt_left;

	x->rbt_left = y->rbt_right;
	if (y->rbt_right != NULL)
		y->rbt_right->rbt_parent = x;
	y->rbt_parent = x->rbt_parent;
	if (x->rbt_parent == NULL)
		rbt->rbt_root = y;
	else if (x == x->rbt_parent->rbt_right)
		x->rbt_parent->rbt_right = y;
	else
		x->rbt_parent->rbt_left = y;
	y->rbt_right = x;
	x->rbt_parent = y;
	if (t->t_augment != NULL) {
		t->t_augment(elm_of(t, x));
		t->t_augment(elm_of(t, y));
	}
}

static void
rbt_insert_fixup(struct rb_tree *rbt, const struct rb_type *t, struct rb_entry *z)
{
	struct rb_entry *y;

	while (rbe_color(z->rbt_parent) == RBE_RED) {
		struct rb_entry *gp = z->rbt_parent->rbt_parent;
		if (z->rbt_parent == gp->rbt_left) {
			y = gp->rbt_right;
			if (rbe_color(y) == RBE_RED) {
				z->rbt_parent->rbt_color = RBE_BLACK;
				y->rbt_color = RBE_BLACK;
				gp->rbt_color = RBE_RED;
				z = gp;
			} else {
				if (z == z->rbt_parent->rbt_right) {
					z = z->rbt_parent;
					rbt_rotate_left(rbt, t, z);
				}
				z->rbt_parent->rbt_color = RBE_BLACK;
				z->rbt_parent->rbt_parent->rbt_color = RBE_RED;
				rbt_rotate_right(rbt, t, z->rbt_parent->rbt_parent);
			}
		} else {
			y = gp->rbt_left;
			if (rbe_color(y) == RBE_RED) {
				z->rbt_parent->rbt_color = RBE_BLACK;
				y->rbt_color = RBE_BLACK;
				gp->rbt_color = RBE_RED;
				z = gp;
			} else {
				if (z == z->rbt_parent->rbt_left) {
					z = z->rbt_parent;
					rbt_rotate_right(rbt, t, z);
				}
				z->rbt_parent->rbt_color = RBE_BLACK;
				z->rbt_parent->rbt_parent->rbt_color = RBE_RED;
				rbt_rotate_left(rbt, t, z->rbt_parent->rbt_parent);
			}
		}
	}
	rbt->rbt_root->rbt_color = RBE_BLACK;
}

/*
 * _rb_insert: insert elm keyed by t_compare. Returns NULL on success, or the
 * existing element if an equal key is already present (OpenBSD's contract:
 * insert fails and returns the duplicate).
 */
void *
_rb_insert(const struct rb_type *t, struct rb_tree *rbt, void *elm)
{
	struct rb_entry *z = rbe_of(t, elm);
	struct rb_entry *y = NULL;
	struct rb_entry *x = rbt->rbt_root;
	int cmp;

	while (x != NULL) {
		y = x;
		cmp = t->t_compare(elm, elm_of(t, x));
		if (cmp < 0)
			x = x->rbt_left;
		else if (cmp > 0)
			x = x->rbt_right;
		else
			return (elm_of(t, x));		/* duplicate */
	}

	z->rbt_parent = y;
	z->rbt_left = NULL;
	z->rbt_right = NULL;
	z->rbt_color = RBE_RED;

	if (y == NULL)
		rbt->rbt_root = z;
	else if (t->t_compare(elm, elm_of(t, y)) < 0)
		y->rbt_left = z;
	else
		y->rbt_right = z;

	rbe_augment(t, z->rbt_parent);
	rbt_insert_fixup(rbt, t, z);
	return (NULL);
}

static struct rb_entry *
rbt_min_entry(struct rb_entry *x)
{
	if (x == NULL)
		return (NULL);
	while (x->rbt_left != NULL)
		x = x->rbt_left;
	return (x);
}

static struct rb_entry *
rbt_max_entry(struct rb_entry *x)
{
	if (x == NULL)
		return (NULL);
	while (x->rbt_right != NULL)
		x = x->rbt_right;
	return (x);
}

static void
rbt_transplant(struct rb_tree *rbt, struct rb_entry *u, struct rb_entry *v)
{
	if (u->rbt_parent == NULL)
		rbt->rbt_root = v;
	else if (u == u->rbt_parent->rbt_left)
		u->rbt_parent->rbt_left = v;
	else
		u->rbt_parent->rbt_right = v;
	if (v != NULL)
		v->rbt_parent = u->rbt_parent;
}

/*
 * Delete-fixup with an explicit NIL parent, so we can rebalance around a NULL
 * child (CLRS uses a sentinel; here we thread the parent through by hand).
 */
static void
rbt_delete_fixup(struct rb_tree *rbt, const struct rb_type *t,
    struct rb_entry *x, struct rb_entry *xparent)
{
	struct rb_entry *w;

	while (x != rbt->rbt_root && rbe_color(x) == RBE_BLACK) {
		if (x == xparent->rbt_left) {
			w = xparent->rbt_right;
			if (rbe_color(w) == RBE_RED) {
				w->rbt_color = RBE_BLACK;
				xparent->rbt_color = RBE_RED;
				rbt_rotate_left(rbt, t, xparent);
				w = xparent->rbt_right;
			}
			if (rbe_color(w->rbt_left) == RBE_BLACK &&
			    rbe_color(w->rbt_right) == RBE_BLACK) {
				w->rbt_color = RBE_RED;
				x = xparent;
				xparent = x->rbt_parent;
			} else {
				if (rbe_color(w->rbt_right) == RBE_BLACK) {
					if (w->rbt_left != NULL)
						w->rbt_left->rbt_color = RBE_BLACK;
					w->rbt_color = RBE_RED;
					rbt_rotate_right(rbt, t, w);
					w = xparent->rbt_right;
				}
				w->rbt_color = rbe_color(xparent);
				xparent->rbt_color = RBE_BLACK;
				if (w->rbt_right != NULL)
					w->rbt_right->rbt_color = RBE_BLACK;
				rbt_rotate_left(rbt, t, xparent);
				x = rbt->rbt_root;
				xparent = NULL;
			}
		} else {
			w = xparent->rbt_left;
			if (rbe_color(w) == RBE_RED) {
				w->rbt_color = RBE_BLACK;
				xparent->rbt_color = RBE_RED;
				rbt_rotate_right(rbt, t, xparent);
				w = xparent->rbt_left;
			}
			if (rbe_color(w->rbt_right) == RBE_BLACK &&
			    rbe_color(w->rbt_left) == RBE_BLACK) {
				w->rbt_color = RBE_RED;
				x = xparent;
				xparent = x->rbt_parent;
			} else {
				if (rbe_color(w->rbt_left) == RBE_BLACK) {
					if (w->rbt_right != NULL)
						w->rbt_right->rbt_color = RBE_BLACK;
					w->rbt_color = RBE_RED;
					rbt_rotate_left(rbt, t, w);
					w = xparent->rbt_left;
				}
				w->rbt_color = rbe_color(xparent);
				xparent->rbt_color = RBE_BLACK;
				if (w->rbt_left != NULL)
					w->rbt_left->rbt_color = RBE_BLACK;
				rbt_rotate_right(rbt, t, xparent);
				x = rbt->rbt_root;
				xparent = NULL;
			}
		}
	}
	if (x != NULL)
		x->rbt_color = RBE_BLACK;
}

/*
 * _rb_remove: unlink elm from the tree. Returns elm (OpenBSD returns the removed
 * element). elm MUST be in the tree.
 */
void *
_rb_remove(const struct rb_type *t, struct rb_tree *rbt, void *elm)
{
	struct rb_entry *z = rbe_of(t, elm);
	struct rb_entry *y = z;
	struct rb_entry *x;
	struct rb_entry *xparent;
	unsigned int yorig = y->rbt_color;

	if (z->rbt_left == NULL) {
		x = z->rbt_right;
		xparent = z->rbt_parent;
		rbt_transplant(rbt, z, z->rbt_right);
	} else if (z->rbt_right == NULL) {
		x = z->rbt_left;
		xparent = z->rbt_parent;
		rbt_transplant(rbt, z, z->rbt_left);
	} else {
		y = rbt_min_entry(z->rbt_right);
		yorig = y->rbt_color;
		x = y->rbt_right;
		if (y->rbt_parent == z) {
			xparent = y;
		} else {
			xparent = y->rbt_parent;
			rbt_transplant(rbt, y, y->rbt_right);
			y->rbt_right = z->rbt_right;
			y->rbt_right->rbt_parent = y;
		}
		rbt_transplant(rbt, z, y);
		y->rbt_left = z->rbt_left;
		y->rbt_left->rbt_parent = y;
		y->rbt_color = z->rbt_color;
	}

	if (t->t_augment != NULL)
		rbe_augment(t, xparent);

	if (yorig == RBE_BLACK)
		rbt_delete_fixup(rbt, t, x, xparent);

	/* poison the removed node's links so a double-remove is caught, not silent */
	z->rbt_parent = z->rbt_left = z->rbt_right = NULL;
	return (elm);
}

void *
_rb_find(const struct rb_type *t, struct rb_tree *rbt, const void *key)
{
	struct rb_entry *x = rbt->rbt_root;
	int cmp;

	while (x != NULL) {
		cmp = t->t_compare(key, elm_of(t, x));
		if (cmp < 0)
			x = x->rbt_left;
		else if (cmp > 0)
			x = x->rbt_right;
		else
			return (elm_of(t, x));
	}
	return (NULL);
}

/* nfind: least element >= key (OpenBSD contract). */
void *
_rb_nfind(const struct rb_type *t, struct rb_tree *rbt, const void *key)
{
	struct rb_entry *x = rbt->rbt_root;
	struct rb_entry *best = NULL;
	int cmp;

	while (x != NULL) {
		cmp = t->t_compare(key, elm_of(t, x));
		if (cmp < 0) {
			best = x;
			x = x->rbt_left;
		} else if (cmp > 0) {
			x = x->rbt_right;
		} else {
			return (elm_of(t, x));
		}
	}
	return (elm_of(t, best));
}

void *
_rb_root(const struct rb_type *t, struct rb_tree *rbt)
{
	return (elm_of(t, rbt->rbt_root));
}

void *
_rb_min(const struct rb_type *t, struct rb_tree *rbt)
{
	return (elm_of(t, rbt_min_entry(rbt->rbt_root)));
}

void *
_rb_max(const struct rb_type *t, struct rb_tree *rbt)
{
	return (elm_of(t, rbt_max_entry(rbt->rbt_root)));
}

/* in-order successor */
void *
_rb_next(const struct rb_type *t, void *elm)
{
	struct rb_entry *x = rbe_of(t, elm);
	struct rb_entry *y;

	if (x->rbt_right != NULL)
		return (elm_of(t, rbt_min_entry(x->rbt_right)));
	y = x->rbt_parent;
	while (y != NULL && x == y->rbt_right) {
		x = y;
		y = y->rbt_parent;
	}
	return (elm_of(t, y));
}

/* in-order predecessor */
void *
_rb_prev(const struct rb_type *t, void *elm)
{
	struct rb_entry *x = rbe_of(t, elm);
	struct rb_entry *y;

	if (x->rbt_left != NULL)
		return (elm_of(t, rbt_max_entry(x->rbt_left)));
	y = x->rbt_parent;
	while (y != NULL && x == y->rbt_left) {
		x = y;
		y = y->rbt_parent;
	}
	return (elm_of(t, y));
}

void *
_rb_left(const struct rb_type *t, void *elm)
{
	return (elm_of(t, rbe_of(t, elm)->rbt_left));
}

void *
_rb_right(const struct rb_type *t, void *elm)
{
	return (elm_of(t, rbe_of(t, elm)->rbt_right));
}

void *
_rb_parent(const struct rb_type *t, void *elm)
{
	return (elm_of(t, rbe_of(t, elm)->rbt_parent));
}

void
_rb_set_left(const struct rb_type *t, void *elm, void *left)
{
	rbe_of(t, elm)->rbt_left = rbe_of(t, left);
}

void
_rb_set_right(const struct rb_type *t, void *elm, void *right)
{
	rbe_of(t, elm)->rbt_right = rbe_of(t, right);
}

void
_rb_set_parent(const struct rb_type *t, void *elm, void *parent)
{
	rbe_of(t, elm)->rbt_parent = rbe_of(t, parent);
}

/*
 * _rb_poison / _rb_check: OpenBSD stamps a removed node's link fields with a
 * poison value so a use-after-remove faults. net80211 does not call these on
 * the node path, but tree.h emits RBT_POISON/RBT_CHECK wrappers, so keep the
 * symbols honest.
 */
void
_rb_poison(const struct rb_type *t, void *elm, unsigned long poison)
{
	struct rb_entry *rbe = rbe_of(t, elm);

	rbe->rbt_parent = (struct rb_entry *)(unsigned long)poison;
	rbe->rbt_left = (struct rb_entry *)(unsigned long)poison;
	rbe->rbt_right = (struct rb_entry *)(unsigned long)poison;
}

int
_rb_check(const struct rb_type *t, void *elm, unsigned long poison)
{
	struct rb_entry *rbe = rbe_of(t, elm);

	return (rbe->rbt_parent == (struct rb_entry *)(unsigned long)poison &&
	    rbe->rbt_left == (struct rb_entry *)(unsigned long)poison &&
	    rbe->rbt_right == (struct rb_entry *)(unsigned long)poison);
}
