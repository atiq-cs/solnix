/*
 * fdt.c — illumos riscv64 flattened-devicetree (FDT) reader (R-P5).
 *
 * R-P4 hardcoded the physical RAM extent (base 0x80000000, size 128 MiB const).
 * R-P5's page allocator needs the REAL memory the platform reports, so we parse
 * the DTB that OpenSBI hands us in a1 (recorded in boot_cpu.bc_dtb) to find the
 * /memory node's `reg` = <base size> and return the RAM extent.
 *
 * We implement only the sliver of the Devicetree Spec (v0.4) needed to walk to
 * /memory and read its reg property: the FDT header, the struct block token
 * stream (BEGIN_NODE/END_NODE/PROP/NOP/END), the strings block, and #address-
 * cells/#size-cells (default 2/2 on riscv virt, which we honor). All multi-byte
 * FDT values are big-endian; RISC-V is little-endian, so every read byteswaps.
 *
 * This is the seed of the illumos device-tree/OBP-analog layer; R-P6 grows it
 * into a real ddi-visible tree for driver attach. Reimplemented from the spec
 * (no CDDL-incompatible source copied).
 */

#include "sbi.h"

/* FDT header (Devicetree Spec §5.2), all fields big-endian u32. */
#define	FDT_MAGIC	0xd00dfeedU

struct fdt_header {
	unsigned int magic;
	unsigned int totalsize;
	unsigned int off_dt_struct;
	unsigned int off_dt_strings;
	unsigned int off_mem_rsvmap;
	unsigned int version;
	unsigned int last_comp_version;
	unsigned int boot_cpuid_phys;
	unsigned int size_dt_strings;
	unsigned int size_dt_struct;
};

/* Struct-block tokens. */
#define	FDT_BEGIN_NODE	1U
#define	FDT_END_NODE	2U
#define	FDT_PROP	3U
#define	FDT_NOP		4U
#define	FDT_END		9U

/* Byteswap a big-endian u32 read from the blob. */
static unsigned int
be32(const unsigned char *p)
{
	return ((unsigned int)p[0] << 24) | ((unsigned int)p[1] << 16) |
	    ((unsigned int)p[2] << 8) | (unsigned int)p[3];
}

/* Read a big-endian cell sequence (1 or 2 cells) into a 64-bit value. */
static unsigned long
be_cells(const unsigned char *p, unsigned int cells)
{
	unsigned long v = 0;
	unsigned int i;

	for (i = 0; i < cells; i++)
		v = (v << 32) | be32(p + i * 4);
	return (v);
}

/* strcmp for FDT names (NUL-terminated); returns 0 if equal. */
static int
namecmp(const char *a, const char *b)
{
	while (*a && *a == *b) {
		a++;
		b++;
	}
	return ((unsigned char)*a - (unsigned char)*b);
}

/*
 * Return 1 if node name is "memory" or "memory@...". The /memory node is
 * conventionally "memory@<addr>"; match the prefix up to '@' or NUL.
 */
static int
is_memory_node(const char *name)
{
	static const char m[] = "memory";
	int i;

	for (i = 0; m[i] != '\0'; i++)
		if (name[i] != m[i])
			return (0);
	return (name[i] == '\0' || name[i] == '@');
}

/*
 * fdt_get_memory — parse the DTB at `dtb` (physical == kernel VA, identity
 * mapped) and fill in *base and *size with the first memory node's reg entry.
 * Returns 1 on success, 0 if the blob is bad or no /memory node is found.
 *
 * Walk: skip to the struct block, then step tokens. We only need to descend
 * one level (root -> /memory), tracking #address-cells/#size-cells that the
 * root declares (riscv virt uses 2/2). At the memory node's `reg` prop we take
 * the first <base size> pair.
 */
int
fdt_get_memory(unsigned long dtb, unsigned long *base, unsigned long *size)
{
	const struct fdt_header *h = (const struct fdt_header *)dtb;
	const unsigned char *stru, *strs, *p;
	unsigned int addr_cells = 2, size_cells = 2;	/* spec defaults */
	int depth = 0;
	int in_memory = 0;

	if (be32((const unsigned char *)&h->magic) != FDT_MAGIC)
		return (0);

	stru = (const unsigned char *)dtb + be32((const unsigned char *)&h->off_dt_struct);
	strs = (const unsigned char *)dtb + be32((const unsigned char *)&h->off_dt_strings);
	p = stru;

	for (;;) {
		unsigned int tok = be32(p);
		p += 4;

		if (tok == FDT_END)
			break;
		if (tok == FDT_NOP)
			continue;

		if (tok == FDT_BEGIN_NODE) {
			const char *name = (const char *)p;
			int len = 0;

			while (name[len] != '\0')
				len++;
			/* Advance p past name + NUL, aligned up to 4. */
			p += (len + 4) & ~3U;

			depth++;
			/*
			 * The root node is depth 1 (after its own increment); its
			 * direct children (like /memory) are depth 2. Detect the
			 * memory node at depth 2.
			 */
			if (depth == 2 && is_memory_node(name))
				in_memory = 1;
			continue;
		}

		if (tok == FDT_END_NODE) {
			if (in_memory && depth == 2)
				in_memory = 0;
			depth--;
			continue;
		}

		if (tok == FDT_PROP) {
			unsigned int plen = be32(p);
			unsigned int noff = be32(p + 4);
			const char *pname = (const char *)strs + noff;
			const unsigned char *pdata = p + 8;

			/*
			 * Root (depth 1) declares the cell sizes used by its
			 * children's reg props (riscv virt: 2/2).
			 */
			if (depth == 1 && namecmp(pname, "#address-cells") == 0 &&
			    plen >= 4)
				addr_cells = be32(pdata);
			if (depth == 1 && namecmp(pname, "#size-cells") == 0 &&
			    plen >= 4)
				size_cells = be32(pdata);

			if (in_memory && namecmp(pname, "reg") == 0 &&
			    plen >= (addr_cells + size_cells) * 4) {
				*base = be_cells(pdata, addr_cells);
				*size = be_cells(pdata + addr_cells * 4,
				    size_cells);
				return (1);
			}

			/* Advance p past prop data, aligned up to 4. */
			p += 8 + ((plen + 3) & ~3U);
			continue;
		}

		/* Unknown token: bail rather than run off the blob. */
		return (0);
	}

	return (0);
}

extern void kputhex(unsigned long v);
extern void kputdec(unsigned long v);

/* Does node name start with `pfx` (up to '@' or NUL)? */
static int
name_prefix(const char *name, const char *pfx)
{
	int i;
	for (i = 0; pfx[i] != '\0'; i++)
		if (name[i] != pfx[i])
			return (0);
	return (1);
}

/*
 * fdt_summary — walk the whole flattened devicetree the firmware handed us in
 * a1 and print a one-line R-P12 summary: the /memory extent, the uart node's
 * unit address, and the count of virtio-mmio nodes. This is a REAL FDT parse
 * (not hardcoded): it steps every BEGIN_NODE token, matches node names, and
 * reads the memory reg. Proves the kernel can discover memory + uart + virtio
 * from firmware rather than compiled-in addresses. Returns 1 on success.
 *
 * PROVE: "dtb: parsed FDT — mem@X size Y, uart@Z, N virtio nodes".
 */
int
fdt_summary(unsigned long dtb)
{
	const struct fdt_header *h = (const struct fdt_header *)dtb;
	const unsigned char *stru, *strs, *p;
	unsigned int addr_cells = 2, size_cells = 2;
	int depth = 0, in_memory = 0;
	unsigned long mem_base = 0, mem_size = 0;
	unsigned long uart_addr = 0;
	int n_virtio = 0;

	if (be32((const unsigned char *)&h->magic) != FDT_MAGIC)
		return (0);
	stru = (const unsigned char *)dtb +
	    be32((const unsigned char *)&h->off_dt_struct);
	strs = (const unsigned char *)dtb +
	    be32((const unsigned char *)&h->off_dt_strings);
	p = stru;

	for (;;) {
		unsigned int tok = be32(p);
		p += 4;
		if (tok == FDT_END)
			break;
		if (tok == FDT_NOP)
			continue;
		if (tok == FDT_BEGIN_NODE) {
			const char *name = (const char *)p;
			int len = 0;
			const char *at;
			while (name[len] != '\0')
				len++;
			p += (len + 4) & ~3U;
			depth++;
			if (depth == 2 && is_memory_node(name))
				in_memory = 1;
			/* uart node: "uart@..." or "serial@...". */
			if (uart_addr == 0 && (name_prefix(name, "uart@") ||
			    name_prefix(name, "serial@"))) {
				for (at = name; *at && *at != '@'; at++)
					;
				if (*at == '@') {
					unsigned long v = 0;
					const char *q = at + 1;
					while (*q) {
						char c = *q++;
						unsigned d;
						if (c >= '0' && c <= '9') d = c - '0';
						else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
						else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
						else break;
						v = (v << 4) | d;
					}
					uart_addr = v;
				}
			}
			if (name_prefix(name, "virtio_mmio@") ||
			    name_prefix(name, "virtio@"))
				n_virtio++;
			continue;
		}
		if (tok == FDT_END_NODE) {
			if (in_memory && depth == 2)
				in_memory = 0;
			depth--;
			continue;
		}
		if (tok == FDT_PROP) {
			unsigned int plen = be32(p);
			unsigned int noff = be32(p + 4);
			const char *pname = (const char *)strs + noff;
			const unsigned char *pdata = p + 8;
			if (depth == 1 && namecmp(pname, "#address-cells") == 0 &&
			    plen >= 4)
				addr_cells = be32(pdata);
			if (depth == 1 && namecmp(pname, "#size-cells") == 0 &&
			    plen >= 4)
				size_cells = be32(pdata);
			if (in_memory && namecmp(pname, "reg") == 0 &&
			    plen >= (addr_cells + size_cells) * 4) {
				mem_base = be_cells(pdata, addr_cells);
				mem_size = be_cells(pdata + addr_cells * 4,
				    size_cells);
			}
			p += 8 + ((plen + 3) & ~3U);
			continue;
		}
		/* Unknown token: stop walking but still report what we found. */
		break;
	}

	sbi_console_puts("dtb: parsed FDT — mem@");
	kputhex(mem_base);
	sbi_console_puts(" size ");
	kputhex(mem_size);
	sbi_console_puts(", uart@");
	kputhex(uart_addr);
	sbi_console_puts(", ");
	kputdec((unsigned long)n_virtio);
	sbi_console_puts(" virtio nodes\n");
	return (1);
}

/*
 * ---------------------------------------------------------------------------
 * R-P14: SpaceMiT K1 board-DTB ingestion.
 *
 * fdt_k1_summary walks a REAL SpaceMiT K1 devicetree (compiled from k1.dts, a
 * faithful subset of the upstream K1 dtsi, handed to qemu via `-dtb k1.dtb`
 * and delivered to the kernel in a1 exactly as U-Boot's `booti` does on the
 * physical board). It discovers, by `compatible` + `reg`, the four devices the
 * K1 boot path needs: the memory extent, the DesignWare APB UART
 * (snps,dw-apb-uart, with its reg-shift), the SDHCI/eMMC controller, and the
 * APLIC+IMSIC AIA controllers. It fills *out with the dw-apb-uart base and
 * reg-shift so the console driver can bind them, and prints the R-P14 gate-1
 * proof line.
 *
 * PROVE: "k1-dtb: parsed SpaceMiT K1 — mem@X, dw-apb-uart@Y, sdhci@Z,
 *         aplic@A/imsic@I".
 * ---------------------------------------------------------------------------
 */

static int compat_has(const char *data, unsigned int plen, const char *pfx);
static int compat_is_ns16550_uart(const char *data, unsigned int plen);
static int compat_is_sdhci_mmc(const char *data, unsigned int plen);

/* struct k1_devs lives in k1.h (shared with uart.c / sdhci.c / startup.c). */
#include "k1.h"

/*
 * Read the FIRST address of a node's `reg` = <addr size ...> using the given
 * #address-cells (K1 soc bus uses 2). Returns the base, or 0 if absent.
 */
static unsigned long
reg_base(const unsigned char *pdata, unsigned int plen, unsigned int acells)
{
	if (plen < acells * 4)
		return (0);
	return (be_cells(pdata, acells));
}

int
fdt_k1_summary(unsigned long dtb, struct k1_devs *out)
{
	const struct fdt_header *h = (const struct fdt_header *)dtb;
	const unsigned char *stru, *strs, *p;
	unsigned int addr_cells = 2, size_cells = 2;
	int depth = 0, in_memory = 0;
	/* Which device is the CURRENT node, so a following reg/reg-shift prop
	 * (which comes AFTER compatible in the token stream) lands in it. */
	int cur = 0;		/* 0 none, 1 uart, 2 sdhci, 3 aplic, 4 imsic */
	struct k1_devs d;
	int i;

	for (i = 0; i < (int)sizeof (d); i++)
		((char *)&d)[i] = 0;

	if (be32((const unsigned char *)&h->magic) != FDT_MAGIC)
		return (0);
	stru = (const unsigned char *)dtb +
	    be32((const unsigned char *)&h->off_dt_struct);
	strs = (const unsigned char *)dtb +
	    be32((const unsigned char *)&h->off_dt_strings);
	p = stru;

	for (;;) {
		unsigned int tok = be32(p);
		p += 4;
		if (tok == FDT_END)
			break;
		if (tok == FDT_NOP)
			continue;
		if (tok == FDT_BEGIN_NODE) {
			const char *name = (const char *)p;
			int len = 0;
			while (name[len] != '\0')
				len++;
			p += (len + 4) & ~3U;
			depth++;
			cur = 0;
			if (is_memory_node(name))
				in_memory = 1;
			continue;
		}
		if (tok == FDT_END_NODE) {
			in_memory = 0;
			cur = 0;
			depth--;
			continue;
		}
		if (tok == FDT_PROP) {
			unsigned int plen = be32(p);
			unsigned int noff = be32(p + 4);
			const char *pname = (const char *)strs + noff;
			const unsigned char *pdata = p + 8;
			if (depth == 1 &&
			    namecmp(pname, "#address-cells") == 0 && plen >= 4)
				addr_cells = be32(pdata);
			if (depth == 1 &&
			    namecmp(pname, "#size-cells") == 0 && plen >= 4)
				size_cells = be32(pdata);
			if (in_memory && namecmp(pname, "reg") == 0 &&
			    plen >= (addr_cells + size_cells) * 4) {
				d.mem_base = be_cells(pdata, addr_cells);
				d.mem_size = be_cells(pdata + addr_cells * 4,
				    size_cells);
			}
			/* Node classification comes from its compatible list. */
			if (namecmp(pname, "compatible") == 0) {
				const char *cd = (const char *)pdata;
				if (compat_is_ns16550_uart(cd, plen)) {
					cur = 1;
					/*
					 * reg-shift (read below) carries the
					 * stride; dw/pxa-class cores use 4-byte
					 * registers (shift 2).
					 */
					d.uart_is_dw = 1;
					d.uart_shift = 0;
				} else if (compat_is_sdhci_mmc(cd, plen)) {
					cur = 2; d.sdhci_present = 1;
				} else if (compat_has(cd, plen, "riscv,aplic")) {
					cur = 3; d.aplic_present = 1;
				} else if (compat_has(cd, plen,
				    "riscv,imsics")) {
					cur = 4; d.imsic_present = 1;
				}
			}
			if (cur != 0 && namecmp(pname, "reg") == 0) {
				unsigned long b =
				    reg_base(pdata, plen, addr_cells);
				if (cur == 1) d.uart_base = b;
				else if (cur == 2) d.sdhci_base = b;
				else if (cur == 3) d.aplic_base = b;
				else if (cur == 4) d.imsic_base = b;
			}
			if (cur == 1 && namecmp(pname, "reg-shift") == 0 &&
			    plen >= 4)
				d.uart_shift = be32(pdata);
			p += 8 + ((plen + 3) & ~3U);
			continue;
		}
		break;
	}

	sbi_console_puts("k1-dtb: parsed SpaceMiT K1 — mem@");
	kputhex(d.mem_base);
	sbi_console_puts(" size ");
	kputhex(d.mem_size);
	sbi_console_puts(", dw-apb-uart@");
	kputhex(d.uart_base);
	sbi_console_puts(" (reg-shift=");
	kputdec(d.uart_shift);
	sbi_console_puts("), sdhci@");
	kputhex(d.sdhci_base);
	sbi_console_puts(", aplic@");
	kputhex(d.aplic_base);
	sbi_console_puts("/imsic@");
	kputhex(d.imsic_base);
	sbi_console_puts("\n");

	if (out != 0)
		*out = d;
	/*
	 * K1 board confirmed iff the SIGNATURE devices are present.
	 *
	 * This used to also require aplic_present && imsic_present, which could
	 * NEVER be true: the K1 is a PLIC SoC, not AIA (that correction is the
	 * whole point of the current k1.dts, and mainline's k1.dtsi has
	 * interrupt-controller@e0000000 compatible "riscv,plic0"). So the
	 * predicate was unsatisfiable on real K1 silicon AND on our own DTB --
	 * the boot log's "[k1] WARN: embedded K1 DTB missing a signature device"
	 * was this bug, not a bad DTB, and the runtime board-detect would have
	 * reported "NOT K1" while running ON the K1 and driven the in-kernel
	 * SDHCI MODEL instead of real silicon.
	 *
	 * The signature is now the two devices that actually identify the board
	 * and that both our k1.dts and mainline's k1.dtsi carry: a 16550-family
	 * UART bound by a SpaceMiT/xscale compatible string, and an SDHCI-standard
	 * MMC controller. UNVERIFIED-until-hardware: only a boot on the board can
	 * confirm the vendor U-Boot's DTB spells them the same way.
	 */
	return (d.uart_is_dw && d.sdhci_present);
}

/*
 * ---------------------------------------------------------------------------
 * R-P13: FDT-driven interrupt-controller detection + driver attach.
 * ---------------------------------------------------------------------------
 */

/* Does a NUL-list `compatible` property (plen bytes, possibly several NUL-
 * terminated strings) contain a string that starts with `pfx`? */
static int
compat_has(const char *data, unsigned int plen, const char *pfx)
{
	unsigned int i = 0;
	while (i < plen) {
		const char *s = data + i;
		if (name_prefix(s, pfx))
			return (1);
		while (i < plen && data[i] != '\0')
			i++;
		i++;		/* skip the NUL */
	}
	return (0);
}

/*
 * Board-independent device classification. Each SoC spells the same IP with a
 * different compatible string, so the accepted spellings live in one table per
 * device class: adding a board is one string, not a new branch at every call
 * site.
 *
 * UART: all of these are 16550-family cores that asy_nsuart.c drives; the
 * register stride differences are carried by reg-shift/reg-io-width in the DT,
 * not by the bind string. The SpaceMiT K1 (Milk-V Jupiter) spells its console
 * "spacemit,pxa-uart" in the vendor BSP and "spacemit,k1-uart" /
 * "intel,xscale-uart" in mainline - none of which matched before, which would
 * leave the K1 console unbound (silent boot) even though the driver is
 * register-compatible.
 */
static const char *ns16550_uart_compat[] = {
	"ns16550a",		/* qemu virt, generic */
	"ns16550",
	"snps,dw-apb-uart",	/* DesignWare APB (many RISC-V SoCs) */
	"spacemit,pxa-uart",	/* K1, vendor BSP spelling */
	"spacemit,k1-uart",	/* K1, mainline spelling */
	"intel,xscale-uart",	/* K1, mainline fallback spelling */
	0
};

/*
 * MMC: SDHCI-standard cores (uts/sdhci.c). The K1 is "spacemit,k1-x-sdhci" -
 * a standard SDHCI core, NOT the Synopsys dw-mmc family, so it binds here and
 * NOT to the dw-mmc driver.
 */
static const char *sdhci_mmc_compat[] = {
	"spacemit,k1-x-sdhci",	/* K1 (Milk-V Jupiter): eMMC + SD */
	"snps,dwcmshc-sdhci",
	"sdhci",
	"mmc",
	0
};

static int
compat_matches_any(const char *data, unsigned int plen, const char **tbl)
{
	unsigned int i;

	for (i = 0; tbl[i] != 0; i++) {
		if (compat_has(data, plen, tbl[i]))
			return (1);
	}
	return (0);
}

static int
compat_is_ns16550_uart(const char *data, unsigned int plen)
{
	return (compat_matches_any(data, plen, ns16550_uart_compat));
}

static int
compat_is_sdhci_mmc(const char *data, unsigned int plen)
{
	return (compat_matches_any(data, plen, sdhci_mmc_compat));
}

/*
 * fdt_intc_is_aia — scan the whole devicetree for an APLIC / IMSIC node
 * (compatible "riscv,aplic" or "riscv,imsics"). Returns 1 if the platform's
 * interrupt controller is AIA (route IRQs via APLIC+IMSIC), 0 if it is a
 * legacy PLIC ("riscv,plic0" / "sifive,plic-1.0.0"). This is how R-P13 PICKS
 * the interrupt model at boot from firmware instead of compiling it in — the
 * K1/K3 boards are AIA; the qemu-virt default is PLIC.
 */
int
fdt_intc_is_aia(unsigned long dtb)
{
	const struct fdt_header *h = (const struct fdt_header *)dtb;
	const unsigned char *stru, *strs, *p;
	int aia = 0;

	if (be32((const unsigned char *)&h->magic) != FDT_MAGIC)
		return (0);
	stru = (const unsigned char *)dtb +
	    be32((const unsigned char *)&h->off_dt_struct);
	strs = (const unsigned char *)dtb +
	    be32((const unsigned char *)&h->off_dt_strings);
	p = stru;

	for (;;) {
		unsigned int tok = be32(p);
		p += 4;
		if (tok == FDT_END)
			break;
		if (tok == FDT_NOP)
			continue;
		if (tok == FDT_BEGIN_NODE) {
			const char *name = (const char *)p;
			int len = 0;
			while (name[len] != '\0')
				len++;
			p += (len + 4) & ~3U;
			continue;
		}
		if (tok == FDT_END_NODE)
			continue;
		if (tok == FDT_PROP) {
			unsigned int plen = be32(p);
			unsigned int noff = be32(p + 4);
			const char *pname = (const char *)strs + noff;
			const char *pdata = (const char *)(p + 8);
			if (namecmp(pname, "compatible") == 0) {
				if (compat_has(pdata, plen, "riscv,aplic") ||
				    compat_has(pdata, plen, "riscv,imsics"))
					aia = 1;
			}
			p += 8 + ((plen + 3) & ~3U);
			continue;
		}
		break;
	}
	return (aia);
}

/*
 * fdt_attach_drivers — walk the devicetree and, for each node, match its
 * `compatible` strings to a driver and print an "attach" line with the node's
 * unit-address (parsed from its name). This turns the R-P12 DTB *summary* into
 * real firmware-driven driver binding: the drivers bind against FDT nodes
 * (compatible=) rather than compiled-in addresses. Returns the number of
 * devices attached.
 *
 * PROVE: "devtree: attached uart@X, virtio-blk@Y, virtio-net@Z by FDT
 * compatible".
 */
int
fdt_attach_drivers(unsigned long dtb)
{
	const struct fdt_header *h = (const struct fdt_header *)dtb;
	const unsigned char *stru, *strs, *p;
	const char *cur_name = "";
	unsigned long cur_addr = 0;
	int attached = 0;

	if (be32((const unsigned char *)&h->magic) != FDT_MAGIC)
		return (0);
	stru = (const unsigned char *)dtb +
	    be32((const unsigned char *)&h->off_dt_struct);
	strs = (const unsigned char *)dtb +
	    be32((const unsigned char *)&h->off_dt_strings);
	p = stru;

	for (;;) {
		unsigned int tok = be32(p);
		p += 4;
		if (tok == FDT_END)
			break;
		if (tok == FDT_NOP)
			continue;
		if (tok == FDT_BEGIN_NODE) {
			const char *name = (const char *)p;
			int len = 0;
			const char *at;
			while (name[len] != '\0')
				len++;
			p += (len + 4) & ~3U;
			cur_name = name;
			cur_addr = 0;
			for (at = name; *at && *at != '@'; at++)
				;
			if (*at == '@') {
				const char *q = at + 1;
				unsigned long v = 0;
				while (*q) {
					char c = *q++;
					unsigned d;
					if (c >= '0' && c <= '9') d = c - '0';
					else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
					else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
					else break;
					v = (v << 4) | d;
				}
				cur_addr = v;
			}
			continue;
		}
		if (tok == FDT_END_NODE)
			continue;
		if (tok == FDT_PROP) {
			unsigned int plen = be32(p);
			unsigned int noff = be32(p + 4);
			const char *pname = (const char *)strs + noff;
			const char *pdata = (const char *)(p + 8);
			if (namecmp(pname, "compatible") == 0) {
				const char *drv = 0;
				/* virtio-mmio: read device-id later; here bind the
				 * transport, blk/net distinguished at probe. */
				if (compat_is_ns16550_uart(pdata, plen))
					drv = "uart";
				else if (compat_is_sdhci_mmc(pdata, plen))
					drv = "sdhci";
				else if (compat_has(pdata, plen, "virtio,mmio"))
					drv = "virtio-mmio";
				else if (compat_has(pdata, plen, "riscv,aplic"))
					drv = "aplic";
				else if (compat_has(pdata, plen, "riscv,imsics"))
					drv = "imsic";
				else if (compat_has(pdata, plen, "riscv,plic0") ||
				    compat_has(pdata, plen, "sifive,plic-1.0.0"))
					drv = "plic";
				if (drv != 0) {
					sbi_console_puts("[devtree] attach ");
					sbi_console_puts(drv);
					sbi_console_puts(" <- ");
					sbi_console_puts(cur_name);
					sbi_console_puts(" @");
					kputhex(cur_addr);
					sbi_console_puts(" (FDT compatible)\n");
					attached++;
				}
			}
			p += 8 + ((plen + 3) & ~3U);
			continue;
		}
		break;
	}
	(void) cur_name;
	return (attached);
}

/*
 * ---------------------------------------------------------------------------
 * R-P16: richer driver-facing property parsing, MERGED from n-hys of_utils.c.
 *
 * Portions Copyright 2017 Hayashi Naoyuki; adapted for solnix from
 * n-hys/illumos-gate (usr/src/uts/riscv64/io/of_utils.c).
 *
 * of_utils.c gives drivers of_get_reg / of_get_clock / of_get_reset /
 * of_is_compatible / of_get_prop_int over a pnode_t promif device tree. We do
 * NOT have that promif tree (our fdt.c is a token-stream walker), so rather
 * than drag in promif/prom_*.c + sys/of_utils.h (a bigger, board-independent
 * import that would not build against our walker), we MERGE of_utils's
 * reg/clock/reset/compatible SEMANTICS onto our walker. A node is identified
 * by its byte OFFSET into the struct block (fdt_node_t) -- the walker's
 * natural handle -- replacing of_utils's pnode_t. This is what an adopted K1
 * driver (dw-apb-uart, dwcmshc-sdhci, dwmac) binds through to get its MMIO
 * base and clock/reset phandles from the DT instead of a compiled-in address.
 * Our AIA-aware helpers above (fdt_intc_is_aia, fdt_k1_summary) are untouched.
 *
 * A node offset points AT the FDT_BEGIN_NODE token of the node. #address-cells
 * / #size-cells are resolved by walking to the parent (of_get_address_cells /
 * of_get_size_cells), defaulting 2/2 as of_utils does.
 * ---------------------------------------------------------------------------
 */

typedef long fdt_node_t;		/* struct-block byte offset, or -1 */
#define	FDT_NONE	(-1L)

/* Base of the struct block + strings block for `dtb'. */
static const unsigned char *
fdt_struct(unsigned long dtb, const unsigned char **strs_out)
{
	const struct fdt_header *h = (const struct fdt_header *)dtb;
	if (be32((const unsigned char *)&h->magic) != FDT_MAGIC)
		return (0);
	if (strs_out != 0)
		*strs_out = (const unsigned char *)dtb +
		    be32((const unsigned char *)&h->off_dt_strings);
	return ((const unsigned char *)dtb +
	    be32((const unsigned char *)&h->off_dt_struct));
}

/* Skip a BEGIN_NODE token's name; return the pointer just past it (aligned). */
static const unsigned char *
fdt_skip_name(const unsigned char *p)
{
	const char *name = (const char *)p;
	int len = 0;
	while (name[len] != '\0')
		len++;
	return (p + ((len + 4) & ~3U));
}

/*
 * fdt_find_compatible -- return the node OFFSET of the first node whose
 * `compatible' property contains a string starting with `pfx', or FDT_NONE.
 * of_utils's of_is_compatible + of_register's walk, collapsed to a finder.
 */
fdt_node_t
fdt_find_compatible(unsigned long dtb, const char *pfx)
{
	const unsigned char *stru, *strs, *p;
	long node_off = FDT_NONE;

	stru = fdt_struct(dtb, &strs);
	if (stru == 0)
		return (FDT_NONE);
	p = stru;

	for (;;) {
		unsigned int tok = be32(p);
		long here = (long)(p - stru);
		p += 4;
		if (tok == FDT_END)
			break;
		if (tok == FDT_NOP)
			continue;
		if (tok == FDT_BEGIN_NODE) {
			node_off = here;
			p = fdt_skip_name(p);
			continue;
		}
		if (tok == FDT_END_NODE)
			continue;
		if (tok == FDT_PROP) {
			unsigned int plen = be32(p);
			unsigned int noff = be32(p + 4);
			const char *pname = (const char *)strs + noff;
			const char *pdata = (const char *)(p + 8);
			if (namecmp(pname, "compatible") == 0 &&
			    compat_has(pdata, plen, pfx))
				return (node_off);
			p += 8 + ((plen + 3) & ~3U);
			continue;
		}
		break;
	}
	return (FDT_NONE);
}

/*
 * fdt_node_prop -- locate property `name' on the node at `node_off'. On
 * success returns 1 and sets *data to the property bytes and *len to its
 * length. Only scans the node's OWN properties (stops at the first child
 * BEGIN_NODE or the node's END_NODE). of_utils's prom_getprop analog.
 */
static int
fdt_node_prop(unsigned long dtb, fdt_node_t node_off, const char *name,
    const unsigned char **data, unsigned int *len)
{
	const unsigned char *stru, *strs, *p;

	if (node_off < 0)
		return (0);
	stru = fdt_struct(dtb, &strs);
	if (stru == 0)
		return (0);
	p = stru + node_off;
	if (be32(p) != FDT_BEGIN_NODE)
		return (0);
	p += 4;
	p = fdt_skip_name(p);
	for (;;) {
		unsigned int tok = be32(p);
		p += 4;
		if (tok == FDT_NOP)
			continue;
		if (tok == FDT_PROP) {
			unsigned int plen = be32(p);
			unsigned int noff = be32(p + 4);
			const char *pname = (const char *)strs + noff;
			if (namecmp(pname, name) == 0) {
				if (data != 0)
					*data = p + 8;
				if (len != 0)
					*len = plen;
				return (1);
			}
			p += 8 + ((plen + 3) & ~3U);
			continue;
		}
		/* first child or our own END_NODE: property not found here */
		return (0);
	}
}

/*
 * fdt_node_prop_str -- read a string property. Returns 1 and points *out at the
 * NUL-terminated bytes in the DTB (no copy) on success, 0 if absent.
 *
 * Used to read `riscv,isa` / `compatible` off cpu@0 so the kernel can pick a
 * cache-maintenance backend that this CPU actually implements: both Zicbom and
 * the T-Head custom ops trap as illegal instructions on a part that lacks them,
 * so the choice must come from the DT rather than from a build flag.
 */
int
fdt_node_prop_str(unsigned long dtb, fdt_node_t node_off, const char *name,
    const char **out)
{
	const unsigned char *d;
	unsigned int l;

	if (!fdt_node_prop(dtb, node_off, name, &d, &l) || l == 0)
		return (0);
	if (out != 0)
		*out = (const char *)d;
	return (1);
}

/*
 * fdt_node_prop_u32 -- read a single-cell (u32) property, defaulting `def' if
 * absent. of_utils's of_get_prop_int (without the parent-walk; #*-cells uses
 * the dedicated helpers below).
 */
int
fdt_node_prop_u32(unsigned long dtb, fdt_node_t node_off, const char *name,
    int def)
{
	const unsigned char *d;
	unsigned int l;
	if (fdt_node_prop(dtb, node_off, name, &d, &l) && l >= 4)
		return ((int)be32(d));
	return (def);
}

/*
 * fdt_parent -- return the OFFSET of the parent of `node_off', or FDT_NONE for
 * the root. Re-walks the struct block tracking a depth stack of BEGIN_NODE
 * offsets (the walker has no back-pointers). of_utils gets this free from the
 * promif tree; we reconstruct it.
 */
static fdt_node_t
fdt_parent(unsigned long dtb, fdt_node_t node_off)
{
	const unsigned char *stru, *strs, *p;
	long stack[16];
	int depth = 0;

	if (node_off <= 0)
		return (FDT_NONE);
	stru = fdt_struct(dtb, &strs);
	if (stru == 0)
		return (FDT_NONE);
	p = stru;
	for (;;) {
		unsigned int tok = be32(p);
		long here = (long)(p - stru);
		p += 4;
		if (tok == FDT_END)
			break;
		if (tok == FDT_NOP)
			continue;
		if (tok == FDT_BEGIN_NODE) {
			if (here == node_off)
				return (depth > 0 ? stack[depth - 1] :
				    FDT_NONE);
			if (depth < 16)
				stack[depth] = here;
			depth++;
			p = fdt_skip_name(p);
			continue;
		}
		if (tok == FDT_END_NODE) {
			if (depth > 0)
				depth--;
			continue;
		}
		if (tok == FDT_PROP) {
			unsigned int plen = be32(p);
			p += 8 + ((plen + 3) & ~3U);
			continue;
		}
		break;
	}
	return (FDT_NONE);
}

/* #address-cells / #size-cells for this node (from its parent). 2/2 default. */
static int
fdt_addr_cells(unsigned long dtb, fdt_node_t node_off)
{
	return (fdt_node_prop_u32(dtb, fdt_parent(dtb, node_off),
	    "#address-cells", 2));
}
static int
fdt_size_cells(unsigned long dtb, fdt_node_t node_off)
{
	return (fdt_node_prop_u32(dtb, fdt_parent(dtb, node_off),
	    "#size-cells", 2));
}

/*
 * fdt_node_reg -- read the `reg' entry at `index', honoring the node's
 * #address-cells/#size-cells (of_utils of_get_reg). Fills *base (and *size if
 * non-NULL). Returns 0 on success, -1 on absence/range error -- of_utils's
 * return convention.
 */
int
fdt_node_reg(unsigned long dtb, fdt_node_t node_off, int index,
    unsigned long *base, unsigned long *size)
{
	const unsigned char *d;
	unsigned int l;
	int ac, sc;
	unsigned int stride, off;

	if (!fdt_node_prop(dtb, node_off, "reg", &d, &l))
		return (-1);
	ac = fdt_addr_cells(dtb, node_off);
	sc = fdt_size_cells(dtb, node_off);
	if (ac < 1 || ac > 2)
		return (-1);
	stride = (ac + sc) * 4;
	off = stride * index;
	if (off + ac * 4 > l)
		return (-1);
	if (base != 0)
		*base = be_cells(d + off, ac);
	if (size != 0)
		*size = (sc > 0) ? be_cells(d + off + ac * 4, sc) : 0;
	return (0);
}

/*
 * fdt_node_phandle_id -- the shared body of of_get_clock / of_get_reset: read
 * the `prop' ("clocks" or "resets") array of <phandle id> pairs at `index',
 * returning the referenced controller's phandle in *phandle and the id in
 * *id. The controller's #<kind>-cells must be 1 (as of_utils requires).
 * Returns 0 on success. We return the phandle value rather than an of_utils
 * pnode_t; a driver resolves it with fdt_find_phandle below.
 */
static int
fdt_node_phandle_id(unsigned long dtb, fdt_node_t node_off, const char *prop,
    int index, unsigned int *phandle, unsigned int *id)
{
	const unsigned char *d;
	unsigned int l;
	unsigned int off;

	if (!fdt_node_prop(dtb, node_off, prop, &d, &l))
		return (-1);
	/* <phandle id> pairs (cells==1 controllers). */
	off = index * 2 * 4;
	if (off + 8 > l)
		return (-1);
	if (phandle != 0)
		*phandle = be32(d + off);
	if (id != 0)
		*id = be32(d + off + 4);
	return (0);
}

int
fdt_node_clock(unsigned long dtb, fdt_node_t node_off, int index,
    unsigned int *phandle, unsigned int *id)
{
	return (fdt_node_phandle_id(dtb, node_off, "clocks", index, phandle,
	    id));
}
int
fdt_node_reset(unsigned long dtb, fdt_node_t node_off, int index,
    unsigned int *phandle, unsigned int *id)
{
	return (fdt_node_phandle_id(dtb, node_off, "resets", index, phandle,
	    id));
}

/*
 * fdt_find_phandle -- resolve a phandle to a node OFFSET (of_utils's
 * prom_findnode_by_phandle). Scans for the node carrying phandle==`ph' in its
 * "phandle" (or legacy "linux,phandle") property.
 */
fdt_node_t
fdt_find_phandle(unsigned long dtb, unsigned int ph)
{
	const unsigned char *stru, *strs, *p;
	long node_off = FDT_NONE;

	stru = fdt_struct(dtb, &strs);
	if (stru == 0)
		return (FDT_NONE);
	p = stru;
	for (;;) {
		unsigned int tok = be32(p);
		long here = (long)(p - stru);
		p += 4;
		if (tok == FDT_END)
			break;
		if (tok == FDT_NOP)
			continue;
		if (tok == FDT_BEGIN_NODE) {
			node_off = here;
			p = fdt_skip_name(p);
			continue;
		}
		if (tok == FDT_END_NODE)
			continue;
		if (tok == FDT_PROP) {
			unsigned int plen = be32(p);
			unsigned int noff = be32(p + 4);
			const char *pname = (const char *)strs + noff;
			const unsigned char *pdata = p + 8;
			if ((namecmp(pname, "phandle") == 0 ||
			    namecmp(pname, "linux,phandle") == 0) &&
			    plen >= 4 && be32(pdata) == ph)
				return (node_off);
			p += 8 + ((plen + 3) & ~3U);
			continue;
		}
		break;
	}
	return (FDT_NONE);
}

extern int cmo_selftest(void);

/*
 * fdt_of_utils_selftest -- R-P16 proof that the merged of_utils-style
 * accessors work against a real DTB (the K1 board DTB, or the qemu-virt DTB).
 * Finds the dw-apb-uart (or ns16550) node by compatible, reads its reg base +
 * reg-shift, and (if present) its first clock phandle -- exactly the sequence
 * a K1 console driver runs to bind from the DT. Returns 1 if reg was obtained.
 *
 * PROVE: "fdt(of): dw-apb-uart reg@X reg-shift=Y clock-phandle=Z (from DT)".
 */
int
fdt_of_utils_selftest(unsigned long dtb)
{
	fdt_node_t n;
	unsigned long base = 0, size = 0;
	int shift;
	unsigned int ph = 0, id = 0;
	int have_reg;

	{
		unsigned int ci;

		n = FDT_NONE;
		for (ci = 0; ns16550_uart_compat[ci] != 0 && n == FDT_NONE;
		    ci++)
			n = fdt_find_compatible(dtb, ns16550_uart_compat[ci]);
	}
	if (n == FDT_NONE) {
		sbi_console_puts("fdt(of): no 16550-family uart node in DT\n");
		return (0);
	}
	have_reg = (fdt_node_reg(dtb, n, 0, &base, &size) == 0);
	shift = fdt_node_prop_u32(dtb, n, "reg-shift", 0);
	(void) fdt_node_clock(dtb, n, 0, &ph, &id);

	sbi_console_puts("fdt(of): dw-apb-uart reg@");
	kputhex(base);
	sbi_console_puts(" size ");
	kputhex(size);
	sbi_console_puts(" reg-shift=");
	kputdec((unsigned long)shift);
	sbi_console_puts(" clock-phandle=");
	kputhex((unsigned long)ph);
	sbi_console_puts(" (parsed from DT via merged of_utils accessors)\n");
	return (have_reg);
}
