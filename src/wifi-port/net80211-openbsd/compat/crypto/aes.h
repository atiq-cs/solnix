/*
 * OpenBSD <crypto/aes.h> compat surface for the vendored net80211.
 *
 * AES block cipher: net80211 uses it directly (CCMP, ieee80211_crypto_ccmp.c
 * embeds AES_CTX by value) and transitively under CMAC (BIP) and key-wrap
 * (RSN 4-way). The struct MUST be a COMPLETE type here because it is embedded
 * by value in ieee80211_ccmp_ctx (`AES_CTX aesctx;`); an incomplete type would
 * reject the enclosing struct at parse.
 *
 * Layout follows OpenBSD sys/crypto/aes.h: a 16-byte-aligned key-schedule
 * blob. AES-256 needs 15 rounds -> 4*(14+1)=60 u32 for enc + 60 for dec = 120,
 * plus the round count. OpenBSD stores it as AES_MAXROUNDS (14) with
 * 4*(AES_MAXROUNDS+1) u32 words per direction. This is the ALGORITHM-fixed
 * schedule size, not an ABI guess.
 *
 * Functions are DECL only. They resolve at LINK against the self-contained
 * crypto shim (n80211_crypto.c) or a vendored aes.c -- nothing here computes.
 */
#ifndef _N80211_COMPAT_CRYPTO_AES_H
#define _N80211_COMPAT_CRYPTO_AES_H

#include <sys/types.h>

#define AES_MAXROUNDS		14
#define AES_BLOCK_LEN		16

typedef struct aes_ctx {
	u_int32_t	aes_ek[4 * (AES_MAXROUNDS + 1)];
	u_int32_t	aes_dk[4 * (AES_MAXROUNDS + 1)];
	int		aes_rounds;
} AES_CTX;

extern int  AES_Setkey(AES_CTX *, const u_int8_t *, int);
extern void AES_Encrypt(AES_CTX *, const u_int8_t *, u_int8_t *);
extern void AES_Decrypt(AES_CTX *, const u_int8_t *, u_int8_t *);

#endif /* _N80211_COMPAT_CRYPTO_AES_H */
