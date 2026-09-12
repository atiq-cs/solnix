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

extern void ifmedia_init(struct ifmedia *, uint64_t, ifm_change_cb_t,
    ifm_stat_cb_t);
extern void ifmedia_add(struct ifmedia *, uint64_t, int, void *);
extern void ifmedia_delete_instance(struct ifmedia *, uint64_t);
extern int ifmedia_ioctl(struct ifnet *, void *, struct ifmedia *, unsigned long);
extern void ifmedia_set(struct ifmedia *, uint64_t);
#endif
