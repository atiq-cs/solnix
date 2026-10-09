/*
 * iwm_gld.c -- the GLDv3 registration half of iwm, in a translation unit that
 * sees only illumos headers.
 *
 * <sys/mac.h> owns LINK_STATE_UP/DOWN (link_state_t) and <net/if.h>-style
 * names that the OpenBSD compat world redefines, so the mac_* calls live
 * here and iwm_attach.c reaches them through five plain functions. Callbacks
 * come back into OpenBSD code through iwm_il_start/stop/tx (iwm_attach.c),
 * which take the giant lock themselves. Modelled on illumos iwn
 * (if_iwn.c:396 mac_callbacks, :1060-1100 mac_register with the wifi plugin).
 */

#include <sys/types.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/kmem.h>
#include <sys/stream.h>
#include <sys/strsun.h>
#include <sys/mac_provider.h>
#include <sys/mac_wifi.h>
#include <sys/net80211.h>

extern int iwm_il_start(void *);
extern void iwm_il_stop(void *);
extern mblk_t *iwm_il_tx(void *, mblk_t *);

struct iwm_gld {
	mac_handle_t	g_mh;
	void		*g_sc;
	uint8_t		g_addr[ETHERADDRL];
};

static int
iwm_m_start(void *arg)
{
	struct iwm_gld *g = arg;

	return (iwm_il_start(g->g_sc));
}

static void
iwm_m_stop(void *arg)
{
	struct iwm_gld *g = arg;

	iwm_il_stop(g->g_sc);
}

static mblk_t *
iwm_m_tx(void *arg, mblk_t *mp)
{
	struct iwm_gld *g = arg;

	return (iwm_il_tx(g->g_sc, mp));
}

/* The firmware filters by its own address and the BSS; accept these. */
static int
iwm_m_promisc(void *arg, boolean_t on)
{
	(void) arg;
	(void) on;
	return (0);
}

static int
iwm_m_multicst(void *arg, boolean_t add, const uint8_t *mca)
{
	(void) arg;
	(void) add;
	(void) mca;
	return (0);
}

static int
iwm_m_unicst(void *arg, const uint8_t *macaddr)
{
	(void) arg;
	(void) macaddr;
	return (0);
}

static int
iwm_m_stat(void *arg, uint_t stat, uint64_t *val)
{
	(void) arg;
	(void) stat;
	(void) val;
	return (ENOTSUP);
}

/* GATED: the WLDP_* / WLAN_* bridge onto OpenBSD net80211 is not written. */
static void
iwm_m_ioctl(void *arg, queue_t *wq, mblk_t *mp)
{
	(void) arg;
	miocnak(wq, mp, 0, ENOTSUP);
}

static int
iwm_m_setprop(void *arg, const char *name, mac_prop_id_t id, uint_t sz,
    const void *val)
{
	(void) arg; (void) name; (void) id; (void) sz; (void) val;
	return (ENOTSUP);
}

static int
iwm_m_getprop(void *arg, const char *name, mac_prop_id_t id, uint_t sz,
    void *val)
{
	(void) arg; (void) name; (void) id; (void) sz; (void) val;
	return (ENOTSUP);
}

static void
iwm_m_propinfo(void *arg, const char *name, mac_prop_id_t id,
    mac_prop_info_handle_t ph)
{
	(void) arg; (void) name; (void) id; (void) ph;
}

static mac_callbacks_t iwm_m_callbacks = {
	.mc_callbacks	= MC_IOCTL | MC_SETPROP | MC_GETPROP | MC_PROPINFO,
	.mc_getstat	= iwm_m_stat,
	.mc_start	= iwm_m_start,
	.mc_stop	= iwm_m_stop,
	.mc_setpromisc	= iwm_m_promisc,
	.mc_multicst	= iwm_m_multicst,
	.mc_unicst	= iwm_m_unicst,
	.mc_tx		= iwm_m_tx,
	.mc_ioctl	= iwm_m_ioctl,
	.mc_setprop	= iwm_m_setprop,
	.mc_getprop	= iwm_m_getprop,
	.mc_propinfo	= iwm_m_propinfo,
};

int
iwm_gld_register(dev_info_t *dip, void *sc, const uint8_t *addr, void **gp)
{
	struct iwm_gld *g;
	mac_register_t *macp;
	wifi_data_t wd = { 0 };
	int err;

	g = kmem_zalloc(sizeof (*g), KM_SLEEP);
	g->g_sc = sc;
	bcopy(addr, g->g_addr, ETHERADDRL);

	macp = mac_alloc(MAC_VERSION);
	if (macp == NULL) {
		kmem_free(g, sizeof (*g));
		return (ENOMEM);
	}
	wd.wd_secalloc = WIFI_SEC_NONE;
	wd.wd_opmode = IEEE80211_M_STA;
	macp->m_type_ident = MAC_PLUGIN_IDENT_WIFI;
	macp->m_driver = g;
	macp->m_dip = dip;
	macp->m_src_addr = g->g_addr;
	macp->m_callbacks = &iwm_m_callbacks;
	macp->m_min_sdu = 0;
	macp->m_max_sdu = IEEE80211_MTU;
	macp->m_pdata = &wd;
	macp->m_pdata_size = sizeof (wd);
	err = mac_register(macp, &g->g_mh);
	mac_free(macp);
	if (err != 0) {
		kmem_free(g, sizeof (*g));
		return (err);
	}
	mac_link_update(g->g_mh, LINK_STATE_DOWN);
	*gp = g;
	return (0);
}

int
iwm_gld_unregister(void *gp)
{
	struct iwm_gld *g = gp;
	int err;

	if (g == NULL)
		return (0);
	err = mac_unregister(g->g_mh);
	if (err == 0)
		kmem_free(g, sizeof (*g));
	return (err);
}

void *
iwm_gld_mac_handle(void *gp)
{
	return (((struct iwm_gld *)gp)->g_mh);
}

void
iwm_gld_init_ops(struct dev_ops *ops)
{
	mac_init_ops(ops, "iwm");
}

void
iwm_gld_fini_ops(struct dev_ops *ops)
{
	mac_fini_ops(ops);
}
