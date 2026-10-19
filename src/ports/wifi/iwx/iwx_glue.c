/*
 * iwx_glue.c -- illumos DDI glue around the vendored OpenBSD iwx(4), under
 * the giant-lock model (net80211/n80211_giant.c).
 *
 * This is iwm_attach.c's structure applied to iwx: build an OpenBSD struct
 * pci_attach_args from the dev_info_t and call the unmodified OpenBSD
 * iwx_match()/iwx_attach(), then run the deferred iwx_attach_hook
 * (config_mountroot -> iwx_preinit: firmware load + NVM MAC read) at once,
 * since the module path is readable at attach.
 *
 * Shared with iwm, unchanged:
 *   ../iwm/iwm_bus.c  bus_dma/bus_space/pci_intr on DDI. Its interrupt
 *                     trampoline takes giant. MSI-X is declined there, so iwx
 *                     takes its MSI path (iwx_intr, not iwx_intr_msix).
 *   ../iwm/iwm_gld.c  GLDv3 + the WLDP bridge. It calls iwm_il_* by name;
 *                     this file implements them against struct iwx_softc,
 *                     and the build renames the public symbols
 *                     (iwm_il_* -> iwx_il_* etc.) so nothing iwm-named leaks.
 *
 * Why giant covers iwx (measured; STATUS.md "lock model"): if_iwx.c has no
 * MPSAFE/KERNEL_LOCK/mtx_* use, so it runs wholly under OpenBSD's big lock,
 * like iwm. Its 8 tsleep_nsec sites drop giant while asleep, ioctl_rwl has
 * writers only, and splnet stays a no-op because giant already excludes the
 * interrupt on every cpu.
 *
 * NOTE: one radio per machine is assumed by the giant lock and by "iwx0".
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
#include <net80211/ieee80211_radiotap.h>
#include <net80211/ieee80211_priv.h>
#define IC2IFP(_ic_) (&(_ic_)->ic_if)
#define le16_to_cpup(_a_) (le16toh(*(const uint16_t *)(_a_)))
#define le32_to_cpup(_a_) (le32toh(*(const uint32_t *)(_a_)))
#include <dev/pci/if_iwxreg.h>
#define IWX_NO_CFG_TABLES	/* if_iwx.c carries the one copy */
#include <dev/pci/if_iwxvar.h>

#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/modctl.h>
#include <sys/conf.h>
#include <sys/pci.h>
#include <sys/stat.h>
#include <sys/strsun.h>
#include <sys/strsubr.h>

/* iwm_gld.c, renamed by the build; see Makefile.illumos. */
extern int iwm_gld_register(dev_info_t *, void *, const uint8_t *, void **);
extern int iwm_gld_unregister(void *);
extern void *iwm_gld_mac_handle(void *);
extern void iwm_gld_init_ops(struct dev_ops *);
extern void iwm_gld_fini_ops(struct dev_ops *);

/* OpenBSD driver entry points (if_iwx.c). */
extern int iwx_match(struct device *, void *, void *);
extern void iwx_attach(struct device *, struct device *, void *);
extern int iwx_ioctl(struct ifnet *, u_long, caddr_t);
extern void iwx_start(struct ifnet *);
extern void iwx_stop(struct ifnet *);
extern int iwx_init(struct ifnet *);
extern void iwx_free_tx_ring(struct iwx_softc *, struct iwx_tx_ring *);
extern void iwx_free_rx_ring(struct iwx_softc *, struct iwx_rx_ring *);
extern void iwx_dma_contig_free(struct iwx_dma_info *);
extern void iwx_stop_device(struct iwx_softc *);
extern void iwx_disable_interrupts(struct iwx_softc *);

extern void n80211_giant_init(void);
extern void n80211_giant_fini(void);
extern void n80211_giant_enter(void);
extern void n80211_giant_exit(void);
extern void n80211_systq_init(void);
extern void n80211_systq_fini(void);

static void *iwx_state;			/* ddi_soft_state of struct iwx_il */

struct iwx_il {
	struct iwx_softc	*il_sc;
	dev_info_t		*il_dip;
	ddi_acc_handle_t	il_pcih;
	struct iwx_bus_dma_tag	il_dmat;
	void			*il_gld;
};

static struct device	*iwx_mr_dev;
static void		(*iwx_mr_fn)(struct device *);

void
config_mountroot(struct device *dev, void (*fn)(struct device *))
{
	iwx_mr_dev = dev;
	iwx_mr_fn = fn;
}

extern void ifq_init(struct ifqueue *, struct ifnet *);

int
if_attach(struct ifnet *ifp)
{
	ifq_init(&ifp->if_snd, ifp);
	return (0);
}

/* Keep ac_enaddr in sync, as OpenBSD does (see iwm_attach.c if_setlladdr). */
int
if_setlladdr(struct ifnet *ifp, const uint8_t *lladdr)
{
	bcopy(lladdr, ifp->if_lladdr, ETHER_ADDR_LEN);
	bcopy(lladdr, ((struct arpcom *)ifp)->ac_enaddr, ETHER_ADDR_LEN);
	return (0);
}

/* --------------------------------------------- GLDv3 callbacks (via gld) --- */

#include "../iwm/iwm_il.h"

int
iwm_il_start(void *arg)
{
	struct iwx_softc *sc = arg;
	struct ifnet *ifp = IC2IFP(&sc->sc_ic);
	int err;

	n80211_giant_enter();
	ifp->if_flags |= IFF_UP;
	err = iwx_ioctl(ifp, SIOCSIFFLAGS, NULL);
	n80211_giant_exit();
	return (err);
}

void
iwm_il_stop(void *arg)
{
	struct iwx_softc *sc = arg;
	struct ifnet *ifp = IC2IFP(&sc->sc_ic);

	n80211_giant_enter();
	ifp->if_flags &= ~IFF_UP;
	(void) iwx_ioctl(ifp, SIOCSIFFLAGS, NULL);
	n80211_giant_exit();
}

/* mc_tx: see iwm_attach.c iwm_il_tx; frames are dropped while not in RUN. */
mblk_t *
iwm_il_tx(void *arg, mblk_t *mp)
{
	struct iwx_softc *sc = arg;
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
		(void) ifq_enqueue(&ifp->if_snd, mp);
	}
	iwx_start(ifp);
	n80211_giant_exit();
	return (NULL);
}

/* ---- WLDP bridge, OpenBSD side. Callers hold giant (iwm_gld.c). ---- */

static uint8_t
iwx_il_rssi(struct ieee80211com *ic, struct ieee80211_node *ni)
{
	uint32_t r = ni->ni_rssi, max = ic->ic_max_rssi;

	if (max == 0 || r == 0)
		return (0);
	if (r >= max)
		return (15);
	return ((uint8_t)(r * 15 / max + 1));
}

static void
iwx_il_fill_node(struct ieee80211com *ic, struct ieee80211_node *ni,
    struct iwm_il_node *n)
{
	int i, nr;

	bzero(n, sizeof (*n));
	IEEE80211_ADDR_COPY(n->n_bssid, ni->ni_bssid);
	n->n_esslen = MIN(ni->ni_esslen, sizeof (n->n_essid));
	bcopy(ni->ni_essid, n->n_essid, n->n_esslen);
	n->n_rssi = iwx_il_rssi(ic, ni);
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
	for (i = 0; i < nr; i++)
		n->n_rates[i] = ni->ni_rates.rs_rates[
		    ni->ni_rates.rs_nrates - i - 1] & IEEE80211_RATE_VAL;
	n->n_nrates = (uint8_t)nr;
}

void
iwm_il_getstate(void *arg, struct iwm_il_state *s)
{
	struct iwx_softc *sc = arg;
	struct ieee80211com *ic = &sc->sc_ic;
	struct ieee80211_node *ni = ic->ic_bss;

	bzero(s, sizeof (*s));
	s->s_running = (ic->ic_if.if_flags & IFF_RUNNING) ? 1 : 0;
	s->s_connected = (ic->ic_state == IEEE80211_S_RUN) && (ni != NULL) &&
	    (!(ic->ic_flags & IEEE80211_F_RSNON) || ni->ni_port_valid);
	s->s_rsn = (ic->ic_flags & IEEE80211_F_RSNON) ? 1 : 0;
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
		s->s_rssi = iwx_il_rssi(ic, ni);
		if (ni->ni_txrate >= 0 && ni->ni_txrate < ni->ni_rates.rs_nrates)
			s->s_rate = ni->ni_rates.rs_rates[ni->ni_txrate] &
			    IEEE80211_RATE_VAL;
	}
}

int
iwm_il_nodes(void *arg, struct iwm_il_node *n, int max)
{
	struct iwx_softc *sc = arg;
	struct ieee80211com *ic = &sc->sc_ic;
	struct ieee80211_node *ni;
	int cnt = 0;

	RBT_FOREACH(ni, ieee80211_tree, &ic->ic_tree) {
		if (cnt >= max)
			break;
		if (IEEE80211_ADDR_EQ(ni->ni_macaddr, ic->ic_myaddr))
			continue;
		if (ni->ni_esslen == 0 && ni->ni_rssi == 0)
			continue;
		iwx_il_fill_node(ic, ni, &n[cnt++]);
	}
	return (cnt);
}

/* WL_SCAN: see iwm_attach.c iwm_il_scan (iwx also sets C_SCANALLBAND). */
int
iwm_il_scan(void *arg, struct iwm_il_node *n, int max, int *cnt)
{
	struct iwx_softc *sc = arg;
	struct ieee80211com *ic = &sc->sc_ic;
	struct ifnet *ifp = &ic->ic_if;
	uint8_t start;
	int i, err;

	*cnt = 0;
	if (ic->ic_state == IEEE80211_S_RUN) {
		*cnt = iwm_il_nodes(sc, n, max);
		return (0);
	}
	if (!(ifp->if_flags & IFF_RUNNING)) {
		ifp->if_flags |= IFF_UP;
		err = iwx_ioctl(ifp, SIOCSIFFLAGS, NULL);
		if (err != 0)
			return (err);
	}
	start = ic->ic_scan_count;
	for (i = 0; i < 100 && ic->ic_scan_count == start &&
	    ic->ic_state <= IEEE80211_S_SCAN &&
	    (ifp->if_flags & IFF_RUNNING); i++)
		(void) tsleep_nsec(&ic->ic_scan_count, 0, "iwxscan",
		    MSEC_TO_NSEC(100));
	*cnt = iwm_il_nodes(sc, n, max);
	return (0);
}

/* MAC_PROP_WL_ESSID set: SIOCS80211NWID semantics + ENETRESET restart. */
int
iwm_il_set_essid(void *arg, const uint8_t *essid, int len)
{
	struct iwx_softc *sc = arg;
	struct ieee80211com *ic = &sc->sc_ic;
	struct ifnet *ifp = &ic->ic_if;

	if (len < 0 || len > IEEE80211_NWID_LEN)
		return (EINVAL);
	memset(ic->ic_des_essid, 0, IEEE80211_NWID_LEN);
	ic->ic_des_esslen = len;
	if (len > 0) {
		memcpy(ic->ic_des_essid, essid, len);
		ic->ic_flags &= ~IEEE80211_F_AUTO_JOIN;
	}
	ieee80211_disable_rsn(ic);
	ieee80211_disable_wep(ic);
	if ((ifp->if_flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING)) {
		ifp->if_flags &= ~IFF_UP;
		(void) iwx_ioctl(ifp, SIOCSIFFLAGS, NULL);
		ifp->if_flags |= IFF_UP;
		return (iwx_ioctl(ifp, SIOCSIFFLAGS, NULL));
	}
	return (0);
}

/*
 * WPA2/CCMP/PSK join through OpenBSD's in-kernel supplicant, the iwm path
 * (iwm_attach.c iwm_il_join, measured on the X1): SIOCS80211WPAPARMS +
 * SIOCS80211WPAPSK through iwx_ioctl, then one SIOCSIFFLAGS up. iwx installs
 * the CCMP keys with iwx_set_key (setkey_task). Never run on an AX2xx.
 */
int
iwm_il_join(void *arg, const uint8_t *essid, int esslen,
    const uint8_t *pmk, int pmklen, const uint8_t *bssid)
{
	struct iwx_softc *sc = arg;
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
	memset(ic->ic_des_essid, 0, IEEE80211_NWID_LEN);
	ic->ic_des_esslen = esslen;
	if (esslen > 0) {
		memcpy(ic->ic_des_essid, essid, esslen);
		ic->ic_flags &= ~IEEE80211_F_AUTO_JOIN;
	}
	if (bssid != NULL) {
		IEEE80211_ADDR_COPY(ic->ic_des_bssid, bssid);
		ic->ic_flags |= IEEE80211_F_DESBSSID;
	} else {
		ic->ic_flags &= ~IEEE80211_F_DESBSSID;
	}
	bzero(&wpa, sizeof (wpa));
	wpa.i_enabled = 1;
	wpa.i_protos = IEEE80211_WPA_PROTO_WPA2;
	wpa.i_akms = IEEE80211_WPA_AKM_PSK;
	wpa.i_ciphers = IEEE80211_WPA_CIPHER_CCMP;
	wpa.i_groupcipher = IEEE80211_WPA_CIPHER_CCMP;
	err = iwx_ioctl(ifp, SIOCS80211WPAPARMS, (caddr_t)&wpa);
	if (err != 0)
		return (err);
	bzero(&psk, sizeof (psk));
	psk.i_enabled = 1;
	memcpy(psk.i_psk, pmk, IEEE80211_PMK_LEN);
	err = iwx_ioctl(ifp, SIOCS80211WPAPSK, (caddr_t)&psk);
	bzero(&psk, sizeof (psk));
	if (err != 0)
		return (err);
	if (ifp->if_flags & IFF_RUNNING) {
		ifp->if_flags &= ~IFF_UP;
		(void) iwx_ioctl(ifp, SIOCSIFFLAGS, NULL);
	}
	ifp->if_flags |= IFF_UP;
	return (iwx_ioctl(ifp, SIOCSIFFLAGS, NULL));
}

/* ---------------------------------------------------------- DDI attach --- */

/* Undo iwx_attach's allocations in its own fail4..fail1 order (if_iwx.c). */
static void
iwx_il_free_hw(struct iwx_softc *sc)
{
	int i;

	n80211_giant_enter();
	if (sc->sc_ih != NULL)
		iwm_intr_disestablish((pci_intr_handle_t)(uintptr_t)sc->sc_ih);
	for (i = 0; i < nitems(sc->txq); i++)
		iwx_free_tx_ring(sc, &sc->txq[i]);
	iwx_free_rx_ring(sc, &sc->rxq);
	iwx_dma_contig_free(&sc->ict_dma);
	iwx_dma_contig_free(&sc->ctxt_info_dma);
	iwx_dma_contig_free(&sc->prph_scratch_dma);
	iwx_dma_contig_free(&sc->prph_info_dma);
	if (sc->sc_nswq != NULL)
		taskq_destroy(sc->sc_nswq);
	n80211_giant_exit();
	bus_space_unmap(sc->sc_st, sc->sc_sh, sc->sc_sz);
}

static int
iwx_il_attach(dev_info_t *dip, ddi_attach_cmd_t cmd)
{
	struct iwx_il *il;
	struct iwx_softc *sc;
	struct pci_attach_args pa;
	int instance;
	uint16_t vid, did;

	if (cmd != DDI_ATTACH)
		return (DDI_FAILURE);	/* NOTE: suspend/resume not wired */

	instance = ddi_get_instance(dip);
	if (ddi_soft_state_zalloc(iwx_state, instance) != DDI_SUCCESS)
		return (DDI_FAILURE);
	il = ddi_get_soft_state(iwx_state, instance);
	il->il_dip = dip;
	if (pci_config_setup(dip, &il->il_pcih) != DDI_SUCCESS)
		goto fail_soft;
	vid = pci_config_get16(il->il_pcih, PCI_CONF_VENID);
	did = pci_config_get16(il->il_pcih, PCI_CONF_DEVID);

	sc = kmem_zalloc(sizeof (*sc), KM_SLEEP);
	il->il_sc = sc;
	(void) snprintf(sc->sc_dev.dv_xname, sizeof (sc->sc_dev.dv_xname),
	    "iwx%d", instance);
	sc->sc_dev.dv_private = il;
	il->il_dmat.dt_dip = dip;

	bzero(&pa, sizeof (pa));
	pa.pa_dip = dip;
	pa.pa_pc = dip;
	pa.pa_tag = il->il_pcih;
	pa.pa_id = ((pcireg_t)did << 16) | vid;
	pa.pa_dmat = &il->il_dmat;

	n80211_giant_enter();
	if (!iwx_match(NULL, NULL, &pa)) {
		n80211_giant_exit();
		dev_err(dip, CE_WARN, "!iwx: %04x:%04x not in iwx_devices",
		    vid, did);
		goto fail_sc;
	}
	iwx_mr_fn = NULL;
	iwx_attach(NULL, &sc->sc_dev, &pa);
	if (iwx_mr_fn == NULL) {
		/* iwx_attach printed why and unwound its own allocations */
		n80211_giant_exit();
		goto fail_sc;
	}
	if (iwm_intr_enable((pci_intr_handle_t)(uintptr_t)sc->sc_ih) != 0) {
		n80211_giant_exit();
		goto fail_hw;
	}
	/* iwx_attach_hook -> iwx_preinit: firmware load + NVM MAC read */
	iwx_mr_fn(iwx_mr_dev);
	if (!sc->attached) {
		n80211_giant_exit();
		dev_err(dip, CE_WARN, "!iwx: firmware/NVM preinit failed");
		goto fail_hw;
	}
	n80211_giant_exit();

	if (iwm_gld_register(dip, sc, sc->sc_ic.ic_myaddr, &il->il_gld) != 0)
		goto fail_hw;
	sc->sc_ic.ic_if.if_mac = iwm_gld_mac_handle(il->il_gld);
	ddi_set_driver_private(dip, (caddr_t)il);
	return (DDI_SUCCESS);

fail_hw:
	iwx_il_free_hw(sc);
fail_sc:
	kmem_free(sc, sizeof (*sc));
	pci_config_teardown(&il->il_pcih);
fail_soft:
	ddi_soft_state_free(iwx_state, instance);
	return (DDI_FAILURE);
}

/* Refused once attached, as iwm: see iwm_attach.c iwm_il_detach. */
static int
iwx_il_detach(dev_info_t *dip, ddi_detach_cmd_t cmd)
{
	(void) dip;
	(void) cmd;
	return (DDI_FAILURE);
}

static int
iwx_il_quiesce(dev_info_t *dip)
{
	struct iwx_il *il = ddi_get_driver_private(dip);

	if (il != NULL && il->il_sc != NULL) {
		iwx_disable_interrupts(il->il_sc);
		iwx_stop_device(il->il_sc);
	}
	return (DDI_SUCCESS);
}

DDI_DEFINE_STREAM_OPS(iwx_devops, nulldev, nulldev, iwx_il_attach,
    iwx_il_detach, nodev, NULL, D_MP, NULL, iwx_il_quiesce);

static struct modldrv iwx_modldrv = {
	&mod_driverops,
	"Intel AX2xx (OpenBSD iwx)",
	&iwx_devops
};

static struct modlinkage iwx_modlinkage = {
	MODREV_1,
	{ &iwx_modldrv, NULL }
};

int
_init(void)
{
	int err;

	err = ddi_soft_state_init(&iwx_state, sizeof (struct iwx_il), 1);
	if (err != 0)
		return (err);
	n80211_giant_init();
	n80211_systq_init();
	iwm_gld_init_ops(&iwx_devops);
	err = mod_install(&iwx_modlinkage);
	if (err != 0) {
		iwm_gld_fini_ops(&iwx_devops);
		n80211_systq_fini();
		n80211_giant_fini();
		ddi_soft_state_fini(&iwx_state);
	}
	return (err);
}

int
_fini(void)
{
	int err;

	err = mod_remove(&iwx_modlinkage);
	if (err == 0) {
		iwm_gld_fini_ops(&iwx_devops);
		n80211_systq_fini();
		n80211_giant_fini();
		ddi_soft_state_fini(&iwx_state);
	}
	return (err);
}

int
_info(struct modinfo *mip)
{
	return (mod_info(&iwx_modlinkage, mip));
}
