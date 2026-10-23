#!/usr/bin/env python3
# aa64c-iort-its.py <gate> : the synth FDT's ITS node follows the IORT route of PCI segment 0 instead of the last MADT translator.
import sys
P = sys.argv[1] + '/usr/src/uts/armv8/dboot/dboot_synth_fdt.c'
s = open(P).read()

def rep(a, b):
    global s
    assert s.count(a) == 1, a[:60]
    s = s.replace(a, b, 1)

# 1. remember every MADT translator (id, base), not only the last one.
rep('\tuint64_t\tits;\n\tuint32_t\tngicc;',
    '\tuint64_t\tits;\n'
    '\tuint32_t\tits_id[SYNTH_ITS_MAX];\t/* MADT GIC ITS TranslationId */\n'
    '\tuint64_t\tits_base[SYNTH_ITS_MAX];\n'
    '\tuint32_t\tnits;\n'
    '\tuint32_t\tngicc;')
rep('typedef struct synth_gic {', '#define\tSYNTH_ITS_MAX\t8\n\ntypedef struct synth_gic {')
rep('\t\t\tmemcpy(&base, &t->BaseAddress, sizeof (base));\n\t\t\tg->its = base;\n',
    '\t\t\tmemcpy(&base, &t->BaseAddress, sizeof (base));\n'
    '\t\t\tif (g->nits < SYNTH_ITS_MAX) {\n'
    '\t\t\t\tmemcpy(&g->its_id[g->nits], &t->TranslationId,\n'
    '\t\t\t\t    sizeof (g->its_id[0]));\n'
    '\t\t\t\tg->its_base[g->nits++] = base;\n'
    '\t\t\t}\n'
    '\t\t\tg->its = base;\n')

# 2. the IORT walk (pure: bytes in, ITS id out) and the selection.
WALK = r'''
/* BEGIN synth_iort_pci_its_id */
static uint32_t
synth_rd32(const uint8_t *t, uint32_t o)
{
	uint32_t v;
	memcpy(&v, t + o, sizeof (v));
	return (v);
}

/*
 * Follow the IORT from the PCI root complex of segment `seg` to the ITS
 * group its MSIs go to, through any SMMU in between, and return the first
 * ITS identifier of that group in *idp.  Raw offsets (ARM DEN 0049):
 * node = type u8 @0, length u16 @1, mapping count @8, mapping offset @12,
 * node data @16; root complex segment @16+12; ITS group count @16, ids @20;
 * ID mapping = in @0, count @4, out @8, output reference @12, flags @16.
 *
 * shortcut: the ID offsets of each hop are not composed into msi-map; the
 * c6g.metal IORT maps RID -> StreamID -> DeviceID with identity at both hops
 * (measured), so msi-map stays 0 -> 0.  Compose them when a platform has an
 * offset.
 */
static bool
synth_iort_pci_its_id(const uint8_t *t, uint32_t len, uint32_t seg,
    uint32_t *idp)
{
	uint32_t n, o, i, hop, ref = 0;

	if (len < 48 || memcmp(t, "IORT", 4) != 0)
		return (false);
	n = synth_rd32(t, 36);
	o = synth_rd32(t, 40);
	for (i = 0; i < n && o + 32 <= len; i++) {
		uint16_t nl;
		memcpy(&nl, t + o + 1, sizeof (nl));
		if (t[o] == ACPI_IORT_NODE_PCI_ROOT_COMPLEX &&
		    synth_rd32(t, o + 28) == seg) {
			ref = o;
			break;
		}
		if (nl == 0)
			return (false);
		o += nl;
	}
	if (ref == 0)
		return (false);

	for (hop = 0; hop < 4; hop++) {
		uint32_t nmap, moff, m;

		if (ref + 24 > len)
			return (false);
		if (t[ref] == ACPI_IORT_NODE_ITS_GROUP) {
			if (synth_rd32(t, ref + 16) == 0)
				return (false);
			*idp = synth_rd32(t, ref + 20);
			return (true);
		}
		nmap = synth_rd32(t, ref + 8);
		moff = synth_rd32(t, ref + 12);
		/* the first range mapping; single mappings are the node's own */
		for (m = 0; m < nmap; m++) {
			uint32_t e = ref + moff + 20 * m;
			if (e + 20 > len)
				return (false);
			if ((synth_rd32(t, e + 16) &
			    ACPI_IORT_ID_SINGLE_MAPPING) == 0)
				break;
		}
		if (m == nmap)
			return (false);
		ref = synth_rd32(t, ref + moff + 20 * m + 12);
	}
	return (false);
}
/* END synth_iort_pci_its_id */

/*
 * With several ITSes the MADT order says nothing about which one PCIe MSIs
 * reach: on c6g.metal the IORT routes segment 0 through the SMMUv3 at
 * 0xbcfde00000 to ITS id 0 (0xbc00040000), while the last MADT translator
 * is id 3 (0xbf00040000), and MSI-X written there is never delivered
 * (measured: nvme's admin completion sits in the CQ, no interrupt).  Use the
 * IORT's choice; keep the old last-wins pick when there is no usable IORT.
 */
static void
synth_pick_pci_its(synth_gic_t *g)
{
	const ACPI_TABLE_HEADER *iort = synth_find_table(ACPI_SIG_IORT);
	uint32_t len, id, k;

	if (iort == NULL)
		return;
	memcpy(&len, &iort->Length, sizeof (len));
	if (!synth_iort_pci_its_id((const uint8_t *)iort, len, 0, &id))
		return;
	for (k = 0; k < g->nits; k++) {
		if (g->its_id[k] == id) {
			g->its = g->its_base[k];
			return;
		}
	}
}
'''
rep('\nstatic int\nprop_interrupt(void *fdt,', WALK + '\nstatic int\nprop_interrupt(void *fdt,')
rep('\tsynth_scan_madt(&gic);\n', '\tsynth_scan_madt(&gic);\n\tsynth_pick_pci_its(&gic);\n')
open(P, 'w').write(s)
print('IORT_ITS_OK')
