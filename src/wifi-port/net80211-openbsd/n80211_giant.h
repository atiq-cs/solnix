/*
 * n80211_giant.h -- the compat structs n80211_giant.c implements, declared
 * WITHOUT the OpenBSD prelude.
 *
 * n80211_giant.c calls GLDv3 (mac_rx, mac_link_update), and <sys/mac.h>
 * defines LINK_STATE_UP/DOWN as the link_state_t enum, which the OpenBSD
 * compat headers redefine as different integers. So that file cannot include
 * both worlds. These declarations must stay layout-identical to the
 * N80211_GIANT branches in ../iwx/compat/sys/iwx_kernel.h; n80211_layout.c
 * (compiled in the compat world) checks the sizes and offsets that matter
 * with CTASSERTs, so a drift is a build error rather than a corrupt struct.
 */
#ifndef _N80211_GIANT_H
#define _N80211_GIANT_H

#include <sys/types.h>
#include <sys/ksynch.h>
#include <sys/queue.h>

#define PCATCH		0x100
#define INFSLP		UINT64_MAX
#define RW_INTR		0

/*
 * OpenBSD's struct task. illumos already has a struct task (the project/
 * resource-control task, <sys/task.h>, reached through <sys/proc.h>, which
 * this file needs for thread_create/p0), so the OpenBSD one is named
 * obsd_task here. Same layout; the symbols task_add/task_del/... take a
 * pointer, so the tag does not reach the ABI.
 */
struct taskq;
struct obsd_task {
	void	(*t_func)(void *);
	void	*t_arg;
	volatile unsigned int t_state;
	struct taskq *t_tq;
	TAILQ_ENTRY(obsd_task) t_entry;
};

struct timeout {
	timeout_id_t	to_id;
	void		(*to_func)(void *);
	void		*to_arg;
	volatile int	to_pending;
	uint64_t	to_seq;
	void		*to_token;
};

struct rwlock {
	void		*rwl_owner;
};

struct refcnt {
	volatile uint32_t r_refs;
};

/* OpenBSD link-state values, as compat/net/if.h defines them. */
#define N80211_OBSD_LINK_STATE_UP	4

int tsleep_nsec(const void *, int, const char *, uint64_t);
void wakeup(const void *);
void timeout_set(struct timeout *, void (*)(void *), void *);
int timeout_del(struct timeout *);

/* sizes the compat world must agree with (checked in n80211_layout.c) */
#define N80211_SIZEOF_TASK	48
#define N80211_SIZEOF_TIMEOUT	48

#endif /* _N80211_GIANT_H */
