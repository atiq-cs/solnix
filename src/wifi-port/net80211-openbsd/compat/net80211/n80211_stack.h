/*
 * net80211 stack shims: the OpenBSD network-stack entry points net80211 calls
 * DOWN into (ether_*, if_*, ifmedia_*, rtm_*), plus the OpenBSD wireless ioctl
 * (SIOCS/G80211*) command numbers. These are the "network stack does not map"
 * wall from FINDINGS.md Finding 2: illumos has no ifmedia, no ether_*, and
 * GLDv3 inverts the direction of control (the stack calls INTO the driver via
 * mac_rx/mac_tx, it is not called down into).
 *
 * DISCIPLINE: everything here is DECLARED ONLY -- it fails at LINK with its own
 * name, which is the correct failure mode for a stack-integration boundary.
 * These are the adapter surface a route-(b) self-contained-module port must
 * implement (in a future n80211_gld.c) to bridge net80211's downward calls onto
 * GLDv3's upward-push model. Declaring them lets the 43 blocking ieee80211_*
 * symbols be produced as real .o text symbols WITHOUT prematurely committing to
 * that adapter's semantics; nothing here is claimed to link or run.
 */
#ifndef _N80211_STACK_H
#define _N80211_STACK_H

#include <sys/types.h>
#include <sys/sockio.h>			/* SIOCADDMULTI, SIOCDELMULTI, SIOCSIFMTU */
#include <net/if.h>
#include <net/if_media.h>
#include <netinet/if_ether.h>

/* ifmedia instance-any wildcard (OpenBSD <net/if_media.h>). */
#ifndef IFM_INST_ANY
#define IFM_INST_ANY	((uint64_t)-1)
#endif

/*
 * ether_* -- OpenBSD's ethernet glue. On illumos these responsibilities live in
 * GLDv3 (mac_register / mac_multicst / the mac_callbacks vector). DECL: the
 * route-(b) adapter maps them there.
 *
 * ether_sprintf is NOT declared here: iwx/compat/sys/iwx_kernel.h already maps
 * it (a macro casting net80211's uint8_t* arg to illumos's struct ether_addr*),
 * so it is redirected to illumos's real symbol -- see the FINDINGS note that
 * this is the one ether_* with an illumos namesake.
 */
extern int   ether_ifattach(struct ifnet *);
extern void  ether_ifdetach(struct ifnet *);
extern int   ether_ioctl(struct ifnet *, struct arpcom *, unsigned long, caddr_t);
extern int   ether_addmulti(struct ifreq *, struct arpcom *);
extern int   ether_delmulti(struct ifreq *, struct arpcom *);
extern void  ether_input(struct ifnet *, mblk_t *);
extern int   ether_output(struct ifnet *, mblk_t *, struct sockaddr *,
	struct rtentry *);
extern uint32_t ether_crc32_le(const uint8_t *, size_t);

/*
 * if_* -- interface-registry glue. if_addgroup/if_deactivate are OpenBSD
 * interface-group and detach hooks with no illumos analogue; if_start pushes
 * the send queue (GLDv3 instead calls mac_tx into the driver);
 * if_link_state_change reports carrier (-> mac_link_update). DECL.
 */
extern void if_start(struct ifnet *);
extern int  if_addgroup(struct ifnet *, const char *);
extern void if_deactivate(struct ifnet *);
extern void if_link_state_change(struct ifnet *);
extern void if_congestion(void);

/*
 * rtm_80211info -- OpenBSD routing-socket wireless event. illumos has no
 * PF_ROUTE 802.11 message; the route-(b) adapter drops it or maps it to a MAC
 * notification. DECL. struct if_ieee80211_data is OpenBSD's <net/if.h>
 * routing-message payload; net80211 fills it by value (needs a complete type),
 * so it is defined here with the fields ieee80211_rtm_80211info_task sets
 * (nwid/addr/channel/flags). Layout matches OpenBSD upstream.
 */
struct if_ieee80211_data {
	uint8_t		ifie_nwid[32];
	uint8_t		ifie_addr[6];
	uint8_t		ifie_nwid_len;
	uint8_t		ifie_channel;
	uint32_t	ifie_flags;
	uint32_t	ifie_xflags;
};
extern void rtm_80211info(struct ifnet *, struct if_ieee80211_data *);

/*
 * OpenBSD wireless ioctl command numbers (SIOCS80211* / SIOCG80211*) and
 * SIOCGIFMEDIA. illumos userland (dladm, wpa_s via WPA_DOOR) does not issue
 * these -- ieee80211_ioctl.c needs them only to COMPILE its 36-case switch.
 * Whether to expose this ABI or rewrite the 536-line path against mac_prop is
 * the open route-(b) decision recorded in FINDINGS.md Finding 2. Values are
 * OpenBSD's (a private _IOWR namespace); they are never seen by illumos tools.
 */
#ifndef SIOCGIFMEDIA
#define SIOCGIFMEDIA	_IOWR('i', 56, struct ifmediareq)
#endif
#ifndef SIOCSIFMEDIA
#define SIOCSIFMEDIA	_IOWR('i', 55, struct ifreq)
#endif

#define SIOCS80211NWID		_IOW('i', 230, struct ifreq)
#define SIOCG80211NWID		_IOWR('i', 231, struct ifreq)
#define SIOCS80211NWKEY		_IOW('i', 232, struct ifreq)
#define SIOCG80211NWKEY		_IOWR('i', 233, struct ifreq)
#define SIOCS80211POWER		_IOW('i', 234, struct ifreq)
#define SIOCG80211POWER		_IOWR('i', 235, struct ifreq)
#define SIOCS80211BSSID		_IOW('i', 236, struct ifreq)
#define SIOCG80211BSSID		_IOWR('i', 237, struct ifreq)
#define SIOCS80211CHANNEL	_IOW('i', 238, struct ifreq)
#define SIOCG80211CHANNEL	_IOWR('i', 239, struct ifreq)
#define SIOCS80211TXPOWER	_IOW('i', 240, struct ifreq)
#define SIOCG80211TXPOWER	_IOWR('i', 241, struct ifreq)
#define SIOCS80211SCAN		_IOW('i', 242, struct ifreq)
#define SIOCG80211ALLNODES	_IOWR('i', 243, struct ifreq)
#define SIOCG80211ALLCHANS	_IOWR('i', 244, struct ifreq)
#define SIOCG80211FLAGS		_IOWR('i', 245, struct ifreq)
#define SIOCS80211FLAGS		_IOW('i', 246, struct ifreq)
#define SIOCS80211NODE		_IOW('i', 247, struct ifreq)
#define SIOCG80211NODE		_IOWR('i', 248, struct ifreq)
#define SIOCS80211DELNODE	_IOW('i', 249, struct ifreq)
#define SIOCG80211STATS		_IOWR('i', 250, struct ifreq)
#define SIOCG80211ZSTATS	_IOWR('i', 251, struct ifreq)
#define SIOCS80211WPAPARMS	_IOW('i', 252, struct ifreq)
#define SIOCG80211WPAPARMS	_IOWR('i', 253, struct ifreq)
#define SIOCS80211WPAPSK	_IOW('i', 254, struct ifreq)
#define SIOCG80211WPAPSK	_IOWR('i', 255, struct ifreq)
#define SIOCS80211JOIN		_IOW('i', 256, struct ifreq)
#define SIOCG80211JOIN		_IOWR('i', 257, struct ifreq)
#define SIOCG80211JOINALL	_IOWR('i', 258, struct ifreq)
#define SIOCS80211KEYAVAIL	_IOW('i', 259, struct ifreq)
#define SIOCS80211KEYRUN	_IOW('i', 260, struct ifreq)

#endif /* _N80211_STACK_H */
