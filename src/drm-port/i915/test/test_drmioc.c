/*
 * test_drmioc.c -- userland check of i915_drmioc.h, the Linux -> OpenBSD
 * DRM ioctl command translation the i915 cdev ioctl entry point uses.
 *
 * For every DRM core + i915 ioctl of OpenBSD's uapi headers (ioc_list.h):
 *   1. i915_ioc_xlate(linux encoding) == OpenBSD encoding, bit for bit;
 *   2. copyin/copyout = OpenBSD's IOC_IN/IOC_OUT, size = sizeof the struct;
 *   3. the command the module's drm_ioctls[] table holds (illumos
 *      ioccom.h, 8-bit size) has the same nr and direction; its size
 *      differs only where the struct is >= 256 bytes (reported: that is
 *      where drm_do_ioctl's IOCPARM_LEN of the table entry would be short).
 * Then the R1a set (the brief's list) is checked by name.
 * Build: Makefile "test-ioc". -DI915_DRMIOC_SABOTAGE must FAIL.
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "../i915_drmioc.h"

extern const uint32_t tbl_linux_cmd[], tbl_obsd_cmd[], tbl_illumos_cmd[];
extern const char *tbl_linux_name[];
extern const size_t tbl_linux_n, tbl_obsd_n, tbl_illumos_n;

static int fails;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL " __VA_ARGS__); \
	printf("\n"); } } while (0)

static const char *r1a[] = {
	"DRM_IOCTL_VERSION", "DRM_IOCTL_GET_CAP", "DRM_IOCTL_SET_CLIENT_CAP",
	"DRM_IOCTL_MODE_GETRESOURCES", "DRM_IOCTL_MODE_GETCONNECTOR",
	"DRM_IOCTL_MODE_GETENCODER", "DRM_IOCTL_MODE_GETCRTC",
	"DRM_IOCTL_MODE_GETPLANERESOURCES", "DRM_IOCTL_MODE_GETPLANE",
	"DRM_IOCTL_MODE_CREATE_DUMB", "DRM_IOCTL_MODE_MAP_DUMB",
	"DRM_IOCTL_MODE_DESTROY_DUMB", "DRM_IOCTL_MODE_ADDFB2",
	"DRM_IOCTL_MODE_RMFB", "DRM_IOCTL_MODE_SETCRTC",
	"DRM_IOCTL_MODE_PAGE_FLIP", "DRM_IOCTL_MODE_ATOMIC",
	"DRM_IOCTL_MODE_GETPROPERTY", "DRM_IOCTL_MODE_OBJ_GETPROPERTIES",
	"DRM_IOCTL_SET_MASTER", "DRM_IOCTL_DROP_MASTER",
};

int
main(void)
{
	size_t i, j, wide = 0, r1a_found = 0;

	CHECK(tbl_linux_n == tbl_obsd_n && tbl_obsd_n == tbl_illumos_n,
	    "table sizes %zu %zu %zu", tbl_linux_n, tbl_obsd_n, tbl_illumos_n);
	for (i = 0; i < tbl_linux_n; i++) {
		uint32_t l = tbl_linux_cmd[i], o = tbl_obsd_cmd[i];
		uint32_t il = tbl_illumos_cmd[i];
		struct i915_ioc x;
		int rc = i915_ioc_xlate(l, &x);

		CHECK(rc == 0, "%s: xlate rc %d", tbl_linux_name[i], rc);
		if (rc != 0)
			continue;
		CHECK(x.ocmd == o, "%s: linux 0x%08x -> 0x%08x, OpenBSD 0x%08x",
		    tbl_linux_name[i], l, x.ocmd, o);
		CHECK(x.in == ((o & I915_OIOC_IN) != 0) &&
		    x.out == ((o & I915_OIOC_OUT) != 0),
		    "%s: in/out %d/%d vs OpenBSD 0x%08x", tbl_linux_name[i],
		    x.in, x.out, o);
		CHECK(x.size == ((o >> 16) & I915_OIOC_SIZEMASK),
		    "%s: size %u", tbl_linux_name[i], x.size);
		/* the module's own table entry (illumos encoding) */
		CHECK((il & 0xffff) == (o & 0xffff) &&
		    (il & 0xe0000000u) == (o & 0xe0000000u),
		    "%s: illumos table 0x%08x vs OpenBSD 0x%08x",
		    tbl_linux_name[i], il, o);
		if (((il >> 16) & 0xff) != x.size) {
			wide++;
			printf("NOTE %s: size %u >= 256, illumos table entry "
			    "carries %u\n", tbl_linux_name[i], x.size,
			    (il >> 16) & 0xff);
		}
	}
	for (j = 0; j < sizeof (r1a) / sizeof (r1a[0]); j++)
		for (i = 0; i < tbl_linux_n; i++)
			if (strcmp(tbl_linux_name[i], r1a[j]) == 0) {
				struct i915_ioc x = { 0 };

				(void) i915_ioc_xlate(tbl_linux_cmd[i], &x);
				printf("R1a %-34s linux 0x%08x obsd 0x%08x "
				    "in %d out %d size %u\n", r1a[j],
				    tbl_linux_cmd[i], x.ocmd, x.in, x.out,
				    x.size);
				r1a_found++;
				break;
			}
	CHECK(r1a_found == sizeof (r1a) / sizeof (r1a[0]),
	    "R1a set: %zu of %zu found", r1a_found, sizeof (r1a) / sizeof (r1a[0]));
	{	/* rejects: not 'd', too big, _IO with a size */
		struct i915_ioc x;

		CHECK(i915_ioc_xlate(0xc0104b0a, &x) == 25, "type 'K' accepted");
		CHECK(i915_ioc_xlate(0xc0000000u | (8192u << 16) | 0x6400, &x) ==
		    25, "8 KB argument accepted");
		CHECK(i915_ioc_xlate((4u << 16) | 0x641e, &x) == 25,
		    "_IO with a size accepted");
	}
	{	/*
		 * Minors: decode i915_il_ominor exactly as OpenBSD's drm_drv.c
		 * does (drm_get_device_from_kdev, drmopen's realminor), for drm
		 * units 0-3, card and render, clones 1..I915_IL_CLONE_MAX of
		 * instance 0. Every open must get its own fminor key.
		 */
		uint32_t u, k, c, kinds[2] = { I915_IL_CARD, I915_IL_RENDER };
		size_t nkeys = 0, bad = 0;
		static unsigned char seen[1u << 24];

		for (u = 0; u < 4; u++)
			for (k = 0; k < 2; k++)
				for (c = 1; c <= I915_IL_CLONE_MAX; c++) {
					uint32_t m = I915_IL_MINOR(0, kinds[k], c);
					uint32_t om = i915_il_ominor(m, u);
					int real = om & ((1 << 8) - 1), unit = real;

					if (unit >= 128)
						unit -= 128;
					if ((uint32_t)unit != u || (real >= 128) != (k == 1) ||
					    (real >= 64 && real < 128) || om >= (1u << 24))
						bad++;
					if (!seen[om])
						nkeys++;
					seen[om] = 1;
				}
		CHECK(bad == 0, "minors: %zu wrong unit/type", bad);
		CHECK(nkeys == 4u * 2u * I915_IL_CLONE_MAX,
		    "minors: %zu distinct drm_file keys for %u opens", nkeys,
		    4u * 2u * I915_IL_CLONE_MAX);
		CHECK(I915_IL_INST(I915_IL_MINOR(7, I915_IL_TEXT, 5)) == 7 &&
		    I915_IL_KIND(I915_IL_MINOR(7, I915_IL_TEXT, 5)) == I915_IL_TEXT &&
		    I915_IL_CLONE(I915_IL_MINOR(7, I915_IL_TEXT, 5)) == 5,
		    "minor field round trip");
		printf("minors: %zu opens -> %zu distinct drm_file keys, %zu bad\n",
		    (size_t)(4u * 2u * I915_IL_CLONE_MAX), nkeys, bad);
	}
	printf("%zu ioctls, %zu with a >= 256-byte argument; %s: %d failure(s)\n",
	    tbl_linux_n, wide, fails ? "FAIL" : "PASS", fails);
	return (fails != 0);
}
