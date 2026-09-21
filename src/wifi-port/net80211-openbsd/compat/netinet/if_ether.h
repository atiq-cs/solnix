/*
 * net80211-only <netinet/if_ether.h> -- OpenBSD ethernet layout.
 *
 * WHY THIS SHADOWS iwx/compat/netinet/if_ether.h (searched later on -I):
 *
 * illumos <sys/ethernet.h> defines struct ether_header with `struct ether_addr
 * ether_dhost/ether_shost` (a struct), whereas OpenBSD -- which net80211 was
 * written against -- uses `u_int8_t ether_dhost[6]` (a byte array). net80211
 * treats those fields as byte arrays: IEEE80211_ADDR_COPY(eh.ether_dhost, ...)
 * expands to memcpy(eh.ether_dhost, ...) and ETHER_IS_MULTICAST(eh->ether_dhost)
 * subscripts [0]. Against the illumos struct that is 8 memcpy type errors and a
 * "subscripted value is not an array" per decap/output site (measured).
 *
 * iwx does NOT touch struct ether_header's FIELDS (it only declares
 * `struct ether_header *eh;` and never dereferences a member -- verified:
 * `grep eh-> if_iwx.c` is empty), so iwx is unaffected by which layout wins in
 * ITS translation unit, and this header is confined to the net80211 build via
 * the -Icompat search order. The two builds never share a translation unit.
 *
 * This header is SELF-CONTAINED: it defines the OpenBSD ether types and
 * suppresses illumos <sys/ethernet.h> (by pre-defining its guard) so the two
 * struct ether_header definitions can never collide inside one net80211 .c.
 * REAL and load-bearing -- getting the layout wrong reads/writes the MAC at the
 * wrong offset, the same class of trap iwx/compat/netinet/if_ether.h records
 * for struct arpcom.
 */
#ifndef _N80211_COMPAT_NETINET_IF_ETHER_H
#define _N80211_COMPAT_NETINET_IF_ETHER_H

#include <sys/types.h>
#include <sys/iwx_bsdtypes.h>	/* u_int8_t / u_int16_t (== uint*_t) before iwx_prelude */

/* Keep illumos <sys/ethernet.h> from also defining struct ether_header with
 * the struct-ether_addr layout: pre-set its include guard. Everything that
 * header would have provided and net80211 needs is provided below. */
#ifndef _SYS_ETHERNET_H
#define _SYS_ETHERNET_H
#endif

#ifndef ETHER_ADDR_LEN
#define ETHER_ADDR_LEN	6
#endif
#define ETHERADDRL	ETHER_ADDR_LEN
#define ETHER_HDR_LEN	14
#define ETHER_CRC_LEN	4
#define ETHER_TYPE_LEN	2
#define ETHER_MIN_LEN	64
#define ETHER_MAX_LEN	1518
#define ETHERMTU	1500
#define ETHERMIN	(ETHER_MIN_LEN - ETHER_CRC_LEN - ETHER_HDR_LEN)

/* OpenBSD byte-array ethernet address; first member matches illumos's
 * ether_addr_octet so the (struct ether_addr *)ni_macaddr casts in
 * ieee80211_node.c stay correct. */
struct ether_addr {
	u_int8_t	ether_addr_octet[ETHER_ADDR_LEN];
};

/* OpenBSD struct ether_header: byte-array MAC fields. */
struct ether_header {
	u_int8_t	ether_dhost[ETHER_ADDR_LEN];
	u_int8_t	ether_shost[ETHER_ADDR_LEN];
	u_int16_t	ether_type;
};

#define ETHER_IS_MULTICAST(addr)	(*(const u_int8_t *)(addr) & 0x01)
#define ETHER_IS_BROADCAST(addr) \
	(((const u_int8_t *)(addr))[0] == 0xff && \
	 ((const u_int8_t *)(addr))[1] == 0xff && \
	 ((const u_int8_t *)(addr))[2] == 0xff && \
	 ((const u_int8_t *)(addr))[3] == 0xff && \
	 ((const u_int8_t *)(addr))[4] == 0xff && \
	 ((const u_int8_t *)(addr))[5] == 0xff)

#define ETHERTYPE_IP	0x0800
#define ETHERTYPE_ARP	0x0806
#define ETHERTYPE_IPV6	0x86dd
#define ETHERTYPE_PAE	0x888e
#define ETHERTYPE_EAPOL	ETHERTYPE_PAE

/*
 * struct arpcom -- OpenBSD's ifnet-plus-MAC container, embedded by value in
 * ieee80211com (ic_ac). Mirrors iwx/compat/netinet/if_ether.h EXACTLY (ifnet
 * FIRST, byte-array ac_enaddr) so ieee80211com's ic_ac is a complete type in
 * the net80211 build; that iwx header is shadowed here by -I order, so this is
 * the only definition net80211 sees. struct ifnet comes from <net/if.h>.
 */
#include <net/if.h>
struct arpcom {
	struct ifnet	ac_if;
	u_int8_t	ac_enaddr[ETHER_ADDR_LEN];
	u_int8_t	ac_pad[2];
	void		*ac_ipac;
	int		ac_multicnt;
	int		ac_multirangecnt;
};

/*
 * ether_sprintf: illumos <sys/ethernet.h> declares it, but that header is
 * suppressed here, so declare it. iwx/compat/sys/iwx_kernel.h wraps the real
 * illumos symbol via a cast macro; this matches its expected prototype (the
 * arg is a struct ether_addr *, per the FINDINGS ether_sprintf signature note).
 */
extern char *ether_sprintf(struct ether_addr *);

#endif /* _N80211_COMPAT_NETINET_IF_ETHER_H */
