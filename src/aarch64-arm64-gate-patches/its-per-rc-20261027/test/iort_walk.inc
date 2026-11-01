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
