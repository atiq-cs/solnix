/*
 * OpenBSD <crypto/cmac.h> compat surface for the vendored net80211.
 *
 * AES-CMAC: net80211's BIP (management-frame protection, ieee80211_crypto_bip.c)
 * embeds `AES_CMAC_CTX cmac;` by value, and the EAPOL key MIC uses it, so the
 * struct MUST be complete. illumos has NO AES_CMAC (FINDINGS.md Finding 2) --
 * it must be written or vendored; this header declares its surface.
 *
 * Layout per OpenBSD sys/crypto/cmac.h: an embedded AES key schedule plus the
 * running MAC/partial-block state. AES_CMAC_DIGEST_LENGTH is 16 (one AES block).
 *
 * SetKey takes (ctx, key[16]); Init/Update/Final as used by BIP. Functions
 * DECL only -- resolve at LINK against the crypto shim.
 */
#ifndef _N80211_COMPAT_CRYPTO_CMAC_H
#define _N80211_COMPAT_CRYPTO_CMAC_H

#include <sys/types.h>
#include <crypto/aes.h>

#define AES_CMAC_DIGEST_LENGTH	16
#define AES_CMAC_KEY_LENGTH	16

typedef struct _AES_CMAC_CTX {
	AES_CTX		aesctx;
	u_int8_t	X[16];
	u_int8_t	M_last[16];
	u_int		M_n;
} AES_CMAC_CTX;

extern void AES_CMAC_Init(AES_CMAC_CTX *);
extern void AES_CMAC_SetKey(AES_CMAC_CTX *, const u_int8_t[AES_CMAC_KEY_LENGTH]);
extern void AES_CMAC_Update(AES_CMAC_CTX *, const u_int8_t *, u_int);
extern void AES_CMAC_Final(u_int8_t[AES_CMAC_DIGEST_LENGTH], AES_CMAC_CTX *);

#endif /* _N80211_COMPAT_CRYPTO_CMAC_H */
