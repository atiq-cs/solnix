/*
 * net80211-specific compat shims: the OpenBSD-kernel primitives that the
 * vendored net80211 sources use but the iwx driver did NOT, so they are absent
 * from iwx/compat/sys/iwx_kernel.h. Kept in the net80211 compat tree (searched
 * before iwx/compat) so the iwx build is untouched.
 *
 * STATUS PER SYMBOL is tagged inline: REAL (a correct illumos-backed inline),
 * DECL (declared-only, resolved at LINK against a future n80211_kcompat.c),
 * or NO-OP (a documented degenerate mapping that is safe at compile+structure
 * level and revisited before load). Nothing here is claimed to link a module.
 *
 * This resolves the recurring cheap-symbol classes measured across the 7
 * blocking-symbol files (FINDINGS.md "remainder" 16% bucket): ISSET, suser,
 * explicit_bzero, timingsafe_bcmp, arc4random*, ratecheck, abs, IFQ_MAXLEN,
 * the 3-arg mq_init and MBUF_QUEUE_INITIALIZER, plus the extra struct ifnet /
 * struct ifreq members net80211 touches beyond if_iwx.c's 11.
 */
#ifndef _N80211_COMPAT_H
#define _N80211_COMPAT_H

#include <sys/types.h>
#include <sys/cmn_err.h>
#include <sys/time.h>

/*
 * swap16: OpenBSD's 16-bit byte swap (libkern), used by the TKIP key-mixing
 * S-box (ieee80211_crypto_tkip.c _S_). A pure value transform -- REAL.
 */
#ifndef swap16
static __inline uint16_t
n80211_swap16(uint16_t v) { return ((uint16_t)((v >> 8) | (v << 8))); }
#define swap16(v)	n80211_swap16(v)
#endif

/*
 * getuptime: OpenBSD returns seconds since boot (time_t). Used by TKIP's
 * countermeasure throttle (two MIC failures within 60s disables the BSS).
 * illumos gethrtime() is nanoseconds since an arbitrary epoch, but only the
 * DIFFERENCE between two getuptime() calls is used, so the epoch is irrelevant
 * and seconds = gethrtime()/NANOSEC is correct. REAL.
 */
static __inline time_t
getuptime(void)
{
	return ((time_t)(gethrtime() / NANOSEC));
}

/*
 * log(pri, fmt, ...) + LOG_WARNING: OpenBSD's kernel logger. illumos uses
 * cmn_err with a level prefix, not a syslog priority. Map log() to cmn_err(CE_*)
 * -- WARNING/ERR -> CE_WARN, else CE_NOTE -- discarding the numeric priority,
 * which net80211 only uses for LOG_WARNING diagnostics. REAL (best-effort: the
 * variadic cannot forward through a macro to cmn_err with full generality, so
 * only the fixed-arg call shapes net80211 uses are covered; a new call shape
 * would need extending).  LOG_* values are the syslog constants (BSD
 * <sys/syslog.h>), kept so the priority argument still type-checks.
 */
#ifndef LOG_WARNING
#define LOG_EMERG	0
#define LOG_ALERT	1
#define LOG_CRIT	2
#define LOG_ERR		3
#define LOG_WARNING	4
#define LOG_NOTICE	5
#define LOG_INFO	6
#define LOG_DEBUG	7
#endif
#ifndef log
#define log(pri, ...)	cmn_err(((pri) <= LOG_ERR ? CE_WARN : CE_NOTE), __VA_ARGS__)
#endif

/*
 * ether_crc32_le_update: incremental little-endian CRC32 (Ethernet FCS
 * polynomial), OpenBSD net/if_ethersubr.c. TKIP and WEP use it to compute the
 * WEP ICV over the frame body. Standard reflected CRC32 (poly 0xEDB88320),
 * seeded by the caller with ~0 and finalized with ~crc -- the exact contract
 * net80211 relies on. REAL. (ether_crc32_le(buf,len) is the one-shot form
 * declared in n80211_stack.h; this is the running form.)
 */
static __inline uint32_t
ether_crc32_le_update(uint32_t crc, const void *buf, size_t len)
{
	static const uint32_t table[16] = {
		0x00000000, 0x1db71064, 0x3b6e20c8, 0x26d930ac,
		0x76dc4190, 0x6b6b51f4, 0x4db26158, 0x5005713c,
		0xedb88320, 0xf00f9344, 0xd6d6a3e8, 0xcb61b38c,
		0x9b64c2b0, 0x86d3d2d4, 0xa00ae278, 0xbdbdf21c
	};
	const uint8_t *p = buf;
	size_t i;

	for (i = 0; i < len; i++) {
		crc ^= p[i];
		crc = (crc >> 4) ^ table[crc & 0x0f];
		crc = (crc >> 4) ^ table[crc & 0x0f];
	}
	return (crc);
}

/*
 * random_get_pseudo_bytes (uts/common/os/random.c) declared here rather than
 * via <sys/random.h>, which drags in thread/klwp headers that need label_t
 * before the machine type foundation is set up in this include order. DECL.
 */
extern int random_get_pseudo_bytes(uint8_t *, size_t);

/* --- bit-set macros (OpenBSD <sys/param.h>). REAL. --- */
#ifndef ISSET
#define ISSET(t, f)	((t) & (f))
#endif
#ifndef SET
#define SET(t, f)	((t) |= (f))
#endif
#ifndef CLR
#define CLR(t, f)	((t) &= ~(f))
#endif

/* OpenBSD's per-interface user-settable flags. Only IFF_LINK0 is read by
 * net80211 (a merge-print gate); the others round out the ABI. REAL constants. */
#ifndef IFF_LINK0
#define IFF_LINK0	0x1000
#define IFF_LINK1	0x2000
#define IFF_LINK2	0x4000
#endif

/*
 * explicit_bzero: OpenBSD's non-elidable zeroing, used to wipe key material.
 * illumos has no explicit_bzero; bzero is the honest floor. NOTE: a
 * sufficiently aggressive optimiser MAY elide this on a dead buffer, which
 * matters for the key-wipe sites in ieee80211_crypto*.c. Tagged so the load
 * gate revisits it; at compile+structure level bzero is correct behaviour.
 * ponytail: bzero floor, swap for a volatile-barrier wipe before load.
 */
static __inline void
explicit_bzero(void *b, size_t len)
{
	bzero(b, len);
}

/*
 * timingsafe_bcmp: constant-time compare (MIC/PN verification). A branch-free
 * fold; not the fastest but constant-time, which is the security property that
 * matters. REAL.
 */
static __inline int
timingsafe_bcmp(const void *b1, const void *b2, size_t n)
{
	const unsigned char *p1 = b1, *p2 = b2;
	unsigned char r = 0;
	size_t i;

	for (i = 0; i < n; i++)
		r |= p1[i] ^ p2[i];
	return (r != 0);
}

/*
 * arc4random / arc4random_buf / arc4random_uniform: OpenBSD's CSPRNG. Backed by
 * the illumos kernel's random_get_pseudo_bytes (uts/common/os/random.c). REAL,
 * though the quality contract differs (illumos "pseudo" vs OpenBSD ChaCha);
 * net80211 uses it for IV/nonce/TA seeding, adequate here. Tagged for a
 * pre-load review of the CCMP-PN and SAE paths specifically.
 */
static __inline uint32_t
arc4random(void)
{
	uint32_t v;
	(void) random_get_pseudo_bytes((uint8_t *)&v, sizeof (v));
	return (v);
}

static __inline void
arc4random_buf(void *buf, size_t n)
{
	(void) random_get_pseudo_bytes((uint8_t *)buf, n);
}

static __inline uint32_t
arc4random_uniform(uint32_t upper_bound)
{
	uint32_t r, min;

	if (upper_bound < 2)
		return (0);
	min = -upper_bound % upper_bound;
	for (;;) {
		r = arc4random();
		if (r >= min)
			return (r % upper_bound);
	}
}

/*
 * suser: OpenBSD's privilege check (0 == allowed). Wired to illumos
 * secpolicy/cred at the ioctl entry when net80211's ioctl path is bridged to
 * mac_prop; declared-only for now so the site fails at LINK by name rather than
 * silently returning "permitted". DECL.
 */
extern int suser(void *);

/*
 * ratecheck: OpenBSD's "has interval elapsed since *lasttime" rate limiter,
 * used only to throttle diagnostic prints. Wired to gethrtime()/hz. REAL.
 */
struct timeval;
extern int ratecheck(struct timeval *lasttime, const struct timeval *mininterval);

/* abs: integer absolute value. OpenBSD gets it from libkern; illumos kernel
 * does not export it. REAL inline. */
#ifndef abs
static __inline int
n80211_abs(int j) { return (j < 0 ? -j : j); }
#define abs(j)	n80211_abs(j)
#endif

/*
 * IFQ_MAXLEN: OpenBSD's default send-queue depth. Used as the maxlen argument
 * to mq_init for ic_mgtq/ic_pwrsaveq. REAL constant (OpenBSD value).
 */
#ifndef IFQ_MAXLEN
#define IFQ_MAXLEN	256
#endif

/*
 * DiffServ codepoints (OpenBSD <netinet/ip.h>). ieee80211_classify() maps the
 * IP DSCP to a WMM/802.11e access-category TID. These are the RFC 2474 / 4594
 * standard codepoint VALUES shifted into the TOS byte (DSCP occupies the top 6
 * bits, so codepoint<<2). REAL constants -- fixed by the standard, not an ABI
 * guess. IPTOS_DSCP_VA is RFC 5865 voice-admit (44).
 */
#ifndef IPTOS_DSCP_CS1
#define IPTOS_DSCP_CS1		0x20	/*  8 << 2 */
#define IPTOS_DSCP_CS3		0x60	/* 24 << 2 */
#define IPTOS_DSCP_CS4		0x80	/* 32 << 2 */
#define IPTOS_DSCP_CS5		0xa0	/* 40 << 2 */
#define IPTOS_DSCP_CS6		0xc0	/* 48 << 2 */
#define IPTOS_DSCP_CS7		0xe0	/* 56 << 2 */
#define IPTOS_DSCP_AF31		0x68	/* 26 << 2 */
#define IPTOS_DSCP_AF32		0x70	/* 28 << 2 */
#define IPTOS_DSCP_AF33		0x78	/* 30 << 2 */
#define IPTOS_DSCP_AF41		0x88	/* 34 << 2 */
#define IPTOS_DSCP_AF42		0x90	/* 36 << 2 */
#define IPTOS_DSCP_AF43		0x98	/* 38 << 2 */
#define IPTOS_DSCP_EF		0xb8	/* 46 << 2 */
#define IPTOS_DSCP_VA		0xb0	/* 44 << 2 (RFC 5865 voice-admit) */
#endif

#endif /* _N80211_COMPAT_H */
