/*
 * OpenBSD <crypto/hmac.h> compat surface for the vendored net80211.
 *
 * HMAC-MD5 / HMAC-SHA1 / HMAC-SHA256 keyed hashes: net80211's RSN key
 * hierarchy PRF (ieee80211_crypto.c) and the EAPOL key MIC. The *_CTX structs
 * are embedded by value in a union in ieee80211_eapol_key_mic (`HMAC_MD5_CTX
 * md5; HMAC_SHA1_CTX sha1;`), so they MUST be complete types.
 *
 * OpenBSD layout (sys/crypto/hmac.h): each HMAC context holds an inner and an
 * outer copy of the underlying digest context. The base contexts (MD5_CTX,
 * SHA1_CTX, SHA2_CTX) are complete types from md5.h/sha1.h/sha2.h.
 *
 * Init takes (ctx, key, key_len); Update takes (ctx, data, len); Final takes
 * (digest, ctx). Functions DECL only -- resolve at LINK against the crypto
 * shim.
 */
#ifndef _N80211_COMPAT_CRYPTO_HMAC_H
#define _N80211_COMPAT_CRYPTO_HMAC_H

#include <sys/types.h>
#include <crypto/md5.h>
#include <crypto/sha1.h>
#include <crypto/sha2.h>

typedef struct _HMAC_MD5_CTX {
	MD5_CTX	ctx;
	MD5_CTX	ctx_key;
	u_int8_t	key[MD5_BLOCK_LENGTH];
} HMAC_MD5_CTX;

typedef struct _HMAC_SHA1_CTX {
	SHA1_CTX	ctx;
	SHA1_CTX	ctx_key;
	u_int8_t	key[SHA1_BLOCK_LENGTH];
} HMAC_SHA1_CTX;

typedef struct _HMAC_SHA256_CTX {
	SHA2_CTX	ctx;
	SHA2_CTX	ctx_key;
	u_int8_t	key[SHA256_BLOCK_LENGTH];
} HMAC_SHA256_CTX;

extern void HMAC_MD5_Init(HMAC_MD5_CTX *, const u_int8_t *, u_int);
extern void HMAC_MD5_Update(HMAC_MD5_CTX *, const u_int8_t *, u_int);
extern void HMAC_MD5_Final(u_int8_t[MD5_DIGEST_LENGTH], HMAC_MD5_CTX *);

extern void HMAC_SHA1_Init(HMAC_SHA1_CTX *, const u_int8_t *, u_int);
extern void HMAC_SHA1_Update(HMAC_SHA1_CTX *, const u_int8_t *, u_int);
extern void HMAC_SHA1_Final(u_int8_t[SHA1_DIGEST_LENGTH], HMAC_SHA1_CTX *);

extern void HMAC_SHA256_Init(HMAC_SHA256_CTX *, const u_int8_t *, u_int);
extern void HMAC_SHA256_Update(HMAC_SHA256_CTX *, const u_int8_t *, u_int);
extern void HMAC_SHA256_Final(u_int8_t[SHA256_DIGEST_LENGTH], HMAC_SHA256_CTX *);

#endif /* _N80211_COMPAT_CRYPTO_HMAC_H */
