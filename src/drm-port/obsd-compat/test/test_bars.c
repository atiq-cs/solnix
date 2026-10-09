/*
 * test_bars.c -- obsd_bars_parse (obsd_bus.c) on the iGPU's real "reg" and
 * "assigned-addresses" properties, read on dixi with
 *   pfexec prtconf -v /devices/pci@0,0/display@2
 * (copy in dixi:/home/gburd/streamE4/prtconf-igpu.txt). Expected values are
 * the BARs docs/x1-gpu-route.md section 1 lists: BAR0 GTTMMADR
 * 0x60_4a000000 16 MB (reg index 1), BAR2 GMADR 0x40_00000000 512 MB
 * prefetchable (reg index 2). The I/O BAR (0x20) is listed too.
 * -DBARS_SABOTAGE swaps two assigned-addresses entries' phys.hi words, so
 * the match by config offset must then FAIL the checks.
 */
#define OBSD_USERTEST
#include "../obsd_bus.c"
#include <stdio.h>

static const uint32_t reg[] = {
	0x00001000, 0, 0, 0, 0,
	0x03001010, 0, 0, 0, 0x01000000,
	0x43001018, 0, 0, 0, 0x20000000,
	0x01001020, 0, 0, 0, 0x00000040,
	0xa1001000, 0, 0x000003b0, 0, 0x0000000c,
	0xa1001000, 0, 0x000003c0, 0, 0x00000020,
	0xa2001000, 0, 0x000a0000, 0, 0x00020000,
};
static uint32_t aa[] = {
	0x83001010, 0x00000060, 0x4a000000, 0, 0x01000000,
	0xc3001018, 0x00000040, 0x00000000, 0, 0x20000000,
	0x81001020, 0, 0x00003000, 0, 0x00000040,
	0xa1001000, 0, 0x000003b0, 0, 0x0000000c,
	0xa1001000, 0, 0x000003c0, 0, 0x00000020,
	0xa2001000, 0, 0x000a0000, 0, 0x00020000,
};

static int fails;
/* evaluates c exactly once (it may allocate) */
#define CHECK(c, what) do { int _ok = (c); \
	printf("%s %s\n", _ok ? "PASS" : "FAIL", what); \
	if (!_ok) fails++; } while (0)

int
main(void)
{
	struct obsd_bar b[OBSD_NBAR];
	int n;

#ifdef BARS_SABOTAGE
	uint32_t t = aa[0]; aa[0] = aa[10]; aa[10] = t;	/* BAR0 <-> I/O phys.hi */
#endif
	n = obsd_bars_parse((const pci_regspec_t *)reg,
	    sizeof (reg) / sizeof (pci_regspec_t), (const pci_regspec_t *)aa,
	    sizeof (aa) / sizeof (pci_regspec_t), b, OBSD_NBAR);
	CHECK(n == 3, "3 BARs (0x10, 0x18, 0x20); VGA legacy ranges skipped");
	CHECK(n > 0 && b[0].cfgoff == 0x10 && b[0].rnumber == 1 &&
	    b[0].base == 0x604a000000ULL && b[0].size == 0x1000000 &&
	    !b[0].prefetch, "BAR0 GTTMMADR 0x604a000000 16M reg[1] non-prefetch");
	CHECK(n > 1 && b[1].cfgoff == 0x18 && b[1].rnumber == 2 &&
	    b[1].base == 0x4000000000ULL && b[1].size == 0x20000000 &&
	    b[1].prefetch, "BAR2 GMADR 0x4000000000 512M reg[2] prefetchable");
	CHECK(n > 2 && b[2].cfgoff == 0x20 && b[2].rnumber == 3 &&
	    b[2].space == PCI_ADDR_IO && b[2].base == 0x3000 &&
	    b[2].size == 0x40, "BAR4 I/O 0x3000+0x40 reg[3]");
	printf("%s: %d failure(s)\n", fails ? "FAIL" : "PASS", fails);
	return (fails != 0);
}
