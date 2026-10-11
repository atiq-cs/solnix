/*
 * net80211-only <net/bpf.h>. Shadows iwx/compat/net/bpf.h (by -I order) to add
 * DLT_IEEE802_11, which net80211's raw-frame injection path (ieee80211_output)
 * compares against but iwx's bpf.h does not define. Same discipline: illumos
 * has no in-kernel bpf tap on this driver path, NBPFILTER=0, so every
 * "#if NBPFILTER > 0" tap is compiled out and monitor mode / injection do NOT
 * work. KNOWN GAP, tagged -- nothing here captures or injects. Values match
 * upstream libpcap DLTs and iwx/compat/net/bpf.h.
 */
#ifndef _N80211_COMPAT_NET_BPF_H
#define _N80211_COMPAT_NET_BPF_H

#define DLT_IEEE802_11		105
#define DLT_IEEE802_11_RADIO	127
#define BPF_DIRECTION_IN	1
#define BPF_DIRECTION_OUT	2

#endif /* _N80211_COMPAT_NET_BPF_H */
