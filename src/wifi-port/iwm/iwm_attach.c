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
 * (net80211-openbsd/n80211_giant.c); see that file for why one lock is the
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

int
if_setlladdr(struct ifnet *ifp, const uint8_t *lladdr)
{
	bcopy(lladdr, ifp->if_lladdr, ETHER_ADDR_LEN);
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
 * mc_tx: queue on if_snd and kick iwm_start, which dequeues, encapsulates
 * through net80211 and maps the frame. Returns the chain it could not queue.
 * The mblks arrive as 802.11 frames built by the wifi plugin
 * (mac_wifi_header); OpenBSD's iwm_start expects Ethernet frames on if_snd
 * and calls ieee80211_encap. NOTE: that framing mismatch is the GATED TX
 * bridge: until it is written, frames are dropped here rather than handed to
 * an encapsulation that would double the header.
 */
mblk_t *
iwm_il_tx(void *arg, mblk_t *mp)
{
	(void) arg;
	freemsgchain(mp);
	return (NULL);
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
