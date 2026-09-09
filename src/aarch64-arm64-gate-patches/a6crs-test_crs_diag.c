/*
 * WHAT: host harness for the [A6CRS] raw-UART emit block added to
 * dboot_synth_fdt.c's dboot_synth_fdt().  It proves the block renders the
 * _CRS verdict correctly BEFORE a multi-hour cross-build and a $2.18/hr metal
 * boot are spent reading it.
 *
 * WHY it exists at all: the value this block prints -- crs_nwin -- is the one
 * that decides whether the emitted pcie "ranges" came from the firmware's _CRS
 * or from the hardcoded QEMU-virt fallback.  A measured c6g.metal boot showed
 * that the pre-existing dboot_printf() verdict line NEVER reaches the console on
 * real SBBR/Graviton (zero "dboot:" lines in four separate metal captures) while
 * synth_gicr_diag()'s raw synth_uart_puts() [A6GIC] lines do.  So the answer was
 * structurally unreadable and the block below is the fix.  A formatting bug here
 * would waste another metal boot, hence this check.
 *
 * WHAT IS REAL vs MODELLED:
 *   REAL (verbatim from dboot_synth_fdt.c): synth_uart_puts, synth_uart_puthex,
 *        the emit block itself, synth_crs_t/synth_win_t, PCI_SPACE_* values.
 *   MODELLED: synth_uart_putc -- the raw MMIO store.  On the target it spins on
 *        UARTFR TXFF (dr[6]) then stores the byte to *dr; there is no way to
 *        observe a plain array store from C, so the harness records the byte
 *        instead.  The TXFF spin is timing, not rendering, and is out of scope.
 *
 * Build/run:  gcc -Wall -Wextra -O2 -o /tmp/a6crs a6crs-test_crs_diag.c && /tmp/a6crs
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <assert.h>

/* From sys/pci.h, as used by the ranges emit. */
#define	PCI_SPACE_IO		0x01000000
#define	PCI_SPACE_MEM32		0x02000000
#define	PCI_SPACE_MEM64		0x03000000

#define	SYNTH_FDT_MAX		16384

/* ---- REAL: types, verbatim from dboot_synth_fdt.c ---------------------- */
typedef struct synth_win {
	uint32_t	space;
	uint64_t	child;
	uint64_t	parent;
	uint64_t	size;
} synth_win_t;

typedef struct synth_crs {
	synth_win_t	win[8];
	int		nwin;
	bool		have;
} synth_crs_t;

/* ---- MODELLED: the MMIO store becomes a capture buffer ----------------- */
static char	cap[4096];
static size_t	caplen;

static void
synth_uart_putc(volatile uint32_t *dr, char c)
{
	(void) dr;
	if (caplen + 1 < sizeof (cap))
		cap[caplen++] = c;
	cap[caplen] = '\0';
}

/* ---- REAL: verbatim from dboot_synth_fdt.c ----------------------------- */
static void
synth_uart_puts(volatile uint32_t *dr, const char *s)
{
	while (*s != '\0') {
		if (*s == '\n')
			synth_uart_putc(dr, '\r');
		synth_uart_putc(dr, *s++);
	}
}

static void
synth_uart_puthex(volatile uint32_t *dr, uint64_t v)
{
	static const char hex[] = "0123456789abcdef";
	char buf[17];
	int i = 0, started = 0, sh;

	for (sh = 60; sh >= 0; sh -= 4) {
		unsigned nyb = (unsigned)((v >> sh) & 0xf);
		if (nyb != 0 || started || sh == 0) {
			buf[i++] = hex[nyb];
			started = 1;
		}
	}
	buf[i] = '\0';
	synth_uart_puts(dr, buf);
}

/*
 * ---- REAL: the emit block, transcribed from dboot_synth_fdt() ----------
 * `sabotage` exists only to give the assertions a negative control: it swaps
 * child for parent, the single most plausible transcription error and the one
 * that would silently mislead the next metal boot.
 */
static void
emit_a6crs(volatile uint32_t *dr, const synth_crs_t *crs, int necam,
    uint64_t ecam0, bool qemu, uint32_t fdt_used, int sabotage)
{
	int w;

	synth_uart_puts(dr, "[A6CRS] crs_nwin=0x");
	synth_uart_puthex(dr, (uint64_t)(uint32_t)crs->nwin);
	synth_uart_puts(dr, " crs_have=0x");
	synth_uart_puthex(dr, crs->have ? 1 : 0);
	synth_uart_puts(dr, " necam=0x");
	synth_uart_puthex(dr, (uint64_t)(uint32_t)necam);
	synth_uart_puts(dr, " ecam0=0x");
	synth_uart_puthex(dr, necam > 0 ? ecam0 : 0);
	synth_uart_puts(dr, " qemu=0x");
	synth_uart_puthex(dr, qemu ? 1 : 0);
	synth_uart_puts(dr, " fdt_used=0x");
	synth_uart_puthex(dr, (uint64_t)fdt_used);
	synth_uart_puts(dr, " fdt_max=0x");
	synth_uart_puthex(dr, (uint64_t)SYNTH_FDT_MAX);
	synth_uart_puts(dr, "\n");

	for (w = 0; w < crs->nwin; w++) {
		synth_uart_puts(dr, "[A6CRS] win[");
		synth_uart_puthex(dr, (uint64_t)(uint32_t)w);
		synth_uart_puts(dr, "] space=0x");
		synth_uart_puthex(dr, crs->win[w].space);
		synth_uart_puts(dr, " child=0x");
		synth_uart_puthex(dr, sabotage ? crs->win[w].parent :
		    crs->win[w].child);
		synth_uart_puts(dr, " parent=0x");
		synth_uart_puthex(dr, crs->win[w].parent);
		synth_uart_puts(dr, " size=0x");
		synth_uart_puthex(dr, crs->win[w].size);
		synth_uart_puts(dr, "\n");
	}
}

/* ------------------------------------------------------------------------ */
static const char *
run(const synth_crs_t *crs, int necam, uint64_t ecam0, bool qemu,
    uint32_t used, int sabotage)
{
	uint32_t fakereg[8];

	memset(fakereg, 0, sizeof (fakereg));
	caplen = 0;
	cap[0] = '\0';
	emit_a6crs(fakereg, crs, necam, ecam0, qemu, used, sabotage);
	return (cap);
}

/* Strip the \r that puts() injects, so expectations stay readable. */
static const char *
nocr(const char *s)
{
	static char b[4096];
	size_t i, j = 0;

	for (i = 0; s[i] != '\0' && j + 1 < sizeof (b); i++)
		if (s[i] != '\r')
			b[j++] = s[i];
	b[j] = '\0';
	return (b);
}

int
main(void)
{
	synth_crs_t crs;
	const char *out;
	int fails = 0;

	/*
	 * CASE 1 -- the case the metal boot is being run to detect: no _CRS
	 * windows found, so dboot_synth_fdt() substitutes the QEMU-virt
	 * constants.  ecam0/necam are the REAL measured c6g.metal MCFG values
	 * (0xc000000000, 1 allocation) from
	 * src/aarch64-arm64-gate-patches/a6pcie-c6gmetal-firmware-tables.txt.
	 * The absence of win[] lines is the signal; assert it explicitly.
	 */
	memset(&crs, 0, sizeof (crs));
	out = nocr(run(&crs, 1, 0xc000000000ULL, false, 9125, 0));
	printf("CASE1 (metal, _CRS empty):\n%s", out);
	if (strcmp(out, "[A6CRS] crs_nwin=0x0 crs_have=0x0 necam=0x1 "
	    "ecam0=0xc000000000 qemu=0x0 fdt_used=0x23a5 fdt_max=0x4000\n")
	    != 0) {
		printf("  FAIL: case 1 rendering\n");
		fails++;
	}
	if (strstr(out, "win[") != NULL) {
		printf("  FAIL: win[] lines emitted for nwin==0\n");
		fails++;
	}

	/*
	 * CASE 2 -- _CRS parsed.  Values are the REAL measured c6g.metal
	 * windows (same capture): MEM32 0x80000000 sz 0x20000000, MEM64
	 * 0x18000000000 sz 0x2000000000, and NO IO window -- metal has none,
	 * which is why only two windows appear.  This is the shape that would
	 * REFUTE the fallback hypothesis if metal prints it.
	 */
	memset(&crs, 0, sizeof (crs));
	crs.have = true;
	crs.nwin = 2;
	crs.win[0].space = PCI_SPACE_MEM32;
	crs.win[0].child = crs.win[0].parent = 0x80000000ULL;
	crs.win[0].size = 0x20000000ULL;
	crs.win[1].space = PCI_SPACE_MEM64;
	crs.win[1].child = crs.win[1].parent = 0x18000000000ULL;
	crs.win[1].size = 0x2000000000ULL;
	out = nocr(run(&crs, 1, 0xc000000000ULL, false, 9125, 0));
	printf("CASE2 (metal, _CRS parsed):\n%s", out);
	if (strstr(out, "crs_nwin=0x2 crs_have=0x1") == NULL ||
	    strstr(out, "win[0] space=0x2000000 child=0x80000000 "
	    "parent=0x80000000 size=0x20000000") == NULL ||
	    strstr(out, "win[1] space=0x3000000 child=0x18000000000 "
	    "parent=0x18000000000 size=0x2000000000") == NULL) {
		printf("  FAIL: case 2 rendering\n");
		fails++;
	}

	/*
	 * CASE 3 -- QEMU, 3 windows with a NON-IDENTITY IO translation
	 * (child 0 -> parent 0x3eff0000).  child != parent is the only case
	 * that can tell a child/parent mix-up apart, so it is also what the
	 * negative control below leans on.
	 */
	memset(&crs, 0, sizeof (crs));
	crs.have = true;
	crs.nwin = 3;
	crs.win[0].space = PCI_SPACE_IO;
	crs.win[0].child = 0;
	crs.win[0].parent = 0x3eff0000ULL;
	crs.win[0].size = 0x10000ULL;
	crs.win[1].space = PCI_SPACE_MEM32;
	crs.win[1].child = crs.win[1].parent = 0x10000000ULL;
	crs.win[1].size = 0x2eff0000ULL;
	crs.win[2].space = PCI_SPACE_MEM64;
	crs.win[2].child = crs.win[2].parent = 0x8000000000ULL;
	crs.win[2].size = 0x8000000000ULL;
	out = nocr(run(&crs, 1, 0x4010000000ULL, true, 6166, 0));
	printf("CASE3 (qemu, 3 wins):\n%s", out);
	if (strstr(out, "crs_nwin=0x3 crs_have=0x1") == NULL ||
	    strstr(out, "qemu=0x1") == NULL ||
	    strstr(out, "win[0] space=0x1000000 child=0x0 "
	    "parent=0x3eff0000 size=0x10000") == NULL) {
		printf("  FAIL: case 3 rendering\n");
		fails++;
	}

	/* CASE 4 -- the 8-window boundary must render all 8 and not overrun. */
	memset(&crs, 0, sizeof (crs));
	crs.have = true;
	crs.nwin = 8;
	for (int i = 0; i < 8; i++) {
		crs.win[i].space = PCI_SPACE_MEM64;
		crs.win[i].child = crs.win[i].parent =
		    0x18000000000ULL + (uint64_t)i * 0x100000ULL;
		crs.win[i].size = 0x100000ULL;
	}
	out = nocr(run(&crs, 1, 0xc000000000ULL, false, 9125, 0));
	if (strstr(out, "win[7]") == NULL || strstr(out, "win[8]") != NULL) {
		printf("  FAIL: case 4 boundary\n");
		fails++;
	} else {
		printf("CASE4 (8-window boundary): win[0]..win[7], no win[8] "
		    "-- OK\n");
	}

	/*
	 * NEGATIVE CONTROL -- sabotage child/parent and confirm the CASE3
	 * assertion FLIPS to failing.  A check that cannot fail proves nothing.
	 */
	memset(&crs, 0, sizeof (crs));
	crs.have = true;
	crs.nwin = 1;
	crs.win[0].space = PCI_SPACE_IO;
	crs.win[0].child = 0;
	crs.win[0].parent = 0x3eff0000ULL;
	crs.win[0].size = 0x10000ULL;
	out = nocr(run(&crs, 1, 0x4010000000ULL, true, 6166, 1));
	if (strstr(out, "child=0x0 parent=0x3eff0000") == NULL) {
		printf("NEGATIVE CONTROL: sabotage detected (got '%s') -- "
		    "controls PASS\n", out);
	} else {
		printf("NEGATIVE CONTROL: FAILED TO DETECT SABOTAGE -- the "
		    "assertions are vacuous\n");
		fails++;
	}

	printf("%s\n", fails == 0 ? "ALL CHECKS PASS" : "CHECKS FAILED");
	return (fails != 0);
}
