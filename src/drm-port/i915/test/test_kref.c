/*
 * test_kref.c -- linux/kref.h + linux/refcount.h as obsd-refcount.patch
 * leaves them: Linux refcount_t semantics. An over-release (the lixi
 * vmdump.4 pattern: a stray put to 0, then get 0 -> 1 and put 1 -> 0 again)
 * must release the object ONCE and report, not release it again.
 * Negative control: built from the unpatched headers (KREF_ORIG), the same
 * sequence releases twice and must FAIL.
 *
 * Built by `make test-kref` (OBSD = the pinned tree; the Makefile patches
 * copies of the two headers, as i915-driver.nix does).
 */
#include <stdint.h>
#include <stdio.h>
#include <stdbool.h>

/* what the two headers use, as the port defines it (obsd_kern.h, atomic.h);
 * the Makefile puts the two headers in test/kref/linux next to empty
 * linux/atomic.h, linux/spinlock.h and sys/rwlock.h */
#define __predict_false(x)	__builtin_expect(!!(x), 0)
#define likely(x)		__builtin_expect(!!(x), 1)
#define atomic_set(p, v)	(*(p) = (v))
#define atomic_read(p)		(*(p))
#define atomic_inc_int(p)	__sync_fetch_and_add((p), 1)
#define atomic_inc_int_nv(p)	__sync_add_and_fetch((p), 1)
#define atomic_dec_int_nv(p)	__sync_sub_and_fetch((p), 1)
#define atomic_inc(p)		__sync_fetch_and_add((p), 1)
#define atomic_dec_return(v)	__sync_sub_and_fetch((v), 1)
#define atomic_dec_and_test(v)	(atomic_dec_return(v) == 0)
static inline int
atomic_add_unless(volatile int *v, int n, int u)
{
	int o;

	do {
		o = *v;
		if (o == u)
			return 0;
	} while (__sync_val_compare_and_swap(v, o, o + n) != o);
	return 1;
}
#define atomic_inc_not_zero(v)	atomic_add_unless((v), 1, 0)
typedef unsigned int atomic_t;
struct rwlock { int x; };
struct mutex { int x; };
#define rw_enter_write(l)	((void)(l))
#define rw_exit_write(l)	((void)(l))
#define mtx_enter(l)		((void)(l))
#define mtx_leave(l)		((void)(l))

/* obsd_kern.h / obsd_kern.c, as the port has them */
#define OBSD_REFCOUNT_SATURATED	0xc0000000U
static int warnings;
void
obsd_refcount_warn(volatile uint32_t *p, const char *what)
{
	*p = OBSD_REFCOUNT_SATURATED;
	if (warnings++ == 0)
		printf("  (warn: %s)\n", what);
}

#include <linux/kref.h>

static int released;
static void release(struct kref *k) { (void)k; released++; }

static int fails;
#define CHECK(c, what) do { if (c) printf("ok   %s\n", what); \
	else { printf("FAIL %s\n", what); fails++; } } while (0)

int
main(void)
{
	struct kref k;
	struct rwlock rl;
	struct mutex ml;

	/* the normal life: init 1, get 2, put 1, put 0 -> one release, no warning */
	kref_init(&k); kref_get(&k);
	kref_put(&k, release); kref_put(&k, release);
	CHECK(released == 1 && warnings == 0, "get/put/put releases once, no warning");

	/* vmdump.4: dead object (0), unconditional get 0 -> 1, put 1 -> 0 again */
	released = 0; warnings = 0;
	kref_init(&k); kref_put(&k, release);		/* the stray put */
	kref_get(&k);					/* ww lock / lookup get */
	kref_put(&k, release);
	CHECK(released == 1, "a get from 0 then a put does not release again");
	CHECK(warnings >= 1, "a get from 0 is reported");
	CHECK(kref_get_unless_zero(&k) == 1 && kref_read(&k) >= OBSD_REFCOUNT_SATURATED,
	    "the count stays saturated (leaked, never 0 again)");

	/* a put below 0 */
	released = 0; warnings = 0;
	kref_init(&k); kref_put(&k, release); kref_put(&k, release);
	CHECK(released == 1 && warnings == 1, "a put below 0 is reported, no second release");

	/* kref_put_mutex / kref_put_lock: the same, through the slow path */
	released = 0; warnings = 0;
	kref_init(&k); kref_put_mutex(&k, release, &rl);
	kref_get(&k); kref_put_mutex(&k, release, &rl);
	kref_init(&k); kref_put_lock(&k, release, &ml);
	kref_get(&k); kref_put_lock(&k, release, &ml);
	CHECK(released == 2 && warnings >= 2, "kref_put_mutex/kref_put_lock: one release each");

	/* refcount_dec_and_test below 0 */
	warnings = 0;
	{
		uint32_t r = 1;

		CHECK(refcount_dec_and_test(&r), "refcount_dec_and_test 1 -> 0 is true");
		CHECK(!refcount_dec_and_test(&r) && warnings == 1,
		    "refcount_dec_and_test below 0 is false and reported");
	}
	printf("%s: %d failures\n", fails ? "FAIL" : "PASS", fails);
	return fails != 0;
}
