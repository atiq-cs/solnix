/*
 * OpenBSD <sys/mbuf.h> stand-in for iwx.
 *
 * The real translation is iwx_mbuf.c, which uses mblk_t directly and has its own
 * unit checks. This header does two things and no more:
 *
 *  1. ALIASES THE TYPE NAME so `struct mbuf *` IS `mblk_t *`. This is safe --
 *     see the argument below -- and it is what lets the driver's own locals,
 *     parameters and struct members carry the illumos currency unchanged.
 *  2. Leaves every FIELD name undefined, so each field access remains a hard
 *     compile error naming its own line.
 *
 * The distinction is the whole safety property: a TYPE alias cannot silently
 * change the meaning of an assignment, a FIELD alias can and does (see
 * iwx_mbuf_adapter.h -- `m->m_len = len` through a #define writes a length into
 * a pointer).
 */
#ifndef _IWX_COMPAT_SYS_MBUF_H
#define _IWX_COMPAT_SYS_MBUF_H
#include <sys/stream.h>
#include <sys/strsun.h>

/*
 * WHY THIS ALIAS IS SOUND, and why it is not the dangerous kind.
 *
 * illumos's mblk_t is `struct msgb`, so aliasing the STRUCT TAG makes every
 * `struct mbuf *` in if_iwx.c and if_iwxvar.h an `mblk_t *` with no cast and no
 * wrapper. Two facts, both measured on the vendored source, make it safe:
 *
 *   - There is no `sizeof(struct mbuf)` and no by-value use anywhere in
 *     if_iwx.c / if_iwxvar.h. All 20 occurrences of the tag are POINTER
 *     declarations (8 prototypes, 5 locals, 2 struct members, 5 definitions).
 *     A layout difference therefore cannot be observed.
 *   - `struct msgb` has none of OpenBSD's field names (m_len, m_data,
 *     m_pkthdr, m_ext, m_flags), so every field access is STILL a hard error,
 *     now phrased "struct msgb has no member named m_len". The incomplete-type
 *     property was only ever a means to that end, and the alias keeps the end
 *     while removing the pointer-assignment noise that hid it.
 *
 * DELIBERATELY NOT, and this remains the rule that matters:
 *     #define m_len  b_wptr        <-- NEVER
 *     #define m_data b_rptr        <-- NEVER
 */
#define mbuf	msgb
/* mbuf_list / mbuf_queue live in iwx_mlist.h, which is force-included. */
#include "iwx_mlist.h"

#define MCLBYTES	2048
#define MT_DATA		1
#define M_DONTWAIT	0
#define M_WAIT		1
#define M_WAITOK	1
#define M_NOWAIT	0
#define M_CANFAIL	0
#define M_ZERO		0x0100
#define M_DEVBUF	2
#define M_EXT		0x0001
#define M_PKTHDR	0x0002
#define M_COPYALL	1000000000
#endif
