/*
 * OpenBSD <net/if_llc.h>: the IEEE 802.2 LLC and SNAP header, used by net80211
 * to encapsulate/decapsulate the LLC/SNAP shim between the 802.11 header and the
 * ethernet payload. illumos has no <net/if_llc.h> (it does LLC/SNAP inside its
 * own DLPI/GLDv3 path), so the struct and constants are vendored verbatim from
 * OpenBSD. REAL -- these are wire-format definitions, not shims; getting a field
 * offset wrong corrupts every encapsulated frame.
 */
#ifndef _N80211_COMPAT_NET_IF_LLC_H
#define _N80211_COMPAT_NET_IF_LLC_H

#include <sys/types.h>

struct llc {
	u_int8_t llc_dsap;
	u_int8_t llc_ssap;
	union {
		struct {
			u_int8_t control;
			u_int8_t format_id;
			u_int8_t class;
			u_int8_t window_x2;
		} type_u_APPLE;
		struct {
			u_int8_t control;
			u_int8_t control_ext;
		} type_raw;
		struct {
			u_int8_t control;
			u_int8_t org_code[3];
			u_int16_t ether_type;
		} type_snap;
		struct {
			u_int8_t control;
			u_int8_t control_ext;
			u_int8_t org_code[3];
			u_int16_t ether_type;
		} type_snap_APPLE;
	} llc_un;
};

/* Field-access spellings net80211 uses (OpenBSD macro names). */
#define llc_control		llc_un.type_raw.control
#define llc_control_ext		llc_un.type_raw.control_ext
#define llc_snap		llc_un.type_snap

#define LLC_SNAP_LSAP		0xaa	/* SNAP SAP */
#define LLC_UI			0x03	/* unnumbered information */
#define LLC_ISO_LSAP		0xfe

/*
 * The on-wire LLC/SNAP header is 8 bytes: dsap ssap control (3) + org_code (3) +
 * ether_type (2). OpenBSD's LLC_SNAPFRAMELEN.
 */
#define LLC_SNAPFRAMELEN	8

#endif /* _N80211_COMPAT_NET_IF_LLC_H */
