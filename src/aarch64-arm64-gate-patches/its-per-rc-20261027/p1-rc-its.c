/* BEGIN synth_rc_its */
/*
 * The ITS a root complex's MSIs reach, as an index into g->its_base[], or -1
 * when the IORT gives no usable path (the caller keeps the default ITS).  The
 * MADT order says nothing about it.  c6g.metal: segment 0 goes through the
 * SMMUv3 at 0xbcfde00000 to ITS id 0, while the last MADT translator is id 3,
 * and MSI-X sent to id 3 is never delivered (measured, aa64c).  c6gd.metal:
 * the instance-store root complex is segment 2, routed to ITS id 2; its MSI-X
 * sent to ITS 0 is lost the same way (measured, aa64g).
 */
static int
synth_rc_its(const synth_gic_t *g, uint32_t seg)
{
	const ACPI_TABLE_HEADER *iort = synth_find_table(ACPI_SIG_IORT);
	uint32_t len, id, k;

	if (iort == NULL)
		return (-1);
	memcpy(&len, &iort->Length, sizeof (len));
	if (!synth_iort_pci_its_id((const uint8_t *)iort, len, seg, &id))
		return (-1);
	for (k = 0; k < g->nits; k++) {
		if (g->its_id[k] == id)
			return ((int)k);
	}
	return (-1);
}
/* END synth_rc_its */

/* The default ITS (its@ with SYNTH_PHANDLE_ITS) is segment 0's. */
static void
synth_pick_pci_its(synth_gic_t *g)
{
	int k = synth_rc_its(g, 0);

	if (k >= 0)
		g->its = g->its_base[k];
}

static void
synth_emit_its(void *fdt, uint64_t base, uint32_t phandle)
{
	char name[32];

	synth_nodename(name, sizeof (name), "its", base);
	(void) fdt_begin_node(fdt, name);
	(void) fdt_property_string(fdt, "compatible", "arm,gic-v3-its");
	(void) fdt_property(fdt, "msi-controller", NULL, 0);
	(void) fdt_property_cell(fdt, "#msi-cells", 1);
	(void) fdt_property_cell(fdt, "phandle", phandle);
	(void) prop_reg2(fdt, base, 0x20000);
	(void) fdt_end_node(fdt);
}

