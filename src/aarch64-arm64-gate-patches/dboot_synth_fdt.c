/*
 * This file and its contents are supplied under the terms of the
 * Common Development and Distribution License ("CDDL"), version 1.0.
 * You may only use this file in accordance with the terms of version
 * 1.0 of the CDDL.
 *
 * A full copy of the text of the CDDL should have accompanied this
 * source.  A copy of the CDDL is also available via the Internet at
 * http://www.illumos.org/license/CDDL.
 */

/*
 * Synthesise a minimal flattened devicetree from the static ACPI tables
 * (MADT/SPCR/MCFG) plus the PCIe host-bridge _CRS in the DSDT, so that
 * the kernel's FDT-fed prom_emul and the standard prom->devinfo
 * enumeration work unchanged on ACPI (SBBR/Graviton) platforms.
 *
 * This is deliberately the minimal node set the aarch64 port binds:
 * the GICv3 distributor/redistributor (+ITS), the architected timer,
 * the console UART and the PCIe ECAM root complex(es), plus /cpus,
 * /psci and /memory scaffolding.  It is not a general ACPI namespace
 * interpreter -- it feeds the existing FDT machinery from the handful
 * of static tables the port already reads.
 */

#include <sys/types.h>
#include <sys/systm.h>
#include <sys/null.h>
#include <sys/bootinfo.h>
#include <sys/stdbool.h>
#include <sys/psci.h>
#include <sys/acpi/platform/acsolaris.h>
#include <sys/acpi/actypes.h>
#include <sys/acpi/actbl.h>
#include <sys/acpi/actbl1.h>
#include <sys/acpi/actbl2.h>
#include <sys/acpi/actbl3.h>
#include <sys/cpuinfo.h>
#include <sys/controlregs.h>
#include <sys/machparam.h>

#include <libfdt.h>

#include "dboot.h"
#include "dboot_printf.h"

/*
 * Phandles used within the synthesised FDT.  The GIC must have a stable
 * phandle since it is the interrupt-parent for the whole tree and the
 * msi-parent for PCIe.
 */
#define	SYNTH_PHANDLE_GIC	1u
#define	SYNTH_PHANDLE_ITS	2u

/*
 * prom_emul (prom_emul_fdt.c) uses the FDT `phandle` property as the node
 * identity: get_phandle() VERIFYs a `phandle` prop exists on every node it
 * walks (root, each child, each sibling, each parent).  Real DTs assign these;
 * we must too, one unique value per node.  Reserve 1/2 for the GIC/ITS (which
 * other nodes reference as interrupt/msi parent) and hand out the rest from a
 * counter starting past them.
 */
#define	SYNTH_PHANDLE_FIRST	3u
static uint32_t synth_next_phandle;

static uint32_t
synth_alloc_phandle(void)
{
	return (synth_next_phandle++);
}

/* Emit a unique `phandle` on the node currently being built. */
static void
synth_emit_phandle(void *fdt)
{
	(void) fdt_property_cell(fdt, "phandle", synth_alloc_phandle());
}

/*
 * GIC v3 interrupt encoding (3 cells): <type nr flags>.
 *   type: 0 = SPI, 1 = PPI
 *   flags: 4 = level-high, 1 = edge-rising
 * These mirror the QEMU virt / SBBR PPI assignments for the architected
 * timer, which are fixed by the architecture.
 */
#define	GIC_SPI			0
#define	GIC_PPI			1
#define	IRQ_LEVEL_HI		4
#define	IRQ_EDGE_RISING		1

/* Architected timer PPIs (INTIDs 16..31 -> PPI index 13,14,11,10). */
#define	TMR_PPI_SEC		13	/* secure EL1 physical */
#define	TMR_PPI_NONSEC		14	/* non-secure EL1 physical */
#define	TMR_PPI_VIRT		11	/* virtual */
#define	TMR_PPI_HYP		10	/* EL2 physical */

/*
 * PCIe outbound address windows.  MCFG only describes the config-space
 * (ECAM) base; the IO / MMIO32 / MMIO64 windows that the pcierc driver
 * requires as the `ranges` property live in the PCIe host-bridge _CRS in
 * the DSDT.  synth_scan_crs() below extracts them directly from the DSDT
 * AML resource descriptors (no full AML interpreter needed -- the root
 * bridge's _CRS resource template is a fixed byte sequence of large
 * address-space descriptors).  If that fails we fall back to the QEMU
 * virt fixed windows so a QEMU-EDK2 boot without a parseable _CRS still
 * works.
 *
 * child-address encoding (DT PCI binding): high cell = space+flags
 *   0x01000000 = IO, 0x02000000 = MEM32, 0x03000000 = MEM64.
 */
#define	PCI_SPACE_IO		0x01000000u
#define	PCI_SPACE_MEM32		0x02000000u
#define	PCI_SPACE_MEM64		0x03000000u

/*
 * The synthesised blob.  Placed in dboot's static data so that it
 * survives the handoff to the kernel (which relocates it via
 * fdt_open_into in bop_relocate).  16KiB is comfortably larger than the
 * node set we emit.
 */
#define	SYNTH_FDT_MAX	16384
static uint8_t synth_fdt[SYNTH_FDT_MAX] __aligned(8);

extern const void *dboot_uefi_get_acpi_rsdp(void);

/*
 * dboot has no snprintf; build "<prefix>@<hex>" node names by hand.
 * buf must be large enough (prefix + 16 hex digits + NUL).
 */
static void
synth_nodename(char *buf, size_t bufsz, const char *prefix, uint64_t addr)
{
	static const char hex[] = "0123456789abcdef";
	char tmp[17];
	size_t p = 0;
	int i, started;

	while (prefix[p] != '\0' && p < bufsz - 1) {
		buf[p] = prefix[p];
		p++;
	}
	if (p < bufsz - 1)
		buf[p++] = '@';

	started = 0;
	tmp[0] = '0';
	tmp[1] = '\0';
	{
		int t = 0;
		for (i = 60; i >= 0; i -= 4) {
			unsigned nyb = (unsigned)((addr >> i) & 0xf);
			if (nyb != 0 || started || i == 0) {
				tmp[t++] = hex[nyb];
				started = 1;
			}
		}
		tmp[t] = '\0';
	}
	for (i = 0; tmp[i] != '\0' && p < bufsz - 1; i++)
		buf[p++] = tmp[i];
	buf[p] = '\0';
}

static const ACPI_TABLE_XSDT *
synth_get_xsdt(void)
{
	const ACPI_TABLE_RSDP *rsdp;
	const ACPI_TABLE_XSDT *xsdt;

	if ((rsdp = dboot_uefi_get_acpi_rsdp()) == NULL)
		return (NULL);

	xsdt = (const ACPI_TABLE_XSDT *)rsdp->XsdtPhysicalAddress;
	if (xsdt == NULL)
		return (NULL);

	if (strncmp(xsdt->Header.Signature, ACPI_SIG_XSDT,
	    strlen(ACPI_SIG_XSDT)) != 0)
		return (NULL);

	return (xsdt);
}

static const ACPI_TABLE_HEADER *
synth_find_table(const char *sig)
{
	const ACPI_TABLE_XSDT *xsdt;
	ACPI_TABLE_HEADER *tab;
	const UINT64 *entries;
	UINT64 entry;
	UINT32 nentries;
	UINT32 i;
	size_t slen;

	if ((xsdt = synth_get_xsdt()) == NULL)
		return (NULL);

	slen = strlen(sig);
	nentries = (xsdt->Header.Length -
	    sizeof (xsdt->Header)) / ACPI_XSDT_ENTRY_SIZE;
	entries = &xsdt->TableOffsetEntry[0];

	for (i = 0; i < nentries; ++i) {
		/* Unaligned: the MMU is off, SCTLR.A is ignored. */
		memcpy(&entry, &entries[i], sizeof (entry));
		if (entry == 0)
			continue;
		tab = (ACPI_TABLE_HEADER *)entry;
		if (strncmp(tab->Signature, sig, slen) == 0)
			return (tab);
	}

	return (NULL);
}

/*
 * Walk the MADT for the GIC distributor/redistributor/ITS base addresses.
 * The distributor and redistributor bases are mandatory for GICv3; the ITS
 * is optional (present on QEMU virt and Graviton).  The redistributor base
 * falls back to the per-CPU GICC GicrBaseAddress if no standalone GICR
 * subtable is present.
 *
 * Redistributor topology: a GICv3 redistributor is 2 MMIO frames (4 with
 * VLPIS).  gicthree.c walks each declared region from its base, advancing a
 * cursor frame-by-frame, and stops on either GICR_TYPER_Last or region end.
 * It therefore needs EVERY region the platform presents, since the last
 * redistributor of each physical block sets GICR_TYPER_Last and terminates
 * that region's walk.
 *
 * QEMU virt puts all redistributors in one contiguous block, but real
 * hardware need not: AWS Graviton (c6g.metal, 64 cpus) spreads them over 4
 * blocks of 16 at 0xbc00080000/0xbd00080000/0xbe00080000/0xbf00080000 (a
 * 0x20000 stride within a block, but a ~4GiB jump between blocks).  Merging
 * those into one region only ever finds the first 16 -- GICR_TYPER_Last on
 * the 16th ends the walk -- so we coalesce the per-cpu bases into maximal
 * constant-stride runs and emit one region per run.
 */
#define	SYNTH_GICR_MAX_REGIONS	16
#define	SYNTH_GICR_FRAME	0x10000ULL	/* one GICR MMIO frame */

typedef struct synth_gic {
	uint64_t	gicd;
	uint64_t	gicr;
	uint64_t	gicr_len;
	uint64_t	its;
	uint32_t	ngicc;		/* count of GICC (per-cpu) entries */
	/*
	 * Per-cpu GICR bases, coalesced into contiguous regions.  Only used
	 * on the GICC-fallback path (no standalone GICR subtable), which is
	 * what real ACPI firmware presents.
	 */
	uint64_t	gicr_base[SYNTH_GICR_MAX_REGIONS];
	uint64_t	gicr_size[SYNTH_GICR_MAX_REGIONS];
	uint32_t	ngicr_regions;
	uint64_t	gicr_stride;	/* derived per-cpu GICR stride */
	bool		have_gicd;
	bool		have_gicr;
	/*
	 * True only when a STANDALONE GICR subtable supplied the region.
	 * Distinct from have_gicr, which merely means "some redistributor base
	 * is known" and goes true as soon as the first GICC is seen.
	 */
	bool		have_gicr_subtable;
	bool		have_its;
} synth_gic_t;

/*
 * Collected per-cpu GICR bases, kept sorted ascending as they are inserted.
 * Sized for NCPU since there is one GICR per cpu.
 */
static uint64_t synth_gicr_cpu_base[NCPU];
static uint32_t synth_gicr_ncpu_base;

/* Insertion sort: keep the base list ascending and deduplicated. */
static void
synth_gicr_insert(uint64_t base)
{
	uint32_t i, j;

	if (base == 0 || synth_gicr_ncpu_base >= NCPU)
		return;

	for (i = 0; i < synth_gicr_ncpu_base; i++) {
		if (synth_gicr_cpu_base[i] == base)
			return;			/* duplicate */
		if (synth_gicr_cpu_base[i] > base)
			break;
	}
	for (j = synth_gicr_ncpu_base; j > i; j--)
		synth_gicr_cpu_base[j] = synth_gicr_cpu_base[j - 1];
	synth_gicr_cpu_base[i] = base;
	synth_gicr_ncpu_base++;
}

/*
 * Coalesce the collected per-cpu GICR bases into maximal runs of constant
 * stride, one FDT reg region per run.  The stride is derived from the data
 * (the smallest positive delta between adjacent bases): 0x20000 for a
 * 2-frame redistributor, 0x40000 when VLPIS adds the vector frames.
 */
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
	/* Single cpu, or a degenerate map: assume a 2-frame redistributor. */
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
		/* Run ended: close this region out. */
		g->gicr_size[g->ngicr_regions] = (uint64_t)n * stride;
		g->ngicr_regions++;
		if (g->ngicr_regions >= SYNTH_GICR_MAX_REGIONS) {
			/*
			 * Out of region slots.  Everything left is dropped;
			 * gicthree.c will VERIFY on the short count rather
			 * than silently mis-map, which is the right failure.
			 */
			dboot_printf("dboot: synth FDT: more than %d GICR "
			    "regions; truncating\n", SYNTH_GICR_MAX_REGIONS);
			return;
		}
		g->gicr_base[g->ngicr_regions] = synth_gicr_cpu_base[i];
		n = 1;
	}
	g->gicr_size[g->ngicr_regions] = (uint64_t)n * stride;
	g->ngicr_regions++;
}

/*
 * Emit the GICR topology to the console.
 *
 * dboot_printf() goes through bcons, which on the real-hardware quiet-loader
 * path is not wired to the SPCR UART -- its output never reached the Graviton
 * serial console.  The mechanism that DOES print (proven by the [A6KCON:*]
 * markers) is a raw store to the SPCR UART data register, so use that: the MMU
 * is off in dboot, making the SPCR base directly addressable.  Falls back to
 * dboot_printf when no SPCR UART was found (e.g. QEMU virt, where
 * dboot_printf works anyway).
 */
static void
synth_uart_putc(volatile uint32_t *dr, char c)
{
	/*
	 * Bounded TXFF wait before each byte.  The short [A6KCON:*] markers
	 * could store blindly (14 bytes fits the 32-byte PL011 TX FIFO), but
	 * this diagnostic emits a few hundred bytes and would overflow the
	 * FIFO and drop characters.  The wait is CAPPED because Graviton's
	 * PL011 does not drive TXFF/TXFE the way SBSA implies (the same quirk
	 * the boot_uart FR-poll fix handles) -- an unbounded spin here would
	 * hang the boot instead of printing.  UARTFR is at offset 0x18, i.e.
	 * dr[6] in uint32_t units; TXFF is bit 5.
	 */
	uint32_t cap;

	for (cap = 0; (dr[6] & (1 << 5)) != 0 && cap < 1000000u; cap++)
		;
	*dr = (uint32_t)(uint8_t)c;
}

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

static void
synth_gicr_diag(struct xboot_info *bi, const synth_gic_t *g, uint32_t nr)
{
	volatile uint32_t *dr;
	uint32_t i;

	if (bi == NULL || bi->bi_bsvc_uart_mmio_base == 0) {
		dboot_printf("[A6GIC] ngicc=%u nbase=%u regions=%u "
		    "stride=0x%llx gicr=0x%llx\n", g->ngicc,
		    synth_gicr_ncpu_base, nr,
		    (unsigned long long)g->gicr_stride,
		    (unsigned long long)g->gicr);
		return;
	}

	dr = (volatile uint32_t *)(uintptr_t)bi->bi_bsvc_uart_mmio_base;

	synth_uart_puts(dr, "[A6GIC] ngicc=");
	synth_uart_puthex(dr, g->ngicc);
	synth_uart_puts(dr, " distinct_gicr_base=");
	synth_uart_puthex(dr, synth_gicr_ncpu_base);
	synth_uart_puts(dr, " regions=");
	synth_uart_puthex(dr, nr);
	synth_uart_puts(dr, " stride=0x");
	synth_uart_puthex(dr, g->gicr_stride);
	synth_uart_puts(dr, "\n");

	for (i = 0; i < nr; i++) {
		synth_uart_puts(dr, "[A6GIC] region[");
		synth_uart_puthex(dr, i);
		synth_uart_puts(dr, "] base=0x");
		synth_uart_puthex(dr, g->gicr_base[i]);
		synth_uart_puts(dr, " size=0x");
		synth_uart_puthex(dr, g->gicr_size[i]);
		synth_uart_puts(dr, " ncpu=0x");
		synth_uart_puthex(dr, g->gicr_stride ?
		    g->gicr_size[i] / g->gicr_stride : 0);
		synth_uart_puts(dr, "\n");
	}

	/* The raw per-cpu bases: min/max bracket the spread. */
	if (synth_gicr_ncpu_base > 0) {
		synth_uart_puts(dr, "[A6GIC] gicr_base min=0x");
		synth_uart_puthex(dr, synth_gicr_cpu_base[0]);
		synth_uart_puts(dr, " max=0x");
		synth_uart_puthex(dr,
		    synth_gicr_cpu_base[synth_gicr_ncpu_base - 1]);
		synth_uart_puts(dr, "\n");
	}
}

static void
synth_scan_madt(synth_gic_t *g)
{
	const ACPI_TABLE_MADT *madt;
	const ACPI_SUBTABLE_HEADER *item;
	const ACPI_SUBTABLE_HEADER *end;

	memset(g, 0, sizeof (*g));

	madt = (const ACPI_TABLE_MADT *)synth_find_table(ACPI_SIG_MADT);
	if (madt == NULL)
		return;

	end = (const ACPI_SUBTABLE_HEADER *)
	    (madt->Header.Length + (uintptr_t)madt);
	item = (const ACPI_SUBTABLE_HEADER *)
	    ((uintptr_t)madt + sizeof (*madt));

	synth_gicr_ncpu_base = 0;

	while (item < end && item->Length != 0) {
		switch (item->Type) {
		case ACPI_MADT_TYPE_GENERIC_DISTRIBUTOR: {
			const ACPI_MADT_GENERIC_DISTRIBUTOR *d =
			    (const ACPI_MADT_GENERIC_DISTRIBUTOR *)item;
			uint64_t base;
			memcpy(&base, &d->BaseAddress, sizeof (base));
			g->gicd = base;
			g->have_gicd = true;
			break;
		}
		case ACPI_MADT_TYPE_GENERIC_REDISTRIBUTOR: {
			const ACPI_MADT_GENERIC_REDISTRIBUTOR *r =
			    (const ACPI_MADT_GENERIC_REDISTRIBUTOR *)item;
			uint64_t base;
			uint32_t len;
			memcpy(&base, &r->BaseAddress, sizeof (base));
			memcpy(&len, &r->Length, sizeof (len));
			g->gicr = base;
			g->gicr_len = len;
			g->have_gicr = true;
			g->have_gicr_subtable = true;
			break;
		}
		case ACPI_MADT_TYPE_GENERIC_TRANSLATOR: {
			const ACPI_MADT_GENERIC_TRANSLATOR *t =
			    (const ACPI_MADT_GENERIC_TRANSLATOR *)item;
			uint64_t base;
			memcpy(&base, &t->BaseAddress, sizeof (base));
			g->its = base;
			g->have_its = true;
			break;
		}
		case ACPI_MADT_TYPE_GENERIC_INTERRUPT: {
			/*
			 * Fallback: GICC subtables carry a per-CPU GICR base.
			 * Only used when no standalone GICR subtable exists.
			 */
			const ACPI_MADT_GENERIC_INTERRUPT *c =
			    (const ACPI_MADT_GENERIC_INTERRUPT *)item;
			g->ngicc++;
			/*
			 * Skip only when a STANDALONE GICR subtable already
			 * described the regions.  Testing have_gicr here would
			 * be wrong: the first GICC sets it, so cpus 1..n-1
			 * would never be collected and every region would
			 * collapse to the single cpu0 base.
			 */
			if (!g->have_gicr_subtable) {
				uint64_t base;
				memcpy(&base, &c->GicrBaseAddress,
				    sizeof (base));
				/*
				 * Collect EVERY per-cpu base; they are
				 * coalesced into regions after the walk.
				 * gicr stays the lowest base (the region-0
				 * base, also the node-name address).
				 */
				synth_gicr_insert(base);
				if (base != 0 &&
				    (g->gicr == 0 || base < g->gicr)) {
					g->gicr = base;
					g->have_gicr = true;
				}
			}
			break;
		}
		default:
			break;
		}

		item = (const ACPI_SUBTABLE_HEADER *)
		    ((uintptr_t)item + item->Length);
	}

	/*
	 * A standalone GICR subtable describes its own region directly; the
	 * GICC-fallback path has to derive regions from the per-cpu bases.
	 */
	if (g->have_gicr_subtable && g->gicr_len != 0) {
		g->gicr_base[0] = g->gicr;
		g->gicr_size[0] = g->gicr_len;
		g->ngicr_regions = 1;
	} else {
		synth_gicr_coalesce(g);
	}
}

/*
 * SPCR describes the console serial port.  We map the ACPI interface type
 * to the FDT compatible string the aarch64 port binds.  InterfaceType per
 * the SPCR/DBG2 spec: 0/1 = 16550(-subset), 3 = ARM PL011, others exist but
 * these two cover QEMU virt (PL011) and typical SBBR 16550 UARTs.
 */
typedef struct synth_uart {
	uint64_t	base;
	uint32_t	irq;		/* GSIV (SPI absolute) */
	uint8_t		iface;		/* raw SPCR/DBG2 InterfaceType */
	const char	*compat;
	bool		have;
} synth_uart_t;

static void
synth_scan_spcr(synth_uart_t *u)
{
	const ACPI_TABLE_SPCR *spcr;
	uint64_t base;
	uint32_t irq;
	uint8_t iface;

	memset(u, 0, sizeof (*u));

	spcr = (const ACPI_TABLE_SPCR *)synth_find_table(ACPI_SIG_SPCR);
	if (spcr == NULL)
		return;

	memcpy(&base, &spcr->SerialPort.Address, sizeof (base));
	memcpy(&irq, &spcr->Interrupt, sizeof (irq));
	iface = spcr->InterfaceType;

	if (base == 0)
		return;

	/*
	 * AWS Graviton quirk: the SPCR declares InterfaceType 0x00 ("full
	 * 16550") with byte-width GAS access descriptors, but the console
	 * device is physically an ARM PL011 (the firmware, the SBSA/PL011
	 * register layout, and Linux's PL011 driver all agree).  When the
	 * SPCR is stamped AMAZON, force the PL011 interpretation so the
	 * boot UART driver (SBSA/PL011-compatible) drives the right device.
	 */
	if (iface != 0x03 && iface != 0x0d && iface != 0x0e &&
	    strncmp(spcr->Header.OemId, "AMAZON", 6) == 0)
		iface = 0x03;

	u->base = base;
	u->irq = irq;
	u->iface = iface;
	u->have = true;

	switch (iface) {
	case 0x03:	/* ARM PL011 UART */
	case 0x0e:	/* ARM SBSA generic UART (32-bit only PL011) */
		u->compat = "arm,pl011";
		break;
	default:	/* 0/1 = 16550 / 16550-subset and friends */
		u->compat = "ns16550a";
		break;
	}
}

/*
 * MCFG describes the PCIe ECAM window(s).  We emit one pcie node per
 * allocation (dboot already counted these into bi_pcierc_cnt).
 */
typedef struct synth_ecam {
	uint64_t	base;
	uint8_t		bus_start;
	uint8_t		bus_end;
	bool		have;
} synth_ecam_t;

static int
synth_scan_mcfg(synth_ecam_t *e, int max)
{
	const ACPI_TABLE_MCFG *mcfg;
	const ACPI_MCFG_ALLOCATION *alloc;
	UINT32 mcfglen;
	UINT32 alloclen;
	uint32_t n, i;

	mcfg = (const ACPI_TABLE_MCFG *)synth_find_table(ACPI_SIG_MCFG);
	if (mcfg == NULL)
		return (0);

	memcpy(&mcfglen, &mcfg->Header.Length, sizeof (mcfglen));
	if (mcfglen < sizeof (ACPI_TABLE_MCFG))
		return (0);

	alloclen = mcfglen - sizeof (ACPI_TABLE_MCFG);
	if (alloclen % sizeof (ACPI_MCFG_ALLOCATION) != 0)
		return (0);

	n = alloclen / sizeof (ACPI_MCFG_ALLOCATION);
	if ((int)n > max)
		n = (uint32_t)max;

	alloc = (const ACPI_MCFG_ALLOCATION *)
	    ((uintptr_t)mcfg + sizeof (ACPI_TABLE_MCFG));

	for (i = 0; i < n; i++) {
		uint64_t addr;
		memcpy(&addr, &alloc[i].Address, sizeof (addr));
		e[i].base = addr;
		e[i].bus_start = alloc[i].StartBusNumber;
		e[i].bus_end = alloc[i].EndBusNumber;
		e[i].have = true;
	}

	return ((int)n);
}

/*
 * PCIe host-bridge outbound windows extracted from the DSDT _CRS.
 *
 * Each window is a (space, child-addr, parent-addr, size) tuple in the
 * DT PCI `ranges` sense: `child` is the PCI-side address, `parent` is the
 * CPU-physical address, `size` the window length.  ACPI resource
 * descriptors carry (min, max, translation-offset, length): the PCI-side
 * (child) address is `min`, and the CPU-side (parent) address is
 * `min + translation`.
 */
typedef struct synth_win {
	uint32_t	space;		/* PCI_SPACE_IO / MEM32 / MEM64 */
	uint64_t	child;
	uint64_t	parent;
	uint64_t	size;
} synth_win_t;

typedef struct synth_crs {
	synth_win_t	win[8];
	int		nwin;
	bool		have;
} synth_crs_t;

/* ACPI large-resource descriptor tags (ACPI 6.x, table 6.42/6.44). */
#define	ACPI_LRES_WORD_ADDR	0x88	/* WordAddressSpace  (2-byte fields) */
#define	ACPI_LRES_DWORD_ADDR	0x87	/* DWordAddressSpace (4-byte fields) */
#define	ACPI_LRES_QWORD_ADDR	0x8a	/* QWordAddressSpace (8-byte fields) */
#define	ACPI_LRES_END_TAG	0x79	/* actually a small-res end tag */

/* Address-space resource types (byte 3 of the descriptor). */
#define	ACPI_RESTYPE_MEMORY	0
#define	ACPI_RESTYPE_IO		1
#define	ACPI_RESTYPE_BUS	2

/*
 * General flags bit 0: 1 = ResourceConsumer, 0 = ResourceProducer.  A
 * host-bridge outbound window is a Producer, so producer == (bit0 clear).
 */
#define	ACPI_RESFLAG_CONSUMER	0x01
#define	ACPI_RES_IS_PRODUCER(gf)	(((gf) & ACPI_RESFLAG_CONSUMER) == 0)

/*
 * Read one address-space descriptor's 5 fields (gran, min, max, tra, len)
 * of `fw` bytes each, little-endian, starting at *p.  Advances *p.
 */
static void
crs_read_fields(const uint8_t *base, uint32_t off, int fw, uint64_t out[5])
{
	int i, b;
	for (i = 0; i < 5; i++) {
		uint64_t v = 0;
		for (b = 0; b < fw; b++)
			v |= ((uint64_t)base[off + i * fw + b]) << (b * 8);
		out[i] = v;
	}
}

/*
 * Scan the DSDT for the PCIe host-bridge _CRS producer windows.  The root
 * bridge's resource template is a run of large address-space descriptors
 * beginning with a WordAddressSpace of ResourceType BusNumber (0x88 /
 * type 2); the memory/IO producer windows follow it.  We locate that
 * bus-number producer and then collect the memory/IO producer windows
 * that immediately follow, stopping at the end tag or a non-address-space
 * descriptor.  This is a direct AML byte-stream read of the fixed
 * resource-descriptor encoding -- not a general AML interpreter.
 */
static void
synth_scan_crs(synth_crs_t *c)
{
	const ACPI_TABLE_FADT *fadt;
	const ACPI_TABLE_HEADER *dsdt;
	uint64_t dsdt_pa;
	uint32_t dsdt32;
	const uint8_t *p;
	uint32_t len, off;

	memset(c, 0, sizeof (*c));

	/*
	 * The DSDT is not listed in the XSDT; it is referenced by the FADT
	 * (XDsdt 64-bit, else Dsdt 32-bit).  Find the FADT, follow it.
	 */
	fadt = (const ACPI_TABLE_FADT *)synth_find_table(ACPI_SIG_FADT);
	if (fadt == NULL)
		return;
	memcpy(&dsdt_pa, &fadt->XDsdt, sizeof (dsdt_pa));
	if (dsdt_pa == 0) {
		memcpy(&dsdt32, &fadt->Dsdt, sizeof (dsdt32));
		dsdt_pa = dsdt32;
	}
	if (dsdt_pa == 0)
		return;
	dsdt = (const ACPI_TABLE_HEADER *)(uintptr_t)dsdt_pa;
	if (strncmp(dsdt->Signature, ACPI_SIG_DSDT,
	    strlen(ACPI_SIG_DSDT)) != 0)
		return;
	memcpy(&len, &dsdt->Length, sizeof (len));
	if (len <= sizeof (*dsdt))
		return;
	p = (const uint8_t *)dsdt;

	/* Find the bus-number WordAddressSpace producer (root bridge). */
	for (off = sizeof (*dsdt); off + 3 < len; off++) {
		uint16_t dlen;
		if (p[off] != ACPI_LRES_WORD_ADDR)
			continue;
		dlen = (uint16_t)(p[off + 1] | (p[off + 2] << 8));
		/* WordAddressSpace min payload is 13 bytes. */
		if (dlen < 13 || off + 3 + dlen > len)
			continue;
		if (p[off + 3] != ACPI_RESTYPE_BUS)
			continue;
		if (!ACPI_RES_IS_PRODUCER(p[off + 4]))
			continue;
		/* Found it: collect the windows that follow. */
		off += 3 + dlen;
		break;
	}
	if (off + 3 >= len)
		return;

	while (off + 3 < len && c->nwin < 8) {
		uint8_t tag = p[off];
		uint16_t dlen;
		uint8_t restype, gflags;
		int fw;
		uint64_t f[5];
		synth_win_t *w;

		if (tag == ACPI_LRES_DWORD_ADDR)
			fw = 4;
		else if (tag == ACPI_LRES_QWORD_ADDR)
			fw = 8;
		else if (tag == ACPI_LRES_WORD_ADDR)
			fw = 2;
		else
			break;	/* end of the root-bridge resource template */

		dlen = (uint16_t)(p[off + 1] | (p[off + 2] << 8));
		if (off + 3 + dlen > len)
			break;
		restype = p[off + 3];
		gflags = p[off + 4];
		/* skip byte 5 (type-specific flags); fields start at +6 */
		crs_read_fields(p, off + 6, fw, f);

		if (ACPI_RES_IS_PRODUCER(gflags) && f[4] != 0 &&
		    (restype == ACPI_RESTYPE_MEMORY ||
		    restype == ACPI_RESTYPE_IO)) {
			w = &c->win[c->nwin++];
			w->child = f[1];		/* min */
			w->parent = f[1] + f[3];	/* min + translation */
			w->size = f[4];			/* length */
			if (restype == ACPI_RESTYPE_IO)
				w->space = PCI_SPACE_IO;
			else if ((f[1] >> 32) != 0 || fw == 8)
				w->space = PCI_SPACE_MEM64;
			else
				w->space = PCI_SPACE_MEM32;
		}

		off += 3 + dlen;
	}

	/*
	 * The loop above stops at win[8]. That bound is correct (one nwin++ per
	 * iteration under a `c->nwin < 8` guard, so no overflow), but hitting it is
	 * SILENT: extra producer windows are simply dropped and the resulting FDT
	 * describes less MMIO than the hardware actually decodes. Real c6g.metal has
	 * roughly 20 PCIe bridges, and metal's DSDT has never been read, so this is a
	 * live possibility rather than a theoretical one -- and a dropped window looks
	 * exactly like a window the firmware never advertised.
	 *
	 * Warn on the boundary, matching what the GICR-region scan already does for
	 * the same class of problem. A near-miss then shows up in the console log
	 * before it becomes a truncation.
	 */
	if (c->nwin == 8)
		dboot_printf("dboot: WARNING _CRS producer windows hit the "
		    "%d-window limit; any further windows were DROPPED\n", 8);

	if (c->nwin > 0)
		c->have = true;
}

/*
 * Distinguish QEMU virt from real SBBR/Graviton firmware by the ACPI OEM
 * ID (FADT header): QEMU/EDK2 stamp "BOCHS "/"BXPC", real Nitro/Graviton
 * stamps "AMAZON".  Only QEMU virt needs the synthesised virtio-mmio
 * transport slots (its virtio-blk disk has no ACPI description); real
 * hardware boots off NVMe-over-PCIe and must not carry them.
 */
static bool
synth_is_qemu_virt(void)
{
	const ACPI_TABLE_HEADER *h;

	h = synth_find_table(ACPI_SIG_FADT);
	if (h == NULL)
		h = synth_find_table(ACPI_SIG_MADT);
	if (h == NULL)
		return (false);
	/* OemId is a 6-byte space-padded field. */
	if (strncmp(h->OemId, "BOCHS", 5) == 0 ||
	    strncmp(h->OemId, "BXPC", 4) == 0 ||
	    strncmp(h->OemId, "QEMU", 4) == 0)
		return (true);
	return (false);
}

static int
prop_reg2(void *fdt, uint64_t addr, uint64_t size)
{
	fdt32_t reg[4];
	reg[0] = cpu_to_fdt32((uint32_t)(addr >> 32));
	reg[1] = cpu_to_fdt32((uint32_t)(addr & 0xffffffff));
	reg[2] = cpu_to_fdt32((uint32_t)(size >> 32));
	reg[3] = cpu_to_fdt32((uint32_t)(size & 0xffffffff));
	return (fdt_property(fdt, "reg", reg, sizeof (reg)));
}

static int
prop_interrupt(void *fdt, uint32_t type, uint32_t nr, uint32_t flags)
{
	fdt32_t irq[3];
	irq[0] = cpu_to_fdt32(type);
	irq[1] = cpu_to_fdt32(nr);
	irq[2] = cpu_to_fdt32(flags);
	return (fdt_property(fdt, "interrupts", irq, sizeof (irq)));
}

/*
 * Build the synthesised FDT.  Returns the blob address (to be stored in
 * bi_fdt) on success, or 0 on failure (caller keeps bi_fdt == 0, meaning
 * the ACPI-only path with no devicetree, which will not enumerate devices).
 */
uint64_t
dboot_synth_fdt(struct xboot_info *bi)
{
	void *fdt = (void *)synth_fdt;
	synth_gic_t gic;
	synth_uart_t uart;
	synth_ecam_t ecam[8];
	synth_crs_t crs;
	bool qemu;
	int necam;
	int nc;
	int rc;
	char name[32];

	synth_scan_madt(&gic);
	synth_scan_spcr(&uart);
	necam = synth_scan_mcfg(ecam, 8);
	synth_scan_crs(&crs);
	qemu = synth_is_qemu_virt();

	/*
	 * Populate the early-boot UART (bi_bsvc_uart_*) from the SPCR when
	 * the loader did not hand us one via the bcons.uart.* properties.
	 *
	 * On QEMU virt the loader's FDT-UART discovery (/chosen/stdout-path
	 * -> serial node) forwards a valid base, so this stays a no-op.  On
	 * real SBBR/Graviton the console UART is described ONLY by the static
	 * SPCR table: the DSDT namespace carries no UART device, so the
	 * loader's ACPI namespace walk finds none ("no compatible MMIO
	 * UARTs") and never sets bcons.uart.mmio_base -- leaving the kernel's
	 * boot_uart at base 0, i.e. silent.  The SPCR base IS authoritative
	 * per SBBR, so drive the early UART from it directly.
	 *
	 * bi_bsvc_uart_type takes the raw SPCR/DBG2 InterfaceType, which
	 * shares the XBI_BSVC_UART_* numbering for the types the boot UART
	 * driver supports (PL011=0x03, SBSA2X=0x0d, SBSA=0x0e).  16550 and
	 * friends are left as NONE (unsupported by the boot UART driver).
	 */
	if (uart.have && bi->bi_bsvc_uart_mmio_base == 0) {
		switch (uart.iface) {
		case 0x03:	/* ARM PL011 */
		case 0x0d:	/* ARM SBSA 32-bit only */
		case 0x0e:	/* ARM SBSA generic */
			/*
			 * Set the early-boot UART fields only.  The kernel
			 * proper runs bcons_init(bi) itself after exitto, in a
			 * clean state: boot_uart_init(bi) picks up these fields
			 * and, because the base is now non-zero, sets diag to
			 * CONS_TTY -- so the kernel banner reaches the SPCR
			 * UART.  We deliberately do NOT re-run bcons_init()
			 * here: re-entering it mid-configure (re-running the
			 * framebuffer/keyboard init) wedges the boot before the
			 * kernel is entered.
			 */
			bi->bi_bsvc_uart_mmio_base = uart.base;
			bi->bi_bsvc_uart_type =
			    (xbi_bsvc_uart_type_t)uart.iface;
			break;
		default:
			break;
		}
	}

	synth_next_phandle = SYNTH_PHANDLE_FIRST;

	if (!gic.have_gicd || !gic.have_gicr) {
		dboot_printf("dboot: synth FDT: MADT missing GICv3 "
		    "distributor/redistributor\n");
		return (0);
	}

	rc = fdt_create(fdt, SYNTH_FDT_MAX);
	if (rc != 0)
		goto fail;

	(void) fdt_add_reservemap_entry(fdt, 0, 0);
	(void) fdt_finish_reservemap(fdt);

	(void) fdt_begin_node(fdt, "");		/* root */
	(void) fdt_property_cell(fdt, "#address-cells", 2);
	(void) fdt_property_cell(fdt, "#size-cells", 2);
	(void) fdt_property_cell(fdt, "interrupt-parent", SYNTH_PHANDLE_GIC);
	(void) fdt_property_string(fdt, "compatible", "solnix,acpi-synth");
	synth_emit_phandle(fdt);

	/* /chosen -- build_firmware_properties_fdt walks this. */
	(void) fdt_begin_node(fdt, "chosen");
	synth_emit_phandle(fdt);
	(void) fdt_end_node(fdt);

	/* /psci -- PSCI is mandatory on ACPI aarch64. */
	(void) fdt_begin_node(fdt, "psci");
	(void) fdt_property_string(fdt, "compatible", "arm,psci-1.0");
	(void) fdt_property_string(fdt, "method",
	    bi->bi_smccc_conduit == BI_SMCCC_CONDUIT_HVC ? "hvc" : "smc");
	(void) fdt_property_cell(fdt, "cpu_suspend",
	    bi->bi_psci_cpu_suspend_id);
	(void) fdt_property_cell(fdt, "cpu_off", bi->bi_psci_cpu_off_id);
	(void) fdt_property_cell(fdt, "cpu_on", bi->bi_psci_cpu_on_id);
	(void) fdt_property_cell(fdt, "migrate", bi->bi_psci_migrate_id);
	synth_emit_phandle(fdt);
	(void) fdt_end_node(fdt);

	/* /cpus with one cpu@N per MADT GICC entry (already in bi_cpuinfo). */
	(void) fdt_begin_node(fdt, "cpus");
	(void) fdt_property_cell(fdt, "#address-cells", 1);
	(void) fdt_property_cell(fdt, "#size-cells", 0);
	synth_emit_phandle(fdt);
	{
		struct xboot_cpu_info *xci =
		    (struct xboot_cpu_info *)bi->bi_cpuinfo;
		uint32_t i;

		for (i = 0; i < bi->bi_cpuinfo_cnt; i++) {
			synth_nodename(name, sizeof (name), "cpu",
			    xci[i].xci_mpidr);
			(void) fdt_begin_node(fdt, name);
			(void) fdt_property_string(fdt, "device_type", "cpu");
			(void) fdt_property_string(fdt, "compatible",
			    "arm,armv8");
			(void) fdt_property_string(fdt, "enable-method",
			    "psci");
			(void) fdt_property_cell(fdt, "reg",
			    (uint32_t)xci[i].xci_mpidr);
			synth_emit_phandle(fdt);
			(void) fdt_end_node(fdt);
		}
	}
	(void) fdt_end_node(fdt);

	/* /memory -- bootstrapped from the UEFI map; a placeholder node. */
	(void) fdt_begin_node(fdt, "memory@0");
	(void) fdt_property_string(fdt, "device_type", "memory");
	(void) prop_reg2(fdt, 0, 0);
	synth_emit_phandle(fdt);
	(void) fdt_end_node(fdt);

	/* Architected timer (PPIs fixed by the architecture). */
	(void) fdt_begin_node(fdt, "timer");
	(void) fdt_property_string(fdt, "compatible", "arm,armv8-timer");
	{
		fdt32_t irq[12];
		irq[0] = cpu_to_fdt32(GIC_PPI);
		irq[1] = cpu_to_fdt32(TMR_PPI_SEC);
		irq[2] = cpu_to_fdt32(IRQ_LEVEL_HI);
		irq[3] = cpu_to_fdt32(GIC_PPI);
		irq[4] = cpu_to_fdt32(TMR_PPI_NONSEC);
		irq[5] = cpu_to_fdt32(IRQ_LEVEL_HI);
		irq[6] = cpu_to_fdt32(GIC_PPI);
		irq[7] = cpu_to_fdt32(TMR_PPI_VIRT);
		irq[8] = cpu_to_fdt32(IRQ_LEVEL_HI);
		irq[9] = cpu_to_fdt32(GIC_PPI);
		irq[10] = cpu_to_fdt32(TMR_PPI_HYP);
		irq[11] = cpu_to_fdt32(IRQ_LEVEL_HI);
		(void) fdt_property(fdt, "interrupts", irq, sizeof (irq));
	}
	(void) fdt_property(fdt, "always-on", NULL, 0);
	synth_emit_phandle(fdt);
	(void) fdt_end_node(fdt);

	/* GICv3 interrupt controller: reg = <GICD .. GICR ..>. */
	synth_nodename(name, sizeof (name), "intc", gic.gicd);
	(void) fdt_begin_node(fdt, name);
	(void) fdt_property_string(fdt, "compatible", "arm,gic-v3");
	(void) fdt_property_cell(fdt, "#interrupt-cells", 3);
	(void) fdt_property(fdt, "interrupt-controller", NULL, 0);
	(void) fdt_property_cell(fdt, "#address-cells", 2);
	(void) fdt_property_cell(fdt, "#size-cells", 2);
	(void) fdt_property_cell(fdt, "#redistributor-regions",
	    gic.ngicr_regions ? gic.ngicr_regions : 1);
	(void) fdt_property(fdt, "ranges", NULL, 0);
	(void) fdt_property_cell(fdt, "phandle", SYNTH_PHANDLE_GIC);
	{
		/*
		 * reg = <GICD len> then ONE address/size pair per
		 * redistributor region.  gicthree.c maps reg index 0 as the
		 * distributor and 1..#redistributor-regions as the
		 * redistributor regions, taking each region's size from the
		 * regspec, so the pair count must match the property exactly.
		 */
		fdt32_t reg[4 * (1 + SYNTH_GICR_MAX_REGIONS)];
		uint64_t gicd_len = 0x10000;
		uint32_t i, nr, np;

		nr = gic.ngicr_regions;
		if (nr == 0) {
			/* No per-cpu bases: fall back to one sized region. */
			gic.gicr_base[0] = gic.gicr;
			gic.gicr_size[0] = gic.gicr_len != 0 ? gic.gicr_len :
			    SYNTH_GICR_FRAME * 2;
			nr = 1;
		}

		np = 0;
		reg[np++] = cpu_to_fdt32((uint32_t)(gic.gicd >> 32));
		reg[np++] = cpu_to_fdt32((uint32_t)(gic.gicd & 0xffffffff));
		reg[np++] = cpu_to_fdt32((uint32_t)(gicd_len >> 32));
		reg[np++] = cpu_to_fdt32((uint32_t)(gicd_len & 0xffffffff));
		for (i = 0; i < nr; i++) {
			reg[np++] = cpu_to_fdt32(
			    (uint32_t)(gic.gicr_base[i] >> 32));
			reg[np++] = cpu_to_fdt32(
			    (uint32_t)(gic.gicr_base[i] & 0xffffffff));
			reg[np++] = cpu_to_fdt32(
			    (uint32_t)(gic.gicr_size[i] >> 32));
			reg[np++] = cpu_to_fdt32(
			    (uint32_t)(gic.gicr_size[i] & 0xffffffff));
		}
		synth_gicr_diag(bi, &gic, nr);
		(void) fdt_property(fdt, "reg", reg,
		    np * sizeof (fdt32_t));
	}

	if (gic.have_its) {
		synth_nodename(name, sizeof (name), "its", gic.its);
		(void) fdt_begin_node(fdt, name);
		(void) fdt_property_string(fdt, "compatible",
		    "arm,gic-v3-its");
		(void) fdt_property(fdt, "msi-controller", NULL, 0);
		(void) fdt_property_cell(fdt, "#msi-cells", 1);
		(void) fdt_property_cell(fdt, "phandle", SYNTH_PHANDLE_ITS);
		(void) prop_reg2(fdt, gic.its, 0x20000);
		(void) fdt_end_node(fdt);
	}
	(void) fdt_end_node(fdt);		/* intc */

	/* Console UART. */
	if (uart.have) {
		synth_nodename(name, sizeof (name), "serial", uart.base);
		(void) fdt_begin_node(fdt, name);
		(void) fdt_property_string(fdt, "compatible", uart.compat);
		(void) prop_reg2(fdt, uart.base, 0x1000);
		if (uart.irq >= 32) {
			(void) prop_interrupt(fdt, GIC_SPI, uart.irq - 32,
			    IRQ_LEVEL_HI);
		}
		synth_emit_phandle(fdt);
		(void) fdt_end_node(fdt);
	}

	/*
	 * virtio-mmio transport slots.  QEMU virt places 32 slots at
	 * 0xa000000 + n*0x200, each SPI (16 + n), edge-rising -- the same
	 * layout QEMU's generated FDT carries, which is how the FDT path
	 * binds the boot disk (virtio-blk-device).  QEMU's ACPI has no table
	 * that describes these, so we emit the fixed QEMU-virt map; the
	 * illumos viommionex nexus binds `virtio,mmio' and probes each slot,
	 * ignoring the empty ones.
	 *
	 * Emitted ONLY under QEMU virt (OEM ID BOCHS/BXPC).  Real
	 * SBBR/Graviton has no virtio-mmio -- its boot disk is
	 * NVMe-over-PCIe, described by ACPI/_CRS and enumerated through the
	 * pcie node below -- and must not carry these slots (they would map
	 * MMIO the platform does not decode).
	 */
	if (qemu) {
		uint64_t vbase = 0xa000000ULL;
		uint32_t n;
		for (n = 0; n < 32; n++) {
			synth_nodename(name, sizeof (name), "virtio_mmio",
			    vbase + (uint64_t)n * 0x200);
			(void) fdt_begin_node(fdt, name);
			(void) fdt_property_string(fdt, "compatible",
			    "virtio,mmio");
			(void) prop_reg2(fdt, vbase + (uint64_t)n * 0x200,
			    0x200);
			(void) prop_interrupt(fdt, GIC_SPI, 16 + n,
			    IRQ_EDGE_RISING);
			(void) fdt_property(fdt, "dma-coherent", NULL, 0);
			synth_emit_phandle(fdt);
			(void) fdt_end_node(fdt);
		}
	}

	/* PCIe ECAM root complex(es). */
	{
		int i;
		for (i = 0; i < necam; i++) {
			if (!ecam[i].have)
				continue;
			synth_nodename(name, sizeof (name), "pcie", ecam[i].base);
			(void) fdt_begin_node(fdt, name);
			(void) fdt_property_string(fdt, "compatible",
			    "pci-host-ecam-generic");
			(void) fdt_property_string(fdt, "device_type", "pci");
			(void) fdt_property_cell(fdt, "#address-cells", 3);
			(void) fdt_property_cell(fdt, "#size-cells", 2);
			(void) fdt_property_cell(fdt, "#interrupt-cells", 1);
			(void) fdt_property_cell(fdt, "linux,pci-domain", i);
			{
				fdt32_t br[2];
				br[0] = cpu_to_fdt32(ecam[i].bus_start);
				br[1] = cpu_to_fdt32(ecam[i].bus_end);
				(void) fdt_property(fdt, "bus-range", br,
				    sizeof (br));
			}
			{
				/*
				 * ranges: <child(3) parent(2) size(2)> per
				 * window.  find_resource() in pcierc walks this
				 * for the IO/MMIO32/MMIO64 available lists; it
				 * panics ("No ranges property") if absent.  Prefer
				 * the windows parsed from the DSDT _CRS (real
				 * hardware); fall back to the fixed QEMU-virt map
				 * only if no _CRS producer windows were found.
				 */
				static const uint64_t qemu_rwin[3][4] = {
					/* space, child, parent, size */
					{ PCI_SPACE_IO,    0x00000000ULL,
					  0x3eff0000ULL,   0x00010000ULL },
					{ PCI_SPACE_MEM32, 0x10000000ULL,
					  0x10000000ULL,   0x2eff0000ULL },
					{ PCI_SPACE_MEM64, 0x8000000000ULL,
					  0x8000000000ULL, 0x8000000000ULL },
				};
				fdt32_t rg[8 * 7];
				int nw, w;
				for (w = 0; w < 8 * 7; w++)
					rg[w] = 0;
				if (crs.have && i == 0) {
					nw = crs.nwin;
					for (w = 0; w < nw; w++) {
						uint64_t ca = crs.win[w].child;
						uint64_t pa = crs.win[w].parent;
						uint64_t sz = crs.win[w].size;
						fdt32_t *e = &rg[w * 7];
						e[0] = cpu_to_fdt32(
						    crs.win[w].space);
						e[1] = cpu_to_fdt32(
						    (uint32_t)(ca >> 32));
						e[2] = cpu_to_fdt32(
						    (uint32_t)ca);
						e[3] = cpu_to_fdt32(
						    (uint32_t)(pa >> 32));
						e[4] = cpu_to_fdt32(
						    (uint32_t)pa);
						e[5] = cpu_to_fdt32(
						    (uint32_t)(sz >> 32));
						e[6] = cpu_to_fdt32(
						    (uint32_t)sz);
					}
				} else {
					nw = 3;
					for (w = 0; w < nw; w++) {
						uint64_t ca = qemu_rwin[w][1];
						uint64_t pa = qemu_rwin[w][2];
						uint64_t sz = qemu_rwin[w][3];
						fdt32_t *e = &rg[w * 7];
						e[0] = cpu_to_fdt32(
						    (uint32_t)qemu_rwin[w][0]);
						e[1] = cpu_to_fdt32(
						    (uint32_t)(ca >> 32));
						e[2] = cpu_to_fdt32(
						    (uint32_t)ca);
						e[3] = cpu_to_fdt32(
						    (uint32_t)(pa >> 32));
						e[4] = cpu_to_fdt32(
						    (uint32_t)pa);
						e[5] = cpu_to_fdt32(
						    (uint32_t)(sz >> 32));
						e[6] = cpu_to_fdt32(
						    (uint32_t)sz);
					}
				}
				(void) fdt_property(fdt, "ranges", rg,
				    (int)(nw * 7 * sizeof (fdt32_t)));
			}
			if (gic.have_its) {
				fdt32_t mm[4];
				mm[0] = cpu_to_fdt32(0);
				mm[1] = cpu_to_fdt32(SYNTH_PHANDLE_ITS);
				mm[2] = cpu_to_fdt32(0);
				mm[3] = cpu_to_fdt32(0x10000);
				(void) fdt_property(fdt, "msi-map", mm,
				    sizeof (mm));
			}
			{
				/*
				 * ECAM window: bus-range * 1MiB of config
				 * space at the MCFG base.
				 */
				uint64_t sz = ((uint64_t)
				    (ecam[i].bus_end - ecam[i].bus_start + 1))
				    << 20;
				(void) prop_reg2(fdt, ecam[i].base, sz);
			}
			synth_emit_phandle(fdt);
			(void) fdt_end_node(fdt);
		}
	}

	rc = fdt_end_node(fdt);			/* root */
	if (rc != 0)
		goto fail;

	rc = fdt_finish(fdt);
	if (rc != 0)
		goto fail;

	if (fdt_check_header(fdt) != 0) {
		dboot_printf("dboot: synth FDT failed self-check\n");
		return (0);
	}

	/*
	 * REPORT THE HEADROOM, because 71 of the 79 libfdt calls in this file are
	 * (void)-cast and therefore discard -FDT_ERR_NOSPACE silently. fdt_finish()
	 * above does catch a genuine overflow, but only AFTER the tree has been
	 * built, and the failure surfaces as "some nodes are missing" -- which is
	 * indistinguishable from a node the ACPI parse never emitted. That
	 * ambiguity cost this project real money: an agent reasonably hypothesised
	 * that SYNTH_FDT_MAX was overflowing on a 64-CPU Graviton (64 cpu@ nodes
	 * versus QEMU's 2) and had to measure it statically to rule it out. Printing
	 * the used/limit numbers makes the question answerable from any console log
	 * for free, and makes a future near-miss visible BEFORE it truncates.
	 */
	dboot_printf("dboot: synth FDT %d of %d bytes used (%d free)\n",
	    fdt_totalsize(fdt), SYNTH_FDT_MAX,
	    SYNTH_FDT_MAX - fdt_totalsize(fdt));

	/*
	 * Repeat the verdict on the RAW SPCR UART, because dboot_printf() output
	 * does not reach the console on real SBBR/Graviton at all.  Measured on a
	 * c6g.metal boot: five [A6GIC] lines (emitted by synth_gicr_diag() through
	 * synth_uart_puts(), the raw MMIO store below) arrive, while every dboot:
	 * line from this same function is absent -- same boot, same file, differing
	 * only in output path.  The cause is stated at the SPCR block above: the
	 * loader finds "no compatible MMIO UARTs" in the ACPI namespace, so dboot's
	 * own console was never wired up; the SPCR base is installed into
	 * bi_bsvc_uart_mmio_base for the kernel's later boot_uart_init(), which is
	 * why the kernel banner prints and dboot's does not.
	 *
	 * Without this, the _CRS-window count -- the value that decides whether the
	 * pcie ranges came from the firmware or from the hardcoded QEMU-virt
	 * fallback -- is unreadable on the only hardware where the answer matters.
	 * Four metal console captures were taken before anyone noticed they
	 * structurally could not contain it.
	 *
	 * Deliberately hex, no format strings, reusing the helpers synth_gicr_diag()
	 * already proves work at this point in the boot.  One ~70-character line: on
	 * a console measured well under 0.1 s/char this is free, but note that at the
	 * old 13 s/char it would have cost ~15 minutes -- an instrument that changes
	 * the system is not an observer.
	 */
	if (bi->bi_bsvc_uart_mmio_base != 0) {
		volatile uint32_t *dr = (volatile uint32_t *)(uintptr_t)
		    bi->bi_bsvc_uart_mmio_base;
		int w;

		synth_uart_puts(dr, "[A6CRS] crs_nwin=0x");
		synth_uart_puthex(dr, (uint64_t)(uint32_t)crs.nwin);
		synth_uart_puts(dr, " crs_have=0x");
		synth_uart_puthex(dr, crs.have ? 1 : 0);
		synth_uart_puts(dr, " necam=0x");
		synth_uart_puthex(dr, (uint64_t)(uint32_t)necam);
		synth_uart_puts(dr, " ecam0=0x");
		synth_uart_puthex(dr, necam > 0 ? ecam[0].base : 0);
		synth_uart_puts(dr, " qemu=0x");
		synth_uart_puthex(dr, qemu ? 1 : 0);
		synth_uart_puts(dr, " fdt_used=0x");
		synth_uart_puthex(dr, (uint64_t)(uint32_t)fdt_totalsize(fdt));
		synth_uart_puts(dr, " fdt_max=0x");
		synth_uart_puthex(dr, (uint64_t)SYNTH_FDT_MAX);
		synth_uart_puts(dr, "\n");

		/*
		 * The windows themselves, one line each.  If crs_nwin is 0 the
		 * emitted ranges are the QEMU-virt constants (MEM32 0x10000000,
		 * MEM64 0x8000000000, IO parent 0x3eff0000) and these lines say so
		 * by their absence -- which distinguishes "firmware advertised
		 * nothing" from "firmware advertised windows we mis-parsed".
		 */
		for (w = 0; w < crs.nwin; w++) {
			synth_uart_puts(dr, "[A6CRS] win[");
			synth_uart_puthex(dr, (uint64_t)(uint32_t)w);
			synth_uart_puts(dr, "] space=0x");
			synth_uart_puthex(dr, crs.win[w].space);
			synth_uart_puts(dr, " child=0x");
			synth_uart_puthex(dr, crs.win[w].child);
			synth_uart_puts(dr, " parent=0x");
			synth_uart_puthex(dr, crs.win[w].parent);
			synth_uart_puts(dr, " size=0x");
			synth_uart_puthex(dr, crs.win[w].size);
			synth_uart_puts(dr, "\n");
		}
	}

	nc = (int)bi->bi_cpuinfo_cnt;
	dboot_printf("dboot: synthesised FDT from ACPI (%d cpu%s, gicd=0x%lx "
	    "gicr=0x%lx%s, %d pcie rc, %s, %d _CRS win%s)\n", nc,
	    nc == 1 ? "" : "s", (unsigned long)gic.gicd,
	    (unsigned long)gic.gicr, gic.have_its ? " +its" : "", necam,
	    qemu ? "qemu virtio-mmio" : "hw pcie-only",
	    crs.nwin, crs.nwin == 1 ? "" : "s");

	return ((uint64_t)(uintptr_t)synth_fdt);

fail:
	dboot_printf("dboot: synth FDT build failed: %s\n", fdt_strerror(rc));
	return (0);
}
