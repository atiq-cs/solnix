/*
 * t_rcits.c: host unit test for the per-root-complex ITS choice in dboot_synth_fdt.c.
 * rcits.inc = synth_iort_pci_its_id + synth_rc_its, extracted verbatim from the PATCHED
 * file by run.sh.  IORTs: iort-dixa.bin (c6gd.metal, from dixa's messages.0, 608 B) and
 * iort-metal-measured.bin (c6g.metal, aa64c, 552 B).  MADT translators are the Graviton2
 * ones: id k at 0xbc00040000 + k * 0x100000000 (a6pcie-c6gmetal-firmware-tables.txt).
 * OLDCODE=1 builds the aa64g-before rule (every RC gets segment 0's ITS): negative control.
 */
#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#define	ACPI_IORT_NODE_ITS_GROUP 0
#define	ACPI_IORT_NODE_PCI_ROOT_COMPLEX 2
#define	ACPI_IORT_ID_SINGLE_MAPPING 1
#define	ACPI_SIG_IORT "IORT"
#define	SYNTH_ITS_MAX 8
typedef struct { char Signature[4]; uint32_t Length; } ACPI_TABLE_HEADER;
typedef struct { uint32_t its_id[SYNTH_ITS_MAX]; uint64_t its_base[SYNTH_ITS_MAX]; uint32_t nits; } synth_gic_t;
static uint8_t tab[4096];
static const ACPI_TABLE_HEADER *synth_find_table(const char *s) { (void)s; return ((const ACPI_TABLE_HEADER *)tab); }
#include "iort_walk.inc"
#include "rcits.inc"
#ifdef OLDCODE
#define	PICK(g, seg) synth_rc_its((g), 0)
#else
#define	PICK(g, seg) synth_rc_its((g), (seg))
#endif
static int fails;
static void load(const char *f) {
	FILE *fp = fopen(f, "rb");
	if (fp == NULL) { perror(f); fails++; return; }
	memset(tab, 0, sizeof (tab)); (void) fread(tab, 1, sizeof (tab), fp); fclose(fp);
}
static void chk(const char *what, const synth_gic_t *g, uint32_t seg, int want_id) {
	int k = PICK(g, seg), got = k < 0 ? -1 : (int)g->its_id[k];
	int ok = got == want_id;
	printf("%s %s: seg %u -> ITS %d (want %d)%s\n", ok ? "PASS" : "FAIL", what, seg, got, want_id,
	    k < 0 ? "" : "");
	fails += !ok;
}
int main(void) {
	synth_gic_t g = { .nits = 4 };
	for (uint32_t k = 0; k < 4; k++) { g.its_id[k] = k; g.its_base[k] = 0xbc00040000ULL + ((uint64_t)k << 32); }
	load("iort-dixa.bin");
	chk("c6gd dixa", &g, 0, 0);
	chk("c6gd dixa", &g, 2, 2);
	chk("c6gd dixa absent seg", &g, 1, -1);
	load("iort-metal-measured.bin");
	chk("c6g metal", &g, 0, 0);
	chk("c6g metal absent seg", &g, 2, -1);
	tab[0] = 'X';
	chk("bad signature", &g, 0, -1);
	printf("%s\n", fails ? "T_RCITS_FAIL" : "T_RCITS_ALL_PASS");
	return (fails != 0);
}
