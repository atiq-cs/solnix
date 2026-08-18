/*
 * fdt.c -- R-P57: a minimal flattened-device-tree (FDT/DTB) parser.
 *
 * A single forward walk of the DTB struct block, no libfdt dependency, no
 * dynamic allocation.  It discovers the machine's REAL memory size, hart count,
 * and device MMIO bases (virtio-mmio / PLIC / CLINT) from the device tree the
 * firmware passes in a1 -- the values hardcoded for qemu-virt today.
 *
 * FDT binary layout (all header + token fields are BIG-ENDIAN):
 *
 *   fdt_header @ dtb:
 *     u32 magic            0xd00dfeed
 *     u32 totalsize
 *     u32 off_dt_struct    (byte offset of the struct block from dtb)
 *     u32 off_dt_strings   (byte offset of the strings block from dtb)
 *     u32 off_mem_rsvmap
 *     u32 version
 *     u32 last_comp_version
 *     u32 boot_cpuid_phys
 *     u32 size_dt_strings
 *     u32 size_dt_struct
 *
 *   struct block: a stream of 32-bit-aligned tokens:
 *     FDT_BEGIN_NODE(1)  followed by the NUL-terminated node name, padded to 4
 *     FDT_END_NODE(2)
 *     FDT_PROP(3)        u32 len, u32 nameoff (into strings), then len bytes
 *                        of value, padded to 4
 *     FDT_NOP(4)
 *     FDT_END(9)
 *
 *   Property names are NUL-terminated strings in the strings block at
 *   off_dt_strings + nameoff.
 *
 * We interpret a node by its (unit) name:
 *   "memory" / "memory@..."      -> "reg" = <base size> (address/size cells)
 *   "cpu@N" under "cpus"         -> count each enabled cpu node = hart count
 *   "virtio_mmio@..."            -> "reg" base = a virtio-mmio slot
 *   "plic@..."                   -> "reg" base = PLIC
 *   "clint@..." / "clint"        -> "reg" base = CLINT (machine timer/IPI)
 *
 * #address-cells / #size-cells default to 2/1 on the qemu-virt root but we read
 * the root's actual values so a board that declares 1/1 still parses.
 *
 * Crib: Devicetree Specification v0.4 sec 5 (flattened format) + the token
 * stream; libfdt fdt.h token constants + fdt_next_node walk idiom.
 */

#include "fdt.h"
#include "mmu_riscv.h"

/* public number/string printers exported by main.c (file-static putdec there) */
extern void sbi_console_puts(const char *s);
extern void putdec_pub(unsigned long v);
extern void puthex_pub(unsigned long v);

#define	FDT_MAGIC	0xd00dfeedU
#define	FDT_BEGIN_NODE	0x1U
#define	FDT_END_NODE	0x2U
#define	FDT_PROP	0x3U
#define	FDT_NOP		0x4U
#define	FDT_END		0x9U

static unsigned int
be32(const unsigned char *p)
{
	return ((unsigned int)p[0] << 24) | ((unsigned int)p[1] << 16) |
	    ((unsigned int)p[2] << 8) | (unsigned int)p[3];
}

/* read `cells` big-endian 32-bit words as one unsigned long (cells is 1 or 2). */
static unsigned long
be_cells(const unsigned char *p, unsigned int cells)
{
	unsigned long v = 0;
	unsigned int i;
	for (i = 0; i < cells; i++)
		v = (v << 32) | (unsigned long)be32(p + i * 4);
	return (v);
}

static int
streq(const char *a, const char *b)
{
	while (*a && *a == *b) { a++; b++; }
	return (*a == *b);
}

/* does name start with prefix (used to match "memory", "cpu@", "virtio_mmio@")? */
static int
startswith(const char *s, const char *pfx)
{
	while (*pfx) {
		if (*s != *pfx)
			return (0);
		s++; pfx++;
	}
	return (1);
}

int
fdt_discover(unsigned long dtb_pa, struct fdt_info *out)
{
	const unsigned char *dtb;
	const unsigned char *strs;
	const unsigned char *p, *end;
	unsigned int off_struct, off_strings, size_struct;
	unsigned int root_addr_cells = 2, root_size_cells = 1;
	/* depth tracking + the immediate parent's node name */
	int depth = 0;
	int in_cpus = 0;		/* depth-1 node "cpus" is open */
	char curname[64];		/* the node at the top of the walk */
	unsigned int i;

	for (i = 0; i < sizeof (struct fdt_info); i++)
		((unsigned char *)out)[i] = 0;
	out->fi_dtb_pa = dtb_pa;

	if (dtb_pa == 0)
		return (0);
	dtb = (const unsigned char *)(KERNEL_DMAP_BASE + dtb_pa);
	if (be32(dtb) != FDT_MAGIC)
		return (0);

	out->fi_totalsize = be32(dtb + 4);
	off_struct = be32(dtb + 8);
	off_strings = be32(dtb + 12);
	size_struct = be32(dtb + 36);
	strs = dtb + off_strings;
	p = dtb + off_struct;
	end = p + size_struct;
	curname[0] = 0;

	while (p + 4 <= end) {
		unsigned int tok = be32(p);
		p += 4;
		if (tok == FDT_NOP)
			continue;
		if (tok == FDT_END)
			break;
		if (tok == FDT_BEGIN_NODE) {
			const char *nm = (const char *)p;
			unsigned int len = 0;
			while (p + len < end && p[len] != 0)
				len++;
			/* remember this node's name (bounded copy) */
			for (i = 0; i < len && i < sizeof (curname) - 1; i++)
				curname[i] = nm[i];
			curname[i] = 0;
			p += len + 1;
			p = (const unsigned char *)(((unsigned long)p + 3) & ~3UL);
			depth++;
			if (depth == 2 && streq(curname, "cpus"))
				in_cpus = 1;
			/* count harts: a cpu@N node one level under /cpus */
			if (depth == 3 && in_cpus && startswith(curname, "cpu@"))
				out->fi_nharts++;
			continue;
		}
		if (tok == FDT_END_NODE) {
			if (depth == 2 && in_cpus)
				in_cpus = 0;
			if (depth > 0)
				depth--;
			curname[0] = 0;
			continue;
		}
		if (tok == FDT_PROP) {
			unsigned int plen = be32(p);
			unsigned int nameoff = be32(p + 4);
			const unsigned char *val = p + 8;
			const char *pname = (const char *)(strs + nameoff);
			/* root (depth 1) address/size cells govern reg decode */
			if (depth == 1 && streq(pname, "#address-cells"))
				root_addr_cells = be32(val);
			if (depth == 1 && streq(pname, "#size-cells"))
				root_size_cells = be32(val);
			if (streq(pname, "reg") && plen >= 8) {
				unsigned int ac = root_addr_cells;
				unsigned int sc = root_size_cells;
				unsigned long base = be_cells(val, ac);
				unsigned long size = be_cells(val + ac * 4, sc);
				if (startswith(curname, "memory") &&
				    out->fi_mem_size == 0) {
					out->fi_mem_base = base;
					out->fi_mem_size = size;
				} else if (startswith(curname, "virtio_mmio")) {
					out->fi_nvirtio++;
					if (out->fi_virtio_base == 0 ||
					    base < out->fi_virtio_base)
						out->fi_virtio_base = base;
				} else if (startswith(curname, "plic")) {
					out->fi_plic_base = base;
				} else if (startswith(curname, "clint")) {
					out->fi_clint_base = base;
				}
			}
			p = val + plen;
			p = (const unsigned char *)(((unsigned long)p + 3) & ~3UL);
			continue;
		}
		/* unknown token -- stop rather than run off the block */
		break;
	}

	out->fi_valid = 1;
	return (1);
}
