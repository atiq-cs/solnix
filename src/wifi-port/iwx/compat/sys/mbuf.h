/*
 * OpenBSD <sys/mbuf.h> stand-in for iwx.
 *
 * MEASUREMENT SCAFFOLD, tagged STUB. This does NOT implement mbufs. It exists
 * to let if_iwx.c reach the compiler so the residual error surface can be
 * COUNTED rather than estimated. The real translation is iwx_mbuf.c, which uses
 * mblk_t directly and has its own unit checks; each site here must be rewritten
 * to call that, not to include this.
 */
#ifndef _IWX_COMPAT_SYS_MBUF_H
#define _IWX_COMPAT_SYS_MBUF_H
#include <sys/stream.h>
#include <sys/strsun.h>

/*
 * DELIBERATELY NOT: #define mbuf mblk_t.
 * struct mbuf is left an INCOMPLETE TYPE so every dereference of an OpenBSD
 * mbuf field is a hard compile error naming its own line. That is the point:
 * the alternative compiles and corrupts packets.
 */
struct mbuf;
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
