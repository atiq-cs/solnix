/*
 * rndtest.c -- rvlogin: getrandom(278) from the kernel's virtio-rng, raw ecalls.
 *   rndtest        expect a working source: two 4096-byte draws differ, each has
 *                  all 256 byte values with a sane chi-square, a short draw works,
 *                  bad flags -> EINVAL, a kernel pointer -> EFAULT.
 *   rndtest none   control (qemu without -device virtio-rng-device): ENOSYS.
 * prints RNDTEST PASS / RNDTEST FAIL <why>
 */
#include <stdio.h>
#include <string.h>

static long
ks(long n, long a, long b, long c)
{
	register long a0 __asm__("a0") = a, a1 __asm__("a1") = b,
	    a2 __asm__("a2") = c, a7 __asm__("a7") = n;
	__asm__ __volatile__("ecall" : "+r"(a0) : "r"(a1), "r"(a2), "r"(a7) : "memory");
	return (a0);
}
#define	K_getrandom	278

static unsigned char b1[4096], b2[4096];

static int
fail(const char *w, long r)
{
	printf("RNDTEST FAIL %s r=%ld\n", w, r);
	return (1);
}

static int
spread(const unsigned char *b, int n, double *chi)
{
	int c[256], i, v = 0;
	double e = n / 256.0, x = 0;

	memset(c, 0, sizeof (c));
	for (i = 0; i < n; i++)
		c[b[i]]++;
	for (i = 0; i < 256; i++) {
		v += c[i] != 0;
		x += (c[i] - e) * (c[i] - e) / e;
	}
	*chi = x;
	return (v);
}

int
main(int argc, char **argv)
{
	long r;
	double x1, x2;
	int v1, v2;

	r = ks(K_getrandom, (long)b1, 16, 0);
	if (argc > 1 && strcmp(argv[1], "none") == 0) {
		if (r != -38)
			return (fail("no-device: want -38 ENOSYS", r));
		printf("RNDTEST PASS (no device: ENOSYS)\n");
		return (0);
	}
	if (r != 16)
		return (fail("short draw", r));
	if ((r = ks(K_getrandom, (long)b1, sizeof (b1), 1)) != (long)sizeof (b1))
		return (fail("draw 1", r));
	if ((r = ks(K_getrandom, (long)b2, sizeof (b2), 0)) != (long)sizeof (b2))
		return (fail("draw 2", r));
	if (memcmp(b1, b2, sizeof (b1)) == 0)
		return (fail("two draws equal", 0));
	v1 = spread(b1, sizeof (b1), &x1);
	v2 = spread(b2, sizeof (b2), &x2);
	/* 255 dof: chi-square above 400 has p < 1e-8 for uniform bytes */
	if (v1 < 250 || v2 < 250 || x1 > 400 || x2 > 400)
		return (fail("not uniform", (long)(x1 > x2 ? x1 : x2)));
	if ((r = ks(K_getrandom, (long)b1, 16, 0x100)) != -22)
		return (fail("bad flags: want -22", r));
	if ((r = ks(K_getrandom, 0x80200000L, 16, 0)) != -14)
		return (fail("kernel ptr: want -14", r));
	printf("RNDTEST PASS values=%d/%d chi2=%d/%d\n", v1, v2, (int)x1, (int)x2);
	return (0);
}
