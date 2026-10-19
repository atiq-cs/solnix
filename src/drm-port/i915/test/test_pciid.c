/*
 * test_pciid.c -- userland self-check of i915_pciid.c (the same source the
 * kernel object is built from). Exit 0 = every expectation held.
 *
 * Expectations come from upstream, not from this table: 0x3E9B is listed
 * under INTEL_CFL_H_GT2_IDS ("Halo GT2") and 0x591B under INTEL_KBL_GT2_IDS in
 * pciids.h; 0x46A6 (the X1E) under INTEL_ADLP_IDS; 0x9A49 is Tiger Lake (not
 * matched); 10de:1c8c is the X1's NVIDIA GP107M; an i915 id with a non-display
 * class must not match.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../i915_pciid.h"

static int fails;

static void
expect(uint16_t v, uint16_t d, uint32_t cls, const char *plat, int gt)
{
	const struct i915_pciid_info *i = i915_pciid_match(v, d, cls);
	int ok = plat == NULL ? i == NULL :
	    (i != NULL && strcmp(i->platform, plat) == 0 && i->gt == gt);

	printf("%s %04x:%04x class %06x -> %s gt%d\n", ok ? "PASS" : "FAIL",
	    v, d, cls, i ? i->platform : "no-match", i ? i->gt : 0);
	fails += !ok;
}

int
main(int argc, char **argv)
{
	unsigned int n = i915_pciid_count(), k, seen = 0;

	/* test_pciid VENDOR DEVICE CLASS (hex): match one live device. */
	if (argc == 4) {
		const struct i915_pciid_info *i = i915_pciid_match(
		    strtoul(argv[1], NULL, 16), strtoul(argv[2], NULL, 16),
		    strtoul(argv[3], NULL, 16));
		printf("%s:%s class %s -> %s gen%d gt%d\n", argv[1], argv[2],
		    argv[3], i ? i->platform : "no-match", i ? i->gen : 0,
		    i ? i->gt : 0);
		return (i == NULL);
	}

	expect(0x8086, 0x3e9b, 0x030000, "coffeelake", 2);	/* the X1 */
	expect(0x8086, 0x591b, 0x030000, "kabylake", 2);
	expect(0x8086, 0x3e9b, 0x040300, NULL, 0);	/* audio class: no */
	expect(0x8086, 0x46a6, 0x030000, "alderlake_p", 0);	/* the X1E */
	expect(0x8086, 0x46a6, 0x040300, NULL, 0);	/* audio class: no */
	expect(0x8086, 0x9a49, 0x030000, NULL, 0);	/* TGL: not matched */
	expect(0x10de, 0x1c8c, 0x030200, NULL, 0);	/* NVIDIA GP107M */
	for (k = 0; k < n; k++)
		seen += i915_pciid_device(k) == 0x3e9b;
	printf("%s table has %u ids, 0x3e9b listed %u time(s)\n",
	    seen == 1 ? "PASS" : "FAIL", n, seen);
	fails += seen != 1;
	printf("%s\n", fails == 0 ? "ALL PASS" : "FAILED");
	return (fails != 0);
}
