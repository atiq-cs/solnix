/*
 * OpenBSD <crypto/michael.h> compat surface for the vendored net80211.
 *
 * Michael MIC: TKIP's message-integrity code (ieee80211_crypto_tkip.c
 * ieee80211_tkip_mic). illumos has NO Michael MIC (FINDINGS.md Finding 2) --
 * written or vendored. `MICHAEL_CTX ctx;` is a by-value local, so the struct
 * MUST be complete: the two 32-bit accumulators, the running block, its count,
 * and the two key words.
 *
 * Signatures as used in the tree:
 *   michael_init(ctx); michael_key(key, ctx);
 *   michael_update(ctx, data, len); michael_final(mic[8], ctx)
 * DECL only -- resolve at LINK against the crypto shim.
 */
#ifndef _N80211_COMPAT_CRYPTO_MICHAEL_H
#define _N80211_COMPAT_CRYPTO_MICHAEL_H

#include <sys/types.h>

#define MICHAEL_MIC_LEN		8

typedef struct _MICHAEL_CTX {
	u_int32_t	l, r;		/* left/right MIC accumulators */
	u_int32_t	k0, k1;		/* key words */
	u_int8_t	block[4];	/* pending partial block */
	u_int		nbytes;
} MICHAEL_CTX;

extern void michael_init(MICHAEL_CTX *);
extern void michael_key(const u_int8_t *, MICHAEL_CTX *);
extern void michael_update(MICHAEL_CTX *, const void *, u_int);
extern void michael_final(u_int8_t[MICHAEL_MIC_LEN], MICHAEL_CTX *);

#endif /* _N80211_COMPAT_CRYPTO_MICHAEL_H */
