/*
 * iwm_il.h -- plain-C interface between iwm_gld.c (illumos headers only) and
 * iwm_attach.c (OpenBSD headers). Neither world's headers can be included
 * in the other's translation unit, so the WLDP bridge passes only these
 * fixed-width structs. Every iwm_il_* function declared here except
 * start/stop/tx expects the caller to hold n80211_giant.
 */
#ifndef IWM_IL_H
#define	IWM_IL_H

#define	IWM_IL_MAXNODES	64

/* one scan result: what wifi_read_ap (illumos net80211_ioctl.c) reports */
struct iwm_il_node {
	uint8_t		n_bssid[6];
	uint8_t		n_esslen;
	uint8_t		n_essid[32];
	uint8_t		n_rssi;		/* 0..15, the WLDP scale */
	uint8_t		n_chan;		/* IEEE channel number */
	uint8_t		n_5ghz;
	uint8_t		n_privacy;	/* CAPINFO_PRIVACY */
	uint8_t		n_ess;		/* CAPINFO_ESS */
	uint8_t		n_rsn;		/* RSN/WPA IE present */
	uint8_t		n_ht;
	uint8_t		n_nrates;
	uint8_t		n_rates[8];	/* highest first, 500 kb/s units */
	uint16_t	n_freq;		/* MHz */
};

struct iwm_il_state {
	int		s_running;	/* IFF_RUNNING */
	int		s_connected;	/* IEEE80211_S_RUN */
	int		s_rsn;		/* RSN enabled */
	uint8_t		s_esslen;
	uint8_t		s_essid[32];
	uint8_t		s_bssid[6];
	uint8_t		s_rssi;		/* 0..15 */
	uint8_t		s_rate;		/* 500 kb/s units, 0 if unknown */
	uint8_t		s_chan;		/* BSS IEEE channel, 0 if none */
	uint8_t		s_5ghz;
	uint8_t		s_ht;
	uint16_t	s_freq;		/* BSS MHz, 0 if none */
};

extern int iwm_il_start(void *);
extern void iwm_il_stop(void *);
extern mblk_t *iwm_il_tx(void *, mblk_t *);

extern void iwm_il_getstate(void *, struct iwm_il_state *);
extern int iwm_il_nodes(void *, struct iwm_il_node *, int);
extern int iwm_il_scan(void *, struct iwm_il_node *, int, int *);
extern int iwm_il_set_essid(void *, const uint8_t *, int);
extern int iwm_il_join(void *, const uint8_t *, int, const uint8_t *, int,
    const uint8_t *);

extern void n80211_giant_enter(void);
extern void n80211_giant_exit(void);

#endif /* IWM_IL_H */
