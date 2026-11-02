/*
 * kshim.c: the NetBSD KPI behind compat/kshim.h, for one thread (solnix, new
 * code). The "kernel" is a pump: kshim_pump() reads events from the transport
 * into the core (hci_input_event) and runs the soft interrupt hci_intr. A
 * sleeper in cv_timedwait_sig gives up bt_lock and pumps until its cv is
 * broadcast or the deadline passes, which is what the kernel's softint thread
 * would do while the ioctl caller sleeps.
 */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "compat/kshim.h"
#include "upstream/netbt/bluetooth.h"
#include "upstream/netbt/hci.h"
#include "xport.h"
#include "core.h"

static kmutex_t bt_lock_store = { 0, "bt_lock" };
kmutex_t *bt_lock = &bt_lock_store;

void
kshim_panic(const char *file, int line, const char *what)
{
	fprintf(stderr, "netbt panic: %s:%d: %s\n", file, line, what);
	abort();
}

void
kshim_aprint_error_dev(device_t dev, const char *fmt, ...)
{
	va_list ap;

	fprintf(stderr, "%s: ", dev != NULL ? dev->xname : "?");
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	core_note_error();
}

void *
kshim_malloc(size_t sz, int flags)
{
	void *p = (malloc)(sz);	/* the libc one, not kshim.h's 3-argument macro */

	if (p != NULL && (flags & M_ZERO))
		memset(p, 0, sz);
	return (p);
}

void
kshim_mutex_init(kmutex_t *m, const char *name)
{
	m->held = 0;
	m->name = name;
}

void
kshim_mutex_enter(kmutex_t *m, const char *f, int l)
{
	if (m->held)
		kshim_panic(f, l, "mutex_enter: already held (recursion or lock order)");
	m->held = 1;
}

void
kshim_mutex_exit(kmutex_t *m, const char *f, int l)
{
	if (!m->held)
		kshim_panic(f, l, "mutex_exit: not held");
	m->held = 0;
}

int
kshim_mutex_owned(kmutex_t *m)
{
	return (m->held);
}

void
kshim_microtime(struct timeval *tv)
{
	uint64_t ms = xport_cur != NULL ? xport_cur->now_ms(xport_cur->arg) : 0;

	tv->tv_sec = (time_t)(ms / 1000);
	tv->tv_usec = (suseconds_t)(ms % 1000) * 1000;
}

/* ---- soft interrupts: a flag; the pump runs the handler ---- */
struct kshim_softint {
	void	(*fn)(void *);
	void	*arg;
	int	pending;
};
static struct kshim_softint *softint_one;	/* netbt establishes one per unit */

void *
kshim_softint_establish(int flags, void (*fn)(void *), void *arg)
{
	struct kshim_softint *si = calloc(1, sizeof (*si));

	(void) flags;
	if (si == NULL)
		return (NULL);
	si->fn = fn;
	si->arg = arg;
	softint_one = si;
	return (si);
}

void
kshim_softint_schedule(void *p)
{
	((struct kshim_softint *)p)->pending = 1;
}

void
kshim_softint_disestablish(void *p)
{
	if (softint_one == p)
		softint_one = NULL;
	(free)(p);
}

/* Run a pending soft interrupt. Called with bt_lock NOT held (hci_intr takes it). */
int
kshim_run_softints(void)
{
	struct kshim_softint *si = softint_one;

	if (si == NULL || !si->pending)
		return (0);
	si->pending = 0;
	si->fn(si->arg);
	return (1);
}

/* ---- callout and pool: only ACL links use them (STUB, see STATUS.md) ---- */
void
kshim_callout_schedule(callout_t *c, int ticks)
{
	(void) c;
	(void) ticks;
	kshim_panic(__FILE__, __LINE__, "STUB: callout_schedule (ACL link expiry not ported)");
}

void *
kshim_pool_get(struct pool *p, int f)
{
	(void) p;
	(void) f;
	kshim_panic(__FILE__, __LINE__, "STUB: pool_get (L2CAP PDUs not ported)");
}

void
kshim_pool_put(struct pool *p, void *v)
{
	(void) p;
	(void) v;
	kshim_panic(__FILE__, __LINE__, "STUB: pool_put (L2CAP PDUs not ported)");
}

/*
 * NetBSD cv_timedwait_sig: drop the lock, sleep at most ticks, retake it.
 * 0 = woken, EWOULDBLOCK = timed out, EIO = the transport failed (where a
 * kernel would see the device detach; the caller treats any nonzero as fatal).
 */
int
kshim_cv_timedwait_sig(kcondvar_t *cv, kmutex_t *m, int ticks)
{
	unsigned gen = cv->gen;
	uint64_t end = xport_cur->now_ms(xport_cur->arg) +
	    (uint64_t)ticks * 1000 / hz;
	int rv = EWOULDBLOCK;

	KASSERT(m->held);
	mutex_exit(m);
	while (cv->gen == gen) {
		uint64_t now = xport_cur->now_ms(xport_cur->arg);

		if (now >= end)
			break;
		if (kshim_pump((int)(end - now)) < 0) {
			rv = EIO;
			break;
		}
	}
	if (cv->gen != gen)
		rv = 0;
	mutex_enter(m);
	return (rv);
}
