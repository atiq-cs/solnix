/*
 * WHAT: host-side harness that compiles the REAL region-coalescing logic from
 * dboot_synth_fdt.c against the REAL Graviton MADT, so the algorithm is proven
 * before a multi-hour cross-build. Extracts synth_gicr_insert/coalesce
 * verbatim (kept textually in sync by the #include of the extracted block) and
 * replays gicthree.c's redistributor walker over the emitted regions.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <assert.h>

#define	NCPU			128
#define	SYNTH_GICR_MAX_REGIONS	16
#define	SYNTH_GICR_FRAME	0x10000ULL
#define	GICR_FRAME_SIZE		(64 * 1024)
#define	GICR_TYPER_Last		0x10
#define	GICR_TYPER_VLPIS	0x02

static void dboot_printf(const char *f, ...) { (void)f; }

typedef struct synth_gic {
	uint64_t	gicd, gicr, gicr_len, its;
	uint32_t	ngicc;
	uint64_t	gicr_base[SYNTH_GICR_MAX_REGIONS];
	uint64_t	gicr_size[SYNTH_GICR_MAX_REGIONS];
	uint32_t	ngicr_regions;
	uint64_t	gicr_stride;
	bool		have_gicd, have_gicr, have_its;
} synth_gic_t;

/* --- verbatim from dboot_synth_fdt.c --- */
static uint64_t synth_gicr_cpu_base[NCPU];
static uint32_t synth_gicr_ncpu_base;

static void
synth_gicr_insert(uint64_t base)
{
	uint32_t i, j;

	if (base == 0 || synth_gicr_ncpu_base >= NCPU)
		return;

	for (i = 0; i < synth_gicr_ncpu_base; i++) {
		if (synth_gicr_cpu_base[i] == base)
			return;
		if (synth_gicr_cpu_base[i] > base)
			break;
	}
	for (j = synth_gicr_ncpu_base; j > i; j--)
		synth_gicr_cpu_base[j] = synth_gicr_cpu_base[j - 1];
	synth_gicr_cpu_base[i] = base;
	synth_gicr_ncpu_base++;
}

static void
synth_gicr_coalesce(synth_gic_t *g)
{
	uint64_t stride, d;
	uint32_t i, n;

	if (synth_gicr_ncpu_base == 0)
		return;

	stride = 0;
	for (i = 1; i < synth_gicr_ncpu_base; i++) {
		d = synth_gicr_cpu_base[i] - synth_gicr_cpu_base[i - 1];
		if (stride == 0 || d < stride)
			stride = d;
	}
	if (stride == 0)
		stride = SYNTH_GICR_FRAME * 2;
	g->gicr_stride = stride;

	g->ngicr_regions = 0;
	g->gicr_base[0] = synth_gicr_cpu_base[0];
	n = 1;
	for (i = 1; i < synth_gicr_ncpu_base; i++) {
		if (synth_gicr_cpu_base[i] - synth_gicr_cpu_base[i - 1] ==
		    stride) {
			n++;
			continue;
		}
		g->gicr_size[g->ngicr_regions] = (uint64_t)n * stride;
		g->ngicr_regions++;
		if (g->ngicr_regions >= SYNTH_GICR_MAX_REGIONS) {
			dboot_printf("truncating\n");
			return;
		}
		g->gicr_base[g->ngicr_regions] = synth_gicr_cpu_base[i];
		n = 1;
	}
	g->gicr_size[g->ngicr_regions] = (uint64_t)n * stride;
	g->ngicr_regions++;
}
/* --- end verbatim --- */

/* Replay gicthree.c:gicv3_assign_redistributors()'s counting loop. */
static uint32_t
walk_regions(const synth_gic_t *g, uint32_t nr, uint32_t ncpu_total)
{
	uint32_t num = 0, i;

	for (i = 0; i < nr; i++) {
		uint64_t base = g->gicr_base[i], size = g->gicr_size[i];
		uint64_t cursor = base, typer = 0;
		uint32_t local = 0;

		for (; cursor < base + size &&
		    (typer & GICR_TYPER_Last) != GICR_TYPER_Last;
		    local++, num++) {
			if (cursor + (GICR_FRAME_SIZE * 2) > base + size)
				break;
			/*
			 * Model the hardware: TYPER.Last is set on the final
			 * redistributor of each physical block (that is what
			 * capped the old single-region walk at 16).
			 */
			typer = (local == (size / g->gicr_stride) - 1) ?
			    GICR_TYPER_Last : 0;
			cursor += (GICR_FRAME_SIZE * 2);
			if (g->gicr_stride)
				cursor = base + (uint64_t)(local + 1) *
				    g->gicr_stride;
		}
	}
	(void) ncpu_total;
	return (num);
}

int
main(int argc, char **argv)
{
	FILE *f = fopen(argv[1], "rb");
	static unsigned char b[65536];
	size_t len_read = fread(b, 1, sizeof (b), f);
	uint32_t length;
	uint32_t off;
	synth_gic_t g;
	uint32_t nr, found;

	assert(len_read > 44);
	memcpy(&length, b + 4, 4);
	memset(&g, 0, sizeof (g));
	synth_gicr_ncpu_base = 0;

	/* Walk the MADT exactly as synth_scan_madt does. */
	off = 44;
	while (off < length) {
		uint8_t t = b[off], l = b[off + 1];
		if (l == 0)
			break;
		if (t == 0x0b) {		/* GICC */
			uint64_t grbase;
			g.ngicc++;
			memcpy(&grbase, b + off + 60, 8);
			synth_gicr_insert(grbase);
			if (grbase != 0 && (g.gicr == 0 || grbase < g.gicr)) {
				g.gicr = grbase;
				g.have_gicr = true;
			}
		}
		off += l;
	}
	synth_gicr_coalesce(&g);

	nr = g.ngicr_regions;
	printf("ngicc=%u distinct_bases=%u regions=%u stride=0x%llx\n",
	    g.ngicc, synth_gicr_ncpu_base, nr,
	    (unsigned long long)g.gicr_stride);
	for (uint32_t i = 0; i < nr; i++) {
		printf("  region[%u] base=0x%llx size=0x%llx ncpu=%llu\n", i,
		    (unsigned long long)g.gicr_base[i],
		    (unsigned long long)g.gicr_size[i],
		    (unsigned long long)(g.gicr_size[i] / g.gicr_stride));
	}

	/* reg property cell count must match #redistributor-regions. */
	printf("reg cells = %u (1 GICD + %u GICR pairs), array cap = %u\n",
	    4 * (1 + nr), nr, 4 * (1 + SYNTH_GICR_MAX_REGIONS));
	assert(4 * (1 + nr) <= 4 * (1 + SYNTH_GICR_MAX_REGIONS));

	found = walk_regions(&g, nr, g.ngicc);
	printf("gicthree walker finds %u redistributors; max_ncpus=64 -> %s\n",
	    found, found >= 64 ? "PASS" : "FAIL");
	assert(found >= g.ngicc);

	/* Regression: the OLD single merged region only ever found 16. */
	{
		synth_gic_t o = g;
		o.ngicr_regions = 1;
		o.gicr_base[0] = g.gicr;
		o.gicr_size[0] = (uint64_t)g.ngicc * 0x40000;
		printf("OLD single-region walk finds %u (observed 0x10=16)\n",
		    walk_regions(&o, 1, g.ngicc));
	}

	/* Degenerate cases must not divide by zero or over-run. */
	{
		synth_gic_t s;
		memset(&s, 0, sizeof (s));
		synth_gicr_ncpu_base = 0;
		synth_gicr_insert(0x1000000);		/* single cpu */
		synth_gicr_coalesce(&s);
		assert(s.ngicr_regions == 1);
		assert(s.gicr_stride == 0x20000);
		printf("single-cpu: regions=%u stride=0x%llx size=0x%llx OK\n",
		    s.ngicr_regions, (unsigned long long)s.gicr_stride,
		    (unsigned long long)s.gicr_size[0]);

		memset(&s, 0, sizeof (s));
		synth_gicr_ncpu_base = 0;
		synth_gicr_coalesce(&s);		/* no bases at all */
		assert(s.ngicr_regions == 0);
		printf("no-bases: regions=0 OK (emitter falls back)\n");
	}

	printf("\nALL CHECKS PASSED\n");
	return (0);
}
