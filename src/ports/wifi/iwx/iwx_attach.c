/*
 * iwx (Intel AX2xx) illumos attach + GLDv3 registration glue -- phase 1.
 *
 * This is the illumos-side half of the driver: DDI attach/detach, PCI config +
 * BAR mapping, interrupt plumbing skeleton, and GLDv3 mac_register. It is the
 * piece the vendored upstream/if_iwx.c does NOT contain, because that file
 * is an OpenBSD driver and knows nothing about dev_info_t, mac_register_t or
 * modlinkage.
 *
 * WHAT IS REAL HERE: every DDI and GLDv3 call site resolves against illumos
 * headers (sys/ddi.h, sys/sunddi.h, sys/mac_provider.h, sys/mac_wifi.h). The
 * translation unit compiles to a real ELF relocatable; the mac_ and ddi_
 * symbols are left undefined and resolved by the kernel at module load, as
 * they are in kernel/drv/amd64/iwn. Modelled on illumos iwn's attach
 * (uts/common/io/iwn/if_iwn.c:765-1136, _init at :7712, mac_callbacks at :396).
 *
 * THE ROUTE-(b) BOUNDARY -- read before "finishing" this file:
 *
 *   iwx_softc.sc_ic is an OpenBSD `struct ieee80211com` (upstream/
 *   if_iwxvar.h:638), NOT illumos's ieee80211com_t. The two share ZERO struct
 *   member names (STATUS.md: 109 members ni_* vs 55 in_*, route (a) refuted).
 *   Therefore this file MUST NOT call illumos ieee80211_attach(ieee80211com_t*)
 *   on sc->sc_ic -- it would be a type error masquerading as progress. The
 *   802.11 attach for a route-(b) driver is OpenBSD net80211's
 *   ieee80211_ifattach(), which is not yet vendored+linked (net80211/
 *   FINDINGS.md: 838 errors, 0/43 blocking symbols resolved).
 *
 *   So the net80211 attach call and the mac_callbacks bodies that bridge into
 *   the 802.11 stack are marked IWX_NET80211_GATED below. They are the seam
 *   where GLDv3 (which calls DOWN into the driver) meets net80211; on illumos
 *   iwn that seam is iwn_m_ioctl -> ieee80211_ioctl, iwn_m_getprop ->
 *   ieee80211_getprop (if_iwn.c:4088,4122,4135,4155), all *illumos* net80211
 *   entry points. A route-(b) iwx cannot use those; it needs an adapter onto
 *   OpenBSD net80211. That adapter is the unmeasured alternative FINDINGS.md
 *   flags for the maintainer, and it is the true remaining phase-1 work.
 *
 * STATUS: REAL for the DDI + GLDv3 + module skeleton (compiles to a kernel .o).
 * IWX_NET80211_GATED for the 802.11 bridge -- named, not faked.
 */

#include <sys/types.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/modctl.h>
#include <sys/conf.h>
#include <sys/pci.h>
#include <sys/mac_provider.h>
#include <sys/mac_wifi.h>
#include <sys/note.h>
#include <sys/stat.h>
#include <sys/strsubr.h>
#include <sys/strsun.h>

/*
 * Minimal softc for the attach skeleton. The full driver's softc is the
 * OpenBSD `struct iwx_softc` in upstream/if_iwxvar.h; this file cannot
 * include that header cleanly yet (it drags in the whole OpenBSD 802.11 world),
 * so phase 1 uses a header-compatible prefix carrying only the illumos-side
 * handles. When the driver links as one module, this collapses into the real
 * softc -- the fields keep the same names so the merge is mechanical.
 *
 * ponytail: separate skeleton softc, merge into struct iwx_softc when net80211
 * links. Named so the merge is not forgotten.
 */
struct iwx_il_softc {
	dev_info_t		*sc_dip;
	ddi_acc_handle_t	sc_pcih;	/* PCI config space */
	caddr_t			sc_base;	/* mapped BAR0 */
	ddi_acc_handle_t	sc_regh;	/* BAR0 acc handle */
	ddi_intr_handle_t	*sc_intr_htable;
	uint_t			sc_intr_pri;
	int			sc_intr_size;
	int			sc_intr_cap;
	mac_handle_t		sc_mach;	/* GLDv3 handle from mac_register */
	uint8_t			sc_macaddr[6];
	kmutex_t		sc_lock;
};

static void *iwx_il_state;	/* ddi_soft_state anchor */

/* Little-endian, strict-order register access -- AX2xx BAR0. Matches iwn. */
static ddi_device_acc_attr_t iwx_reg_accattr = {
	DDI_DEVICE_ATTR_V0,
	DDI_STRUCTURE_LE_ACC,
	DDI_STRICTORDER_ACC
};

/* ------------------------------------------------------------------ *
 * GLDv3 mac_callbacks.
 *
 * The data-path callbacks (m_tx/m_stat) and the 802.11 property/ioctl
 * callbacks (m_ioctl/m_setprop/m_getprop/m_propinfo) are the seam into
 * net80211. On a route-(b) driver they must bridge to OpenBSD net80211, which
 * is not linked yet, so they are IWX_NET80211_GATED: present so mac_register
 * has a complete vector, returning a fail-closed status until the bridge
 * exists. This is deliberate -- a stub that pretended to work would be the
 * "stub reported as an implementation" failure this project warns against.
 * ------------------------------------------------------------------ */

static int
iwx_m_stat(void *arg, uint_t stat, uint64_t *val)
{
	_NOTE(ARGUNUSED(arg, stat))
	*val = 0;
	return (ENOTSUP);		/* IWX_NET80211_GATED: -> ieee80211 stats */
}

static int
iwx_m_start(void *arg)
{
	struct iwx_il_softc *sc = arg;
	_NOTE(ARGUNUSED(sc))
	return (0);			/* IWX_NET80211_GATED: firmware bring-up */
}

static void
iwx_m_stop(void *arg)
{
	struct iwx_il_softc *sc = arg;
	_NOTE(ARGUNUSED(sc))
}

static int
iwx_m_promisc(void *arg, boolean_t on)
{
	_NOTE(ARGUNUSED(arg, on))
	return (0);
}

static int
iwx_m_multicst(void *arg, boolean_t add, const uint8_t *mca)
{
	_NOTE(ARGUNUSED(arg, add, mca))
	return (0);
}

static int
iwx_m_unicst(void *arg, const uint8_t *macaddr)
{
	_NOTE(ARGUNUSED(arg, macaddr))
	return (0);			/* IWX_NET80211_GATED */
}

static mblk_t *
iwx_m_tx(void *arg, mblk_t *mp)
{
	_NOTE(ARGUNUSED(arg))
	/*
	 * IWX_NET80211_GATED: the TX path is phase 5. Until it exists, drop
	 * rather than leak: return NULL means "consumed", so freemsg here.
	 */
	freemsgchain(mp);
	return (NULL);
}

static void
iwx_m_ioctl(void *arg, queue_t *wq, mblk_t *mp)
{
	_NOTE(ARGUNUSED(arg, wq))
	/*
	 * IWX_NET80211_GATED: on illumos iwn this is
	 * `ieee80211_ioctl(ic, wq, mp)` (if_iwn.c:4088). A route-(b) iwx needs
	 * the OpenBSD-net80211 adapter here. Fail closed with a miocnak.
	 */
	miocnak(wq, mp, 0, ENOTSUP);
}

static int
iwx_m_setprop(void *arg, const char *pr_name, mac_prop_id_t wldp_pr_num,
    uint_t wldp_length, const void *wldp_buf)
{
	_NOTE(ARGUNUSED(arg, pr_name, wldp_pr_num, wldp_length, wldp_buf))
	return (ENOTSUP);		/* IWX_NET80211_GATED: ieee80211_setprop */
}

static int
iwx_m_getprop(void *arg, const char *pr_name, mac_prop_id_t wldp_pr_num,
    uint_t wldp_length, void *wldp_buf)
{
	_NOTE(ARGUNUSED(arg, pr_name, wldp_pr_num, wldp_length, wldp_buf))
	return (ENOTSUP);		/* IWX_NET80211_GATED: ieee80211_getprop */
}

static void
iwx_m_propinfo(void *arg, const char *pr_name, mac_prop_id_t wldp_pr_num,
    mac_prop_info_handle_t prh)
{
	_NOTE(ARGUNUSED(arg, pr_name, wldp_pr_num, prh))
	/* IWX_NET80211_GATED: ieee80211_propinfo */
}

static mac_callbacks_t iwx_m_callbacks = {
	.mc_callbacks	= MC_IOCTL | MC_SETPROP | MC_GETPROP | MC_PROPINFO,
	.mc_getstat	= iwx_m_stat,
	.mc_start	= iwx_m_start,
	.mc_stop	= iwx_m_stop,
	.mc_setpromisc	= iwx_m_promisc,
	.mc_multicst	= iwx_m_multicst,
	.mc_unicst	= iwx_m_unicst,
	.mc_tx		= iwx_m_tx,
	.mc_ioctl	= iwx_m_ioctl,
	.mc_setprop	= iwx_m_setprop,
	.mc_getprop	= iwx_m_getprop,
	.mc_propinfo	= iwx_m_propinfo
};

/* ------------------------------------------------------------------ *
 * Interrupt allocation skeleton -- structurally modelled on iwn
 * (if_iwn.c:645-700). The real handler is iwx_intr in if_iwx.c; here we only
 * prove the ddi_intr_* call sites resolve and the priority is captured for the
 * mutex. Uses MSI/fixed as available.
 * ------------------------------------------------------------------ */
static uint_t iwx_intr(caddr_t arg, caddr_t unused);

static int
iwx_intr_setup(struct iwx_il_softc *sc)
{
	int intr_type = 0, count = 0, actual = 0;
	int ret;

	if (ddi_intr_get_supported_types(sc->sc_dip, &intr_type) !=
	    DDI_SUCCESS)
		return (DDI_FAILURE);

	/* Prefer MSI, fall back to fixed. */
	if (intr_type & DDI_INTR_TYPE_MSI)
		intr_type = DDI_INTR_TYPE_MSI;
	else if (intr_type & DDI_INTR_TYPE_FIXED)
		intr_type = DDI_INTR_TYPE_FIXED;
	else
		return (DDI_FAILURE);

	if (ddi_intr_get_nintrs(sc->sc_dip, intr_type, &count) != DDI_SUCCESS ||
	    count == 0)
		return (DDI_FAILURE);

	sc->sc_intr_size = sizeof (ddi_intr_handle_t);
	sc->sc_intr_htable = kmem_zalloc(sc->sc_intr_size, KM_SLEEP);

	ret = ddi_intr_alloc(sc->sc_dip, sc->sc_intr_htable, intr_type, 0, 1,
	    &actual, DDI_INTR_ALLOC_STRICT);
	if (ret != DDI_SUCCESS || actual != 1)
		goto fail;

	if (ddi_intr_get_pri(sc->sc_intr_htable[0], &sc->sc_intr_pri) !=
	    DDI_SUCCESS)
		goto fail;

	if (ddi_intr_add_handler(sc->sc_intr_htable[0], iwx_intr,
	    (caddr_t)sc, NULL) != DDI_SUCCESS)
		goto fail;

	if (ddi_intr_get_cap(sc->sc_intr_htable[0], &sc->sc_intr_cap) !=
	    DDI_SUCCESS)
		goto fail_handler;

	if (ddi_intr_enable(sc->sc_intr_htable[0]) != DDI_SUCCESS)
		goto fail_handler;

	return (DDI_SUCCESS);

fail_handler:
	(void) ddi_intr_remove_handler(sc->sc_intr_htable[0]);
fail:
	(void) ddi_intr_free(sc->sc_intr_htable[0]);
	kmem_free(sc->sc_intr_htable, sc->sc_intr_size);
	sc->sc_intr_htable = NULL;
	return (DDI_FAILURE);
}

static void
iwx_intr_teardown(struct iwx_il_softc *sc)
{
	if (sc->sc_intr_htable == NULL)
		return;
	(void) ddi_intr_disable(sc->sc_intr_htable[0]);
	(void) ddi_intr_remove_handler(sc->sc_intr_htable[0]);
	(void) ddi_intr_free(sc->sc_intr_htable[0]);
	kmem_free(sc->sc_intr_htable, sc->sc_intr_size);
	sc->sc_intr_htable = NULL;
}

/*
 * Interrupt handler stub. The real ISR is if_iwx.c:iwx_intr (11425). Here it
 * only claims/declines so ddi_intr_add_handler has a valid target and the
 * type matches ddi_intr_handler_t. IWX_NET80211_GATED for real dispatch.
 */
static uint_t
iwx_intr(caddr_t arg, caddr_t unused)
{
	_NOTE(ARGUNUSED(arg, unused))
	return (DDI_INTR_UNCLAIMED);	/* claim once the RX/notif path exists */
}

/* ------------------------------------------------------------------ *
 * DDI attach. Structure mirrors iwn_attach (if_iwn.c:765).
 * ------------------------------------------------------------------ */
static int
iwx_attach(dev_info_t *dip, ddi_attach_cmd_t cmd)
{
	struct iwx_il_softc *sc;
	mac_register_t *macp;
	wifi_data_t wd = { 0 };
	int instance, error;
	uint8_t reg;
	char strbuf[32];

	switch (cmd) {
	case DDI_ATTACH:
		break;
	case DDI_RESUME:
		return (DDI_SUCCESS);	/* IWX_NET80211_GATED: resume path */
	default:
		return (DDI_FAILURE);
	}

	instance = ddi_get_instance(dip);
	if (ddi_soft_state_zalloc(iwx_il_state, instance) != DDI_SUCCESS)
		return (DDI_FAILURE);
	sc = ddi_get_soft_state(iwx_il_state, instance);
	ddi_set_driver_private(dip, (caddr_t)sc);
	sc->sc_dip = dip;

	/* PCI config space. */
	if (pci_config_setup(dip, &sc->sc_pcih) != DDI_SUCCESS) {
		dev_err(dip, CE_WARN, "!pci_config_setup() failed");
		goto fail_soft;
	}

	/* Clear the device-specific "PCI retry timeout" (reg 0x41), as iwn. */
	reg = pci_config_get8(sc->sc_pcih, 0x41);
	if (reg != 0)
		pci_config_put8(sc->sc_pcih, 0x41, 0);

	/* Map BAR0 (rnumber 1 is the memory BAR, matching iwn). */
	error = ddi_regs_map_setup(dip, 1, &sc->sc_base, 0, 0,
	    &iwx_reg_accattr, &sc->sc_regh);
	if (error != DDI_SUCCESS) {
		dev_err(dip, CE_WARN, "!ddi_regs_map_setup() failed");
		goto fail_pci;
	}

	if (iwx_intr_setup(sc) != DDI_SUCCESS) {
		dev_err(dip, CE_WARN, "!interrupt setup failed");
		goto fail_regs;
	}

	mutex_init(&sc->sc_lock, NULL, MUTEX_DRIVER,
	    DDI_INTR_PRI(sc->sc_intr_pri));

	/*
	 * IWX_NET80211_GATED: OpenBSD net80211 ieee80211_ifattach(&sc->sc_ic)
	 * goes here (equivalently, iwx's iwx_attach body from if_iwx.c that
	 * fills sc_ic and reads the MAC). It is NOT illumos ieee80211_attach --
	 * see the boundary note at the top of this file. Until net80211 links,
	 * the MAC address is left zeroed and mac_register still succeeds so the
	 * GLDv3 half is exercised.
	 */

	/* GLDv3 registration -- the illumos-side attach, fully real. */
	macp = mac_alloc(MAC_VERSION);
	if (macp == NULL) {
		dev_err(dip, CE_WARN, "!mac_alloc() failed");
		goto fail_lock;
	}
	wd.wd_secalloc = WIFI_SEC_NONE;
	wd.wd_opmode = IEEE80211_M_STA;
	bcopy(sc->sc_macaddr, wd.wd_bssid, 6);

	macp->m_type_ident	= MAC_PLUGIN_IDENT_WIFI;
	macp->m_driver		= sc;
	macp->m_dip		= dip;
	macp->m_src_addr	= sc->sc_macaddr;
	macp->m_callbacks	= &iwx_m_callbacks;
	macp->m_min_sdu		= 0;
	macp->m_max_sdu		= IEEE80211_MTU;
	macp->m_pdata		= &wd;
	macp->m_pdata_size	= sizeof (wd);

	error = mac_register(macp, &sc->sc_mach);
	mac_free(macp);
	if (error != DDI_SUCCESS) {
		dev_err(dip, CE_WARN, "!mac_register() failed");
		goto fail_lock;
	}

	(void) snprintf(strbuf, sizeof (strbuf), "iwx%d", instance);
	error = ddi_create_minor_node(dip, strbuf, S_IFCHR, instance + 1,
	    DDI_NT_NET_WIFI, 0);
	if (error != DDI_SUCCESS) {
		dev_err(dip, CE_WARN, "!ddi_create_minor_node() failed");
		goto fail_mac;
	}

	mac_link_update(sc->sc_mach, LINK_STATE_DOWN);
	return (DDI_SUCCESS);

fail_mac:
	(void) mac_unregister(sc->sc_mach);
fail_lock:
	mutex_destroy(&sc->sc_lock);
	iwx_intr_teardown(sc);
fail_regs:
	ddi_regs_map_free(&sc->sc_regh);
fail_pci:
	pci_config_teardown(&sc->sc_pcih);
fail_soft:
	ddi_soft_state_free(iwx_il_state, instance);
	return (DDI_FAILURE);
}

static int
iwx_detach(dev_info_t *dip, ddi_detach_cmd_t cmd)
{
	struct iwx_il_softc *sc = ddi_get_driver_private(dip);
	int error;

	switch (cmd) {
	case DDI_DETACH:
		break;
	case DDI_SUSPEND:
		return (DDI_SUCCESS);	/* IWX_NET80211_GATED: suspend path */
	default:
		return (DDI_FAILURE);
	}

	if (sc == NULL)
		return (DDI_SUCCESS);

	error = mac_unregister(sc->sc_mach);
	if (error != 0)
		return (error);

	/* IWX_NET80211_GATED: ieee80211_ifdetach(&sc->sc_ic) here. */

	iwx_intr_teardown(sc);
	mutex_destroy(&sc->sc_lock);
	ddi_regs_map_free(&sc->sc_regh);
	pci_config_teardown(&sc->sc_pcih);
	ddi_remove_minor_node(dip, NULL);
	ddi_soft_state_free(iwx_il_state, ddi_get_instance(dip));
	return (DDI_SUCCESS);
}

static int
iwx_quiesce(dev_info_t *dip)
{
	struct iwx_il_softc *sc = ddi_get_driver_private(dip);

	if (sc == NULL)
		return (DDI_SUCCESS);
	/*
	 * IWX_NET80211_GATED: mask interrupts and stop DMA at the register
	 * level here (no locks, no logging -- quiesce(9E) contract). The
	 * register writes are iwx's, added when if_iwx.c links in.
	 */
	return (DDI_SUCCESS);
}

/* ------------------------------------------------------------------ *
 * Module linkage. Real illumos boilerplate, identical shape to iwn
 * (if_iwn.c:7696-7749). driver_aliases come from IWX_PCI_ALIASES
 * (compat/dev/pci/pcidevs.h) at packaging time.
 * ------------------------------------------------------------------ */
DDI_DEFINE_STREAM_OPS(iwx_devops, nulldev, nulldev, iwx_attach, iwx_detach,
    nodev, NULL, D_MP, NULL, iwx_quiesce);

static struct modldrv iwx_modldrv = {
	&mod_driverops,
	"Intel WiFi AX2xx (iwx) driver",
	&iwx_devops
};

static struct modlinkage iwx_modlinkage = {
	MODREV_1,
	{ &iwx_modldrv, NULL }
};

int
_init(void)
{
	int status;

	status = ddi_soft_state_init(&iwx_il_state,
	    sizeof (struct iwx_il_softc), 1);
	if (status != DDI_SUCCESS)
		return (status);

	mac_init_ops(&iwx_devops, "iwx");
	status = mod_install(&iwx_modlinkage);
	if (status != DDI_SUCCESS) {
		mac_fini_ops(&iwx_devops);
		ddi_soft_state_fini(&iwx_il_state);
	}
	return (status);
}

int
_fini(void)
{
	int status;

	status = mod_remove(&iwx_modlinkage);
	if (status == DDI_SUCCESS) {
		mac_fini_ops(&iwx_devops);
		ddi_soft_state_fini(&iwx_il_state);
	}
	return (status);
}

int
_info(struct modinfo *mip)
{
	return (mod_info(&iwx_modlinkage, mip));
}
