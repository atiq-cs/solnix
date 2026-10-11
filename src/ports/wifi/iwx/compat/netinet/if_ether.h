/*
 * OpenBSD <netinet/if_ether.h>: struct arpcom, the ifnet-plus-MAC-address
 * container that OpenBSD ethernet drivers embed.
 *
 * ⚠ illumos ALSO has a struct arpcom (netinet/if_ether.h), and its ac_enaddr is
 * a `struct ether_addr` while OpenBSD's is a raw uint8_t[6]. That difference is
 * silent at the memcpy in IEEE80211_ADDR_COPY -- it happens to be the same 6
 * bytes today, so it would "work" -- but it is a type pun across two unrelated
 * definitions of the same struct name, and the two structs have entirely
 * different LAYOUTS. if_iwx.c:12113 casts an ifnet* to arpcom*, which is only
 * valid if ifnet is the FIRST member, and it is not in illumos's version.
 *
 * So OpenBSD's layout is defined here explicitly and illumos's is not used.
 * REAL, and load-bearing: getting this wrong reads the MAC from the wrong offset.
 */
#ifndef _IWX_COMPAT_NETINET_IF_ETHER_H
#define _IWX_COMPAT_NETINET_IF_ETHER_H

#include <sys/types.h>
#include <net/if.h>

#ifndef ETHER_ADDR_LEN
#define ETHER_ADDR_LEN	6
#endif
#define ETHER_HDR_LEN	14
#define ETHER_CRC_LEN	4
#define ETHER_MIN_LEN	64
#define ETHER_MAX_LEN	1518
#define ETHERMTU	1500

/* illumos sys/ethernet.h already defines struct ether_header identically. */
#include <sys/ethernet.h>

/*
 * OpenBSD layout: struct ifnet FIRST, so the (struct arpcom *)ifp cast at
 * if_iwx.c:12113 is valid and ac_enaddr is a plain byte array.
 */
struct arpcom {
	struct ifnet	ac_if;
	uint8_t		ac_enaddr[ETHER_ADDR_LEN];
	uint8_t		ac_pad[2];
	void		*ac_ipac;
	int		ac_multicnt;
	int		ac_multirangecnt;
};

#define ETHERTYPE_IP	0x0800
#define ETHERTYPE_ARP	0x0806
#define ETHERTYPE_IPV6	0x86dd
#define ETHERTYPE_PAE	0x888e

#endif /* _IWX_COMPAT_NETINET_IF_ETHER_H */
