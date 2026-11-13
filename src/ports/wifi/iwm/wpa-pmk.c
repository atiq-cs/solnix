/*
 * wpa-pmk -- derive the WPA/WPA2 PMK from a passphrase and SSID and set it on
 * an illumos wifi link as the private property _wpa_psk (64 hex chars), so
 * OpenBSD's in-kernel RSN supplicant (iwm) can run the 4-way handshake. This
 * is the thin userland half of the iwm WPA2 join: the passphrase is read here
 * and never crosses into the kernel; only the 32-byte PMK does.
 *
 *   PMK = PBKDF2(HMAC-SHA1, passphrase, SSID, 4096, 32)   (IEEE 802.11i / RFC 2898)
 *
 * Usage:
 *   wpa-pmk <ssid> <link>              passphrase on stdin (one line)
 *   wpa-pmk -f <pskfile> <ssid> <link> passphrase from file (first line)
 *   wpa-pmk -n <ssid>                  print PMK hex only, set nothing (test)
 *   wpa-pmk -t                         run the self-test and exit
 *
 * Self-contained SHA-1 + HMAC-SHA1 + PBKDF2 (no libcrypto on the target).
 * Build:  gcc -O2 -o wpa-pmk wpa-pmk.c            (host self-test)
 *         gcc -O2 -o wpa-pmk wpa-pmk.c -ldladm    (on dixi, to set the prop)
 * The -ldladm path is compiled only when WPA_PMK_WITH_DLADM is defined; by
 * default the tool shells out to dladm(8) so it needs no library at all.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* ---- SHA-1 (FIPS 180) ------------------------------------------------- */

typedef struct {
	uint32_t h[5];
	uint64_t len;
	uint8_t  buf[64];
	size_t   n;
} sha1_ctx;

static uint32_t rol(uint32_t v, int b) { return (v << b) | (v >> (32 - b)); }

static void sha1_block(sha1_ctx *c, const uint8_t *p)
{
	uint32_t w[80], a, b, d, e, f, k, t;
	int i;

	for (i = 0; i < 16; i++)
		w[i] = (uint32_t)p[i*4] << 24 | (uint32_t)p[i*4+1] << 16 |
		    (uint32_t)p[i*4+2] << 8 | (uint32_t)p[i*4+3];
	for (i = 16; i < 80; i++)
		w[i] = rol(w[i-3] ^ w[i-8] ^ w[i-14] ^ w[i-16], 1);
	a = c->h[0]; b = c->h[1]; d = c->h[2]; e = c->h[3]; f = c->h[4];
	for (i = 0; i < 80; i++) {
		uint32_t x;
		if (i < 20)      { x = (b & d) | (~b & e);          k = 0x5A827999; }
		else if (i < 40) { x = b ^ d ^ e;                   k = 0x6ED9EBA1; }
		else if (i < 60) { x = (b & d) | (b & e) | (d & e); k = 0x8F1BBCDC; }
		else             { x = b ^ d ^ e;                   k = 0xCA62C1D6; }
		t = rol(a, 5) + x + f + k + w[i];
		f = e; e = d; d = rol(b, 30); b = a; a = t;
	}
	c->h[0] += a; c->h[1] += b; c->h[2] += d; c->h[3] += e; c->h[4] += f;
}

static void sha1_init(sha1_ctx *c)
{
	c->h[0] = 0x67452301; c->h[1] = 0xEFCDAB89; c->h[2] = 0x98BADCFE;
	c->h[3] = 0x10325476; c->h[4] = 0xC3D2E1F0;
	c->len = 0; c->n = 0;
}

static void sha1_update(sha1_ctx *c, const uint8_t *p, size_t n)
{
	c->len += n;
	while (n) {
		size_t k = 64 - c->n;
		if (k > n) k = n;
		memcpy(c->buf + c->n, p, k);
		c->n += k; p += k; n -= k;
		if (c->n == 64) { sha1_block(c, c->buf); c->n = 0; }
	}
}

static void sha1_final(sha1_ctx *c, uint8_t out[20])
{
	uint64_t bits = c->len * 8;
	uint8_t pad = 0x80;
	int i;

	sha1_update(c, &pad, 1);
	pad = 0;
	while (c->n != 56)
		sha1_update(c, &pad, 1);
	for (i = 7; i >= 0; i--) {
		uint8_t b = (uint8_t)(bits >> (i * 8));
		sha1_update(c, &b, 1);
	}
	for (i = 0; i < 5; i++) {
		out[i*4]   = (uint8_t)(c->h[i] >> 24);
		out[i*4+1] = (uint8_t)(c->h[i] >> 16);
		out[i*4+2] = (uint8_t)(c->h[i] >> 8);
		out[i*4+3] = (uint8_t)(c->h[i]);
	}
}

/* ---- HMAC-SHA1 -------------------------------------------------------- */

static void hmac_sha1(const uint8_t *key, size_t klen,
    const uint8_t *msg, size_t mlen, uint8_t out[20])
{
	uint8_t k[64], ipad[64], opad[64], ih[20];
	sha1_ctx c;
	int i;

	memset(k, 0, sizeof (k));
	if (klen > 64) {
		sha1_init(&c); sha1_update(&c, key, klen); sha1_final(&c, k);
	} else {
		memcpy(k, key, klen);
	}
	for (i = 0; i < 64; i++) { ipad[i] = k[i] ^ 0x36; opad[i] = k[i] ^ 0x5c; }
	sha1_init(&c); sha1_update(&c, ipad, 64); sha1_update(&c, msg, mlen);
	sha1_final(&c, ih);
	sha1_init(&c); sha1_update(&c, opad, 64); sha1_update(&c, ih, 20);
	sha1_final(&c, out);
}

/* ---- PBKDF2-HMAC-SHA1 ------------------------------------------------- */

static void pbkdf2(const char *pass, const uint8_t *salt, size_t slen,
    int iter, uint8_t *out, size_t olen)
{
	size_t plen = strlen(pass);
	uint32_t block = 1;
	size_t done = 0;

	while (done < olen) {
		uint8_t u[20], t[20], in[256];
		size_t n = olen - done, inlen;
		int i, j;

		if (n > 20) n = 20;
		if (slen > sizeof (in) - 4) slen = sizeof (in) - 4;
		memcpy(in, salt, slen);
		in[slen]   = (uint8_t)(block >> 24);
		in[slen+1] = (uint8_t)(block >> 16);
		in[slen+2] = (uint8_t)(block >> 8);
		in[slen+3] = (uint8_t)(block);
		inlen = slen + 4;
		hmac_sha1((const uint8_t *)pass, plen, in, inlen, u);
		memcpy(t, u, 20);
		for (i = 1; i < iter; i++) {
			hmac_sha1((const uint8_t *)pass, plen, u, 20, u);
			for (j = 0; j < 20; j++) t[j] ^= u[j];
		}
		memcpy(out + done, t, n);
		done += n;
		block++;
	}
}

static void tohex(const uint8_t *b, size_t n, char *out)
{
	static const char d[] = "0123456789abcdef";
	size_t i;
	for (i = 0; i < n; i++) { out[i*2] = d[b[i] >> 4]; out[i*2+1] = d[b[i] & 15]; }
	out[n*2] = '\0';
}

/* ---- self-test: IEEE 802.11i test vector ------------------------------ */

static int selftest(void)
{
	/* RFC-known WPA vector: pass "password", ssid "IEEE" */
	static const char *want =
	    "f42c6fc52df0ebef9ebb4b90b38a5f90"
	    "2e83fe1b135a70e23aed762e9710a12e";
	uint8_t pmk[32];
	char hex[65];

	pbkdf2("password", (const uint8_t *)"IEEE", 4, 4096, pmk, 32);
	tohex(pmk, 32, hex);
	if (strcmp(hex, want) != 0) {
		fprintf(stderr, "SELFTEST FAIL\n got %s\n want %s\n", hex, want);
		return (1);
	}
	/* second published vector: pass "ThisIsAPassword", ssid "ThisIsASSID" */
	pbkdf2("ThisIsAPassword", (const uint8_t *)"ThisIsASSID", 11, 4096,
	    pmk, 32);
	tohex(pmk, 32, hex);
	if (strcmp(hex,
	    "0dc0d6eb90555ed6419756b9a15ec3e3"
	    "209b63df707dd508d14581f8982721af") != 0) {
		fprintf(stderr, "SELFTEST FAIL vector 2: %s\n", hex);
		return (1);
	}
	printf("selftest OK\n");
	return (0);
}

/* ---- main ------------------------------------------------------------- */

static void readpass(const char *file, char *buf, size_t bufsz)
{
	FILE *f = file ? fopen(file, "r") : stdin;
	size_t n;

	if (f == NULL) { perror(file); exit(2); }
	if (fgets(buf, (int)bufsz, f) == NULL) { fprintf(stderr, "empty passphrase\n"); exit(2); }
	if (file) fclose(f);
	n = strlen(buf);
	while (n > 0 && (buf[n-1] == '\n' || buf[n-1] == '\r')) buf[--n] = '\0';
	if (n < 8 || n > 63) { fprintf(stderr, "passphrase must be 8..63 chars\n"); exit(2); }
}

/*
 * Canonicalize a BSSID to 17 chars "aa:bb:cc:dd:ee:ff" (lowercase, 2-digit
 * octets). Accepts dladm scan-wifi's abbreviated form (e.g. "0:0:5e:0:53:7e")
 * and pads single-digit octets. The driver's _wpa_psk parser needs the fixed
 * 17-char form. Returns 0 on success.
 */
static int canon_bssid(const char *in, char out[18])
{
	unsigned v[6];
	int n = 0, consumed = 0;
	if (sscanf(in, "%x:%x:%x:%x:%x:%x%n", &v[0],&v[1],&v[2],&v[3],&v[4],&v[5], &consumed) != 6)
		return (-1);
	if (in[consumed] != '\0')
		return (-1);
	for (n = 0; n < 6; n++)
		if (v[n] > 0xff)
			return (-1);
	(void) snprintf(out, 18, "%02x:%02x:%02x:%02x:%02x:%02x",
	    v[0],v[1],v[2],v[3],v[4],v[5]);
	return (0);
}

int main(int argc, char **argv)
{
	const char *pskfile = NULL, *ssid, *link = NULL, *bssid = NULL;
	char bssidc[18];
	int noset = 0, i = 1;
	char pass[128], pmkhex[65], cmd[448];
	uint8_t pmk[32];

	if (argc >= 2 && strcmp(argv[1], "-t") == 0)
		return (selftest());
	if (i < argc && strcmp(argv[i], "-n") == 0) { noset = 1; i++; }
	if (i < argc && strcmp(argv[i], "-f") == 0) { pskfile = argv[i+1]; i += 2; }
	if (i < argc && strcmp(argv[i], "-b") == 0) {
		if (canon_bssid(argv[i+1], bssidc) != 0) {
			fprintf(stderr, "invalid bssid '%s'\n", argv[i+1]);
			return (2);
		}
		bssid = bssidc;
		i += 2;
	}
	if (i >= argc) {
		fprintf(stderr, "usage: wpa-pmk [-f pskfile] [-b bssid] <ssid> <link>\n"
		    "       wpa-pmk -n [-b bssid] <ssid>   (print value, set nothing)\n"
		    "       wpa-pmk -t                     (self-test)\n"
		    "  -b pins a BSSID (aa:bb:cc:dd:ee:ff) when several APs share\n"
		    "     the SSID with mixed security.\n");
		return (2);
	}
	ssid = argv[i++];
	if (!noset) {
		if (i >= argc) { fprintf(stderr, "missing <link>\n"); return (2); }
		link = argv[i++];
	}
	readpass(pskfile, pass, sizeof (pass));
	pbkdf2(pass, (const uint8_t *)ssid, strlen(ssid), 4096, pmk, 32);
	memset(pass, 0, sizeof (pass));
	tohex(pmk, 32, pmkhex);
	memset(pmk, 0, sizeof (pmk));
	/*
	 * Value is "<pmk>:<bssid-or-->:<ssid>": PMK (fixed 64 hex), ':', then a
	 * fixed-position BSSID field (17-char aa:bb:cc:dd:ee:ff or a single '-'
	 * for no pin), ':', then the SSID last (may contain ':'). dladm rejects
	 * '|' in a value and SSIDs may contain ':', so the BSSID is a fixed
	 * field, not a suffix. -t: active only, not persisted.
	 */
	if (noset) {
		printf("%s:%s:%s\n", pmkhex, bssid ? bssid : "-", ssid);
		return (0);
	}
	(void) snprintf(cmd, sizeof (cmd),
	    "dladm set-linkprop -t -p _wpa_psk=%s:%s:%s %s",
	    pmkhex, bssid ? bssid : "-", ssid, link);
	memset(pmkhex, 0, sizeof (pmkhex));
	return (system(cmd) == 0 ? 0 : 1);
}
