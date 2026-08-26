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
 * (MADT/SPCR/MCFG) parsed by dboot_conf_acpi.c, so that the kernel's
 * FDT-fed prom_emul and the standard prom->devinfo enumeration work
 * unchanged on ACPI (SBBR/Graviton) platforms.
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
 * requires as the `ranges` property are not in any static ACPI table we
 * parse (they live in the DSDT _CRS).  Emit the fixed QEMU virt machine
 * windows, which also match the layout EDK2 presents on that platform.
 *
 * child-address encoding (DT PCI binding): high cell = space+flags
 *   0x01000000 = IO, 0x02000000 = MEM32, 0x03000000 = MEM64.
 *
 * NOTE: QEMU-virt-fixed windows; real SBBR/Graviton needs the DSDT
 * _CRS parsed for its own IO/MMIO windows.  Upgrade dboot_conf_acpi to
 * extract the root-bridge _CRS and feed it here when moving off QEMU.
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
 */
typedef struct synth_gic {
	uint64_t	gicd;
	uint64_t	gicr;
	uint64_t	gicr_len;
	uint64_t	its;
	bool		have_gicd;
	bool		have_gicr;
	bool		have_its;
} synth_gic_t;

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
			if (!g->have_gicr) {
				uint64_t base;
				memcpy(&base, &c->GicrBaseAddress,
				    sizeof (base));
				if (base != 0) {
					g->gicr = base;
					g->gicr_len = 0x20000;
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

	u->base = base;
	u->irq = irq;
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

/* Emit a 2-cell (addr, size) reg property. */
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
	int necam;
	int nc;
	int rc;
	char name[32];

	synth_scan_madt(&gic);
	synth_scan_spcr(&uart);
	necam = synth_scan_mcfg(ecam, 8);

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
	(void) fdt_property_cell(fdt, "#redistributor-regions", 1);
	(void) fdt_property(fdt, "ranges", NULL, 0);
	(void) fdt_property_cell(fdt, "phandle", SYNTH_PHANDLE_GIC);
	{
		/* GICD (default 0x10000) and GICR windows. */
		fdt32_t reg[8];
		uint64_t gicd_len = 0x10000;
		reg[0] = cpu_to_fdt32((uint32_t)(gic.gicd >> 32));
		reg[1] = cpu_to_fdt32((uint32_t)(gic.gicd & 0xffffffff));
		reg[2] = cpu_to_fdt32((uint32_t)(gicd_len >> 32));
		reg[3] = cpu_to_fdt32((uint32_t)(gicd_len & 0xffffffff));
		reg[4] = cpu_to_fdt32((uint32_t)(gic.gicr >> 32));
		reg[5] = cpu_to_fdt32((uint32_t)(gic.gicr & 0xffffffff));
		reg[6] = cpu_to_fdt32((uint32_t)(gic.gicr_len >> 32));
		reg[7] = cpu_to_fdt32((uint32_t)(gic.gicr_len & 0xffffffff));
		(void) fdt_property(fdt, "reg", reg, sizeof (reg));
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
	 * binds the boot disk (virtio-blk-device).  ACPI has no table that
	 * describes these, so we emit the fixed QEMU-virt map; the illumos
	 * viommionex nexus binds `virtio,mmio' and probes each slot,
	 * ignoring the empty ones.  Without these the root virtio-blk disk
	 * never attaches and vfs_mountroot falls back to the ramdisk lofi.
	 *
	 * NOTE: QEMU-virt-fixed 32-slot window; real SBBR/Graviton has
	 * no virtio-mmio (boot disk is NVMe/virtio over PCIe).  Gate this on
	 * a QEMU-virt detection (or drop it) when moving to real hardware.
	 */
	{
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
				 * panics ("No ranges property") if absent.
				 */
				static const uint64_t rwin[3][4] = {
					/* space, child-addr, parent-addr, size */
					{ PCI_SPACE_IO,    0x00000000ULL,
					  0x3eff0000ULL,   0x00010000ULL },
					{ PCI_SPACE_MEM32, 0x10000000ULL,
					  0x10000000ULL,   0x2eff0000ULL },
					{ PCI_SPACE_MEM64, 0x8000000000ULL,
					  0x8000000000ULL, 0x8000000000ULL },
				};
				fdt32_t rg[3 * 7];
				int w;
				for (w = 0; w < 3; w++) {
					uint64_t ca = rwin[w][1];
					uint64_t pa = rwin[w][2];
					uint64_t sz = rwin[w][3];
					fdt32_t *e = &rg[w * 7];
					e[0] = cpu_to_fdt32(
					    (uint32_t)rwin[w][0]);
					e[1] = cpu_to_fdt32(
					    (uint32_t)(ca >> 32));
					e[2] = cpu_to_fdt32((uint32_t)ca);
					e[3] = cpu_to_fdt32(
					    (uint32_t)(pa >> 32));
					e[4] = cpu_to_fdt32((uint32_t)pa);
					e[5] = cpu_to_fdt32(
					    (uint32_t)(sz >> 32));
					e[6] = cpu_to_fdt32((uint32_t)sz);
				}
				(void) fdt_property(fdt, "ranges", rg,
				    sizeof (rg));
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

	nc = (int)bi->bi_cpuinfo_cnt;
	dboot_printf("dboot: synthesised FDT from ACPI (%d cpu%s, gicd=0x%lx "
	    "gicr=0x%lx%s, %d pcie rc)\n", nc, nc == 1 ? "" : "s",
	    (unsigned long)gic.gicd, (unsigned long)gic.gicr,
	    gic.have_its ? " +its" : "", necam);

	return ((uint64_t)(uintptr_t)synth_fdt);

fail:
	dboot_printf("dboot: synth FDT build failed: %s\n", fdt_strerror(rc));
	return (0);
}
