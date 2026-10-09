/*
 * n80211_layout.c -- compile-time proof that n80211_giant.h (the GLDv3-side
 * view) and the N80211_GIANT compat structs (../iwx/compat/sys/iwx_kernel.h,
 * the OpenBSD-side view) describe the same memory. No code; a mismatch is a
 * build error here. Built in the compat world with -DN80211_GIANT.
 */
#include <sys/iwx_kernel.h>
#include <sys/debug.h>
#include <sys/sysmacros.h>

CTASSERT(sizeof (struct task) == 48);	/* N80211_SIZEOF_TASK */
CTASSERT(offsetof(struct task, t_state) == 16);
CTASSERT(offsetof(struct task, t_tq) == 24);
CTASSERT(offsetof(struct task, t_entry) == 32);
CTASSERT(sizeof (struct timeout) == 48);	/* N80211_SIZEOF_TIMEOUT */
CTASSERT(offsetof(struct timeout, to_pending) == 24);
CTASSERT(offsetof(struct timeout, to_seq) == 32);
CTASSERT(offsetof(struct timeout, to_token) == 40);
CTASSERT(sizeof (struct rwlock) == sizeof (void *));
CTASSERT(sizeof (struct refcnt) == 4);
CTASSERT(LINK_STATE_UP == 4);	/* N80211_OBSD_LINK_STATE_UP */
