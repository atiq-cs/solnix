/*
 * test_idr_race.c -- the idr/xarray code of OpenBSD's drm_linux.c under
 * threads, as drm ioctls run in this port: KERNEL_LOCK is a no-op, so
 * threads sharing one drm fd look up, create and close GEM handles at once.
 *
 * Built by `make test-idr` from the idr/xarray section of drm_linux.c
 * (IDR_REGION, extracted by the Makefile). With obsd-idrlock.patch it must
 * pass; on the unpatched file it must FAIL (the negative control): a handle
 * that names another file's object (one idr_entry in two trees, via the
 * shared preload entry), a lost or leaked entry, a corrupt tree (crash or a
 * loop the watchdog catches).
 *
 * The model follows drm_gem.c / i915: per file, creators do
 * idr_preload + idr_alloc(NULL) + idr_replace(obj) and later
 * idr_replace(NULL) + idr_remove, all under the file's table_lock;
 * lookers call idr_find with no lock (i915_gem_object_lookup_rcu); a
 * walker uses idr_get_next under table_lock (drm_show_memory_stats).
 * A context xarray gets __xa_alloc/__xa_erase under xa_lock and unlocked
 * __xa_load (__context_lookup). Freed entries are poisoned and reused
 * LIFO, as kmem's magazines reuse them.
 */
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <unistd.h>

#ifndef __unused
#define __unused	__attribute__((__unused__))
#endif
#include "../../obsd-compat/sys/tree.h"	/* -Itest/idr: an empty sys/_null.h */

/* ---- what the region needs (OpenBSD include/linux/idr.h, xarray.h) ---- */
typedef unsigned int gfp_t;
typedef uint32_t u32;
#define GFP_NOWAIT	0x1
#define GFP_KERNEL	0x2
#define PR_WAITOK	0x1
#define PR_NOWAIT	0x2
#define IPL_NONE	0
#define IPL_TTY		1
#define KERNEL_ASSERT_LOCKED()	((void)0)
#define spltty()	(0)
#define splx(s)		((void)(s))
#define ERR_PTR(e)	((void *)(long)(e))
#define IS_ERR(p)	((unsigned long)(p) >= (unsigned long)-4095)
struct xa_node;
#define XA_ERROR(x)	((struct xa_node *)(((unsigned long)x << 2) | 2))
#define XA_FLAGS_ALLOC1	(1 << 1)
#define XA_FLAGS_LOCK_IRQ (1 << 2)

struct mutex { pthread_mutex_t pm; };
#define MUTEX_INITIALIZER(ipl)	{ PTHREAD_MUTEX_INITIALIZER }
#define mtx_init(m, ipl)	pthread_mutex_init(&(m)->pm, NULL)
#define mtx_enter(m)		pthread_mutex_lock(&(m)->pm)
#define mtx_leave(m)		pthread_mutex_unlock(&(m)->pm)

struct idr_entry {
	SPLAY_ENTRY(idr_entry) entry;
	unsigned long id;
	void *ptr;
};
struct idr {
	SPLAY_HEAD(idr_tree, idr_entry) tree;
	unsigned long next;
};
struct ida { struct idr idr; };
struct xarray_entry {
	SPLAY_ENTRY(xarray_entry) entry;
	int id;
	void *ptr;
};
struct xarray {
	gfp_t		xa_flags;
	struct mutex	xa_lock;
	SPLAY_HEAD(xarray_tree, xarray_entry) xa_tree;
};
struct xarray_range { uint32_t start; uint32_t end; };

/* pool(9): LIFO reuse of poisoned entries, and a count of what is out */
struct pool { int unused; };
#define ENTSZ	64
static pthread_mutex_t pool_mtx = PTHREAD_MUTEX_INITIALIZER;
static void *pool_free;
static long pool_out;

static void *
pool_get(struct pool *pp, int flags)
{
	void *p;

	(void)pp; (void)flags;
	pthread_mutex_lock(&pool_mtx);
	if ((p = pool_free) != NULL)
		pool_free = *(void **)((char *)p + ENTSZ - sizeof (void *));
	pool_out++;
	pthread_mutex_unlock(&pool_mtx);
	if (p == NULL && (p = malloc(ENTSZ)) == NULL)
		abort();
	memset(p, 0, ENTSZ);
	return p;
}

static void
pool_put(struct pool *pp, void *p)
{
	(void)pp;
	memset(p, 0x5a, ENTSZ);		/* a stale reader sees garbage */
	pthread_mutex_lock(&pool_mtx);
	*(void **)((char *)p + ENTSZ - sizeof (void *)) = pool_free;
	pool_free = p;
	pool_out--;
	pthread_mutex_unlock(&pool_mtx);
}

#include IDR_REGION		/* the idr + xarray section of drm_linux.c */

/* ---- the test ---- */
#define NFILE	4		/* drm files */
#define NCREAT	2		/* threads per file creating/closing handles */
#define NLOOK	2		/* threads per file looking handles up, unlocked */
#define NOBJ	48		/* live objects per creator, at most */
#define NXOBJ	32

struct obj {
	int file;		/* owner, fixed (a looker may read a closing one) */
	int live;
	unsigned long h;
};
struct file {
	struct idr idr;
	pthread_mutex_t table_lock;
};
struct creator {
	int f;
	unsigned seed;
	struct obj o[NOBJ];
};

static struct file files[NFILE];
static struct creator creators[NFILE * NCREAT];
static struct xarray ctx_xa;
static struct obj xobj[2][NXOBJ];
static volatile int stop;
static volatile long fails, progress;

#define FAIL(...) do {							\
	if (__atomic_fetch_add(&fails, 1, __ATOMIC_RELAXED) < 8) {	\
		printf("FAIL: " __VA_ARGS__); fflush(stdout);		\
	}								\
} while (0)

static void *
creator_main(void *arg)
{
	struct creator *c = arg;
	struct file *F = &files[c->f];
	struct obj *o;
	void *old;
	int h, i;

	for (i = 0; i < NOBJ; i++)
		c->o[i].file = c->f;
	while (!stop) {
		o = &c->o[rand_r(&c->seed) % NOBJ];
		if (!o->live) {
			idr_preload(GFP_KERNEL);
			pthread_mutex_lock(&F->table_lock);
			h = idr_alloc(&F->idr, NULL, 1, 0, GFP_NOWAIT);
			pthread_mutex_unlock(&F->table_lock);
			if (h < 0) {
				FAIL("file %d: idr_alloc = %d\n", c->f, h);
				continue;
			}
			o->h = h;
			pthread_mutex_lock(&F->table_lock);
			old = idr_replace(&F->idr, o, h);
			pthread_mutex_unlock(&F->table_lock);
			if (old != NULL)
				FAIL("file %d: new handle %d was not empty (%s)\n",
				    c->f, h, IS_ERR(old) ? "not found" : "taken");
			o->live = 1;
		} else {
			pthread_mutex_lock(&F->table_lock);
			old = idr_replace(&F->idr, NULL, o->h);
			pthread_mutex_unlock(&F->table_lock);
			if (old != o)
				FAIL("file %d: handle %lu names %s, not its object\n",
				    c->f, o->h, old == NULL ? "nothing" :
				    IS_ERR(old) ? "no entry" :
				    "another object (a put on an object it does not own)");
			pthread_mutex_lock(&F->table_lock);
			(void) idr_remove(&F->idr, o->h);
			pthread_mutex_unlock(&F->table_lock);
			o->live = 0;
		}
		__atomic_fetch_add(&progress, 1, __ATOMIC_RELAXED);
	}
	return NULL;
}

static void *
looker_main(void *arg)
{
	int f = (int)(intptr_t)arg;
	unsigned seed = f * 7919 + 1;
	struct obj *o;

	while (!stop) {
		o = idr_find(&files[f].idr, 1 + rand_r(&seed) % (NCREAT * NOBJ + 8));
		if (o != NULL && o->file != f)
			FAIL("file %d: idr_find gave file %d's object\n", f, o->file);
	}
	return NULL;
}

static void *
walker_main(void *arg)
{
	struct obj *o;
	int f, id;

	(void)arg;
	while (!stop) {
		for (f = 0; f < NFILE; f++) {
			pthread_mutex_lock(&files[f].table_lock);
			for (id = 0; (o = idr_get_next(&files[f].idr, &id)) != NULL; id++)
				if (o->file != f)
					FAIL("file %d: walk found file %d's object\n",
					    f, o->file);
			pthread_mutex_unlock(&files[f].table_lock);
		}
	}
	return NULL;
}

/* contexts: __xa_alloc/__xa_erase under xa_lock, __xa_load unlocked */
static void *
xwriter_main(void *arg)
{
	int t = (int)(intptr_t)arg;
	unsigned seed = t + 17;
	struct obj *o;
	u32 id;

	while (!stop) {
		o = &xobj[t][rand_r(&seed) % NXOBJ];
		mtx_enter(&ctx_xa.xa_lock);
		if (!o->live) {
			if (__xa_alloc(&ctx_xa, &id, o, (struct xarray_range){ 1, 4096 },
			    GFP_NOWAIT) == 0) {
				o->h = id;
				o->live = 1;
			}
		} else if (__xa_erase(&ctx_xa, o->h) != o) {
			FAIL("context %lu: erase did not find its object\n", o->h);
		} else {
			o->live = 0;
		}
		mtx_leave(&ctx_xa.xa_lock);
	}
	return NULL;
}

static void *
xreader_main(void *arg)
{
	unsigned seed = (int)(intptr_t)arg + 31;
	unsigned long id;
	struct obj *o;

	while (!stop) {
		id = 1 + rand_r(&seed) % (2 * NXOBJ + 4);
		o = __xa_load(&ctx_xa, id);
		if (o != NULL && ((uintptr_t)o < (uintptr_t)xobj ||
		    (uintptr_t)o >= (uintptr_t)xobj + sizeof (xobj)))
			FAIL("context %lu: load gave a pointer to no object\n", id);
	}
	return NULL;
}

static void
crash(int sig)
{
	char m[] = "FAIL: crash (signal 00): a corrupt tree or a freed entry\n";

	m[20] = '0' + sig / 10; m[21] = '0' + sig % 10;
	(void) write(1, m, sizeof (m) - 1);
	_exit(3);
}

static void
watchdog(int sig)
{
	static const char m[] = "FAIL: watchdog: no progress (a corrupt splay tree loops)\n";

	(void)sig;
	(void) write(1, m, sizeof (m) - 1);
	_exit(2);
}

static int
cmpp(const void *a, const void *b)
{
	uintptr_t x = *(const uintptr_t *)a, y = *(const uintptr_t *)b;

	return (x > y) - (x < y);
}

int
main(void)
{
	pthread_t th[64];
	int i, f, nth = 0, secs = getenv("IDR_SECS") ? atoi(getenv("IDR_SECS")) : 3;
	long last = -1, nent = 0, n;
	static uintptr_t ents[NFILE * NCREAT * NOBJ + 2 * NXOBJ + 8];
	struct idr_entry *e;
	struct xarray_entry *xe;

	signal(SIGSEGV, crash);
	signal(SIGBUS, crash);
	signal(SIGALRM, watchdog);
	for (f = 0; f < NFILE; f++) {
		idr_init(&files[f].idr);
		pthread_mutex_init(&files[f].table_lock, NULL);
	}
	xa_init_flags(&ctx_xa, XA_FLAGS_ALLOC1);
	for (i = 0; i < NFILE * NCREAT; i++) {
		creators[i].f = i % NFILE;
		creators[i].seed = i + 1;
		pthread_create(&th[nth++], NULL, creator_main, &creators[i]);
	}
	for (i = 0; i < NFILE * NLOOK; i++)
		pthread_create(&th[nth++], NULL, looker_main, (void *)(intptr_t)(i % NFILE));
	pthread_create(&th[nth++], NULL, walker_main, NULL);
	for (i = 0; i < 2; i++) {
		pthread_create(&th[nth++], NULL, xwriter_main, (void *)(intptr_t)i);
		pthread_create(&th[nth++], NULL, xreader_main, (void *)(intptr_t)i);
	}
	for (i = 0; i < secs * 4; i++) {
		alarm(10);
		usleep(250000);
		if (progress == last)
			watchdog(0);
		last = progress;
	}
	stop = 1;
	for (i = 0; i < nth; i++)
		pthread_join(th[i], NULL);

	/* quiescent: every tree holds exactly the live handles, each entry once */
	for (f = 0; f < NFILE; f++) {
		n = 0;
		SPLAY_FOREACH(e, idr_tree, &files[f].idr.tree) {
			struct obj *o = e->ptr;

			if (o == NULL || o->file != f || !o->live || o->h != e->id)
				FAIL("file %d: entry %lu names %s\n", f, e->id,
				    o == NULL ? "nothing" : "another object");
			if (nent < (long)(sizeof (ents) / sizeof (ents[0])))
				ents[nent++] = (uintptr_t)e;
			n++;
		}
		for (i = 0; i < NFILE * NCREAT; i++)
			if (creators[i].f == f)
				for (int j = 0; j < NOBJ; j++)
					n -= creators[i].o[j].live;
		if (n != 0)
			FAIL("file %d: tree has %+ld entries vs the live handles\n", f, n);
	}
	n = 0;
	SPLAY_FOREACH(xe, xarray_tree, &ctx_xa.xa_tree) {
		if (nent < (long)(sizeof (ents) / sizeof (ents[0])))
			ents[nent++] = (uintptr_t)xe;
		n++;
	}
	for (i = 0; i < 2 * NXOBJ; i++)
		n -= xobj[i / NXOBJ][i % NXOBJ].live;
	if (n != 0)
		FAIL("contexts: tree has %+ld entries vs the live contexts\n", n);
	qsort(ents, nent, sizeof (ents[0]), cmpp);
	for (i = 1; i < nent; i++)
		if (ents[i] == ents[i - 1])
			FAIL("one entry %p is in two trees\n", (void *)ents[i]);
	if (pool_out != nent + (idr_entry_cache != NULL))
		FAIL("pool: %ld entries out, %ld in trees + %d preloaded "
		    "(leaked or shared)\n", pool_out, nent, idr_entry_cache != NULL);
	printf("%s: %ld handle ops in %d s, %d threads, %ld entries at the end, %ld failures\n",
	    fails ? "FAIL" : "PASS", progress, secs, nth, nent, fails);
	return fails != 0;
}
