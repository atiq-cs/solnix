/*
 * OpenBSD <crypto/sha2.h> -- SHA-256/384/512. net80211 uses HMAC-SHA256 for the
 * SHA256 PRF (RSN). Layout per OpenBSD; functions DECL (LINK against illumos
 * SHA2 or vendored sha2.c). See sha1.h for the discipline.
 */
#ifndef _N80211_COMPAT_CRYPTO_SHA2_H
#define _N80211_COMPAT_CRYPTO_SHA2_H

#include <sys/types.h>

#define SHA256_BLOCK_LENGTH	64
#define SHA256_DIGEST_LENGTH	32
#define SHA384_BLOCK_LENGTH	128
#define SHA384_DIGEST_LENGTH	48
#define SHA512_BLOCK_LENGTH	128
#define SHA512_DIGEST_LENGTH	64

typedef struct _SHA2_CTX {
	union {
		u_int32_t	st32[8];
		u_int64_t	st64[8];
	} state;
	u_int64_t	bitcount[2];
	u_int8_t	buffer[SHA512_BLOCK_LENGTH];
} SHA2_CTX;

extern void SHA256Init(SHA2_CTX *);
extern void SHA256Update(SHA2_CTX *, const u_int8_t *, size_t);
extern void SHA256Final(u_int8_t[SHA256_DIGEST_LENGTH], SHA2_CTX *);

#endif /* _N80211_COMPAT_CRYPTO_SHA2_H */
