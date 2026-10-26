/*
 * iwm_gld.c -- the GLDv3 half of iwm, in a translation unit that sees only
 * illumos headers.
 *
 * <sys/mac.h> owns LINK_STATE_UP/DOWN (link_state_t) and <net/if.h>-style
 * names that the OpenBSD compat world redefines, so the mac_* calls live
 * here and reach OpenBSD state only through the plain structs and functions
 * of iwm_il.h (implemented in iwm_attach.c, which take or expect giant).
 * Modelled on illumos iwn (if_iwn.c:396 mac_callbacks, :1060-1100
 * mac_register with the wifi plugin, :3995-4160 m_tx/m_ioctl/m_*prop).
 *
 * What illumos wifi userland sends, measured from libdladm (gate
 * ac45d71f libdlwlan.c, linkprop.c:4771):
 *   - WLAN_COMMAND WL_SCAN / WL_DISASSOCIATE as a STREAMS I_STR on
 *     /dev/net/<link> -> mc_ioctl (libdlwlan.c:1093-1183);
 *   - every parameter as DLDIOC_GET/SETMACPROP MAC_PROP_WL_* ->
 *     mc_getprop / mc_setprop.
 * Tagged per property in iwm_m_getprop / iwm_m_setprop below and in STATUS.md.
 *
 * Framing. The wifi plugin hands mc_tx an 802.11 data header + LLC/SNAP
 * that it built from the ethertype (mac_wifi.c:184-269) and expects mac_rx
 * to get the same shape (mac_wifi_header_info, mac_wifi.c:281-360). OpenBSD
 * net80211 speaks Ethernet on both ends (iwm_start -> ieee80211_encap;
 * ieee80211_decap -> if_input). iwm_wifi_to_ether / iwm_ether_to_wifi convert
 * at this boundary, so neither side's encapsulation code changes.
 */

#include <sys/types.h>
#include <sys/stddef.h>
#include <sys/sysmacros.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/kmem.h>
#include <sys/stream.h>
#include <sys/strsun.h>
#include <sys/policy.h>
#include <sys/mac_provider.h>
#include <sys/dls.h>		/* DLS_SAP_LLC */
#include <sys/mac_wifi.h>
#include <sys/net80211.h>
#include <inet/wifi_ioctl.h>
#include "iwm_il.h"

/*
 * mac_header_info is exported by misc/mac (measured in the running kernel's
 * symbol table) but declared only in the gate-internal sys/mac_client_priv.h
 * (mac_client_priv.h:76), which the proto does not install.
 */
extern int mac_header_info(mac_handle_t, mblk_t *, mac_header_info_t *);

struct iwm_gld {
	mac_handle_t	g_mh;
	void		*g_sc;
	uint8_t		g_addr[ETHERADDRL];
	wifi_data_t	g_wd;		/* last pdata given to mac */
	/*
	 * Scan snapshot. dladm reads MAC_PROP_WL_ESS_LIST after it has closed
	 * the link that ran WL_SCAN, and that close stops the radio and frees
	 * OpenBSD's node tree (see iwm_il_scan), so ESS_LIST serves this copy
	 * while the radio is down. Guarded by giant.
	 */
	struct iwm_il_node g_scan[IWM_IL_MAXNODES];
	int		g_nscan;
};

/*
 * Headroom for ieee80211_encap: it trims the 14-byte Ethernet header to the
 * 8-byte LLC/SNAP and then M_PREPENDs the 802.11 header (24..30 bytes) in
 * place (n80211_mbuf.c n80211_m_prepend fails rather than allocate), and iwm
 * prepends nothing further. 64 bytes covers a QoS + HT-control header.
 */
#define	IWM_TX_HEADROOM	64

/*
 * Private link property that carries the WPA2 PMK and SSID into OpenBSD's
 * in-kernel RSN supplicant. A thin userland tool computes the 32-byte PMK
 * with PBKDF2 (RFC 2898, HMAC-SHA1, 4096 iterations) from the passphrase and
 * SSID and sets it with the SSID appended:
 *   dladm set-linkprop -t -p _wpa_psk=<64hex>:<ssid> iwm0
 * The passphrase never enters the kernel; wpad is not involved. This single
 * set is the whole join trigger (iwm_il_join in iwm_attach.c): connect-wifi
 * refuses a WPA network without a -k secobj, so there is no keyless assoc path
 * to lean on, and this set brings the radio up and starts scan/assoc/4-way.
 */
#define	IWM_PRIV_WPA_PSK	"_wpa_psk"
#define	IWM_PMK_LEN		32

static char *iwm_priv_props[] = {
	IWM_PRIV_WPA_PSK,
	NULL
};

/* 64 hex chars -> 32 bytes. Returns 0 on success. */
static int
iwm_hexdigit(char c)
{
	if (c >= '0' && c <= '9')
		return (c - '0');
	if (c >= 'a' && c <= 'f')
		return (c - 'a' + 10);
	if (c >= 'A' && c <= 'F')
		return (c - 'A' + 10);
	return (-1);
}

static int
iwm_hex2pmk(const char *s, uint_t slen, uint8_t pmk[IWM_PMK_LEN])
{
	uint_t i;

	if (slen < IWM_PMK_LEN * 2)
		return (EINVAL);
	for (i = 0; i < IWM_PMK_LEN; i++) {
		int hi, lo;

		hi = iwm_hexdigit(s[2 * i]);
		lo = iwm_hexdigit(s[2 * i + 1]);
		if (hi < 0 || lo < 0)
			return (EINVAL);
		pmk[i] = (uint8_t)((hi << 4) | lo);
	}
	return (0);
}

/* Parse "aa:bb:cc:dd:ee:ff" (len bytes, no NUL assumed) into 6 bytes. 0 on ok. */
static int
iwm_parse_bssid(const char *s, int len, uint8_t out[6])
{
	int i, hi, lo;

	if (len < 17)
		return (EINVAL);
	for (i = 0; i < 6; i++) {
		hi = iwm_hexdigit(s[i * 3]);
		lo = iwm_hexdigit(s[i * 3 + 1]);
		if (hi < 0 || lo < 0)
			return (EINVAL);
		if (i < 5 && s[i * 3 + 2] != ':')
			return (EINVAL);
		out[i] = (uint8_t)((hi << 4) | lo);
	}
	return (0);
}

/*
 * 802.11 + LLC (as built by the wifi plugin) -> Ethernet, in a new leading
 * mblk with headroom. mac_header_info parses the frame with the plugin's own
 * header_info, so this accepts exactly what the plugin produces.
 */
static mblk_t *
iwm_wifi_to_ether(mac_handle_t mh, mblk_t *mp)
{
	mac_header_info_t mhi;
	struct ether_header *eh;
	mblk_t *hd;

	if (mac_header_info(mh, mp, &mhi) != 0 ||
	    mhi.mhi_bindsap == DLS_SAP_LLC || MBLKL(mp) < mhi.mhi_hdrsize) {
		freemsg(mp);
		return (NULL);
	}
	if ((hd = allocb(IWM_TX_HEADROOM + sizeof (*eh), BPRI_MED)) == NULL) {
		freemsg(mp);
		return (NULL);
	}
	hd->b_rptr += IWM_TX_HEADROOM;
	hd->b_wptr = hd->b_rptr + sizeof (*eh);
	eh = (struct ether_header *)hd->b_rptr;
	bcopy(mhi.mhi_daddr, &eh->ether_dhost, ETHERADDRL);
	bcopy(mhi.mhi_saddr, &eh->ether_shost, ETHERADDRL);
	eh->ether_type = htons(mhi.mhi_origsap);
	mp->b_rptr += mhi.mhi_hdrsize;
	if (MBLKL(mp) == 0 && mp->b_cont != NULL) {
		hd->b_cont = mp->b_cont;
		mp->b_cont = NULL;
		freeb(mp);
	} else {
		hd->b_cont = mp;
	}
	return (hd);
}

/*
 * Ethernet (from OpenBSD ieee80211_decap) -> the 802.11 FROMDS data header +
 * LLC/SNAP that mac_wifi_header_info parses (mac_wifi.c:281-360): addr1 = us
 * (the Ethernet destination), addr2 = the BSSID, addr3 = the source. Called
 * from n80211_giant_exit with giant dropped, right before mac_rx.
 */
static mblk_t *
iwm_gld_rx_frame(void *gp, mblk_t *mp)
{
	struct iwm_gld *g = gp;
	struct ether_header eh;
	struct ieee80211_frame *wh;
	struct ieee80211_llc *llc;
	mblk_t *hd;
	size_t hl = sizeof (*wh) + sizeof (*llc);

	if (MBLKL(mp) < sizeof (eh) && (pullupmsg(mp, sizeof (eh)) == 0)) {
		freemsg(mp);
		return (NULL);
	}
	bcopy(mp->b_rptr, &eh, sizeof (eh));
	mp->b_rptr += sizeof (eh);
	if ((hd = allocb(hl, BPRI_MED)) == NULL) {
		freemsg(mp);
		return (NULL);
	}
	bzero(hd->b_rptr, hl);
	wh = (struct ieee80211_frame *)hd->b_rptr;
	wh->i_fc[0] = IEEE80211_FC0_VERSION_0 | IEEE80211_FC0_TYPE_DATA;
	wh->i_fc[1] = IEEE80211_FC1_DIR_FROMDS;
	bcopy(&eh.ether_dhost, wh->i_addr1, ETHERADDRL);
	bcopy(g->g_wd.wd_bssid, wh->i_addr2, ETHERADDRL);
	bcopy(&eh.ether_shost, wh->i_addr3, ETHERADDRL);
	llc = (struct ieee80211_llc *)(wh + 1);
	llc->illc_dsap = llc->illc_ssap = 0xaa;	/* LLC_SNAP_LSAP */
	llc->illc_control = 0x03;		/* LLC_UI, OUI 0 = RFC 1042 */
	llc->illc_ether_type = eh.ether_type;
	hd->b_wptr = hd->b_rptr + hl;
	hd->b_cont = mp;
	return (hd);
}

/*
 * The wifi plugin builds TX headers from pdata: the BSSID (addr1 for STA) and
 * whether there is a QoS pad. Called on every association change, as illumos
 * net80211 ieee80211_mac_update does (net80211.c:115-138). wd_secalloc stays
 * WIFI_SEC_NONE: OpenBSD ieee80211_encap reserves its own crypto header, so
 * the plugin must not reserve one too; wd_qospad stays 0 because the plugin
 * header is converted back to Ethernet before encapsulation.
 */
static void
iwm_gld_set_bss(void *gp, const uint8_t *bssid)
{
	struct iwm_gld *g = gp;

	g->g_wd.wd_secalloc = WIFI_SEC_NONE;
	g->g_wd.wd_opmode = IEEE80211_M_STA;
	g->g_wd.wd_qospad = 0;
	bcopy(bssid, g->g_wd.wd_bssid, IEEE80211_ADDR_LEN);
	(void) mac_pdata_update(g->g_mh, &g->g_wd, sizeof (g->g_wd));
	mac_tx_update(g->g_mh);
}

/*
 * n80211_link_hook (n80211_giant.c), giant dropped: on link up, read the
 * BSSID under giant and push it to the plugin before mac_link_update.
 * mac_pdata_update allocates and notifies mac clients, so it runs unlocked.
 */
extern kmutex_t n80211_giant;
extern mblk_t *(*n80211_rx_xlate)(void *, mblk_t *);
extern void (*n80211_link_hook)(void *, int);
extern void *n80211_xlate_arg;
extern int servicing_interrupt(void);

static void
iwm_gld_link_hook(void *gp, int up)
{
	struct iwm_gld *g = gp;
	struct iwm_il_state st;

	/*
	 * mac_pdata_update allocates KM_SLEEP. An open network reaches RUN in
	 * iwm_newstate_task (a task thread); only the GATED WPA path
	 * (ieee80211_pae_input.c:676) raises link up from the RX interrupt,
	 * and there the plugin keeps the previous BSSID.
	 */
	if (!up || servicing_interrupt())
		return;
	mutex_enter(&n80211_giant);
	iwm_il_getstate(g->g_sc, &st);
	mutex_exit(&n80211_giant);
	iwm_gld_set_bss(g, st.s_bssid);
}

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
	mblk_t *head = NULL, **tailp = &head, *next, *e;

	for (; mp != NULL; mp = next) {
		next = mp->b_next;
		mp->b_next = NULL;
		if ((e = iwm_wifi_to_ether(g->g_mh, mp)) != NULL) {
			*tailp = e;
			tailp = &e->b_next;
		}
	}
	return (head == NULL ? NULL : iwm_il_tx(g->g_sc, head));
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

/*
 * mc_ioctl: WLAN_COMMAND, the only legacy ioctl libdladm still issues
 * (do_cmd_ioctl, libdlwlan.c:1155-1167: WL_SCAN, WL_DISASSOCIATE). The
 * wldp_t sits in b_cont; the reply reuses it, as illumos wifi_setupoutmsg
 * (net80211_ioctl.c:95-103). GET/SET_PARAM are answered WL_LACK_FEATURE:
 * libdladm sends parameters as mac properties, never through this path.
 */
static void
iwm_m_ioctl(void *arg, queue_t *wq, mblk_t *mp)
{
	struct iwm_gld *g = arg;
	struct iocblk *iocp;
	mblk_t *mp1;
	wldp_t *wp;
	int err = 0, n;

	if (MBLKL(mp) < sizeof (struct iocblk)) {
		miocnak(wq, mp, 0, EINVAL);
		return;
	}
	iocp = (struct iocblk *)mp->b_rptr;
	switch (iocp->ioc_cmd) {
	case WLAN_COMMAND:
	case WLAN_SET_PARAM:
		if ((err = secpolicy_dl_config(iocp->ioc_cr)) != 0) {
			miocnak(wq, mp, 0, err);
			return;
		}
		break;
	case WLAN_GET_PARAM:
		break;
	default:
		miocnak(wq, mp, 0, EINVAL);
		return;
	}
	mp1 = mp->b_cont;
	if (mp1 == NULL || iocp->ioc_count < sizeof (wldp_t) ||
	    MBLKL(mp1) < WIFI_BUF_OFFSET) {
		miocnak(wq, mp, 0, EINVAL);
		return;
	}
	if (mp1->b_cont != NULL) {
		freemsg(mp1->b_cont);
		mp1->b_cont = NULL;
	}
	wp = (wldp_t *)mp1->b_rptr;
	wp->wldp_result = WL_SUCCESS;
	if (iocp->ioc_cmd != WLAN_COMMAND) {
		wp->wldp_result = WL_LACK_FEATURE;
		err = ENOTSUP;
	} else {
		n80211_giant_enter();
		switch (wp->wldp_id) {
		case WL_SCAN:
			err = iwm_il_scan(g->g_sc, g->g_scan, IWM_IL_MAXNODES,
			    &n);
			g->g_nscan = (err == 0) ? n : 0;
			break;
		case WL_DISASSOCIATE:
			/* as wifi_cmd_disassoc: drop the BSS, keep running */
			err = iwm_il_set_essid(g->g_sc, NULL, 0);
			break;
		default:
			wp->wldp_result = WL_LACK_FEATURE;
			err = ENOTSUP;
			break;
		}
		n80211_giant_exit();
	}
	wp->wldp_length = WIFI_BUF_OFFSET;
	mp1->b_wptr = mp1->b_rptr + WIFI_BUF_OFFSET;
	miocack(wq, mp, msgdsize(mp1), err);
}

/*
 * MAC_PROP_WL_ESS_LIST, in the format of illumos wifi_read_ap
 * (net80211_ioctl.c:709-813) so dladm's fill_wlan_attr decodes it.
 */
static void
iwm_fill_esslist(const struct iwm_il_node *n, int cnt, void *buf, uint_t sz)
{
	wl_ess_list_t *l = buf;
	wl_ess_conf_t *c;
	int i, j, max;

	max = (sz - offsetof(wl_ess_list_t, wl_ess_list_ess)) /
	    sizeof (wl_ess_conf_t);
	if (cnt > max)
		cnt = max;
	l->wl_ess_list_num = 0;
	for (i = 0; i < cnt; i++, n++) {
		c = &l->wl_ess_list_ess[i];
		bzero(c, sizeof (*c));
		c->wl_ess_conf_length = sizeof (*c);
		c->wl_ess_conf_essid.wl_essid_length = n->n_esslen;
		bcopy(n->n_essid, c->wl_ess_conf_essid.wl_essid_essid,
		    MIN(n->n_esslen, 32));
		bcopy(n->n_bssid, c->wl_ess_conf_bssid, 6);
		c->wl_ess_conf_wepenabled = n->n_privacy ?
		    WL_ENC_WEP : WL_NOENCRYPTION;
		c->wl_ess_conf_bsstype = n->n_ess ? WL_BSS_BSS : WL_BSS_IBSS;
		c->wl_ess_conf_sl = n->n_rssi;
		c->wl_ess_conf_reserved[0] = n->n_rsn;	/* dladm: WPA if > 0 */
		if (n->n_5ghz) {
			wl_ofdm_t *o = (wl_ofdm_t *)&c->wl_phy_conf;

			o->wl_ofdm_subtype = WL_OFDM;
			o->wl_ofdm_frequency = n->n_freq;
			o->wl_ofdm_ht_enabled = n->n_ht;
		} else {
			wl_erp_t *e = (wl_erp_t *)&c->wl_phy_conf;

			e->wl_erp_subtype = WL_ERP;
			e->wl_erp_channel = n->n_chan;
			e->wl_erp_ht_enabled = n->n_ht;
		}
		for (j = 0; j < n->n_nrates && j < MAX_SCAN_SUPPORT_RATES; j++)
			c->wl_supported_rates[j] = (char)n->n_rates[j];
		l->wl_ess_list_num++;
	}
}

/*
 * mc_getprop. REAL: ESSID, BSSID, LINKSTATUS, ESS_LIST, RSSI,
 * DESIRED_RATES (the current TX rate, as wl_get_desrates), ENCRYPTION,
 * AUTH_MODE (open), BSSTYPE (BSS), CAPABILITY (no WEP/WPA advertised, so
 * dladm connect-wifi -k refuses a keyed network up front instead of failing
 * later). Everything else ENOTSUP.
 */
static int
iwm_m_getprop(void *arg, const char *name, mac_prop_id_t id, uint_t sz,
    void *val)
{
	struct iwm_gld *g = arg;
	struct iwm_il_state st;
	struct iwm_il_node *n;
	int err = 0, cnt;

	(void) name;
	n80211_giant_enter();
	iwm_il_getstate(g->g_sc, &st);
	switch (id) {
	case MAC_PROP_WL_ESSID: {
		wl_essid_t *e = val;

		if (sz < sizeof (*e)) {
			err = EINVAL;
			break;
		}
		bzero(e, sizeof (*e));
		e->wl_essid_length = st.s_esslen;
		bcopy(st.s_essid, e->wl_essid_essid, MIN(st.s_esslen, 32));
		break;
	}
	case MAC_PROP_WL_BSSID:
		if (sz < sizeof (wl_bssid_t)) {
			err = EINVAL;
			break;
		}
		bcopy(st.s_bssid, val, sizeof (wl_bssid_t));
		break;
	case MAC_PROP_WL_LINKSTATUS:
		if (sz < sizeof (wl_linkstatus_t)) {
			err = EINVAL;
			break;
		}
		*(wl_linkstatus_t *)val = st.s_connected ?
		    WL_CONNECTED : WL_NOTCONNECTED;
		break;
	case MAC_PROP_WL_ESS_LIST:
		if (sz < sizeof (wl_ess_list_t)) {
			err = EINVAL;
			break;
		}
		if (st.s_running) {
			/* live tree; refresh the snapshot as well */
			n = g->g_scan;
			g->g_nscan = iwm_il_nodes(g->g_sc, n, IWM_IL_MAXNODES);
		}
		cnt = g->g_nscan;
		iwm_fill_esslist(g->g_scan, cnt, val, sz);
		break;
	case MAC_PROP_WL_RSSI:
		if (sz < sizeof (wl_rssi_t)) {
			err = EINVAL;
			break;
		}
		*(wl_rssi_t *)val = st.s_rssi;
		break;
	case MAC_PROP_WL_DESIRED_RATES: {
		wl_rates_t *r = val;

		if (sz < sizeof (*r)) {
			err = EINVAL;
			break;
		}
		r->wl_rates_num = 1;
		r->wl_rates_rates[0] = (char)st.s_rate;
		break;
	}
	case MAC_PROP_WL_ENCRYPTION:
		if (sz < sizeof (wl_encryption_t)) {
			err = EINVAL;
			break;
		}
		*(wl_encryption_t *)val = st.s_rsn ? WL_ENC_WPA :
		    WL_NOENCRYPTION;
		break;
	case MAC_PROP_WL_AUTH_MODE:
		if (sz < sizeof (wl_authmode_t)) {
			err = EINVAL;
			break;
		}
		*(wl_authmode_t *)val = WL_OPENSYSTEM;
		break;
	case MAC_PROP_WL_BSSTYPE:
		if (sz < sizeof (wl_bss_type_t)) {
			err = EINVAL;
			break;
		}
		*(wl_bss_type_t *)val = WL_BSS_BSS;
		break;
	case MAC_PROP_WL_CAPABILITY:
		if (sz < sizeof (wl_capability_t)) {
			err = EINVAL;
			break;
		}
		/*
		 * Advertise WPA2 so a WPA client is not refused up front
		 * (libdlwlan do_connect checks caps & IEEE80211_C_WPA). The
		 * join itself is OpenBSD's in-kernel RSN supplicant, driven
		 * by the _wpa_psk private property below; wpad is not used.
		 */
		((wl_capability_t *)val)->caps = IEEE80211_C_WPA2;
		break;
	case MAC_PROP_WL_PHY_CONFIG:
		/*
		 * As illumos net80211 wl_get_phy: OFDM with the frequency on
		 * 5 GHz, ERP with the channel on 2.4 GHz. libdladm reads it
		 * once associated (dladm_wlan_get_linkattr), so ENOTSUP here
		 * failed every show-wifi of a connected link.
		 */
		if (sz < sizeof (wl_phy_conf_t)) {
			err = EINVAL;
			break;
		}
		bzero(val, sizeof (wl_phy_conf_t));
		if (st.s_5ghz) {
			wl_ofdm_t *o = val;

			o->wl_ofdm_subtype = WL_OFDM;
			o->wl_ofdm_frequency = st.s_freq;
			o->wl_ofdm_ht_enabled = st.s_ht;
		} else {
			wl_erp_t *e = val;

			e->wl_erp_subtype = WL_ERP;
			e->wl_erp_channel = st.s_chan;
			e->wl_erp_ht_enabled = st.s_ht;
		}
		break;
	default:
		err = ENOTSUP;
		break;
	}
	n80211_giant_exit();
	return (err);
}

/*
 * mc_setprop. REAL: ESSID (OpenBSD SIOCS80211NWID semantics, restarting
 * the radio when it runs), ENCRYPTION/AUTH_MODE/BSSTYPE accepted only at
 * the one value the bridge supports (none / open / BSS), which is what
 * dladm connect-wifi sets for an open network before the ESSID
 * (do_connect, libdlwlan.c:448-470). GATED (ENOTSUP): KEY_TAB, WPA, KEY,
 * DELKEY, SETOPTIE, MLME (the wpad door path), PHY_CONFIG (channel pinning),
 * CREATE_IBSS, DESIRED_RATES.
 */
static int
iwm_m_setprop(void *arg, const char *name, mac_prop_id_t id, uint_t sz,
    const void *val)
{
	struct iwm_gld *g = arg;
	int err = 0;

	(void) name;
	switch (id) {
	case MAC_PROP_WL_ESSID: {
		const wl_essid_t *e = val;

		if (sz < sizeof (*e) || e->wl_essid_length > 32)
			return (EINVAL);
		n80211_giant_enter();
		err = iwm_il_set_essid(g->g_sc,
		    (const uint8_t *)e->wl_essid_essid,
		    (int)e->wl_essid_length);
		n80211_giant_exit();
		return (err);
	}
	case MAC_PROP_WL_ENCRYPTION:
		if (sz < sizeof (wl_encryption_t))
			return (EINVAL);
		return (*(const wl_encryption_t *)val == WL_NOENCRYPTION ?
		    0 : ENOTSUP);
	case MAC_PROP_WL_AUTH_MODE:
		if (sz < sizeof (wl_authmode_t))
			return (EINVAL);
		return (*(const wl_authmode_t *)val == WL_OPENSYSTEM ?
		    0 : ENOTSUP);
	case MAC_PROP_WL_BSSTYPE:
		if (sz < sizeof (wl_bss_type_t))
			return (EINVAL);
		return (*(const wl_bss_type_t *)val == WL_BSS_BSS ?
		    0 : ENOTSUP);
	case MAC_PROP_PRIVATE: {
		uint8_t pmk[IWM_PMK_LEN];
		uint8_t bssid[6];
		const uint8_t *bssidp = NULL;
		const char *s = val;
		const char *essid;
		int esslen;

		if (name == NULL || strcmp(name, IWM_PRIV_WPA_PSK) != 0)
			return (ENOTSUP);
		/*
		 * Value is "<64 hex PMK>:<bssid-or-->:<ssid>": the 32-byte PMK
		 * (fixed 64 hex) and a colon, then a fixed-position BSSID field
		 * that is either 17 chars "aa:bb:cc:dd:ee:ff" or a single '-'
		 * (no pin), another colon, then the SSID (last, may contain any
		 * byte including ':'). dladm rejects '|' in a value, and the SSID
		 * may contain ':', so the BSSID is placed at a FIXED position
		 * rather than used as a suffix. This single set carries key +
		 * optional AP pin + network and drives the keyed join (connect-wifi
		 * will not do WPA without wpad). sz is the value length; dladm may
		 * or may not include the trailing NUL.
		 */
		if (sz < IWM_PMK_LEN * 2 + 3 || s[IWM_PMK_LEN * 2] != ':') {
			cmn_err(CE_NOTE, "!iwm: _wpa_psk bad format sz=%u", sz);
			return (EINVAL);
		}
		if (iwm_hex2pmk(s, sz, pmk) != 0) {
			cmn_err(CE_NOTE, "!iwm: _wpa_psk bad hex");
			return (EINVAL);
		}
		{
			const char *f2 = s + IWM_PMK_LEN * 2 + 1;
			int rem = (int)(sz - (IWM_PMK_LEN * 2 + 1));

			/* field 2: "-" (no pin) or a 17-char BSSID, then ':' */
			if (rem >= 2 && f2[0] == '-' && f2[1] == ':') {
				essid = f2 + 2;
				esslen = rem - 2;
			} else if (rem >= 18 && f2[17] == ':' &&
			    iwm_parse_bssid(f2, 17, bssid) == 0) {
				bssidp = bssid;
				essid = f2 + 18;
				esslen = rem - 18;
			} else {
				cmn_err(CE_NOTE, "!iwm: _wpa_psk bad bssid field");
				bzero(pmk, sizeof (pmk));
				return (EINVAL);
			}
		}
		while (esslen > 0 && (essid[esslen - 1] == '\0' ||
		    essid[esslen - 1] == '\n'))
			esslen--;
		if (esslen < 1 || esslen > 32) {
			cmn_err(CE_NOTE, "!iwm: _wpa_psk bad ssid len=%d", esslen);
			bzero(pmk, sizeof (pmk));
			return (EINVAL);
		}
		n80211_giant_enter();
		err = iwm_il_join(g->g_sc, (const uint8_t *)essid, esslen,
		    pmk, IWM_PMK_LEN, bssidp);
		n80211_giant_exit();
		bzero(pmk, sizeof (pmk));
		return (err);
	}
	default:
		return (ENOTSUP);
	}
}

/* Read-only properties, as illumos ieee80211_propinfo (net80211_ioctl.c). */
static void
iwm_m_propinfo(void *arg, const char *name, mac_prop_id_t id,
    mac_prop_info_handle_t ph)
{
	(void) arg;
	switch (id) {
	case MAC_PROP_WL_LINKSTATUS:
	case MAC_PROP_WL_ESS_LIST:
	case MAC_PROP_WL_SUPPORTED_RATES:
	case MAC_PROP_WL_RSSI:
	case MAC_PROP_WL_CAPABILITY:
	case MAC_PROP_WL_PHY_CONFIG:
	case MAC_PROP_WL_SCANRESULTS:
	case MAC_PROP_WL_CREATE_IBSS:
		mac_prop_info_set_perm(ph, MAC_PROP_PERM_READ);
		break;
	case MAC_PROP_PRIVATE:
		if (name != NULL && strcmp(name, IWM_PRIV_WPA_PSK) == 0)
			mac_prop_info_set_perm(ph, MAC_PROP_PERM_WRITE);
		break;
	default:
		break;
	}
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
	int err;

	g = kmem_zalloc(sizeof (*g), KM_SLEEP);
	g->g_sc = sc;
	bcopy(addr, g->g_addr, ETHERADDRL);

	macp = mac_alloc(MAC_VERSION);
	if (macp == NULL) {
		kmem_free(g, sizeof (*g));
		return (ENOMEM);
	}
	g->g_wd.wd_secalloc = WIFI_SEC_NONE;
	g->g_wd.wd_opmode = IEEE80211_M_STA;
	macp->m_type_ident = MAC_PLUGIN_IDENT_WIFI;
	macp->m_driver = g;
	macp->m_dip = dip;
	macp->m_src_addr = g->g_addr;
	macp->m_callbacks = &iwm_m_callbacks;
	macp->m_min_sdu = 0;
	macp->m_max_sdu = IEEE80211_MTU;
	macp->m_pdata = &g->g_wd;
	macp->m_pdata_size = sizeof (g->g_wd);
	macp->m_priv_props = iwm_priv_props;
	err = mac_register(macp, &g->g_mh);
	mac_free(macp);
	if (err != 0) {
		kmem_free(g, sizeof (*g));
		return (err);
	}
	mac_link_update(g->g_mh, LINK_STATE_DOWN);
	n80211_xlate_arg = g;
	n80211_link_hook = iwm_gld_link_hook;
	n80211_rx_xlate = iwm_gld_rx_frame;
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
	if (err == 0) {
		n80211_rx_xlate = NULL;
		n80211_link_hook = NULL;
		n80211_xlate_arg = NULL;
		kmem_free(g, sizeof (*g));
	}
	return (err);
}

void *
iwm_gld_mac_handle(void *gp)
{
	return (((struct iwm_gld *)gp)->g_mh);
}

/*
 * The GLDv3 driver name: mac_init_ops marks THIS name's major as a GLDv3
 * driver, and mac_register refuses (EINVAL) a dip whose major is not marked.
 * The iwx build compiles this file too and must pass "iwx" (its own major),
 * the same #ifndef default pattern as N80211_FW_MODULE in n80211_giant.c.
 */
#ifndef N80211_DRV_NAME
#define	N80211_DRV_NAME	"iwm"
#endif

void
iwm_gld_init_ops(struct dev_ops *ops)
{
	mac_init_ops(ops, N80211_DRV_NAME);
}

/*
 * mac_init_ops returns before dld_init_ops when the driver has no major
 * number (mac.c:515), leaving cb_str NULL, and dld_fini_ops dereferences
 * cb_str unconditionally (dld_str.c:536-539). That is exactly the _init
 * failure path of a load with no name_to_major entry (mod_installdrv fails
 * ENXIO, modconf.c:568), so only undo what was done.
 */
void
iwm_gld_fini_ops(struct dev_ops *ops)
{
	if (ops->devo_cb_ops != NULL && ops->devo_cb_ops->cb_str != NULL)
		mac_fini_ops(ops);
}
