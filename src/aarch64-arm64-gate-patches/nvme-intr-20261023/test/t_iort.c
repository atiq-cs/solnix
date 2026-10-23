/* host unit test for synth_iort_pci_its_id (the walk compiled verbatim from the patched dboot_synth_fdt.c) */
#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <stdlib.h>
#define ACPI_IORT_NODE_ITS_GROUP 0
#define ACPI_IORT_NODE_PCI_ROOT_COMPLEX 2
#define ACPI_IORT_ID_SINGLE_MAPPING 1
#include "iort_walk.inc"
static uint8_t buf[4096];
static int fails;
static void chk(const char *what, bool got, uint32_t id, bool wok, uint32_t wid) {
	int ok = (got == wok) && (!got || id == wid);
	printf("%s %s: got=%d id=%u (want %d %u)\n", ok ? "PASS" : "FAIL", what, got, got ? id : 0, wok, wid);
	fails += !ok;
}
int main(void) { setvbuf(stdout, NULL, _IONBF, 0);
	FILE *f = fopen("iort-metal.bin", "rb"); if (f == NULL) { perror("iort-metal.bin"); return 2; } size_t n = fread(buf, 1, sizeof buf, f); fclose(f);
	uint32_t id = 99; bool r;
	r = synth_iort_pci_its_id(buf, n, 0, &id); chk("metal IORT seg 0 -> ITS id", r, id, true, 0);
	r = synth_iort_pci_its_id(buf, n, 1, &id); chk("metal IORT seg 1 (absent)", r, id, false, 0);
	/* negative control: repoint the RC's map at SMMU @0x198 -> group @0x78 (id 3); the answer must flip */
	uint8_t b2[4096]; memcpy(b2, buf, n); uint32_t ref = 0x198; memcpy(b2 + 0x1f0 + 0x24 + 12, &ref, 4);
	r = synth_iort_pci_its_id(b2, n, 0, &id); chk("NEG: RC repointed to SMMU bf -> id 3", r, id, true, 3);
	memcpy(b2, buf, n); b2[0] = 'X';
	r = synth_iort_pci_its_id(b2, n, 0, &id); chk("NEG: bad signature", r, id, false, 0);
	r = synth_iort_pci_its_id(buf, 0x1f0, 0, &id); chk("NEG: truncated before RC", r, id, false, 0);
	memcpy(b2, buf, n); uint32_t loop = 0x1f0; memcpy(b2 + 0x1f0 + 0x24 + 12, &loop, 4);
	r = synth_iort_pci_its_id(b2, n, 0, &id); chk("NEG: self-referencing RC (loop bound)", r, id, false, 0);
	printf("%s\n", fails ? "T_IORT_FAIL" : "T_IORT_ALL_PASS");
	return fails != 0;
}
