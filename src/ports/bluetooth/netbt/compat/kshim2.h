/*
 * kshim2.h: locks, sleeping, soft interrupts, timers, credentials and time
 * for the netbt core in userland (solnix, new code). Part 2 of kshim.h.
 */
#ifndef _SOLNIX_NETBT_KSHIM2_H
#define	_SOLNIX_NETBT_KSHIM2_H

/* ---- mutexes: one thread, so a mutex is a "held" flag that checks its use ---- */
typedef struct kshim_mutex {
	int		held;
	const char	*name;
} kmutex_t;
#define	MUTEX_DRIVER	0
#define	IPL_SOFTNET	0
#define	IPL_NONE	0
void kshim_mutex_init(kmutex_t *, const char *);
void kshim_mutex_enter(kmutex_t *, const char *, int);
void kshim_mutex_exit(kmutex_t *, const char *, int);
int kshim_mutex_owned(kmutex_t *);
#define	mutex_init(m, t, ipl)	kshim_mutex_init((m), #m)
#define	mutex_destroy(m)	((void)(m))
#define	mutex_enter(m)		kshim_mutex_enter((m), __FILE__, __LINE__)
#define	mutex_exit(m)		kshim_mutex_exit((m), __FILE__, __LINE__)
#define	mutex_owned(m)		kshim_mutex_owned(m)
#define	mutex_obj_hold(m)	((void)(m))

/* ---- condition variables ---- */
typedef struct kshim_cv {
	unsigned	gen;	/* bumped by cv_broadcast; the waiter watches it */
	const char	*name;
} kcondvar_t;
#define	cv_init(cv, n)		((void)((cv)->gen = 0, (cv)->name = (n)))
#define	cv_destroy(cv)		((void)(cv))
#define	cv_broadcast(cv)	((cv)->gen++)
#define	cv_signal(cv)		((cv)->gen++)
/*
 * NetBSD semantics: relative timeout in ticks; returns 0 when woken,
 * EWOULDBLOCK on timeout, EINTR/ERESTART on a signal. The illumos kernel
 * flavour maps this to cv_reltimedwait_sig (plan 2.3); here it pumps events.
 */
int kshim_cv_timedwait_sig(kcondvar_t *, kmutex_t *, int);
#define	cv_timedwait_sig	kshim_cv_timedwait_sig

/* ---- clock: hz ticks; the pump owns time (virtual under a fixture) ---- */
#define	hz		100
void kshim_microtime(struct timeval *);
#define	microtime	kshim_microtime

/* ---- soft interrupts: run by the pump, never re-entrantly ---- */
#define	SOFTINT_NET	0
void *kshim_softint_establish(int, void (*)(void *), void *);
void kshim_softint_schedule(void *);
void kshim_softint_disestablish(void *);
#define	softint_establish	kshim_softint_establish
#define	softint_schedule	kshim_softint_schedule
#define	softint_disestablish	kshim_softint_disestablish

/*
 * ---- callout(9) ----
 * Only ACL links arm one (hci_link.c expiry). Phase 1 makes no links, so
 * scheduling one is STUB: it aborts, which is a loud "this path is not ported".
 */
typedef struct kshim_callout {
	void	(*fn)(void *);
	void	*arg;
	int	pending;
	int	invoking;
} callout_t;
#define	callout_init(c, f)	((void)((c)->fn = NULL, (c)->pending = (c)->invoking = 0))
#define	callout_setfunc(c, f, a)	((void)((c)->fn = (f), (c)->arg = (a)))
void kshim_callout_schedule(callout_t *, int);
#define	callout_schedule	kshim_callout_schedule
#define	callout_stop(c)		((void)((c)->pending = 0))
#define	callout_invoking(c)	((c)->invoking)
#define	callout_ack(c)		((c)->invoking = 0)
#define	callout_destroy(c)	((void)(c))

/* ---- kauth(9): userland runs as root; the kernel flavour uses secpolicy_net_config ---- */
typedef void *kauth_cred_t;
#define	KAUTH_DEVICE_BLUETOOTH_SETPRIV	0
#define	KAUTH_ARG(x)			((void *)(uintptr_t)(x))
#define	kauth_cred_get()		((kauth_cred_t)NULL)
#define	kauth_authorize_device(c, a, u, x, b, n)	0

/* ---- the global stack lock ---- */
extern kmutex_t *bt_lock;

#endif
