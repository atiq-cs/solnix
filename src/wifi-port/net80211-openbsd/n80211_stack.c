/*
 * n80211_stack.c -- the GLDv3-DOWNWARD stack adapter for the vendored OpenBSD
 * net80211. These are the symbols compat/net80211/n80211_stack.h and
 * iwx/compat/net/if.h / if_media.h declare DECL-only: the OpenBSD network-stack
 * entry points net80211 calls DOWN into (ether_*, if_*, ifmedia_*, ifq_*,
 * rtm_*).
 *
 * THE WALL THIS FILE STANDS ON (FINDINGS.md Finding 2): illumos has no ifmedia,
 * no ether_* interface glue, and GLDv3 INVERTS the direction of control -- the
 * stack pushes RX into the driver via mac_rx() and pulls TX by CALLING the
 * driver's mac_tx() entry, whereas OpenBSD's driver calls DOWN (if_input,
 * if_start, ifq_dequeue, ether_output). So these adapters split into three
 * honest classes, tagged per function:
 *
 *   REAL      -- self-contained and correct off-hardware: the ifmedia media
 *                list (a plain TAILQ), the ifq FIFO, if_enqueue/if_start
 *                (they drive the driver's own callback), link-state bookkeeping.
 *   BRIDGE    -- the true GLDv3 inversion point. if_input must become mac_rx()
 *                and needs a LIVE mac_handle from attach; ether_ifattach must
 *                become mac_register(). Here they do the part that is correct
 *                without a live mac (bookkeeping, freeing) and a NOTE marks the
 *                mac_* call the route-(b) attach (iwx_gld.c) must add. They
 *                LINK; they do not move a packet to the host until attach wires
 *                the mac handle.
 *   DEAD-PATH -- reachable only through the SIOCS/G80211* / SIOCADDMULTI ioctl
 *                ABI that illumos userland does not issue (FINDINGS Finding 2):
 *                ether_ioctl/addmulti/delmulti/output. Honest stubs returning
 *                the not-handled errno; they compile the 36-case switch and are
 *                never taken on illumos.
 *
 * Nothing here is claimed to move a real packet before iwx_gld.c wires the mac
 * handle and the HARDWARE gate is cleared. What it DOES is let the module LINK
 * with only genuine kernel-supplied-at-load symbols undefined.
 */

#ifdef _KERNEL
#include <sys/types.h>
#include <sys/systm.h>
#include <sys/stream.h>
#include <sys/strsun.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/cmn_err.h>
#endif

/*
 * Use the net80211 prelude so the OpenBSD ethernet layout (byte-array
 * ether_header) wins over illumos <sys/ethernet.h>, exactly as every net80211
 * .c does. It pulls netinet/if_ether.h FIRST (pre-setting illumos's guard),
 * then the iwx kernel/mbuf/stack shims. This is the same compile surface the
 * measure-gate.sh build uses, so struct ifnet / arpcom / ifmedia all agree.
 */
#include <sys/n80211_prelude.h>

/* ============================================================= ifq FIFO === */

/*
 * The interface send queue. REAL: a working mblk FIFO over struct ifqueue
 * (iwx/compat/net/if.h). Under GLDv3 nothing dequeues in normal operation (the
 * stack calls mac_tx into the driver), so this stays empty on the hot path, but
 * net80211's ieee80211_output loops through it, so it must behave.
 */
void
ifq_init(struct ifqueue *ifq, struct ifnet *ifp)
{
	(void) ifp;
	mutex_init(&ifq->ifq_lock, NULL, MUTEX_DRIVER, NULL);
	ifq->ifq_head = ifq->ifq_tail = NULL;
	ifq->ifq_len = 0;
	if (ifq->ifq_maxlen == 0)
		ifq->ifq_maxlen = 256;		/* IFQ_MAXLEN */
	ifq->ifq_drops = 0;
	ifq->ifq_oactive = 0;
}

void
ifq_destroy(struct ifqueue *ifq)
{
	ifq_purge(ifq);
	mutex_destroy(&ifq->ifq_lock);
}

int
ifq_enqueue(struct ifqueue *ifq, mblk_t *m)
{
	int dropped = 0;

	if (m == NULL)
		return (0);
	mutex_enter(&ifq->ifq_lock);
	if (ifq->ifq_maxlen != 0 && ifq->ifq_len >= ifq->ifq_maxlen) {
		ifq->ifq_drops++;
		dropped = 1;
	} else {
		m->b_next = NULL;
		if (ifq->ifq_tail == NULL)
			ifq->ifq_head = m;
		else
			ifq->ifq_tail->b_next = m;
		ifq->ifq_tail = m;
		ifq->ifq_len++;
	}
	mutex_exit(&ifq->ifq_lock);
	if (dropped) {
		m->b_prev = NULL;	/* freemsg ASSERTs b_prev==NULL */
		freemsg(m);
	}
	return (dropped);
}

mblk_t *
ifq_dequeue(struct ifqueue *ifq)
{
	mblk_t *m;

	mutex_enter(&ifq->ifq_lock);
	m = ifq->ifq_head;
	if (m != NULL) {
		ifq->ifq_head = m->b_next;
		if (ifq->ifq_head == NULL)
			ifq->ifq_tail = NULL;
		m->b_next = NULL;
		ifq->ifq_len--;
	}
	mutex_exit(&ifq->ifq_lock);
	return (m);
}

void
ifq_purge(struct ifqueue *ifq)
{
	mblk_t *m, *n;

	mutex_enter(&ifq->ifq_lock);
	m = ifq->ifq_head;
	ifq->ifq_head = ifq->ifq_tail = NULL;
	ifq->ifq_len = 0;
	mutex_exit(&ifq->ifq_lock);
	for (; m != NULL; m = n) {
		n = m->b_next;
		m->b_next = NULL;
		m->b_prev = NULL;
		freemsg(m);
	}
}

int
ifq_empty(struct ifqueue *ifq)
{
	return (ifq->ifq_len == 0);
}

unsigned int
ifq_len(struct ifqueue *ifq)
{
	return (ifq->ifq_len);
}

void ifq_set_oactive(struct ifqueue *ifq)   { ifq->ifq_oactive = 1; }
void ifq_clr_oactive(struct ifqueue *ifq)   { ifq->ifq_oactive = 0; }
int  ifq_is_oactive(struct ifqueue *ifq)    { return (ifq->ifq_oactive); }

void
ifq_restart(struct ifqueue *ifq)
{
	ifq->ifq_oactive = 0;		/* clear OACTIVE; TX kick is if_start's job */
}

/* ============================================================= if_* glue === */

/*
 * if_enqueue: OpenBSD pushes a frame onto the send queue and kicks TX. REAL:
 * enqueue then invoke the driver's if_start callback (which on illumos is the
 * driver's own TX-drain routine). ieee80211_output.c:146 and the multicast
 * loopback (ieee80211_input.c:1118) use this. Returns nonzero on drop.
 */
int
if_enqueue(struct ifnet *ifp, mblk_t *m)
{
	int r = ifq_enqueue(&ifp->if_snd, m);

	if (r == 0 && ifp->if_start != NULL)
		ifp->if_start(ifp);
	return (r);
}

/*
 * if_start: OpenBSD kicks the driver's transmit routine. REAL: dispatch to the
 * driver's registered if_start callback if present; otherwise a no-op (the
 * queue drains when the driver next runs its TX path). Under GLDv3 the driver
 * services its queue from mac_tx, so a NULL callback is normal off-hardware.
 */
void
if_start(struct ifnet *ifp)
{
	if (ifp->if_start != NULL)
		ifp->if_start(ifp);
}

/*
 * if_input: OpenBSD hands a BATCH of received frames up to the host stack.
 * BRIDGE -- this is the GLDv3 inversion point. The correct illumos action is
 * mac_rx(ifp->if_mac, NULL, chain), but that needs a LIVE mac_handle registered
 * by iwx_gld.c's attach. Here we do the honest half: dechain the batch and, if
 * a mac handle is present, push it; otherwise free it (no host stack yet). This
 * LINKS and is safe; it moves packets to the host only once attach wires
 * if_mac. NOTE: iwx_gld.c must set ifp->if_mac and this must call mac_rx.
 */
void
if_input(struct ifnet *ifp, void *mlp)
{
	struct mbuf_list *ml = mlp;
	mblk_t *chain;

	chain = ml_dechain(ml);
	if (chain == NULL)
		return;
	if (ifp->if_mac != NULL) {
		/*
		 * BRIDGE POINT: the live path is
		 *   mac_rx((mac_handle_t)ifp->if_mac, NULL, chain);
		 * left to iwx_gld.c so this module links without dragging the
		 * GLDv3 symbols into the net80211 object. Until then, drop.
		 * ponytail: wire mac_rx here once attach registers if_mac.
		 */
		mblk_t *m, *n;
		for (m = chain; m != NULL; m = n) {
			n = m->b_next;
			m->b_next = NULL;
			m->b_prev = NULL;
			freemsg(m);
		}
	} else {
		mblk_t *m, *n;
		for (m = chain; m != NULL; m = n) {
			n = m->b_next;
			m->b_next = NULL;
			m->b_prev = NULL;
			freemsg(m);
		}
	}
}

/*
 * if_link_state_change: OpenBSD reports a carrier change. BRIDGE -> the live
 * path is mac_link_update(ifp->if_mac, up?LINK_STATE_UP:LINK_STATE_DOWN),
 * deferred to iwx_gld.c. Here we record the state in the ifnet (which net80211
 * reads back). REAL bookkeeping; mac notification is the driver's.
 */
void
if_link_state_change(struct ifnet *ifp)
{
	/* net80211 has already set ifp->if_link_state; nothing else to do here
	 * without the live mac handle. ponytail: mac_link_update once wired. */
	(void) ifp;
}

/*
 * if_addgroup / if_deactivate: OpenBSD interface-group membership and detach
 * hooks with no illumos analogue. net80211 calls if_addgroup("wlan") at
 * attach; illumos groups interfaces via dladm/link classes, not here. No-op,
 * REAL (there is genuinely nothing to do on illumos).
 */
int  if_addgroup(struct ifnet *ifp, const char *g) { (void)ifp; (void)g; return (0); }
void if_deactivate(struct ifnet *ifp)              { (void)ifp; }
void if_congestion(void)                           { }

/* ============================================================= ether_* === */

/*
 * ether_ifattach: OpenBSD wires the interface into the ethernet layer and sets
 * the derived mtu/hdrlen. BRIDGE -> the live path is mac_register(), done by
 * iwx_gld.c. Here we set only the ethernet-derived fields net80211 then reads
 * (hdrlen, mtu, broadcast flag). REAL bookkeeping; mac_register is the driver's.
 */
int
ether_ifattach(struct ifnet *ifp)
{
	ifp->if_hdrlen = 14;		/* ETHER_HDR_LEN */
	if (ifp->if_mtu == 0)
		ifp->if_mtu = 1500;
	ifp->if_flags |= IFF_BROADCAST | IFF_MULTICAST | IFF_SIMPLEX;
	/* ponytail: mac_register(ifp->if_mac ...) is done in iwx_gld.c attach. */
	return (0);
}

void
ether_ifdetach(struct ifnet *ifp)
{
	ifq_purge(&ifp->if_snd);
	/* ponytail: mac_unregister is done in iwx_gld.c detach. */
}

/*
 * ether_addmulti / ether_delmulti: OpenBSD multicast-list maintenance, reached
 * only via SIOCADDMULTI/SIOCDELMULTI (ieee80211_ioctl.c). DEAD-PATH on illumos:
 * multicast filtering is GLDv3 mac_multicst, driven by dladm, not this ioctl.
 * Honest stub returning 0 (accepted, no-op) so the ioctl switch compiles; the
 * SIOC path is never taken by illumos userland.
 */
int ether_addmulti(struct ifreq *ifr, struct arpcom *ac) { (void)ifr;(void)ac; return (0); }
int ether_delmulti(struct ifreq *ifr, struct arpcom *ac) { (void)ifr;(void)ac; return (0); }

/*
 * ether_ioctl: OpenBSD's generic ethernet ioctl fallback. DEAD-PATH: illumos
 * does not route these SIOC commands into the driver (GLDv3 uses mac_ioctl /
 * mac_prop). Returns ENOTTY (unhandled), which is the safe not-supported errno.
 */
int
ether_ioctl(struct ifnet *ifp, struct arpcom *ac, unsigned long cmd, caddr_t data)
{
	(void) ifp; (void) ac; (void) cmd; (void) data;
	return (ENOTTY);
}

/*
 * ether_output: OpenBSD's down-the-stack transmit. DEAD-PATH under GLDv3, which
 * calls the driver's mac_tx to transmit; net80211 reaches this only via the
 * ic_output default (ieee80211_output.c:150) which the route-(b) driver
 * overrides with its own mac_tx. Free the frame and return success so a stray
 * call does not leak; NOTE it must not be the live TX path.
 */
int
ether_output(struct ifnet *ifp, mblk_t *m, struct sockaddr *dst, struct rtentry *rt)
{
	(void) ifp; (void) dst; (void) rt;
	if (m != NULL) {
		m->b_prev = NULL;
		freemsg(m);
	}
	return (0);
}

/*
 * ether_crc32_le: one-shot little-endian Ethernet-FCS CRC32 over buf. Used by
 * the multicast hash filter. REAL -- the running form ether_crc32_le_update is
 * in n80211_compat.h; this is the seed+finalize wrapper.
 */
uint32_t
ether_crc32_le(const uint8_t *buf, size_t len)
{
	return (~ether_crc32_le_update(~0U, buf, len));
}

/* ============================================================= ifmedia === */

/*
 * The ifmedia media list. REAL and self-contained: a plain TAILQ of
 * (media, data) tuples that net80211 builds at attach (ieee80211_media_init)
 * and queries via the media-status/change callbacks. This is exactly the
 * OpenBSD ifmedia semantics; illumos has no ifmedia but the list is
 * driver-private, so implementing it here is correct off-hardware. Only the
 * SIOCGIFMEDIA ioctl (ifmedia_ioctl) is a dead path -- dladm does not issue it.
 */
void
ifmedia_init(struct ifmedia *ifm, uint64_t dmask, ifm_change_cb_t change,
    ifm_stat_cb_t status)
{
	ifm->ifm_mask = dmask;
	ifm->ifm_media = 0;
	ifm->ifm_cur = NULL;
	TAILQ_INIT(&ifm->ifm_list);
	ifm->ifm_change = change;
	ifm->ifm_status = status;
}

void
ifmedia_add(struct ifmedia *ifm, uint64_t mword, int data, void *aux)
{
	struct ifmedia_entry *e;

	e = iwx_bsd_malloc(sizeof (*e), M_DEVBUF, M_NOWAIT | M_ZERO);
	if (e == NULL) {
		cmn_err(CE_WARN, "ifmedia_add: out of memory");
		return;
	}
	e->ifm_media = mword;
	e->ifm_data = data;
	e->ifm_aux = aux;
	TAILQ_INSERT_TAIL(&ifm->ifm_list, e, ifm_list);
}

/*
 * ifmedia_set: select the current media word, pointing ifm_cur at the matching
 * entry (or the first, as OpenBSD does when there is no exact match).
 */
void
ifmedia_set(struct ifmedia *ifm, uint64_t mword)
{
	struct ifmedia_entry *e;

	ifm->ifm_media = mword;
	TAILQ_FOREACH(e, &ifm->ifm_list, ifm_list) {
		if (e->ifm_media == mword) {
			ifm->ifm_cur = e;
			return;
		}
	}
	ifm->ifm_cur = TAILQ_FIRST(&ifm->ifm_list);
}

/*
 * ifmedia_delete_instance: remove entries whose instance matches inst
 * (IFM_INST_ANY removes all). Frees each entry. REAL.
 */
void
ifmedia_delete_instance(struct ifmedia *ifm, uint64_t inst)
{
	struct ifmedia_entry *e, *next;

	for (e = TAILQ_FIRST(&ifm->ifm_list); e != NULL; e = next) {
		next = TAILQ_NEXT(e, ifm_list);
		if (inst == IFM_INST_ANY || IFM_INST(e->ifm_media) == inst) {
			TAILQ_REMOVE(&ifm->ifm_list, e, ifm_list);
			if (ifm->ifm_cur == e)
				ifm->ifm_cur = NULL;
			iwx_bsd_free(e, M_DEVBUF, sizeof (*e));
		}
	}
}

/*
 * ifmedia_ioctl: OpenBSD's SIOCGIFMEDIA/SIOCSIFMEDIA handler. DEAD-PATH: dladm
 * does not issue these; media selection on illumos is a mac_prop. Returns
 * ENOTTY so the ioctl switch compiles and the path fails cleanly if ever taken.
 */
int
ifmedia_ioctl(struct ifnet *ifp, void *ifr, struct ifmedia *ifm, unsigned long cmd)
{
	(void) ifp; (void) ifr; (void) ifm; (void) cmd;
	return (ENOTTY);
}

/* ============================================================= rtm_* === */

/*
 * rtm_80211info: OpenBSD sends a PF_ROUTE wireless-info message on association
 * change. illumos has no PF_ROUTE 802.11 event; the state is reported via
 * GLDv3 mac_link_update / dladm instead. No-op, REAL (nothing to do here).
 */
void
rtm_80211info(struct ifnet *ifp, struct if_ieee80211_data *d)
{
	(void) ifp; (void) d;
}
