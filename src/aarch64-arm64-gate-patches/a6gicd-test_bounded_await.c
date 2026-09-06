/*
 * Host harness for the bounded GIC flag poll (a6-gicd-bounded-await).
 *
 * WHAT: exercises reg_await_clear4_site()'s control flow against a fake MMIO
 * register, with the same cap/report logic as gicthree.c.
 *
 * WHY: the bug being fixed is a HANG, and a hang cannot be observed by the
 * usual means -- the machine simply stops.  So the property that matters is
 * "this function always returns", and that must be proven somewhere it can be
 * proven at all, i.e. off the target.  This also pins the two behaviours the
 * metal run depends on: a flag that clears late must NOT report, and a flag
 * that never clears MUST report exactly once per site and then return.
 *
 * Build: cc -std=gnu99 -Wall -o /tmp/t a6gicd-test_bounded_await.c && /tmp/t
 */

#include <assert.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

/* Small cap so the "never clears" case is cheap to run here. */
#define	GICV3_AWAIT_MAX		1000u
#define	GICV3_AWAIT_REPORT_MAX	8

static uint32_t gicv3_await_timeouts = 0;

/* Fake MMIO: clears the masked bits after `clear_after` reads, or never. */
static uint32_t fake_reads;
static uint32_t fake_clear_after;
static uint32_t fake_value;

static uint32_t
ddi_get32_fake(void)
{
	if (++fake_reads >= fake_clear_after)
		return (fake_value & ~0x80000000u);
	return (fake_value);
}

static int reports;
static char last_report[256];

static void
prom_printf_fake(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	(void) vsnprintf(last_report, sizeof (last_report), fmt, ap);
	va_end(ap);
	reports++;
}

/* Transcription of gicthree.c:reg_await_clear4_site(). */
static uint32_t
reg_await_clear4_site(uint32_t mask, const char *site)
{
	uint32_t val = 0;
	uint32_t n;

	for (n = 0; n < GICV3_AWAIT_MAX; n++) {
		val = ddi_get32_fake();
		if ((val & mask) == 0)
			return (n);
	}

	if (++gicv3_await_timeouts <= GICV3_AWAIT_REPORT_MAX) {
		prom_printf_fake("[A6GICD:await-timeout site=%s mask=0x%x "
		    "val=0x%x]\n", site, mask, val);
	}
	return (n);
}

static void
reset(uint32_t clear_after)
{
	fake_reads = 0;
	fake_clear_after = clear_after;
	fake_value = 0x80000000u;	/* RWP set */
	reports = 0;
	gicv3_await_timeouts = 0;
	last_report[0] = '\0';
}

int
main(void)
{
	uint32_t iters;

	/* 1. Flag already clear: returns immediately, says nothing. */
	reset(1);
	iters = reg_await_clear4_site(0x80000000u, "gicd_drain_writes");
	assert(iters == 0);
	assert(reports == 0);

	/* 2. Flag clears late but within the cap: no report. This is the
	 * case a too-tight bound would wrongly flag on slow hardware. */
	reset(GICV3_AWAIT_MAX - 1);
	iters = reg_await_clear4_site(0x80000000u, "gicd_drain_writes");
	assert(iters < GICV3_AWAIT_MAX);
	assert(reports == 0);

	/* 3. Flag never clears: MUST return (the whole point) and MUST name
	 * the site. The old code looped here forever. */
	reset(0xFFFFFFFFu);
	iters = reg_await_clear4_site(0x80000000u, "gicv3_awaken_cpu");
	assert(iters == GICV3_AWAIT_MAX);
	assert(reports == 1);
	assert(strstr(last_report, "gicv3_awaken_cpu") != NULL);
	assert(strstr(last_report, "await-timeout") != NULL);

	/* 4. Report cap holds: 64 stuck redistributors must not emit 64
	 * lines onto a slow console, but every call still returns. */
	reset(0xFFFFFFFFu);
	for (int i = 0; i < 64; i++) {
		fake_reads = 0;
		iters = reg_await_clear4_site(0x80000000u, "gicr_drain_writes");
		assert(iters == GICV3_AWAIT_MAX);
	}
	assert(reports == GICV3_AWAIT_REPORT_MAX);
	assert(gicv3_await_timeouts == 64);

	/* 5. A different mask on the same register is independent: a stuck
	 * RWP must not mask a healthy ChildrenAsleep. */
	reset(0xFFFFFFFFu);
	iters = reg_await_clear4_site(0x00000004u, "gicv3_awaken_cpu");
	assert(iters == 0);		/* bit 2 is clear in 0x80000000 */
	assert(reports == 0);

	printf("ALL CHECKS PASSED (bounded await always returns; "
	    "stuck flag reports its site; report cap holds)\n");
	return (0);
}
