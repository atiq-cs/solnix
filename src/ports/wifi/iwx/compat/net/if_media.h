/*
 * OpenBSD <net/if_media.h> subset. iwx uses it only via net80211's ic_media,
 * and net80211 in turn only for the media-status/change callbacks.
 * Types are REAL; the ifmedia list operations are stubs at LINK level.
 */
#ifndef _IWX_COMPAT_NET_IF_MEDIA_H
#define _IWX_COMPAT_NET_IF_MEDIA_H
#include <sys/types.h>
#include <sys/queue.h>

struct ifnet;
struct ifmediareq;

typedef int (*ifm_change_cb_t)(struct ifnet *);
typedef void (*ifm_stat_cb_t)(struct ifnet *, struct ifmediareq *);

struct ifmedia_entry {
	TAILQ_ENTRY(ifmedia_entry) ifm_list;
	uint64_t	ifm_media;
	uint64_t	ifm_data;
	void		*ifm_aux;
};

struct ifmedia {
	uint64_t	ifm_mask;
	uint64_t	ifm_media;
	struct ifmedia_entry *ifm_cur;
	TAILQ_HEAD(, ifmedia_entry) ifm_list;
	ifm_change_cb_t	ifm_change;
	ifm_stat_cb_t	ifm_status;
};

struct ifmediareq {
	char		ifm_name[16];
	uint64_t	ifm_current;
	uint64_t	ifm_mask;
	uint64_t	ifm_status;
	uint64_t	ifm_active;
	int		ifm_count;
	uint64_t	*ifm_ulist;
};

#define IFM_TYPE_MASK		0x000000ff
#define IFM_IEEE80211		0x00000080
#define IFM_AUTO		0
#define IFM_MANUAL		1
#define IFM_NONE		2
#define IFM_ACTIVE		0x0000000000000002ULL
#define IFM_AVALID		0x0000000000000001ULL
#define IFM_MAKEWORD(t, s, o, i)	((t) | (s) | (o) | ((uint64_t)(i) << 32))
#define IFM_SUBTYPE(x)		((x) & 0x0000ff00)
#define IFM_OPTIONS(x)		((x) & 0x00ff0000)
#define IFM_INST(x)		(((x) >> 32) & 0xff)
#define IFM_INST_ANY		((uint64_t)-1)

/*
 * OpenBSD <net80211/ieee80211_ifmedia.h> subtype/mode/option constants. These
 * are pure enumerants used to BUILD net80211's media table; the table machinery
 * (ifmedia_add/ifmedia_set) remains declared-only and fails at LINK by name.
 * Values match OpenBSD upstream so a re-fetch diff of the constant block is
 * clean. Route (b) drives 11n/WPA2 -- the VHT/HE entries are present only so
 * ieee80211_media_init's table-build loop compiles unchanged.
 */
#define IFM_IEEE80211_ADHOC	0x00000100
#define IFM_IEEE80211_HOSTAP	0x00000200
#define IFM_IEEE80211_IBSS	0x00000400
#define IFM_IEEE80211_IBSSMASTER 0x00000800
#define IFM_IEEE80211_MONITOR	0x00001000

/* modes (bits 20-27) */
#define IFM_IEEE80211_11A	0x00100000
#define IFM_IEEE80211_11B	0x00200000
#define IFM_IEEE80211_11G	0x00300000
#define IFM_IEEE80211_FH	0x00400000
#define IFM_IEEE80211_11N	0x00800000
#define IFM_IEEE80211_11AC	0x00900000
#define IFM_IEEE80211_11AX	0x00a00000

/* subtypes: DS/OFDM rates (bits 8-15) */
#define IFM_IEEE80211_DS1	0x00000200
#define IFM_IEEE80211_DS2	0x00000300
#define IFM_IEEE80211_DS5	0x00000400
#define IFM_IEEE80211_DS11	0x00000500
#define IFM_IEEE80211_DS22	0x00000600
#define IFM_IEEE80211_OFDM6	0x00000700
#define IFM_IEEE80211_OFDM9	0x00000800
#define IFM_IEEE80211_OFDM12	0x00000900
#define IFM_IEEE80211_OFDM18	0x00000a00
#define IFM_IEEE80211_OFDM24	0x00000b00
#define IFM_IEEE80211_OFDM36	0x00000c00
#define IFM_IEEE80211_OFDM48	0x00000d00
#define IFM_IEEE80211_OFDM54	0x00000e00
#define IFM_IEEE80211_OFDM72	0x00000f00
/* HT/VHT/HE MCS ranges; net80211 uses the base + an MCS offset */
#define IFM_IEEE80211_HT_MCS0	0x00001000
#define IFM_IEEE80211_HT_MCS76	0x0000104c
#define IFM_IEEE80211_VHT_MCS0	0x00002000
#define IFM_IEEE80211_VHT_MCS9	0x00002009
#define IFM_IEEE80211_HE_MCS0	0x00003000

extern void ifmedia_init(struct ifmedia *, uint64_t, ifm_change_cb_t,
    ifm_stat_cb_t);
extern void ifmedia_add(struct ifmedia *, uint64_t, int, void *);
extern void ifmedia_delete_instance(struct ifmedia *, uint64_t);
extern int ifmedia_ioctl(struct ifnet *, void *, struct ifmedia *, unsigned long);
extern void ifmedia_set(struct ifmedia *, uint64_t);
#endif
