/*
 * OpenBSD <crypto/sha1.h> -- SHA-1 context and API. net80211 uses HMAC-SHA1 for
 * the PRF in the RSN key hierarchy. Struct layout matches OpenBSD (wire/algorithm
 * defined -- the digest state is fixed by the SHA-1 spec). Functions DECL: they
 * resolve at LINK against illumos's SHA1 (uts/common/sys/sha1.h) via a thin
 * n80211_crypto.c shim, or a vendored OpenBSD sha1.c. Nothing here computes yet.
 */
#ifndef _N80211_COMPAT_CRYPTO_SHA1_H
#define _N80211_COMPAT_CRYPTO_SHA1_H

#include <sys/types.h>

#define SHA1_BLOCK_LENGTH	64
#define SHA1_DIGEST_LENGTH	20

typedef struct {
	u_int32_t	state[5];
	u_int64_t	count;
	u_int8_t	buffer[SHA1_BLOCK_LENGTH];
} SHA1_CTX;

extern void SHA1Init(SHA1_CTX *);
extern void SHA1Update(SHA1_CTX *, const u_int8_t *, size_t);
extern void SHA1Final(u_int8_t[SHA1_DIGEST_LENGTH], SHA1_CTX *);

#endif /* _N80211_COMPAT_CRYPTO_SHA1_H */
