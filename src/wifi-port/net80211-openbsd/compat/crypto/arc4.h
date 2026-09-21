/*
 * OpenBSD <crypto/arc4.h> compat surface for the vendored net80211.
 *
 * RC4 stream cipher: TKIP and WEP embed `struct rc4_ctx rc4;` by value, so the
 * struct MUST be complete (the empty PROBE stub caused the "field 'rc4' has
 * incomplete type" errors). Layout per OpenBSD sys/crypto/arc4.h: the 256-byte
 * S-box plus the two index bytes.
 *
 * OpenBSD also exposes the state as RC4STATE (the array element type). Both the
 * struct and the RC4STATE alias are used in the tree.
 *
 * Functions DECL only; resolve at LINK against the crypto shim.
 */
#ifndef _N80211_COMPAT_CRYPTO_ARC4_H
#define _N80211_COMPAT_CRYPTO_ARC4_H

#include <sys/types.h>

#define RC4STATE	256

struct rc4_ctx {
	u_int8_t	x, y;
	u_int8_t	state[RC4STATE];
};

extern void rc4_keysetup(struct rc4_ctx *, const u_int8_t *, u_int32_t);
extern void rc4_crypt(struct rc4_ctx *, const u_int8_t *, u_int8_t *, u_int32_t);
extern void rc4_skip(struct rc4_ctx *, u_int32_t);

#endif /* _N80211_COMPAT_CRYPTO_ARC4_H */
