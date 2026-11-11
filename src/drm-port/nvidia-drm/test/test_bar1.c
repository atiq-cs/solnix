/*
 * SPDX-FileCopyrightText: Copyright (c) 2026 solnix contributors
 * SPDX-License-Identifier: MIT
 *
 * test_bar1.c -- userland self-check of nvidia_drm_bar1.h, the GEM mmap
 * arithmetic of the illumos shell (the same header the kernel objects
 * include). Exit 0 = every expectation held. nvidia-drm-driver.nix runs it,
 * and each -DNVD_BAR1_SABOTAGE_* build must fail.
 *
 * The properties are the X1E's (lixi) RTX 3080 Ti Laptop 10de:2420 at
 * 01:00.0, read with prtconf -v on 2026-11-11: BAR0 32-bit 16 MB at
 * 0xb3000000, BAR1 (0x14) 64-bit 16 GB at 0x60_0000_0000 (resized by the
 * firmware), BAR3 (0x1c) 64-bit 32 MB, an I/O BAR (0x24), the VGA ranges.
 */
#include <stdio.h>
#include <stdint.h>
#include <errno.h>
#include "../nvidia_drm_bar1.h"

static int fails;

#define	EXPECT(c, what) do {						\
	int ok_ = (c);							\
	printf("%s %s\n", ok_ ? "PASS" : "FAIL", what);			\
	fails += !ok_;							\
} while (0)

static const int x1e_reg[] = {
	0x00010000, 0, 0, 0, 0,
	0x02010010, 0, 0, 0, 0x01000000,
	0x43010014, 0, 0, 4, 0,
	0x4301001c, 0, 0, 0, 0x02000000,
	0x01010024, 0, 0, 0, 0x80,
	(int)0xa1010000, 0, 0x3b0, 0, 0xc,
	(int)0xa1010000, 0, 0x3c0, 0, 0x20,
	(int)0xa2010000, 0, 0xa0000, 0, 0x20000,
};
static const int x1e_aa[] = {
	(int)0x82010010, 0, (int)0xb3000000, 0, 0x01000000,
	(int)0xc3010014, 0x60, 0, 4, 0,
	(int)0xc301001c, 0x64, 0, 0, 0x02000000,
	(int)0x81010024, 0, 0x3000, 0, 0x80,
	(int)0xa1010000, 0, 0x3b0, 0, 0xc,
	(int)0xa1010000, 0, 0x3c0, 0, 0x20,
	(int)0xa2010000, 0, 0xa0000, 0, 0x20000,
};

/* a 32-bit layout with "reg" in another order: the rnumber follows "reg" */
static const int r32_reg[] = {
	0x00020000, 0, 0, 0, 0,
	0x02020014, 0, 0, 0, 0x10000000,
	0x02020010, 0, 0, 0, 0x01000000,
};
static const int r32_aa[] = {
	(int)0x82020010, 0, (int)0xd0000000, 0, 0x01000000,
	(int)0x82020014, 0, (int)0xc0000000, 0, 0x10000000,
};

#define	N(a)	((uint32_t)(sizeof (a) / sizeof ((a)[0])))

int
main(void)
{
	struct nvd_bar1 b = { 0 };
	uint64_t s, p, rl, roff;
	int e;

	/* locate */
	e = nvd_bar1_locate(x1e_reg, N(x1e_reg), x1e_aa, N(x1e_aa), &b);
	EXPECT(e == 0 && b.rnumber == 2 && b.cfgoff == 0x14 &&
	    b.base == 0x6000000000ULL && b.size == 0x400000000ULL,
	    "x1e: FB = reg[2] (0x14), 16 GB at 0x6000000000");
	e = nvd_bar1_locate(r32_reg, N(r32_reg), r32_aa, N(r32_aa), &b);
	EXPECT(e == 0 && b.rnumber == 1 && b.cfgoff == 0x14 &&
	    b.base == 0xc0000000ULL && b.size == 0x10000000ULL,
	    "32-bit, reg reordered: FB = reg[1] (0x14), 256 MB at 0xc0000000");
	EXPECT(nvd_bar1_locate(x1e_reg, N(x1e_reg), x1e_aa, 5, &b) == ENXIO,
	    "only BAR0 assigned: ENXIO");
	EXPECT(nvd_bar1_locate(x1e_reg, 10, x1e_aa, N(x1e_aa), &b) == ENXIO,
	    "no reg entry for 0x14: ENXIO");
	{
		int aa0[N(x1e_aa)];
		uint32_t i;

		for (i = 0; i < N(x1e_aa); i++)
			aa0[i] = x1e_aa[i];
		aa0[6] = 0;	/* BAR1 unassigned (base 0) */
		EXPECT(nvd_bar1_locate(x1e_reg, N(x1e_reg), aa0, N(aa0), &b) ==
		    ENXIO, "FB BAR unassigned (base 0): ENXIO");
	}
	(void) nvd_bar1_locate(x1e_reg, N(x1e_reg), x1e_aa, N(x1e_aa), &b);

	/* the mmap request */
	EXPECT(nvd_vma_req(0x100000000LL, 1, &s, &p, &rl) == 0 &&
	    s == 0x100000 && p == 1 && rl == 4096,
	    "req: 1 byte at fake offset 4 GB = page 0x100000, 1 page");
	EXPECT(nvd_vma_req(0x100000000LL, 8294400, &s, &p, &rl) == 0 &&
	    p == 2025 && rl == 2025 * 4096ULL,
	    "req: 1920x1080x4 rounds to 2025 pages");
	EXPECT(nvd_vma_req(0x100000800LL, 4096, &s, &p, &rl) == EINVAL,
	    "req: unaligned offset: EINVAL");
	EXPECT(nvd_vma_req(-4096, 4096, &s, &p, &rl) == EINVAL,
	    "req: negative offset: EINVAL");
	EXPECT(nvd_vma_req(0, 0, &s, &p, &rl) == EINVAL, "req: length 0: EINVAL");
	EXPECT(nvd_vma_req(0, ~0ULL, &s, &p, &rl) == EINVAL,
	    "req: length that wraps when rounded: EINVAL");

	/* the object's range inside the FB BAR */
	EXPECT(nvd_bar1_range(&b, b.base, 2025 * 4096ULL,
	    2025 * 4096ULL, &roff) == 0 && roff == 0, "range: at the BAR start");
	EXPECT(nvd_bar1_range(&b, b.base + b.size - 4096, 4096, 4096, &roff) == 0 &&
	    roff == b.size - 4096, "range: the last page of the BAR");
	EXPECT(nvd_bar1_range(&b, b.base + b.size - 4096, 8192, 8192, &roff) ==
	    ERANGE, "range: crosses the BAR end: ERANGE");
	EXPECT(nvd_bar1_range(&b, b.base + b.size, 4096, 4096, &roff) == ERANGE,
	    "range: starts at the BAR end: ERANGE");
	EXPECT(nvd_bar1_range(&b, b.base - 4096, 4096, 4096, &roff) == ERANGE,
	    "range: below the BAR: ERANGE");
	EXPECT(nvd_bar1_range(&b, b.base, 4096, 8192, &roff) == ERANGE,
	    "range: longer than the object: ERANGE");
	EXPECT(nvd_bar1_range(&b, b.base + 0x800, 8192, 4096, &roff) == ERANGE,
	    "range: unaligned address: ERANGE");
	EXPECT(nvd_bar1_range(&b, b.base + b.size - 4096, ~0ULL & ~4095ULL,
	    0x8000000000000000ULL, &roff) == ERANGE,
	    "range: a length that would wrap: ERANGE");

	printf("%s: %d failure(s)\n", fails ? "FAIL" : "PASS", fails);
	return (fails != 0);
}
