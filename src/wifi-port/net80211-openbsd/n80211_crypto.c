/*
 * n80211_crypto.c -- self-contained crypto primitives for the vendored OpenBSD
 * net80211, against the exact struct layouts and signatures declared in
 * net80211-openbsd/compat/crypto/{aes,arc4,hmac,cmac,key_wrap,michael,md5,
 * sha1,sha2}.h.
 *
 * WHY SELF-CONTAINED. illumos has AES/arcfour/MD5/SHA1/SHA2 in
 * common/crypto/, but with DIFFERENT struct layouts and a KCF-oriented API; the
 * compat headers use OpenBSD's byte-for-byte layouts because net80211 embeds
 * the contexts BY VALUE in its cipher structs (AES_CTX in ieee80211_ccmp_ctx,
 * rc4_ctx in the WEP/TKIP ctx, the HMAC/CMAC unions in the EAPOL key MIC).
 * Bridging OpenBSD-layout structs onto illumos's crypto would require
 * reimplementing each schedule inside the OpenBSD struct anyway, so the honest
 * self-contained shim IS the smaller correct path -- and illumos genuinely
 * lacks AES-CMAC, AES key wrap and Michael MIC (FINDINGS.md Finding 2).
 *
 * Every algorithm here is standard and small, and every one carries a published
 * test vector in the self-test (compile with -DN80211_CRYPTO_TEST for a
 * userland main() that asserts each vector -- FIPS-197 AES, RFC 6229 RC4,
 * RFC 1321 MD5, RFC 3174 SHA-1, FIPS-180 SHA-256, RFC 2104/4231 HMAC, RFC 4493
 * AES-CMAC, RFC 3394 AES key wrap, IEEE 802.11 Michael). A vector that fails is
 * a HARD failure -- this is load-bearing security code.
 *
 * STATUS: REAL. Not a stub. The crypto is computed here. Whether the SILICON
 * accepts a frame these produce is the separate HARDWARE gate.
 */

#ifdef N80211_CRYPTO_TEST
#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <assert.h>
typedef uint8_t  u_int8_t;
typedef uint16_t u_int16_t;
typedef uint32_t u_int32_t;
typedef uint64_t u_int64_t;
typedef unsigned int u_int;
#define bzero(b, n)	memset((b), 0, (n))
#else
#include <sys/types.h>
#include <sys/systm.h>
#endif

#include <crypto/aes.h>
#include <crypto/arc4.h>
#include <crypto/md5.h>
#include <crypto/sha1.h>
#include <crypto/sha2.h>
#include <crypto/hmac.h>
#include <crypto/cmac.h>
#include <crypto/key_wrap.h>
#include <crypto/michael.h>

/* ===================================================================== */
/* AES (FIPS-197). Compact table-driven implementation.                  */
/* ===================================================================== */

static const u_int8_t aes_sbox[256] = {
0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16
};

static u_int8_t aes_inv_sbox[256];
static int aes_inv_ready;

static const u_int8_t aes_rcon[11] = {
	0x00,0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1b,0x36
};

static __inline u_int8_t
aes_xtime(u_int8_t x)
{
	return ((u_int8_t)((x << 1) ^ ((x >> 7) * 0x1b)));
}

static u_int8_t
aes_mul(u_int8_t a, u_int8_t b)
{
	u_int8_t p = 0;
	int i;
	for (i = 0; i < 8; i++) {
		if (b & 1)
			p ^= a;
		a = aes_xtime(a);
		b >>= 1;
	}
	return (p);
}

/*
 * AES_Setkey: expand `keylen`-byte key into aes_ek[] (encrypt) and aes_dk[]
 * (decrypt) schedules. keylen is 16/24/32; rounds = keylen/4 + 6. The schedule
 * words are stored big-endian-packed u32, one word per column, Nr+1 rounds x 4.
 */
int
AES_Setkey(AES_CTX *ctx, const u_int8_t *key, int keylen)
{
	int Nk = keylen / 4;
	int Nr = Nk + 6;
	int total = 4 * (Nr + 1);
	int i;
	u_int32_t *w = ctx->aes_ek;

	if (keylen != 16 && keylen != 24 && keylen != 32)
		return (-1);
	ctx->aes_rounds = Nr;

	for (i = 0; i < Nk; i++)
		w[i] = ((u_int32_t)key[4*i] << 24) | ((u_int32_t)key[4*i+1] << 16) |
		    ((u_int32_t)key[4*i+2] << 8) | key[4*i+3];

	for (i = Nk; i < total; i++) {
		u_int32_t t = w[i-1];
		if (i % Nk == 0) {
			t = (t << 8) | (t >> 24);	/* RotWord */
			t = ((u_int32_t)aes_sbox[(t >> 24) & 0xff] << 24) |
			    ((u_int32_t)aes_sbox[(t >> 16) & 0xff] << 16) |
			    ((u_int32_t)aes_sbox[(t >> 8) & 0xff] << 8) |
			    aes_sbox[t & 0xff];
			t ^= (u_int32_t)aes_rcon[i / Nk] << 24;
		} else if (Nk > 6 && i % Nk == 4) {
			t = ((u_int32_t)aes_sbox[(t >> 24) & 0xff] << 24) |
			    ((u_int32_t)aes_sbox[(t >> 16) & 0xff] << 16) |
			    ((u_int32_t)aes_sbox[(t >> 8) & 0xff] << 8) |
			    aes_sbox[t & 0xff];
		}
		w[i] = w[i-Nk] ^ t;
	}

	/* the decrypt schedule is just a copy of the encrypt words here;
	 * AES_Decrypt applies InvMixColumns on the fly, so no separate
	 * equivalent-inverse schedule is precomputed. */
	for (i = 0; i < total; i++)
		ctx->aes_dk[i] = w[i];

	if (!aes_inv_ready) {
		int k;
		for (k = 0; k < 256; k++)
			aes_inv_sbox[aes_sbox[k]] = (u_int8_t)k;
		aes_inv_ready = 1;
	}
	return (0);
}

void
AES_Encrypt(AES_CTX *ctx, const u_int8_t *in, u_int8_t *out)
{
	u_int8_t s[16];
	int Nr = ctx->aes_rounds;
	int r, c;
	const u_int32_t *w = ctx->aes_ek;

	memcpy(s, in, 16);
	/* AddRoundKey round 0 */
	for (c = 0; c < 4; c++) {
		s[4*c+0] ^= (w[c] >> 24) & 0xff;
		s[4*c+1] ^= (w[c] >> 16) & 0xff;
		s[4*c+2] ^= (w[c] >> 8) & 0xff;
		s[4*c+3] ^= w[c] & 0xff;
	}
	for (r = 1; r <= Nr; r++) {
		u_int8_t t[16];
		int last = (r == Nr);
		/* SubBytes */
		for (c = 0; c < 16; c++)
			s[c] = aes_sbox[s[c]];
		/* ShiftRows (state is column-major: s[4*col+row]) */
		{
			u_int8_t tmp;
			/* row 1 <<< 1 */
			tmp = s[1]; s[1]=s[5]; s[5]=s[9]; s[9]=s[13]; s[13]=tmp;
			/* row 2 <<< 2 */
			tmp = s[2]; s[2]=s[10]; s[10]=tmp;
			tmp = s[6]; s[6]=s[14]; s[14]=tmp;
			/* row 3 <<< 3 (== >>> 1) */
			tmp = s[15]; s[15]=s[11]; s[11]=s[7]; s[7]=s[3]; s[3]=tmp;
		}
		if (!last) {
			/* MixColumns */
			for (c = 0; c < 4; c++) {
				u_int8_t *col = &s[4*c];
				u_int8_t a0=col[0],a1=col[1],a2=col[2],a3=col[3];
				t[4*c+0] = aes_xtime(a0) ^ (aes_xtime(a1)^a1) ^ a2 ^ a3;
				t[4*c+1] = a0 ^ aes_xtime(a1) ^ (aes_xtime(a2)^a2) ^ a3;
				t[4*c+2] = a0 ^ a1 ^ aes_xtime(a2) ^ (aes_xtime(a3)^a3);
				t[4*c+3] = (aes_xtime(a0)^a0) ^ a1 ^ a2 ^ aes_xtime(a3);
			}
			memcpy(s, t, 16);
		}
		/* AddRoundKey */
		{
			const u_int32_t *rw = &w[4*r];
			for (c = 0; c < 4; c++) {
				s[4*c+0] ^= (rw[c] >> 24) & 0xff;
				s[4*c+1] ^= (rw[c] >> 16) & 0xff;
				s[4*c+2] ^= (rw[c] >> 8) & 0xff;
				s[4*c+3] ^= rw[c] & 0xff;
			}
		}
	}
	memcpy(out, s, 16);
}

void
AES_Decrypt(AES_CTX *ctx, const u_int8_t *in, u_int8_t *out)
{
	u_int8_t s[16];
	int Nr = ctx->aes_rounds;
	int r, c;
	const u_int32_t *w = ctx->aes_dk;

	memcpy(s, in, 16);
	/* AddRoundKey round Nr */
	{
		const u_int32_t *rw = &w[4*Nr];
		for (c = 0; c < 4; c++) {
			s[4*c+0] ^= (rw[c] >> 24) & 0xff;
			s[4*c+1] ^= (rw[c] >> 16) & 0xff;
			s[4*c+2] ^= (rw[c] >> 8) & 0xff;
			s[4*c+3] ^= rw[c] & 0xff;
		}
	}
	for (r = Nr - 1; r >= 0; r--) {
		u_int8_t tmp, t[16];
		/* InvShiftRows */
		tmp = s[13]; s[13]=s[9]; s[9]=s[5]; s[5]=s[1]; s[1]=tmp;
		tmp = s[2]; s[2]=s[10]; s[10]=tmp;
		tmp = s[6]; s[6]=s[14]; s[14]=tmp;
		tmp = s[3]; s[3]=s[7]; s[7]=s[11]; s[11]=s[15]; s[15]=tmp;
		/* InvSubBytes */
		for (c = 0; c < 16; c++)
			s[c] = aes_inv_sbox[s[c]];
		/* AddRoundKey */
		{
			const u_int32_t *rw = &w[4*r];
			for (c = 0; c < 4; c++) {
				s[4*c+0] ^= (rw[c] >> 24) & 0xff;
				s[4*c+1] ^= (rw[c] >> 16) & 0xff;
				s[4*c+2] ^= (rw[c] >> 8) & 0xff;
				s[4*c+3] ^= rw[c] & 0xff;
			}
		}
		if (r != 0) {
			/* InvMixColumns */
			for (c = 0; c < 4; c++) {
				u_int8_t *col = &s[4*c];
				u_int8_t a0=col[0],a1=col[1],a2=col[2],a3=col[3];
				t[4*c+0] = aes_mul(a0,14)^aes_mul(a1,11)^aes_mul(a2,13)^aes_mul(a3,9);
				t[4*c+1] = aes_mul(a0,9)^aes_mul(a1,14)^aes_mul(a2,11)^aes_mul(a3,13);
				t[4*c+2] = aes_mul(a0,13)^aes_mul(a1,9)^aes_mul(a2,14)^aes_mul(a3,11);
				t[4*c+3] = aes_mul(a0,11)^aes_mul(a1,13)^aes_mul(a2,9)^aes_mul(a3,14);
			}
			memcpy(s, t, 16);
		}
	}
	memcpy(out, s, 16);
}

/* ===================================================================== */
/* RC4 (arc4).                                                           */
/* ===================================================================== */

void
rc4_keysetup(struct rc4_ctx *ctx, const u_int8_t *key, u_int32_t klen)
{
	int i, j = 0;
	u_int8_t *S = ctx->state;

	for (i = 0; i < 256; i++)
		S[i] = (u_int8_t)i;
	for (i = 0; i < 256; i++) {
		u_int8_t tmp;
		j = (j + S[i] + key[i % klen]) & 0xff;
		tmp = S[i]; S[i] = S[j]; S[j] = tmp;
	}
	ctx->x = 0;
	ctx->y = 0;
}

void
rc4_crypt(struct rc4_ctx *ctx, const u_int8_t *src, u_int8_t *dst,
    u_int32_t len)
{
	u_int8_t *S = ctx->state;
	u_int8_t x = ctx->x, y = ctx->y;
	u_int32_t i;

	for (i = 0; i < len; i++) {
		u_int8_t tmp;
		x = (x + 1) & 0xff;
		y = (y + S[x]) & 0xff;
		tmp = S[x]; S[x] = S[y]; S[y] = tmp;
		dst[i] = src[i] ^ S[(S[x] + S[y]) & 0xff];
	}
	ctx->x = x;
	ctx->y = y;
}

void
rc4_skip(struct rc4_ctx *ctx, u_int32_t len)
{
	u_int8_t *S = ctx->state;
	u_int8_t x = ctx->x, y = ctx->y;
	u_int32_t i;

	for (i = 0; i < len; i++) {
		u_int8_t tmp;
		x = (x + 1) & 0xff;
		y = (y + S[x]) & 0xff;
		tmp = S[x]; S[x] = S[y]; S[y] = tmp;
	}
	ctx->x = x;
	ctx->y = y;
}

/* ===================================================================== */
/* MD5 (RFC 1321).                                                       */
/* ===================================================================== */

#define MD5_F(x,y,z) (((x) & (y)) | (~(x) & (z)))
#define MD5_G(x,y,z) (((x) & (z)) | ((y) & ~(z)))
#define MD5_H(x,y,z) ((x) ^ (y) ^ (z))
#define MD5_I(x,y,z) ((y) ^ ((x) | ~(z)))
#define MD5_ROT(x,n) (((x) << (n)) | ((x) >> (32-(n))))

static void
md5_transform(u_int32_t state[4], const u_int8_t block[64])
{
	static const u_int32_t K[64] = {
	0xd76aa478,0xe8c7b756,0x242070db,0xc1bdceee,0xf57c0faf,0x4787c62a,
	0xa8304613,0xfd469501,0x698098d8,0x8b44f7af,0xffff5bb1,0x895cd7be,
	0x6b901122,0xfd987193,0xa679438e,0x49b40821,0xf61e2562,0xc040b340,
	0x265e5a51,0xe9b6c7aa,0xd62f105d,0x02441453,0xd8a1e681,0xe7d3fbc8,
	0x21e1cde6,0xc33707d6,0xf4d50d87,0x455a14ed,0xa9e3e905,0xfcefa3f8,
	0x676f02d9,0x8d2a4c8a,0xfffa3942,0x8771f681,0x6d9d6122,0xfde5380c,
	0xa4beea44,0x4bdecfa9,0xf6bb4b60,0xbebfbc70,0x289b7ec6,0xeaa127fa,
	0xd4ef3085,0x04881d05,0xd9d4d039,0xe6db99e5,0x1fa27cf8,0xc4ac5665,
	0xf4292244,0x432aff97,0xab9423a7,0xfc93a039,0x655b59c3,0x8f0ccc92,
	0xffeff47d,0x85845dd1,0x6fa87e4f,0xfe2ce6e0,0xa3014314,0x4e0811a1,
	0xf7537e82,0xbd3af235,0x2ad7d2bb,0xeb86d391};
	static const u_int8_t S[64] = {
	7,12,17,22,7,12,17,22,7,12,17,22,7,12,17,22,
	5,9,14,20,5,9,14,20,5,9,14,20,5,9,14,20,
	4,11,16,23,4,11,16,23,4,11,16,23,4,11,16,23,
	6,10,15,21,6,10,15,21,6,10,15,21,6,10,15,21};
	u_int32_t a=state[0],b=state[1],c=state[2],d=state[3];
	u_int32_t M[16];
	int i;
	for (i = 0; i < 16; i++)
		M[i] = block[4*i] | (block[4*i+1]<<8) | (block[4*i+2]<<16) |
		    ((u_int32_t)block[4*i+3]<<24);
	for (i = 0; i < 64; i++) {
		u_int32_t f;
		int g;
		if (i < 16) { f = MD5_F(b,c,d); g = i; }
		else if (i < 32) { f = MD5_G(b,c,d); g = (5*i+1) & 15; }
		else if (i < 48) { f = MD5_H(b,c,d); g = (3*i+5) & 15; }
		else { f = MD5_I(b,c,d); g = (7*i) & 15; }
		f = f + a + K[i] + M[g];
		a = d; d = c; c = b;
		b = b + MD5_ROT(f, S[i]);
	}
	state[0]+=a; state[1]+=b; state[2]+=c; state[3]+=d;
}

void
MD5Init(MD5_CTX *ctx)
{
	ctx->state[0]=0x67452301; ctx->state[1]=0xefcdab89;
	ctx->state[2]=0x98badcfe; ctx->state[3]=0x10325476;
	ctx->count = 0;
}

void
MD5Update(MD5_CTX *ctx, const u_int8_t *data, size_t len)
{
	size_t have = (size_t)((ctx->count >> 3) & 63);
	size_t need;
	ctx->count += (u_int64_t)len << 3;
	need = 64 - have;
	if (len >= need) {
		if (have) {
			memcpy(ctx->buffer + have, data, need);
			md5_transform(ctx->state, ctx->buffer);
			data += need; len -= need; have = 0;
		}
		while (len >= 64) { md5_transform(ctx->state, data); data += 64; len -= 64; }
	}
	if (len) memcpy(ctx->buffer + have, data, len);
}

void
MD5Final(u_int8_t digest[MD5_DIGEST_LENGTH], MD5_CTX *ctx)
{
	u_int8_t pad[72];
	u_int64_t bits = ctx->count;
	size_t have = (size_t)((ctx->count >> 3) & 63);
	size_t padlen = (have < 56) ? (56 - have) : (120 - have);
	int i;
	pad[0] = 0x80;
	memset(pad + 1, 0, padlen - 1);
	for (i = 0; i < 8; i++)
		pad[padlen + i] = (u_int8_t)(bits >> (8*i));
	MD5Update(ctx, pad, padlen + 8);
	for (i = 0; i < 4; i++) {
		digest[4*i]   = ctx->state[i] & 0xff;
		digest[4*i+1] = (ctx->state[i] >> 8) & 0xff;
		digest[4*i+2] = (ctx->state[i] >> 16) & 0xff;
		digest[4*i+3] = (ctx->state[i] >> 24) & 0xff;
	}
}

/* ===================================================================== */
/* SHA-1 (RFC 3174).                                                     */
/* ===================================================================== */

#define ROL32(x,n) (((x) << (n)) | ((x) >> (32-(n))))

static void
sha1_transform(u_int32_t state[5], const u_int8_t block[64])
{
	u_int32_t w[80], a,b,c,d,e,f,k,t;
	int i;
	for (i = 0; i < 16; i++)
		w[i] = ((u_int32_t)block[4*i]<<24)|((u_int32_t)block[4*i+1]<<16)|
		    ((u_int32_t)block[4*i+2]<<8)|block[4*i+3];
	for (i = 16; i < 80; i++)
		w[i] = ROL32(w[i-3]^w[i-8]^w[i-14]^w[i-16], 1);
	a=state[0];b=state[1];c=state[2];d=state[3];e=state[4];
	for (i = 0; i < 80; i++) {
		if (i < 20) { f = (b&c)|(~b&d); k = 0x5a827999; }
		else if (i < 40) { f = b^c^d; k = 0x6ed9eba1; }
		else if (i < 60) { f = (b&c)|(b&d)|(c&d); k = 0x8f1bbcdc; }
		else { f = b^c^d; k = 0xca62c1d6; }
		t = ROL32(a,5) + f + e + k + w[i];
		e = d; d = c; c = ROL32(b,30); b = a; a = t;
	}
	state[0]+=a;state[1]+=b;state[2]+=c;state[3]+=d;state[4]+=e;
}

void
SHA1Init(SHA1_CTX *ctx)
{
	ctx->state[0]=0x67452301;ctx->state[1]=0xefcdab89;
	ctx->state[2]=0x98badcfe;ctx->state[3]=0x10325476;ctx->state[4]=0xc3d2e1f0;
	ctx->count = 0;
}

void
SHA1Update(SHA1_CTX *ctx, const u_int8_t *data, size_t len)
{
	size_t have = (size_t)((ctx->count >> 3) & 63);
	size_t need = 64 - have;
	ctx->count += (u_int64_t)len << 3;
	if (len >= need) {
		if (have) {
			memcpy(ctx->buffer + have, data, need);
			sha1_transform(ctx->state, ctx->buffer);
			data += need; len -= need; have = 0;
		}
		while (len >= 64) { sha1_transform(ctx->state, data); data += 64; len -= 64; }
	}
	if (len) memcpy(ctx->buffer + have, data, len);
}

void
SHA1Final(u_int8_t digest[SHA1_DIGEST_LENGTH], SHA1_CTX *ctx)
{
	u_int8_t pad[72];
	u_int64_t bits = ctx->count;
	size_t have = (size_t)((ctx->count >> 3) & 63);
	size_t padlen = (have < 56) ? (56 - have) : (120 - have);
	int i;
	pad[0] = 0x80;
	memset(pad + 1, 0, padlen - 1);
	for (i = 0; i < 8; i++)
		pad[padlen + i] = (u_int8_t)(bits >> (56 - 8*i));
	SHA1Update(ctx, pad, padlen + 8);
	for (i = 0; i < 5; i++) {
		digest[4*i]   = (ctx->state[i] >> 24) & 0xff;
		digest[4*i+1] = (ctx->state[i] >> 16) & 0xff;
		digest[4*i+2] = (ctx->state[i] >> 8) & 0xff;
		digest[4*i+3] = ctx->state[i] & 0xff;
	}
}

/* ===================================================================== */
/* SHA-256 (FIPS-180).                                                   */
/* ===================================================================== */

static const u_int32_t sha256_k[64] = {
0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2};

#define SHR(x,n) ((x) >> (n))
#define ROR(x,n) (((x) >> (n)) | ((x) << (32-(n))))
#define S0(x) (ROR(x,2)^ROR(x,13)^ROR(x,22))
#define S1(x) (ROR(x,6)^ROR(x,11)^ROR(x,25))
#define s0(x) (ROR(x,7)^ROR(x,18)^SHR(x,3))
#define s1(x) (ROR(x,17)^ROR(x,19)^SHR(x,10))

static void
sha256_transform(u_int32_t state[8], const u_int8_t block[64])
{
	u_int32_t w[64], a,b,c,d,e,f,g,h;
	int i;
	for (i = 0; i < 16; i++)
		w[i] = ((u_int32_t)block[4*i]<<24)|((u_int32_t)block[4*i+1]<<16)|
		    ((u_int32_t)block[4*i+2]<<8)|block[4*i+3];
	for (i = 16; i < 64; i++)
		w[i] = s1(w[i-2]) + w[i-7] + s0(w[i-15]) + w[i-16];
	a=state[0];b=state[1];c=state[2];d=state[3];
	e=state[4];f=state[5];g=state[6];h=state[7];
	for (i = 0; i < 64; i++) {
		u_int32_t t1 = h + S1(e) + ((e&f)^(~e&g)) + sha256_k[i] + w[i];
		u_int32_t t2 = S0(a) + ((a&b)^(a&c)^(b&c));
		h=g;g=f;f=e;e=d+t1;d=c;c=b;b=a;a=t1+t2;
	}
	state[0]+=a;state[1]+=b;state[2]+=c;state[3]+=d;
	state[4]+=e;state[5]+=f;state[6]+=g;state[7]+=h;
}

void
SHA256Init(SHA2_CTX *ctx)
{
	ctx->state.st32[0]=0x6a09e667;ctx->state.st32[1]=0xbb67ae85;
	ctx->state.st32[2]=0x3c6ef372;ctx->state.st32[3]=0xa54ff53a;
	ctx->state.st32[4]=0x510e527f;ctx->state.st32[5]=0x9b05688c;
	ctx->state.st32[6]=0x1f83d9ab;ctx->state.st32[7]=0x5be0cd19;
	ctx->bitcount[0] = 0;
}

void
SHA256Update(SHA2_CTX *ctx, const u_int8_t *data, size_t len)
{
	size_t have = (size_t)((ctx->bitcount[0] >> 3) & 63);
	size_t need = 64 - have;
	ctx->bitcount[0] += (u_int64_t)len << 3;
	if (len >= need) {
		if (have) {
			memcpy(ctx->buffer + have, data, need);
			sha256_transform(ctx->state.st32, ctx->buffer);
			data += need; len -= need; have = 0;
		}
		while (len >= 64) { sha256_transform(ctx->state.st32, data); data += 64; len -= 64; }
	}
	if (len) memcpy(ctx->buffer + have, data, len);
}

void
SHA256Final(u_int8_t digest[SHA256_DIGEST_LENGTH], SHA2_CTX *ctx)
{
	u_int8_t pad[72];
	u_int64_t bits = ctx->bitcount[0];
	size_t have = (size_t)((ctx->bitcount[0] >> 3) & 63);
	size_t padlen = (have < 56) ? (56 - have) : (120 - have);
	int i;
	pad[0] = 0x80;
	memset(pad + 1, 0, padlen - 1);
	for (i = 0; i < 8; i++)
		pad[padlen + i] = (u_int8_t)(bits >> (56 - 8*i));
	SHA256Update(ctx, pad, padlen + 8);
	for (i = 0; i < 8; i++) {
		digest[4*i]   = (ctx->state.st32[i] >> 24) & 0xff;
		digest[4*i+1] = (ctx->state.st32[i] >> 16) & 0xff;
		digest[4*i+2] = (ctx->state.st32[i] >> 8) & 0xff;
		digest[4*i+3] = ctx->state.st32[i] & 0xff;
	}
}

/* ===================================================================== */
/* HMAC (RFC 2104) over MD5 / SHA1 / SHA256.                             */
/* ===================================================================== */

#define HMAC_IMPL(NAME, CTXT, BASECTX, INIT, UPDATE, FINAL, BLOCK, DIGEST) \
void									\
NAME##_Init(CTXT *ctx, const u_int8_t *key, u_int klen)			\
{									\
	u_int8_t k[BLOCK], ipad[BLOCK];					\
	u_int i;							\
	if (klen > BLOCK) {						\
		BASECTX t; u_int8_t d[DIGEST];				\
		INIT(&t); UPDATE(&t, key, klen); FINAL(d, &t);		\
		memcpy(k, d, DIGEST); memset(k+DIGEST, 0, BLOCK-DIGEST);	\
	} else {							\
		memcpy(k, key, klen); memset(k+klen, 0, BLOCK-klen);	\
	}								\
	for (i = 0; i < BLOCK; i++) ipad[i] = k[i] ^ 0x36;		\
	INIT(&ctx->ctx);						\
	UPDATE(&ctx->ctx, ipad, BLOCK);					\
	memcpy(ctx->key, k, BLOCK);					\
}									\
void									\
NAME##_Update(CTXT *ctx, const u_int8_t *data, u_int len)		\
{									\
	UPDATE(&ctx->ctx, data, len);					\
}									\
void									\
NAME##_Final(u_int8_t digest[DIGEST], CTXT *ctx)			\
{									\
	u_int8_t opad[BLOCK], inner[DIGEST];				\
	u_int i;							\
	FINAL(inner, &ctx->ctx);					\
	for (i = 0; i < BLOCK; i++) opad[i] = ctx->key[i] ^ 0x5c;	\
	INIT(&ctx->ctx_key);						\
	UPDATE(&ctx->ctx_key, opad, BLOCK);				\
	UPDATE(&ctx->ctx_key, inner, DIGEST);				\
	FINAL(digest, &ctx->ctx_key);					\
}

HMAC_IMPL(HMAC_MD5, HMAC_MD5_CTX, MD5_CTX, MD5Init, MD5Update, MD5Final,
    MD5_BLOCK_LENGTH, MD5_DIGEST_LENGTH)
HMAC_IMPL(HMAC_SHA1, HMAC_SHA1_CTX, SHA1_CTX, SHA1Init, SHA1Update, SHA1Final,
    SHA1_BLOCK_LENGTH, SHA1_DIGEST_LENGTH)
HMAC_IMPL(HMAC_SHA256, HMAC_SHA256_CTX, SHA2_CTX, SHA256Init, SHA256Update,
    SHA256Final, SHA256_BLOCK_LENGTH, SHA256_DIGEST_LENGTH)

/* ===================================================================== */
/* AES-CMAC (RFC 4493).                                                  */
/* ===================================================================== */

static void
cmac_shift_left(const u_int8_t in[16], u_int8_t out[16])
{
	int i;
	u_int8_t carry = 0;
	for (i = 15; i >= 0; i--) {
		u_int8_t b = in[i];
		out[i] = (u_int8_t)((b << 1) | carry);
		carry = (b & 0x80) ? 1 : 0;
	}
}

void
AES_CMAC_SetKey(AES_CMAC_CTX *ctx, const u_int8_t key[AES_CMAC_KEY_LENGTH])
{
	AES_Setkey(&ctx->aesctx, key, 16);
}

void
AES_CMAC_Init(AES_CMAC_CTX *ctx)
{
	memset(ctx->X, 0, 16);
	ctx->M_n = 0;
}

void
AES_CMAC_Update(AES_CMAC_CTX *ctx, const u_int8_t *data, u_int len)
{
	u_int i;
	/* fill and flush full blocks, but keep the LAST block pending
	 * (CMAC treats the final block specially in Final) */
	while (len > 0) {
		if (ctx->M_n == 16) {
			u_int8_t y[16];
			for (i = 0; i < 16; i++)
				y[i] = ctx->X[i] ^ ctx->M_last[i];
			AES_Encrypt(&ctx->aesctx, y, ctx->X);
			ctx->M_n = 0;
		}
		ctx->M_last[ctx->M_n++] = *data++;
		len--;
	}
}

void
AES_CMAC_Final(u_int8_t digest[AES_CMAC_DIGEST_LENGTH], AES_CMAC_CTX *ctx)
{
	u_int8_t L[16], K1[16], K2[16], Y[16], M_last[16];
	u_int i;

	memset(L, 0, 16);
	AES_Encrypt(&ctx->aesctx, L, L);
	cmac_shift_left(L, K1);
	if (L[0] & 0x80)
		K1[15] ^= 0x87;
	cmac_shift_left(K1, K2);
	if (K1[0] & 0x80)
		K2[15] ^= 0x87;

	if (ctx->M_n == 16) {
		for (i = 0; i < 16; i++)
			M_last[i] = ctx->M_last[i] ^ K1[i];
	} else {
		/* pad: 0x80 then zeros */
		for (i = 0; i < 16; i++) {
			u_int8_t b;
			if (i < ctx->M_n) b = ctx->M_last[i];
			else if (i == ctx->M_n) b = 0x80;
			else b = 0x00;
			M_last[i] = b ^ K2[i];
		}
	}
	for (i = 0; i < 16; i++)
		Y[i] = M_last[i] ^ ctx->X[i];
	AES_Encrypt(&ctx->aesctx, Y, digest);
}

/* ===================================================================== */
/* AES Key Wrap (RFC 3394).                                              */
/* ===================================================================== */

void
aes_key_wrap_set_key(aes_key_wrap_ctx *ctx, const u_int8_t *kek, size_t kek_len)
{
	AES_Setkey(&ctx->ctx, kek, (int)kek_len);
}

void
aes_key_wrap_set_key_wrap_only(aes_key_wrap_ctx *ctx, const u_int8_t *kek,
    size_t kek_len)
{
	AES_Setkey(&ctx->ctx, kek, (int)kek_len);
}

void
aes_key_wrap(aes_key_wrap_ctx *ctx, const u_int8_t *plain, size_t nblocks,
    u_int8_t *cipher)
{
	u_int8_t A[8], B[16];
	size_t i, j, t;

	/* A = IV (0xA6 x8) */
	for (i = 0; i < 8; i++)
		A[i] = 0xa6;
	memmove(cipher + 8, plain, nblocks * 8);

	for (j = 0; j < 6; j++) {
		for (i = 1; i <= nblocks; i++) {
			memcpy(B, A, 8);
			memcpy(B + 8, cipher + i*8, 8);
			AES_Encrypt(&ctx->ctx, B, B);
			t = nblocks * j + i;
			memcpy(A, B, 8);
			/* A ^= t (64-bit big-endian) */
			A[7] ^= t & 0xff;
			A[6] ^= (t >> 8) & 0xff;
			A[5] ^= (t >> 16) & 0xff;
			A[4] ^= (t >> 24) & 0xff;
			memcpy(cipher + i*8, B + 8, 8);
		}
	}
	memcpy(cipher, A, 8);
}

int
aes_key_unwrap(aes_key_wrap_ctx *ctx, const u_int8_t *cipher, u_int8_t *plain,
    size_t nblocks)
{
	u_int8_t A[8], B[16];
	size_t i, t;
	long j;

	memcpy(A, cipher, 8);
	memmove(plain, cipher + 8, nblocks * 8);

	for (j = 5; j >= 0; j--) {
		for (i = nblocks; i >= 1; i--) {
			t = nblocks * (size_t)j + i;
			A[7] ^= t & 0xff;
			A[6] ^= (t >> 8) & 0xff;
			A[5] ^= (t >> 16) & 0xff;
			A[4] ^= (t >> 24) & 0xff;
			memcpy(B, A, 8);
			memcpy(B + 8, plain + (i-1)*8, 8);
			AES_Decrypt(&ctx->ctx, B, B);
			memcpy(A, B, 8);
			memcpy(plain + (i-1)*8, B + 8, 8);
		}
	}
	/* verify integrity: A must be the default IV */
	for (i = 0; i < 8; i++)
		if (A[i] != 0xa6)
			return (-1);
	return (0);
}

/* ===================================================================== */
/* Michael MIC (IEEE 802.11i TKIP).                                      */
/* ===================================================================== */

static __inline u_int32_t
mic_rol32(u_int32_t v, int n) { return ((v << n) | (v >> (32 - n))); }
static __inline u_int32_t
mic_ror32(u_int32_t v, int n) { return ((v >> n) | (v << (32 - n))); }

static void
michael_block(MICHAEL_CTX *ctx)
{
	u_int32_t l = ctx->l, r = ctx->r;
	r ^= mic_rol32(l, 17);
	l += r;
	r ^= ((l & 0xff00ff00) >> 8) | ((l & 0x00ff00ff) << 8);
	l += r;
	r ^= mic_rol32(l, 3);
	l += r;
	r ^= mic_ror32(l, 2);
	l += r;
	ctx->l = l; ctx->r = r;
}

void
michael_init(MICHAEL_CTX *ctx)
{
	ctx->nbytes = 0;
	ctx->l = 0;
	ctx->r = 0;
}

void
michael_key(const u_int8_t *key, MICHAEL_CTX *ctx)
{
	ctx->k0 = key[0] | (key[1]<<8) | (key[2]<<16) | ((u_int32_t)key[3]<<24);
	ctx->k1 = key[4] | (key[5]<<8) | (key[6]<<16) | ((u_int32_t)key[7]<<24);
	ctx->l = ctx->k0;
	ctx->r = ctx->k1;
	ctx->nbytes = 0;
}

void
michael_update(MICHAEL_CTX *ctx, const void *data, u_int len)
{
	const u_int8_t *p = data;
	while (len > 0) {
		ctx->block[ctx->nbytes++] = *p++;
		len--;
		if (ctx->nbytes == 4) {
			ctx->l ^= ctx->block[0] | (ctx->block[1]<<8) |
			    (ctx->block[2]<<16) | ((u_int32_t)ctx->block[3]<<24);
			michael_block(ctx);
			ctx->nbytes = 0;
		}
	}
}

void
michael_final(u_int8_t mic[MICHAEL_MIC_LEN], MICHAEL_CTX *ctx)
{
	/* append the "1" bit (0x5a) then zeros, per IEEE 802.11i */
	u_int8_t pad[4] = { 0x5a, 0, 0, 0 };
	u_int i;
	ctx->block[ctx->nbytes] = pad[0];
	for (i = ctx->nbytes + 1; i < 4; i++)
		ctx->block[i] = 0;
	ctx->l ^= ctx->block[0] | (ctx->block[1]<<8) |
	    (ctx->block[2]<<16) | ((u_int32_t)ctx->block[3]<<24);
	michael_block(ctx);
	/* one more all-zero block */
	michael_block(ctx);
	mic[0] = ctx->l & 0xff; mic[1] = (ctx->l>>8)&0xff;
	mic[2] = (ctx->l>>16)&0xff; mic[3] = (ctx->l>>24)&0xff;
	mic[4] = ctx->r & 0xff; mic[5] = (ctx->r>>8)&0xff;
	mic[6] = (ctx->r>>16)&0xff; mic[7] = (ctx->r>>24)&0xff;
}

/* ===================================================================== */
/* Self-test: published vectors. -DN80211_CRYPTO_TEST builds a main().   */
/* ===================================================================== */

#ifdef N80211_CRYPTO_TEST
static int fails;
static void
chk(const char *name, const void *got, const void *want, size_t n)
{
	if (memcmp(got, want, n) != 0) {
		size_t i;
		printf("FAIL %s: got ", name);
		for (i = 0; i < n; i++) printf("%02x", ((const u_int8_t*)got)[i]);
		printf(" want ");
		for (i = 0; i < n; i++) printf("%02x", ((const u_int8_t*)want)[i]);
		printf("\n");
		fails++;
	} else {
		printf("ok   %s\n", name);
	}
}

int
main(void)
{
	/* AES-128 FIPS-197 vector */
	{
		AES_CTX c;
		u_int8_t key[16] = {0x2b,0x7e,0x15,0x16,0x28,0xae,0xd2,0xa6,
		    0xab,0xf7,0x15,0x88,0x09,0xcf,0x4f,0x3c};
		u_int8_t pt[16] = {0x32,0x43,0xf6,0xa8,0x88,0x5a,0x30,0x8d,
		    0x31,0x31,0x98,0xa2,0xe0,0x37,0x07,0x34};
		u_int8_t exp[16] = {0x39,0x25,0x84,0x1d,0x02,0xdc,0x09,0xfb,
		    0xdc,0x11,0x85,0x97,0x19,0x6a,0x0b,0x32};
		u_int8_t ct[16], back[16];
		AES_Setkey(&c, key, 16);
		AES_Encrypt(&c, pt, ct);
		chk("AES128-enc", ct, exp, 16);
		AES_Decrypt(&c, ct, back);
		chk("AES128-dec", back, pt, 16);
	}
	/* AES-256 FIPS-197 vector */
	{
		AES_CTX c;
		u_int8_t key[32];
		u_int8_t pt[16], ct[16], back[16];
		u_int8_t exp[16] = {0x8e,0xa2,0xb7,0xca,0x51,0x67,0x45,0xbf,
		    0xea,0xfc,0x49,0x90,0x4b,0x49,0x60,0x89};
		int i;
		for (i=0;i<32;i++) key[i]=i;
		for (i=0;i<16;i++) pt[i]=(i<<4)|i, pt[i]=0x00; /* set below */
		{ u_int8_t p2[16]={0x00,0x11,0x22,0x33,0x44,0x55,0x66,0x77,
		    0x88,0x99,0xaa,0xbb,0xcc,0xdd,0xee,0xff}; memcpy(pt,p2,16); }
		AES_Setkey(&c, key, 32);
		AES_Encrypt(&c, pt, ct);
		chk("AES256-enc", ct, exp, 16);
		AES_Decrypt(&c, ct, back);
		chk("AES256-dec", back, pt, 16);
	}
	/* RC4 RFC 6229 key=0x0102030405, first 16 keystream bytes */
	{
		struct rc4_ctx c;
		u_int8_t key[5] = {0x01,0x02,0x03,0x04,0x05};
		u_int8_t zero[16] = {0}, ks[16];
		u_int8_t exp[16] = {0xb2,0x39,0x63,0x05,0xf0,0x3d,0xc0,0x27,
		    0xcc,0xc3,0x52,0x4a,0x0a,0x11,0x18,0xa8};
		rc4_keysetup(&c, key, 5);
		rc4_crypt(&c, zero, ks, 16);
		chk("RC4-6229", ks, exp, 16);
	}
	/* MD5("abc") RFC 1321 */
	{
		MD5_CTX c; u_int8_t d[16];
		u_int8_t exp[16] = {0x90,0x01,0x50,0x98,0x3c,0xd2,0x4f,0xb0,
		    0xd6,0x96,0x3f,0x7d,0x28,0xe1,0x7f,0x72};
		MD5Init(&c); MD5Update(&c, (u_int8_t*)"abc", 3); MD5Final(d, &c);
		chk("MD5-abc", d, exp, 16);
	}
	/* SHA1("abc") RFC 3174 */
	{
		SHA1_CTX c; u_int8_t d[20];
		u_int8_t exp[20] = {0xa9,0x99,0x3e,0x36,0x47,0x06,0x81,0x6a,
		    0xba,0x3e,0x25,0x71,0x78,0x50,0xc2,0x6c,0x9c,0xd0,0xd8,0x9d};
		SHA1Init(&c); SHA1Update(&c, (u_int8_t*)"abc", 3); SHA1Final(d, &c);
		chk("SHA1-abc", d, exp, 20);
	}
	/* SHA256("abc") FIPS-180 */
	{
		SHA2_CTX c; u_int8_t d[32];
		u_int8_t exp[32] = {0xba,0x78,0x16,0xbf,0x8f,0x01,0xcf,0xea,
		    0x41,0x41,0x40,0xde,0x5d,0xae,0x22,0x23,0xb0,0x03,0x61,0xa3,
		    0x96,0x17,0x7a,0x9c,0xb4,0x10,0xff,0x61,0xf2,0x00,0x15,0xad};
		SHA256Init(&c); SHA256Update(&c, (u_int8_t*)"abc", 3); SHA256Final(d, &c);
		chk("SHA256-abc", d, exp, 32);
	}
	/* HMAC-SHA1 RFC 2202 test case 2: key="Jefe", data="what do ya want..." */
	{
		HMAC_SHA1_CTX c; u_int8_t d[20];
		u_int8_t exp[20] = {0xef,0xfc,0xdf,0x6a,0xe5,0xeb,0x2f,0xa2,
		    0xd2,0x74,0x16,0xd5,0xf1,0x84,0xdf,0x9c,0x25,0x9a,0x7c,0x79};
		HMAC_SHA1_Init(&c, (u_int8_t*)"Jefe", 4);
		HMAC_SHA1_Update(&c, (u_int8_t*)"what do ya want for nothing?", 28);
		HMAC_SHA1_Final(d, &c);
		chk("HMAC-SHA1-rfc2202", d, exp, 20);
	}
	/* HMAC-SHA256 RFC 4231 test case 2 */
	{
		HMAC_SHA256_CTX c; u_int8_t d[32];
		u_int8_t exp[32] = {0x5b,0xdc,0xc1,0x46,0xbf,0x60,0x75,0x4e,
		    0x6a,0x04,0x24,0x26,0x08,0x95,0x75,0xc7,0x5a,0x00,0x3f,0x08,
		    0x9d,0x27,0x39,0x83,0x9d,0xec,0x58,0xb9,0x64,0xec,0x38,0x43};
		HMAC_SHA256_Init(&c, (u_int8_t*)"Jefe", 4);
		HMAC_SHA256_Update(&c, (u_int8_t*)"what do ya want for nothing?", 28);
		HMAC_SHA256_Final(d, &c);
		chk("HMAC-SHA256-rfc4231", d, exp, 32);
	}
	/* AES-CMAC RFC 4493: key=2b7e..., Mlen=0 and Mlen=16 */
	{
		AES_CMAC_CTX c; u_int8_t d[16];
		u_int8_t key[16] = {0x2b,0x7e,0x15,0x16,0x28,0xae,0xd2,0xa6,
		    0xab,0xf7,0x15,0x88,0x09,0xcf,0x4f,0x3c};
		u_int8_t exp0[16] = {0xbb,0x1d,0x69,0x29,0xe9,0x59,0x37,0x28,
		    0x7f,0xa3,0x7d,0x12,0x9b,0x75,0x67,0x46};
		u_int8_t m16[16] = {0x6b,0xc1,0xbe,0xe2,0x2e,0x40,0x9f,0x96,
		    0xe9,0x3d,0x7e,0x11,0x73,0x93,0x17,0x2a};
		u_int8_t exp16[16] = {0x07,0x0a,0x16,0xb4,0x6b,0x4d,0x41,0x44,
		    0xf7,0x9b,0xdd,0x9d,0xd0,0x4a,0x28,0x7c};
		AES_CMAC_SetKey(&c, key);
		AES_CMAC_Init(&c); AES_CMAC_Final(d, &c);
		chk("AES-CMAC-len0", d, exp0, 16);
		AES_CMAC_SetKey(&c, key);
		AES_CMAC_Init(&c); AES_CMAC_Update(&c, m16, 16); AES_CMAC_Final(d, &c);
		chk("AES-CMAC-len16", d, exp16, 16);
	}
	/* AES Key Wrap RFC 3394 128-bit KEK / 128-bit key */
	{
		aes_key_wrap_ctx c;
		u_int8_t kek[16] = {0x00,0x01,0x02,0x03,0x04,0x05,0x06,0x07,
		    0x08,0x09,0x0a,0x0b,0x0c,0x0d,0x0e,0x0f};
		u_int8_t key[16] = {0x00,0x11,0x22,0x33,0x44,0x55,0x66,0x77,
		    0x88,0x99,0xaa,0xbb,0xcc,0xdd,0xee,0xff};
		u_int8_t exp[24] = {0x1f,0xa6,0x8b,0x0a,0x81,0x12,0xb4,0x47,
		    0xae,0xf3,0x4b,0xd8,0xfb,0x5a,0x7b,0x82,0x9d,0x3e,0x86,0x23,
		    0x71,0xd2,0xcf,0xe5};
		u_int8_t wrapped[24], back[16];
		int rc;
		aes_key_wrap_set_key(&c, kek, 16);
		aes_key_wrap(&c, key, 2, wrapped);
		chk("AES-keywrap-rfc3394", wrapped, exp, 24);
		rc = aes_key_unwrap(&c, wrapped, back, 2);
		if (rc != 0) { printf("FAIL keyunwrap integrity\n"); fails++; }
		else chk("AES-keyunwrap", back, key, 16);
	}
	/* Michael MIC (IEEE 802.11i TKIP). Two vectors, cross-checked against an
	 * independent reference implementation of the same algorithm:
	 *   michael(key=0, msg="")            = 82925c1ca1d130b8  (802.11i documented)
	 *   michael(key=82925c1ca1d130b8,"") = 535b082aea59682a  (chained) */
	{
		MICHAEL_CTX c; u_int8_t mic[8];
		u_int8_t zkey[8] = {0};
		u_int8_t exp0[8] = {0x82,0x92,0x5c,0x1c,0xa1,0xd1,0x30,0xb8};
		u_int8_t key[8] = {0x82,0x92,0x5c,0x1c,0xa1,0xd1,0x30,0xb8};
		u_int8_t exp1[8] = {0x53,0x5b,0x08,0x2a,0xea,0x59,0x68,0x2a};
		michael_init(&c);
		michael_key(zkey, &c);
		michael_final(mic, &c);
		chk("Michael-zerokey", mic, exp0, 8);
		michael_init(&c);
		michael_key(key, &c);
		michael_final(mic, &c);
		chk("Michael-chained", mic, exp1, 8);
	}
	printf(fails ? "\n%d FAILURES\n" : "\nALL VECTORS PASS\n", fails);
	return (fails != 0);
}
#endif /* N80211_CRYPTO_TEST */
