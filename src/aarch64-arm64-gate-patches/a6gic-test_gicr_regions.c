/*
 * WHAT: host-side harness that compiles the REAL region-coalescing logic from
 * dboot_synth_fdt.c against the REAL Graviton MADT, so the algorithm is proven
 * before a multi-hour cross-build.
 *
 * WHY it is structured in two independent halves: a HARDWARE MODEL built only
 * from the MADT (which redistributors physically exist, and where each physical
 * block ends -- i.e. where GICR_TYPER_Last is set), and a WALKER that is a
 * transcription of gicthree.c:gicv3_assign_redistributors() and may consult the
 * hardware ONLY by reading TYPER at an address, exactly as ddi_get64() would.
 * The walker is never told the block layout. That separation is what makes the
 * result a prediction rather than an assumption: the same model must reproduce
 * the known-BAD old number (16, observed on metal) and the known-GOOD new one.
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
	bool		have_gicd, have_gicr, have_gicr_subtable, have_its;
} synth_gic_t;

/* ------------------------------------------------------------------ */
/* VERBATIM from dboot_synth_fdt.c -- the code under test.            */
/* ------------------------------------------------------------------ */
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
/* ---------------------- end verbatim ------------------------------ */


/* ------------------------------------------------------------------ */
/* HARDWARE MODEL. Built ONLY from the MADT: the set of addresses at   */
/* which a redistributor physically exists, and which of those are the */
/* last in their physical block. Knows nothing about the FDT.          */
/* ------------------------------------------------------------------ */
typedef struct hw_redist {
	uint64_t	addr;
	bool		last;		/* TYPER.Last set here */
	bool		vlpis;		/* TYPER.VLPIS set here */
} hw_redist_t;

static hw_redist_t hw_redist[NCPU];
static uint32_t hw_nredist;

/*
 * Build the hardware model from the sorted per-cpu bases. A redistributor is
 * the last of its physical block when the next base is not exactly one stride
 * away (or there is no next base) -- which is precisely what the 4-block MADT
 * tells us. VLPIS is inferred from the stride: a 0x20000 stride leaves no room
 * for the two extra vector frames, so those parts cannot implement VLPIS.
 */
static void
hw_build(const uint64_t *bases, uint32_t n, uint64_t stride)
{
	uint32_t i;

	hw_nredist = 0;
	for (i = 0; i < n; i++) {
		hw_redist[i].addr = bases[i];
		hw_redist[i].last = (i + 1 == n) ||
		    (bases[i + 1] - bases[i] != stride);
		hw_redist[i].vlpis = (stride >= SYNTH_GICR_FRAME * 4);
		hw_nredist++;
	}
}

/*
 * Model ddi_get64(hdl, cursor + GICR_TYPER). Returns the TYPER value if a
 * redistributor physically exists at this address. Reading MMIO where no
 * redistributor exists returns an unspecified value on real hardware; we return
 * 0 (Last clear), which is the PESSIMISTIC choice -- it lets the walk continue
 * and keep counting, so the old path cannot be made to look bad by this model.
 */
static bool hw_read_typer(uint64_t addr, uint64_t *typer)
{
	uint32_t i;

	for (i = 0; i < hw_nredist; i++) {
		if (hw_redist[i].addr == addr) {
			*typer = (hw_redist[i].last ? GICR_TYPER_Last : 0) |
			    (hw_redist[i].vlpis ? GICR_TYPER_VLPIS : 0);
			return (true);
		}
	}
	*typer = 0;
	return (false);
}

/*
 * Transcription of gicthree.c:gicv3_assign_redistributors()'s counting loop.
 * Consults the hardware only through hw_read_typer(). `phantom` counts frames
 * it counted where no redistributor actually exists -- those would be bogus
 * mappings on real hardware.
 */
static uint32_t
walk_regions(const synth_gic_t *g, uint32_t nr, uint64_t stride_prop,
    uint32_t *phantom)
{
	uint32_t num = 0, i;

	if (phantom != NULL)
		*phantom = 0;

	for (i = 0; i < nr; i++) {
		uint64_t base = g->gicr_base[i], size = g->gicr_size[i];
		uint64_t cursor = base, typer = 0, ptr;

		for (; cursor < base + size &&
		    (typer & GICR_TYPER_Last) != GICR_TYPER_Last;
		    num++) {
			if (cursor + (GICR_FRAME_SIZE * 2) > base + size)
				break;

			ptr = cursor;
			if (!hw_read_typer(cursor, &typer) && phantom != NULL)
				(*phantom)++;
			cursor += (GICR_FRAME_SIZE * 2);

			if (typer & GICR_TYPER_VLPIS) {
				cursor += (GICR_FRAME_SIZE * 2);
				if (cursor > base + size)
					break;
			}

			if (stride_prop)
				cursor = ptr + stride_prop;
		}
	}
	return (num);
}

int
main(int argc, char **argv)
{
	FILE *f;
	static unsigned char b[65536];
	size_t len_read;
	uint32_t length, off, i, nr, found, phantom;
	synth_gic_t g;

	if (argc < 2) {
		fprintf(stderr, "usage: %s <MADT.bin>\n", argv[0]);
		return (2);
	}
	f = fopen(argv[1], "rb");
	assert(f != NULL);
	len_read = fread(b, 1, sizeof (b), f);
	fclose(f);
	assert(len_read > 44);
	memcpy(&length, b + 4, 4);
	assert(length <= len_read);

	memset(&g, 0, sizeof (g));
	synth_gicr_ncpu_base = 0;

	/* Walk the MADT exactly as synth_scan_madt() does. */
	off = 44;
	while (off < length) {
		uint8_t t = b[off], l = b[off + 1];
		if (l == 0)
			break;
		if (t == 0x0b) {			/* GICC */
			uint64_t grbase;
			g.ngicc++;
			memcpy(&grbase, b + off + 60, 8);
			/*
			 * Mirror the REAL guard in synth_scan_madt(): collect
			 * per-cpu bases unless a STANDALONE GICR subtable
			 * already described the regions. Guarding on have_gicr
			 * instead (as the first version did) collects only
			 * cpu0, because the first GICC sets have_gicr -- the
			 * bug that shipped and produced distinct_gicr_base=1
			 * on real metal. The assert below pins the regression.
			 */
			if (!g.have_gicr_subtable)
				synth_gicr_insert(grbase);
			if (grbase != 0 && (g.gicr == 0 || grbase < g.gicr)) {
				g.gicr = grbase;
				g.have_gicr = true;
			}
		}
		off += l;
	}
	synth_gicr_coalesce(&g);

	/* Hardware model from the same MADT data. */
	hw_build(synth_gicr_cpu_base, synth_gicr_ncpu_base, g.gicr_stride);

	/*
	 * REGRESSION GUARD (metal-observed bug): on a box whose GICCs each
	 * carry their own GicrBaseAddress, the number of distinct collected
	 * bases must equal the cpu count. distinct==1 while ngicc>1 is the
	 * exact symptom of guarding the collection on have_gicr, which the
	 * shipped kernel did -- metal printed ngicc=40 (0x40=64) with
	 * distinct_gicr_base=1, collapsing all four regions into one cpu.
	 */
	if (g.ngicc > 1) {
		assert(synth_gicr_ncpu_base > 1);
		assert(synth_gicr_ncpu_base == g.ngicc);
	}

	nr = g.ngicr_regions;
	printf("MADT: ngicc=%u distinct_bases=%u -> regions=%u stride=0x%llx\n",
	    g.ngicc, synth_gicr_ncpu_base, nr,
	    (unsigned long long)g.gicr_stride);
	for (i = 0; i < nr; i++) {
		printf("  region[%u] base=0x%llx size=0x%llx ncpu=%llu\n", i,
		    (unsigned long long)g.gicr_base[i],
		    (unsigned long long)g.gicr_size[i],
		    (unsigned long long)(g.gicr_size[i] / g.gicr_stride));
	}
	printf("hardware model: %u redistributors, TYPER.Last set at:", hw_nredist);
	for (i = 0; i < hw_nredist; i++)
		if (hw_redist[i].last)
			printf(" 0x%llx", (unsigned long long)hw_redist[i].addr);
	printf("\n\n");

	/* reg property cell count must match #redistributor-regions. */
	printf("reg cells = %u (1 GICD + %u GICR pairs), array cap = %u\n",
	    4 * (1 + nr), nr, 4 * (1 + SYNTH_GICR_MAX_REGIONS));
	assert(4 * (1 + nr) <= 4 * (1 + SYNTH_GICR_MAX_REGIONS));

	/*
	 * OLD path: one merged region at the lowest base, sized ngicc*0x40000.
	 * Must reproduce the number observed on metal (0x10 = 16).
	 */
	{
		synth_gic_t o;
		uint32_t old_found;

		memset(&o, 0, sizeof (o));
		o.gicr_stride = g.gicr_stride;
		o.ngicr_regions = 1;
		o.gicr_base[0] = g.gicr;
		o.gicr_size[0] = (uint64_t)g.ngicc * 0x40000;
		old_found = walk_regions(&o, 1, 0, &phantom);
		printf("\nOLD single merged region base=0x%llx size=0x%llx\n",
		    (unsigned long long)o.gicr_base[0],
		    (unsigned long long)o.gicr_size[0]);
		printf("OLD walker finds %u (metal observed 0x10 = 16) -> %s\n",
		    old_found, old_found == 16 ? "REPRODUCED" : "MISMATCH");
		assert(old_found == 16);
	}

	/* NEW path: N regions. Must reach >= max_ncpus with no phantoms. */
	found = walk_regions(&g, nr, 0, &phantom);
	printf("\nNEW %u-region walker finds %u redistributors "
	    "(phantom frames=%u)\n", nr, found, phantom);
	printf("VERIFY3U(%u >= max_ncpus 64) -> %s\n", found,
	    found >= 64 ? "PASS" : "FAIL");
	assert(found == g.ngicc);
	assert(found >= 64);
	assert(phantom == 0);

	/*
	 * The new path must reach 64 *because* Last terminates each region
	 * after its 16, not by ignoring Last. Show it explicitly: every region
	 * ends on a Last-setting redistributor, and each contributes 16.
	 */
	printf("\nper-region walk (Last must fire at each region's end):\n");
	for (i = 0; i < nr; i++) {
		synth_gic_t one;
		uint32_t n_one;

		memset(&one, 0, sizeof (one));
		one.gicr_stride = g.gicr_stride;
		one.ngicr_regions = 1;
		one.gicr_base[0] = g.gicr_base[i];
		one.gicr_size[0] = g.gicr_size[i];
		n_one = walk_regions(&one, 1, 0, &phantom);
		printf("  region[%u] -> %u redistributors, phantom=%u, "
		    "last addr=0x%llx Last=%d\n", i, n_one, phantom,
		    (unsigned long long)(g.gicr_base[i] + g.gicr_size[i] -
		    g.gicr_stride),
		    (int)hw_redist[(i + 1) * n_one - 1].last);
		assert(n_one == 16);
		assert(phantom == 0);
		assert(hw_redist[(i + 1) * n_one - 1].last);
	}

	/*
	 * Sanity: if Last were ignored, region end alone would still cap each
	 * region at 16 (size/stride), so the total is 64 either way -- the new
	 * geometry is correct under both models, which is the point.
	 */
	printf("\nboth-models check: region size alone caps each region at "
	    "%llu, so total=%llu regardless of Last\n",
	    (unsigned long long)(g.gicr_size[0] / g.gicr_stride),
	    (unsigned long long)(nr * (g.gicr_size[0] / g.gicr_stride)));

	/* Degenerate maps must not divide by zero or over-run. */
	{
		synth_gic_t s;

		memset(&s, 0, sizeof (s));
		synth_gicr_ncpu_base = 0;
		synth_gicr_insert(0x1000000);		/* single cpu */
		synth_gicr_coalesce(&s);
		assert(s.ngicr_regions == 1);
		assert(s.gicr_stride == 0x20000);
		printf("\nsingle-cpu: regions=%u stride=0x%llx size=0x%llx OK\n",
		    s.ngicr_regions, (unsigned long long)s.gicr_stride,
		    (unsigned long long)s.gicr_size[0]);

		memset(&s, 0, sizeof (s));
		synth_gicr_ncpu_base = 0;
		synth_gicr_coalesce(&s);		/* no bases at all */
		assert(s.ngicr_regions == 0);
		printf("no-bases: regions=0 OK (emitter falls back)\n");
	}

	printf("\nALL CHECKS PASSED "
	    "(old path reproduces metal's 16; new path yields 64)\n");
	return (0);
}
