/*
 * Forced-include prelude for compiling the vendored OpenBSD net80211 sources
 * against illumos. Analogous to iwx/compat/sys/iwx_prelude.h but for the
 * net80211 build, which needs a WIDER compat surface than the driver: net80211
 * uses OpenBSD-kernel primitives (ISSET, arc4random, ratecheck, ...), the mbuf
 * API at 8.4x the driver's volume, and the ifmedia / ether / ifnet stack model
 * that illumos lacks entirely (FINDINGS.md Finding 2).
 *
 * Order matters: BSD scalar aliases and the queue/tree macros first (via the
 * iwx prelude), then the mbuf adapter so mtod()/m_freem() are macros before any
 * net80211 body is parsed, then the net80211-specific shims.
 *
 * Nothing here links a module. It establishes the compile+structure surface so
 * the 43 blocking ieee80211_* symbols can be produced as real .o text symbols.
 */
#ifndef _N80211_PRELUDE_H
#define _N80211_PRELUDE_H

#include <sys/iwx_prelude.h>		/* BSD types, queue/tree, spl/refcnt/timeout */
#include <sys/mbuf.h>			/* struct mbuf->msgb alias, mbuf_list/mbuf_queue */
#include "iwx_mbuf_adapter.h"		/* mtod, m_freem, m_pullup, m_adj -> mblk */
#include <sys/n80211_mbuf.h>		/* MGET/MGETHDR/MCLGET/M_PREPEND alloc adapter */
#include <sys/n80211_mcookie.h>		/* ph_cookie peek/clear for the pwrsave purge */
#include <sys/n80211_compat.h>		/* ISSET, arc4random, ratecheck, IFQ_MAXLEN */
#include <net80211/n80211_stack.h>	/* ether, if_, ifmedia stack shims */

#endif /* _N80211_PRELUDE_H */
