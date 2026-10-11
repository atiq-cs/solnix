/*
 * OpenBSD <net/bpf.h>: iwx taps frames for radiotap monitor mode.
 *
 * illumos has no in-kernel BPF tap on this path. NBPFILTER is 0 in
 * compat/bpfilter.h, so every bpf_mtap call in if_iwx.c is inside
 * "#if NBPFILTER > 0" and is COMPILED OUT. Monitor mode therefore does not
 * work, and that is a KNOWN GAP, tagged, not a silent stub: nothing here
 * pretends to capture.
 */
#ifndef _IWX_COMPAT_NET_BPF_H
#define _IWX_COMPAT_NET_BPF_H
#define DLT_IEEE802_11_RADIO	127
#define BPF_DIRECTION_IN	1
#define BPF_DIRECTION_OUT	2
#endif
