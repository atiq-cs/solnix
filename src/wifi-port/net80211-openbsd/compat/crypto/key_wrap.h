/*
 * OpenBSD <crypto/key_wrap.h> compat surface for the vendored net80211.
 *
 * AES Key Wrap (RFC 3394): net80211's RSN 4-way handshake wraps/unwraps the
 * GTK (ieee80211_crypto.c aes_key_wrap / aes_key_unwrap). illumos has NO AES
 * key wrap (FINDINGS.md Finding 2) -- written or vendored. `aes_key_wrap_ctx
 * aes;` is a local by-value, so the struct MUST be complete: it is just an AES
 * key schedule.
 *
 * Signatures as used in the tree:
 *   set_key(ctx, kek, kek_len)               / set_key_wrap_only(ctx, kek, len)
 *   aes_key_wrap(ctx, plain, nblocks, out)   -> void
 *   aes_key_unwrap(ctx, cipher, out, nblocks) -> int (0 = MIC ok)
 * DECL only -- resolve at LINK against the crypto shim.
 */
#ifndef _N80211_COMPAT_CRYPTO_KEY_WRAP_H
#define _N80211_COMPAT_CRYPTO_KEY_WRAP_H

#include <sys/types.h>
#include <crypto/aes.h>

typedef struct _aes_key_wrap_ctx {
	AES_CTX		ctx;
} aes_key_wrap_ctx;

extern void aes_key_wrap_set_key(aes_key_wrap_ctx *, const u_int8_t *, size_t);
extern void aes_key_wrap_set_key_wrap_only(aes_key_wrap_ctx *, const u_int8_t *,
	    size_t);
extern void aes_key_wrap(aes_key_wrap_ctx *, const u_int8_t *, size_t,
	    u_int8_t *);
extern int  aes_key_unwrap(aes_key_wrap_ctx *, const u_int8_t *, u_int8_t *,
	    size_t);

#endif /* _N80211_COMPAT_CRYPTO_KEY_WRAP_H */
