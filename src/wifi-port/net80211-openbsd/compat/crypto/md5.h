/*
 * OpenBSD <crypto/md5.h> -- MD5, used by HMAC-MD5 in net80211's MIC paths.
 * Layout per OpenBSD; functions DECL. See sha1.h for the discipline.
 */
#ifndef _N80211_COMPAT_CRYPTO_MD5_H
#define _N80211_COMPAT_CRYPTO_MD5_H

#include <sys/types.h>

#define MD5_BLOCK_LENGTH	64
#define MD5_DIGEST_LENGTH	16

typedef struct MD5Context {
	u_int32_t	state[4];
	u_int64_t	count;
	u_int8_t	buffer[MD5_BLOCK_LENGTH];
} MD5_CTX;

extern void MD5Init(MD5_CTX *);
extern void MD5Update(MD5_CTX *, const u_int8_t *, size_t);
extern void MD5Final(u_int8_t[MD5_DIGEST_LENGTH], MD5_CTX *);

#endif /* _N80211_COMPAT_CRYPTO_MD5_H */
