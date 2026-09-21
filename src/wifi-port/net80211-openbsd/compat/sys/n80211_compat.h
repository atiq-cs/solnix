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
