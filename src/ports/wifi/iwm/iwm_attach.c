/*
 * iwm_attach.c -- illumos DDI + GLDv3 glue around the vendored OpenBSD iwm(4).
 *
 * This is the illumos half of the driver. It does NOT re-implement attach:
 * it builds an OpenBSD struct pci_attach_args from the dev_info_t and calls
 * the unmodified OpenBSD iwm_attach() (if_iwm.c:11709), so the device table,
 * firmware selection, ring allocation, interrupt setup, ieee80211_ifattach
 * and the deferred MAC-address read (config_mountroot -> iwm_attach_hook ->
 * iwm_preinit) all run as OpenBSD wrote them. Shapes taken from iwx_attach.c
 * (DDI skeleton) and illumos iwn (if_iwn.c: mac_callbacks, wifi plugin).
 *
 * Every entry from illumos into OpenBSD code takes the giant lock
 * (net80211/n80211_giant.c); see that file for why one lock is the
 * faithful translation of OpenBSD's KERNEL_LOCK model.
 *
 * GLDv3 surface, tagged:
 *   REAL  attach/detach/quiesce, mac_register (wifi plugin, MAC from the
 *         firmware NVM), mc_start/mc_stop -> SIOCSIFFLAGS IFF_UP via
 *         iwm_ioctl (so firmware load + scan start run the OpenBSD path),
 *         mc_tx -> if_snd + iwm_start, mc_unicst/multicst/promisc accept.
 *   GATED mc_ioctl/mc_setprop/mc_getprop: illumos wifi config (dladm
 *         scan-wifi / connect-wifi) speaks WLDP_* properties and the
 *         WLAN_GET_PARAM ioctls of <sys/net80211.h>, which have no OpenBSD
 *         net80211 counterpart yet. They fail closed (ENOTSUP / miocnak)
 *         until the WLDP bridge is written. Named, not faked.
 *
 * NOTE: one radio per machine is assumed by the giant lock (see
 * n80211_giant.c) and by the "iwm0" naming; the soft state is still
 * per-instance so the DDI side is correct for more.
 */

/*
 * Same include sequence as if_iwm.c:83-113 (and the same forced-include
 * prelude and mbuf adapter, from the build), so struct iwm_softc has the
 * identical layout in both translation units.
 */
#include <sys/param.h>
#include <sys/malloc.h>
#include <sys/mbuf.h>
#include <sys/rwlock.h>
#include <sys/socket.h>
#include <sys/sockio.h>
#include <sys/systm.h>
#include <sys/endian.h>
#include <sys/refcnt.h>
#include <sys/task.h>
#include <machine/bus.h>
#include <machine/intr.h>
#include <dev/pci/pcireg.h>
#include <dev/pci/pcivar.h>
#include <dev/pci/pcidevs.h>
#include <net/if.h>
#include <net/if_media.h>
#include <netinet/in.h>
#include <netinet/if_ether.h>
#include <net80211/ieee80211_var.h>
#include <net80211/ieee80211_amrr.h>
#include <net80211/ieee80211_ra.h>
#include <net80211/ieee80211_ra_vht.h>
#include <net80211/ieee80211_radiotap.h>
#define IC2IFP(_ic_) (&(_ic_)->ic_if)
#define le16_to_cpup(_a_) (le16toh(*(const uint16_t *)(_a_)))
#define le32_to_cpup(_a_) (le32toh(*(const uint32_t *)(_a_)))
#include <dev/pci/if_iwmreg.h>
#include <dev/pci/if_iwmvar.h>

#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/modctl.h>
#include <sys/conf.h>
#include <sys/pci.h>
#include <sys/stat.h>
#include <sys/strsun.h>
#include <sys/strsubr.h>

/*
 * GLDv3 headers redefine LINK_STATE_* (link_state_t) and other names the
 * OpenBSD world owns, so the mac_* calls are made from iwm_gld.c, a separate
 * translation unit that sees only illumos headers. This file talks to it
 * through these four functions.
 */
extern int iwm_gld_register(dev_info_t *, void *, const uint8_t *, void **);
extern int iwm_gld_unregister(void *);
extern void *iwm_gld_mac_handle(void *);
extern void iwm_gld_init_ops(struct dev_ops *);
extern void iwm_gld_fini_ops(struct dev_ops *);

/* OpenBSD driver entry points (if_iwm.c). */
extern int iwm_match(struct device *, void *, void *);
extern void iwm_attach(struct device *, struct device *, void *);
extern int iwm_ioctl(struct ifnet *, u_long, caddr_t);
extern void iwm_start(struct ifnet *);
extern void iwm_stop(struct ifnet *);
extern int iwm_init(struct ifnet *);
extern void iwm_free_tx_ring(struct iwm_softc *, struct iwm_tx_ring *);
extern void iwm_free_rx_ring(struct iwm_softc *, struct iwm_rx_ring *);
extern void iwm_dma_contig_free(struct iwm_dma_info *);
extern void iwm_stop_device(struct iwm_softc *);
extern void iwm_disable_interrupts(struct iwm_softc *);

/* quiesce(9E): stop DMA and interrupts. Register writes and DELAY only. */
static void
iwm_quiesce_hw(struct iwm_softc *sc)
{
	iwm_disable_interrupts(sc);
	iwm_stop_device(sc);
}

/* Giant and runtime (n80211_giant.c). */
extern void n80211_giant_init(void);
extern void n80211_giant_fini(void);
extern void n80211_giant_enter(void);
extern void n80211_giant_exit(void);
extern void n80211_systq_init(void);
extern void n80211_systq_fini(void);

static void *iwm_state;			/* ddi_soft_state of struct iwm_il */

struct iwm_il {
	struct iwm_softc	*il_sc;		/* the OpenBSD softc */
	dev_info_t		*il_dip;
	ddi_acc_handle_t	il_pcih;
	struct iwx_bus_dma_tag	il_dmat;
	void			*il_gld;	/* iwm_gld.c state */
	int			il_mountroot_ran;
	int			il_registered;
};

/*
 * config_mountroot: OpenBSD defers iwm_attach_hook until the root file
 * system can serve /etc/firmware. On illumos the module path is readable at
 * attach (iwn loads its firmware from attach too), so the hook runs right
 * away, after iwm_attach returns, from iwm_il_attach below.
 */
static struct device	*iwm_mr_dev;
static void		(*iwm_mr_fn)(struct device *);

void
config_mountroot(struct device *dev, void (*fn)(struct device *))
{
	iwm_mr_dev = dev;
	iwm_mr_fn = fn;
}

/*
 * if_attach / if_setlladdr: the OpenBSD ifnet registration. The interface
 * is published to illumos by mac_register in iwm_il_attach, after the MAC
 * address is known, so if_attach only initialises the send queue and
 * if_setlladdr records the address (iwm_preinit, if_iwm.c:11673).
 */
extern void ifq_init(struct ifqueue *, struct ifnet *);

int
if_attach(struct ifnet *ifp)
{
	ifq_init(&ifp->if_snd, ifp);
	return (0);
}

/*
 * if_setlladdr records the MAC address. OpenBSD's if_setlladdr (net/if.c)
 * updates the arpcom's ac_enaddr as well as the link-layer address; mirror
 * that here. iwm_preinit runs once per bring-up (iwm_init), and on every call
 * after the first it refreshes ic_myaddr from ac_enaddr
 * (if_iwm.c iwm_preinit, "Update MAC in case the upper layers changed it").
 * ieee80211_ifattach seeds ac_enaddr from ic_myaddr while that is still zero
 * (the NVM MAC is not read until the deferred iwm_preinit), so unless
 * if_setlladdr also writes ac_enaddr, the second and later bring-ups copy a
 * stale zero back into ic_myaddr and every management frame goes out with
 * addr2 (the transmitter address) all zeros, which no AP answers. Keeping
 * ac_enaddr in sync, as OpenBSD does, preserves the real MAC across re-init.
 */
int
if_setlladdr(struct ifnet *ifp, const uint8_t *lladdr)
{
	bcopy(lladdr, ifp->if_lladdr, ETHER_ADDR_LEN);
	bcopy(lladdr, ((struct arpcom *)ifp)->ac_enaddr, ETHER_ADDR_LEN);
	return (0);
}

/* --------------------------------------------- GLDv3 callbacks (via gld) --- */

/* Called by iwm_gld.c; arg is the OpenBSD softc. */
int
iwm_il_start(void *arg)
{
	struct iwm_softc *sc = arg;
	struct ifnet *ifp = IC2IFP(&sc->sc_ic);
	int err;

	n80211_giant_enter();
	ifp->if_flags |= IFF_UP;
	err = iwm_ioctl(ifp, SIOCSIFFLAGS, NULL);
	n80211_giant_exit();
	return (err);
}

void
iwm_il_stop(void *arg)
{
	struct iwm_softc *sc = arg;
	struct ifnet *ifp = IC2IFP(&sc->sc_ic);

	n80211_giant_enter();
	ifp->if_flags &= ~IFF_UP;
	(void) iwm_ioctl(ifp, SIOCSIFFLAGS, NULL);
	n80211_giant_exit();
}

/*
 * mc_tx: the chain arrives as Ethernet frames (iwm_gld.c converted the wifi
 * plugin's 802.11+LLC header back, with headroom for ieee80211_encap's
 * M_PREPEND). Queue each on if_snd and run iwm_start, which dequeues,
 * encapsulates through net80211 and maps the frame, exactly the OpenBSD
 * if_enqueue path. Frames are dropped, not returned, when the link is not
 * associated, as illumos iwn does (if_iwn.c:4010-4013); returning them would
 * make mac retry a link that has no BSS.
 */
mblk_t *
iwm_il_tx(void *arg, mblk_t *mp)
{
	struct iwm_softc *sc = arg;
	struct ifnet *ifp = IC2IFP(&sc->sc_ic);
	mblk_t *next;

	n80211_giant_enter();
	if (!(ifp->if_flags & IFF_RUNNING) ||
	    sc->sc_ic.ic_state != IEEE80211_S_RUN) {
		n80211_giant_exit();
		freemsgchain(mp);
		return (NULL);
	}
	for (; mp != NULL; mp = next) {
		next = mp->b_next;
		mp->b_next = NULL;
		(void) ifq_enqueue(&ifp->if_snd, mp);	/* frees on overflow */
	}
	iwm_start(ifp);
	n80211_giant_exit();
	return (NULL);
}

/* ------------------------------------- WLDP bridge, OpenBSD-side half --- */

/*
 * The illumos side (iwm_gld.c) speaks WLDP (<inet/wifi_ioctl.h>) and cannot
 * see struct ieee80211com; this side cannot see WLDP. These functions read
 * and write OpenBSD net80211 state the way OpenBSD's own ieee80211_ioctl
 * does, and hand back the plain structs of iwm_il.h. Each expects giant held
 * (the caller is a GLDv3 entry point that took it).
 */
#include "iwm_il.h"

/* RSSI on the WLDP 0..15 scale, as illumos wifi_getrssi scales its own. */
static uint8_t
iwm_il_rssi(struct ieee80211com *ic, struct ieee80211_node *ni)
{
	uint32_t r = ni->ni_rssi, max = ic->ic_max_rssi;

	if (max == 0 || r == 0)
		return (0);
	if (r >= max)
		return (15);
	return ((uint8_t)(r * 15 / max + 1));
}

static void
iwm_il_fill_node(struct ieee80211com *ic, struct ieee80211_node *ni,
    struct iwm_il_node *n)
{
	int i, nr;

	bzero(n, sizeof (*n));
	IEEE80211_ADDR_COPY(n->n_bssid, ni->ni_bssid);
	n->n_esslen = MIN(ni->ni_esslen, sizeof (n->n_essid));
	bcopy(ni->ni_essid, n->n_essid, n->n_esslen);
	n->n_rssi = iwm_il_rssi(ic, ni);
	if (ni->ni_chan != NULL && ni->ni_chan != IEEE80211_CHAN_ANYC) {
		n->n_chan = (uint8_t)ieee80211_chan2ieee(ic, ni->ni_chan);
		n->n_freq = ni->ni_chan->ic_freq;
		n->n_5ghz = IEEE80211_IS_CHAN_5GHZ(ni->ni_chan) ? 1 : 0;
	}
	n->n_privacy = (ni->ni_capinfo & IEEE80211_CAPINFO_PRIVACY) ? 1 : 0;
	n->n_ess = (ni->ni_capinfo & IEEE80211_CAPINFO_ESS) ? 1 : 0;
	n->n_rsn = (ni->ni_rsnprotos != IEEE80211_PROTO_NONE) ? 1 : 0;
	n->n_ht = (ni->ni_flags & IEEE80211_NODE_HT) ? 1 : 0;
	nr = MIN(ni->ni_rates.rs_nrates, (int)sizeof (n->n_rates));
	for (i = 0; i < nr; i++)	/* highest first, as wifi_read_ap */
		n->n_rates[i] = ni->ni_rates.rs_rates[
		    ni->ni_rates.rs_nrates - i - 1] & IEEE80211_RATE_VAL;
	n->n_nrates = (uint8_t)nr;
}

void
iwm_il_getstate(void *arg, struct iwm_il_state *s)
{
	struct iwm_softc *sc = arg;
	struct ieee80211com *ic = &sc->sc_ic;
	struct ieee80211_node *ni = ic->ic_bss;

	bzero(s, sizeof (*s));
	s->s_running = (ic->ic_if.if_flags & IFF_RUNNING) ? 1 : 0;
	/* as illumos wl_get_linkstatus: with RSN, connected once keyed */
	s->s_connected = (ic->ic_state == IEEE80211_S_RUN) && (ni != NULL) &&
	    (!(ic->ic_flags & IEEE80211_F_RSNON) || ni->ni_port_valid);
	s->s_rsn = (ic->ic_flags & IEEE80211_F_RSNON) ? 1 : 0;
	/* SIOCG80211NWID (ieee80211_ioctl.c:511): desired until associated */
	if (ic->ic_state == IEEE80211_S_INIT ||
	    ic->ic_state == IEEE80211_S_SCAN || ni == NULL) {
		s->s_esslen = MIN(ic->ic_des_esslen, sizeof (s->s_essid));
		bcopy(ic->ic_des_essid, s->s_essid, s->s_esslen);
		if (ic->ic_flags & IEEE80211_F_DESBSSID)
			IEEE80211_ADDR_COPY(s->s_bssid, ic->ic_des_bssid);
	} else {
		s->s_esslen = MIN(ni->ni_esslen, sizeof (s->s_essid));
		bcopy(ni->ni_essid, s->s_essid, s->s_esslen);
		IEEE80211_ADDR_COPY(s->s_bssid, ni->ni_bssid);
		s->s_rssi = iwm_il_rssi(ic, ni);
		if (ni->ni_txrate >= 0 && ni->ni_txrate < ni->ni_rates.rs_nrates)
			s->s_rate = ni->ni_rates.rs_rates[ni->ni_txrate] &
			    IEEE80211_RATE_VAL;
	}
}

/* Copy the node tree (scan results) into n[0..max). Returns the count. */
int
iwm_il_nodes(void *arg, struct iwm_il_node *n, int max)
{
	struct iwm_softc *sc = arg;
	struct ieee80211com *ic = &sc->sc_ic;
	struct ieee80211_node *ni;
	int cnt = 0;

	RBT_FOREACH(ni, ieee80211_tree, &ic->ic_tree) {
		if (cnt >= max)
			break;
		/* the placeholder BSS node carries our own address */
		if (IEEE80211_ADDR_EQ(ni->ni_macaddr, ic->ic_myaddr))
			continue;
		if (ni->ni_esslen == 0 && ni->ni_rssi == 0)
			continue;
		iwm_il_fill_node(ic, ni, &n[cnt++]);
	}
	return (cnt);
}

/*
 * WL_SCAN. OpenBSD runs scans from iwm_init (IFF_UP) and never "finishes"
 * one without a target: ieee80211_end_scan with no candidate resets and
 * rescans forever, bumping ic_scan_count once per all-band pass
 * (ieee80211_node.c:1554-1560; iwm sets IEEE80211_C_SCANALLBAND,
 * if_iwm.c:11995). So: make sure the radio runs, wait until one more pass
 * has completed (tsleep drops giant like OpenBSD's drops kernel_lock), and
 * snapshot the tree, because the dladm caller closes the link right after
 * the ioctl (mac_stop -> iwm_stop -> INIT frees every node,
 * ieee80211_proto.c:1207) before reading MAC_PROP_WL_ESS_LIST.
 * Returns 0 or an errno; *cnt = number of nodes copied.
 */
int
iwm_il_scan(void *arg, struct iwm_il_node *n, int max, int *cnt)
{
	struct iwm_softc *sc = arg;
	struct ieee80211com *ic = &sc->sc_ic;
	struct ifnet *ifp = &ic->ic_if;
	uint8_t start;
	int i, err = 0;

	*cnt = 0;
	if (ic->ic_state == IEEE80211_S_RUN) {
		/* as illumos wifi_cmd_scan: never leave the AP's channel */
		*cnt = iwm_il_nodes(sc, n, max);
		return (0);
	}
	if (!(ifp->if_flags & IFF_RUNNING)) {
		ifp->if_flags |= IFF_UP;
		err = iwm_ioctl(ifp, SIOCSIFFLAGS, NULL);
		if (err != 0)
			return (err);
	}
	/*
	 * iwm_init calls ieee80211_begin_scan synchronously (if_iwm.c:10415),
	 * which zeroes ic_scan_count, but the INIT -> SCAN transition itself
	 * runs later from iwm_newstate_task: wait through INIT as well.
	 */
	start = ic->ic_scan_count;
	for (i = 0; i < 100 && ic->ic_scan_count == start &&
	    ic->ic_state <= IEEE80211_S_SCAN &&
	    (ifp->if_flags & IFF_RUNNING); i++)
		(void) tsleep_nsec(&ic->ic_scan_count, 0, "iwmscan",
		    MSEC_TO_NSEC(100));
	*cnt = iwm_il_nodes(sc, n, max);
	return (0);
}

/*
 * MAC_PROP_WL_ESSID set: OpenBSD SIOCS80211NWID (ieee80211_ioctl.c:487-509),
 * including its ENETRESET -> iwm_stop/iwm_init restart (iwm_ioctl,
 * if_iwm.c:10701-10708) when the interface is running.
 */
int
iwm_il_set_essid(void *arg, const uint8_t *essid, int len)
{
	struct iwm_softc *sc = arg;
	struct ieee80211com *ic = &sc->sc_ic;
	struct ifnet *ifp = &ic->ic_if;

	if (len < 0 || len > IEEE80211_NWID_LEN)
		return (EINVAL);
	memset(ic->ic_des_essid, 0, IEEE80211_NWID_LEN);
	ic->ic_des_esslen = len;
	if (len > 0)
		memcpy(ic->ic_des_essid, essid, len);
	if (len > 0)
		ic->ic_flags &= ~IEEE80211_F_AUTO_JOIN;
	ieee80211_disable_rsn(ic);
	ieee80211_disable_wep(ic);
	if ((ifp->if_flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING)) {
		iwm_stop(ifp);
		return (iwm_init(ifp));
	}
	return (0);
}

/*
 * WPA2/CCMP/PSK join, OpenBSD's own in-kernel supplicant. This is the
 * SIOCS80211WPAPARMS + SIOCS80211WPAPSK path that OpenBSD's ifconfig uses
 * (ieee80211_ioctl.c:633-655): set the desired SSID, the RSN protocol/akm/
 * cipher parameters, and the 32-byte PMK, then bring the interface up so the
 * state machine runs scan -> auth -> assoc and ieee80211_recv_4way_msg1..4
 * completes the 4-way handshake and installs the pairwise/group CCMP keys
 * through ic_set_key (= iwm_set_key, if_iwm.c:12073, which programs the
 * firmware). No frame of the handshake and no key crosses into userland;
 * wpad is not involved.
 *
 * This is a SELF-CONTAINED trigger: illumos connect-wifi refuses a WPA network
 * without a -k secobj (it would spawn wpad), so the WLDP ENCRYPTION/ESSID path
 * never starts the radio for us. Instead the single _wpa_psk private-property
 * set (iwm_gld.c) carries both the SSID and the PMK here, and this function
 * sets the SSID, enables RSN, installs the PMK, and brings the interface up
 * itself -- the one action that drives the whole keyed join.
 *
 * The PMK (32 bytes) is computed by a thin userland tool with PBKDF2 (RFC
 * 2898) from the passphrase and SSID, so the passphrase never enters the
 * kernel. A wrong PMK associates then fails the 4-way (MIC check), ending in
 * disassociation, not a panic.
 */
int
iwm_il_join(void *arg, const uint8_t *essid, int esslen,
    const uint8_t *pmk, int pmklen, const uint8_t *bssid)
{
	struct iwm_softc *sc = arg;
	struct ieee80211com *ic = &sc->sc_ic;
	struct ifnet *ifp = &ic->ic_if;
	struct ieee80211_wpaparams wpa;
	struct ieee80211_wpapsk psk;
	int err;

	if (pmklen != IEEE80211_PMK_LEN || esslen < 0 ||
	    esslen > IEEE80211_NWID_LEN)
		return (EINVAL);
	if (!(ic->ic_caps & IEEE80211_C_RSN))
		return (ENODEV);

	/*
	 * Drive everything through iwm_ioctl (the proven path): it holds
	 * sc->ioctl_rwl that iwm_init asserts, forces the firmware reload on
	 * the down->up transition, and runs the ENETRESET restart. The round-2
	 * bug called iwm_init directly, skipping all three; it returned 0 but
	 * no scan ran. Set the desired SSID + RSN + PSK while the radio is
	 * down (ENETRESET is a no-op then), then one SIOCSIFFLAGS up runs
	 * iwm_init -> ieee80211_begin_scan; end_scan auto-selects the BSS and
	 * runs auth -> assoc -> 4-way.
	 */
	memset(ic->ic_des_essid, 0, IEEE80211_NWID_LEN);
	ic->ic_des_esslen = esslen;
	if (esslen > 0) {
		memcpy(ic->ic_des_essid, essid, esslen);
		ic->ic_flags &= ~IEEE80211_F_AUTO_JOIN;
	}

	/*
	 * Optional BSSID pin (SIOCS80211BSSID semantics). "sedgwick" is served
	 * by several APs of mixed security (WPA and WEP) and bands; without a
	 * pin, ieee80211_node_choose_bss selects by RSSI and may try to
	 * associate to a WEP or distant/5GHz AP that never completes the WPA2
	 * handshake. A BSSID pin makes the join deterministic against one
	 * known WPA2/CCMP AP.
	 */
	if (bssid != NULL) {
		IEEE80211_ADDR_COPY(ic->ic_des_bssid, bssid);
		ic->ic_flags |= IEEE80211_F_DESBSSID;
	} else {
		ic->ic_flags &= ~IEEE80211_F_DESBSSID;
	}

	/* WPA2 (RSN) / CCMP / PSK -- the sedgwick profile. */
	bzero(&wpa, sizeof (wpa));
	wpa.i_enabled = 1;
	wpa.i_protos = IEEE80211_WPA_PROTO_WPA2;
	wpa.i_akms = IEEE80211_WPA_AKM_PSK;
	wpa.i_ciphers = IEEE80211_WPA_CIPHER_CCMP;
	wpa.i_groupcipher = IEEE80211_WPA_CIPHER_CCMP;
	err = iwm_ioctl(ifp, SIOCS80211WPAPARMS, (caddr_t)&wpa);
	if (err != 0)
		return (err);

	bzero(&psk, sizeof (psk));
	psk.i_enabled = 1;
	memcpy(psk.i_psk, pmk, IEEE80211_PMK_LEN);
	err = iwm_ioctl(ifp, SIOCS80211WPAPSK, (caddr_t)&psk);
	bzero(&psk, sizeof (psk));
	if (err != 0)
		return (err);

	/* if a prior scan left the radio up, cycle it so iwm_init re-runs */
	if (ifp->if_flags & IFF_RUNNING) {
		ifp->if_flags &= ~IFF_UP;
		(void) iwm_ioctl(ifp, SIOCSIFFLAGS, NULL);
	}
	ifp->if_flags |= IFF_UP;
	err = iwm_ioctl(ifp, SIOCSIFFLAGS, NULL);
	cmn_err(CE_NOTE, "!iwm: WPA join ssid_len=%d rsn=0x%x running=%d "
	    "state=%d siocflags=%d", esslen,
	    ic->ic_flags & IEEE80211_F_RSNON,
	    (ifp->if_flags & IFF_RUNNING) ? 1 : 0, ic->ic_state, err);
	return (err);
}

/* ---------------------------------------------------------- DDI attach --- */

static int
iwm_il_attach(dev_info_t *dip, ddi_attach_cmd_t cmd)
{
	struct iwm_il *il;
	struct iwm_softc *sc;
	struct pci_attach_args pa;
	int instance;
	uint16_t vid, did;

	if (cmd == DDI_RESUME)
		return (DDI_FAILURE);	/* NOTE: suspend/resume not wired */
	if (cmd != DDI_ATTACH)
		return (DDI_FAILURE);

	instance = ddi_get_instance(dip);
	if (ddi_soft_state_zalloc(iwm_state, instance) != DDI_SUCCESS)
		return (DDI_FAILURE);
	il = ddi_get_soft_state(iwm_state, instance);
	il->il_dip = dip;
	if (pci_config_setup(dip, &il->il_pcih) != DDI_SUCCESS)
		goto fail_soft;
	vid = pci_config_get16(il->il_pcih, PCI_CONF_VENID);
	did = pci_config_get16(il->il_pcih, PCI_CONF_DEVID);

	sc = kmem_zalloc(sizeof (*sc), KM_SLEEP);
	il->il_sc = sc;
	(void) snprintf(sc->sc_dev.dv_xname, sizeof (sc->sc_dev.dv_xname),
	    "iwm%d", instance);
	sc->sc_dev.dv_private = il;
	il->il_dmat.dt_dip = dip;

	bzero(&pa, sizeof (pa));
	pa.pa_dip = dip;
	pa.pa_pc = dip;
	pa.pa_tag = il->il_pcih;
	pa.pa_id = ((pcireg_t)did << 16) | vid;
	pa.pa_dmat = &il->il_dmat;

	n80211_giant_enter();
	if (!iwm_match(NULL, NULL, &pa)) {
		n80211_giant_exit();
		dev_err(dip, CE_WARN, "!iwm: %04x:%04x not in iwm_devices",
		    vid, did);
		goto fail_sc;
	}
	iwm_mr_fn = NULL;
	iwm_attach(NULL, &sc->sc_dev, &pa);
	if (iwm_mr_fn == NULL) {
		/* iwm_attach printed why and returned before the hook */
		n80211_giant_exit();
		goto fail_sc;
	}
	if (iwm_intr_enable((pci_intr_handle_t)(uintptr_t)sc->sc_ih) != 0) {
		n80211_giant_exit();
		goto fail_hw;
	}
	/* iwm_attach_hook -> iwm_preinit: firmware load + NVM MAC read */
	iwm_mr_fn(iwm_mr_dev);
	il->il_mountroot_ran = 1;
	if (!sc->attached) {
		n80211_giant_exit();
		dev_err(dip, CE_WARN, "!iwm: firmware/NVM preinit failed");
		goto fail_hw;
	}
	n80211_giant_exit();

	if (iwm_gld_register(dip, sc, sc->sc_ic.ic_myaddr, &il->il_gld) != 0)
		goto fail_hw;
	sc->sc_ic.ic_if.if_mac = iwm_gld_mac_handle(il->il_gld);
	il->il_registered = 1;
	ddi_set_driver_private(dip, (caddr_t)il);
	return (DDI_SUCCESS);

fail_hw:
	/*
	 * Undo iwm_attach's allocations in its own fail4..fail1 order
	 * (if_iwm.c:12093-12102). ieee80211_ifdetach is not called: attach
	 * failure leaves no stack state that outlives the softc.
	 */
	{
		int i;

		n80211_giant_enter();
		if (sc->sc_ih != NULL)
			iwm_intr_disestablish((pci_intr_handle_t)
			    (uintptr_t)sc->sc_ih);
		for (i = 0; i < nitems(sc->txq); i++)
			iwm_free_tx_ring(sc, &sc->txq[i]);
		iwm_free_rx_ring(sc, &sc->rxq);
		iwm_dma_contig_free(&sc->sched_dma);
		iwm_dma_contig_free(&sc->ict_dma);
		iwm_dma_contig_free(&sc->kw_dma);
		iwm_dma_contig_free(&sc->fw_dma);
		if (sc->sc_nswq != NULL)
			taskq_destroy(sc->sc_nswq);
		n80211_giant_exit();
		bus_space_unmap(sc->sc_st, sc->sc_sh, sc->sc_sz);
	}
fail_sc:
	kmem_free(sc, sizeof (*sc));
	pci_config_teardown(&il->il_pcih);
fail_soft:
	ddi_soft_state_free(iwm_state, instance);
	return (DDI_FAILURE);
}

/*
 * NOTE: detach is refused once attached. A correct detach has to quiesce
 * the OpenBSD timeouts and tasks (iwm_stop does most of it), call
 * ieee80211_ifdetach, and free what iwm_attach allocated; until that path
 * has been exercised on hardware, refusing keeps modunload from freeing
 * memory the firmware may still DMA into. modunload of a module with no
 * attached instance (the load-without-alias test) is unaffected.
 */
static int
iwm_il_detach(dev_info_t *dip, ddi_detach_cmd_t cmd)
{
	(void) dip;
	(void) cmd;
	return (DDI_FAILURE);
}

static int
iwm_il_quiesce(dev_info_t *dip)
{
	struct iwm_il *il = ddi_get_driver_private(dip);

	/* quiesce(9E) runs single-threaded at fast reboot: no locks */
	if (il != NULL && il->il_sc != NULL)
		iwm_quiesce_hw(il->il_sc);
	return (DDI_SUCCESS);
}

DDI_DEFINE_STREAM_OPS(iwm_devops, nulldev, nulldev, iwm_il_attach,
    iwm_il_detach, nodev, NULL, D_MP, NULL, iwm_il_quiesce);

static struct modldrv iwm_modldrv = {
	&mod_driverops,
	"Intel AC 7260-9560 (OpenBSD iwm)",
	&iwm_devops
};

static struct modlinkage iwm_modlinkage = {
	MODREV_1,
	{ &iwm_modldrv, NULL }
};

int
_init(void)
{
	int err;

	err = ddi_soft_state_init(&iwm_state, sizeof (struct iwm_il), 1);
	if (err != 0)
		return (err);
	n80211_giant_init();
	n80211_systq_init();
	iwm_gld_init_ops(&iwm_devops);
	err = mod_install(&iwm_modlinkage);
	if (err != 0) {
		iwm_gld_fini_ops(&iwm_devops);
		n80211_systq_fini();
		n80211_giant_fini();
		ddi_soft_state_fini(&iwm_state);
	}
	return (err);
}

int
_fini(void)
{
	int err;

	err = mod_remove(&iwm_modlinkage);
	if (err == 0) {
		iwm_gld_fini_ops(&iwm_devops);
		n80211_systq_fini();
		n80211_giant_fini();
		ddi_soft_state_fini(&iwm_state);
	}
	return (err);
}

int
_info(struct modinfo *mip)
{
	return (mod_info(&iwm_modlinkage, mip));
}
