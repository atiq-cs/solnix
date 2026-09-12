/*
 * OpenBSD <net/if.h> -> a driver-local struct ifnet, plus the ifqueue the
 * driver's TX path drains.
 *
 * WHY A LOCAL STRUCT AND NOT illumos's ifnet: illumos net/if.h exists but its
 * `struct ifnet` is the old 4.3BSD socket-layer one, not a driver interface --
 * a GLDv3 driver never sees an ifnet at all, it registers a mac_register_t and
 * receives packets as mblk_t chains. So there is no illumos ifnet to map onto,
 * and the honest translation is:
 *
 *   - keep a driver-local struct ifnet holding exactly the 11 fields if_iwx.c
 *     touches, so the 70-odd member accesses compile unchanged, and
 *   - bridge the 3 real functions (if_attach, if_input, if_setlladdr) to
 *     mac_register / mac_rx / mac_unicst_update in iwx_gld.c.
 *
 * The counters (if_ierrors/if_oerrors) are read by GLDv3's mac_stat handler
 * rather than by an ifnet consumer, so they stay plain fields here and are
 * reported out from iwx_gld.c.
 *
 * ⚠ if_snd/ifq_*: OpenBSD's driver pulls its own TX queue with ifq_dequeue in
 * iwx_start(). GLDv3 instead CALLS the driver's mac_tx entry point with an mblk
 * chain, so nothing dequeues. The ifqueue below is therefore a real, working
 * mblk FIFO (so iwx_start's loop compiles AND behaves), but under GLDv3 it stays
 * empty in normal operation. Keeping the queue rather than deleting the loop
 * means the OpenBSD control flow is preserved for a later diff against upstream.
 *
 * STATUS: struct + queue REAL. if_attach/if_input/if_setlladdr are declared
 * here and implemented in iwx_gld.c.
 */
#ifndef _IWX_COMPAT_NET_IF_H
#define _IWX_COMPAT_NET_IF_H

#include <sys/types.h>
#include <sys/stream.h>
#include <sys/ksynch.h>

#define IFNAMSIZ	16

/* Bits if_iwx.c tests and sets on if_flags. */
#define IFF_UP		0x0001
#define IFF_BROADCAST	0x0002
#define IFF_DEBUG	0x0004
#define IFF_RUNNING	0x0040
#define IFF_PROMISC	0x0100
#define IFF_ALLMULTI	0x0200
#define IFF_OACTIVE	0x0400
#define IFF_SIMPLEX	0x0800
#define IFF_MULTICAST	0x8000

struct ifnet;

/*
 * A real mblk FIFO. OpenBSD's ifqueue also carries a drop counter and a maxlen
 * that the stack enforces; both are kept because iwx reads them.
 */
struct ifqueue {
	kmutex_t	ifq_lock;
	mblk_t		*ifq_head;
	mblk_t		*ifq_tail;
	unsigned int	ifq_len;
	unsigned int	ifq_maxlen;
	unsigned int	ifq_drops;
	unsigned int	ifq_oactive;
};

struct ifnet {
	char		if_xname[IFNAMSIZ];
	void		*if_softc;
	unsigned int	if_flags;
	int		if_timer;		/* watchdog countdown, seconds */
	unsigned long	if_ierrors;
	unsigned long	if_oerrors;
	unsigned long	if_ipackets;
	unsigned long	if_opackets;
	unsigned long	if_ibytes;
	unsigned long	if_obytes;
	struct ifqueue	if_snd;
	void		*if_bpf;		/* always NULL: see compat/net/bpf.h */
	void		(*if_start)(struct ifnet *);
	void		(*if_watchdog)(struct ifnet *);
	int		(*if_ioctl)(struct ifnet *, unsigned long, caddr_t);
	int		(*if_output)(struct ifnet *, mblk_t *, void *, void *);
	unsigned int	if_hardmtu;
	uint8_t		if_lladdr[6];
	void		*if_mac;		/* mac_handle_t, opaque here */
};

/* OpenBSD ifq API. Implemented in iwx_gld.c against the FIFO above. */
extern void ifq_init(struct ifqueue *, struct ifnet *);
extern void ifq_destroy(struct ifqueue *);
extern mblk_t *ifq_dequeue(struct ifqueue *);
extern int ifq_enqueue(struct ifqueue *, mblk_t *);
extern void ifq_purge(struct ifqueue *);
extern int ifq_empty(struct ifqueue *);
extern unsigned int ifq_len(struct ifqueue *);
extern void ifq_set_oactive(struct ifqueue *);
extern void ifq_clr_oactive(struct ifqueue *);
extern int ifq_is_oactive(struct ifqueue *);
extern void ifq_restart(struct ifqueue *);

/* The 3 real ifnet functions, bridged to GLDv3 in iwx_gld.c. */
extern int if_attach(struct ifnet *);
extern void if_detach(struct ifnet *);
extern void if_input(struct ifnet *, void *ml);
extern int if_setlladdr(struct ifnet *, const uint8_t *);

#endif /* _IWX_COMPAT_NET_IF_H */
