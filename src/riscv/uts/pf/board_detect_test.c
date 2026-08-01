/*
 * board_detect_test.c -- R-P16 host-side unit check for the RUNTIME board
 * detector. It compiles the REAL fdt.c (fdt_k1_summary) natively with tiny
 * console stubs and asserts the exact decision startup.c makes at boot:
 *
 *   real SpaceMiT K1 boot DTB (k1.dtb)  -> fdt_k1_summary() == 1  (live MMIO)
 *   qemu-virt boot DTB       (virt.dtb) -> fdt_k1_summary() == 0  (model)
 *
 * This is the branch the in-qemu boot cannot exercise (a pure-K1 DTB hangs
 * OpenSBI on qemu -- wrong RAM base), so it is proven here instead. The SAME
 * fdt_k1_summary that startup.c calls decides the platform, so a pass here is
 * a pass for the board-detect logic that flips sdhci to live K1 MMIO.
 *
 * Build/run:
 *   cc -DBOARD_DETECT_HOST_TEST -I.. board_detect_test.c -o /tmp/bdt \
 *      && /tmp/bdt ../k1.dtb /tmp/virt.dtb
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

/* Console stubs so fdt.c links without the kernel SBI console. */
void sbi_console_puts(const char *s) { (void) s; }
void kputhex(unsigned long v) { (void) v; }
void kputdec(unsigned long v) { (void) v; }

/*
 * fdt.c pulls in "sbi.h" (pure prototypes) and "k1.h" (pure prototypes). Our
 * stubs above provide the console definitions; the FDT walk itself is
 * freestanding C, so include the real fdt.c directly and test it as-is.
 */
#include "../fdt.c"

static void *
load(const char *path)
{
	FILE *f = fopen(path, "rb");
	if (!f) { perror(path); exit(2); }
	fseek(f, 0, SEEK_END);
	long n = ftell(f);
	fseek(f, 0, SEEK_SET);
	/* FDT is big-endian on disk; fdt_k1_summary reads it in place. */
	void *buf = malloc((size_t)n);
	if (fread(buf, 1, (size_t)n, f) != (size_t)n) { perror("read"); exit(2); }
	fclose(f);
	return (buf);
}

int
main(int argc, char **argv)
{
	if (argc != 3) {
		fprintf(stderr, "usage: %s k1.dtb virt.dtb\n", argv[0]);
		return (2);
	}
	void *k1 = load(argv[1]);
	void *virt = load(argv[2]);
	struct k1_devs dk1, dv;

	int r_k1 = fdt_k1_summary((unsigned long)k1, &dk1);
	int r_virt = fdt_k1_summary((unsigned long)virt, &dv);

	printf("k1.dtb   -> fdt_k1_summary = %d  (sdhci@0x%lx uart@0x%lx)\n",
	    r_k1, dk1.sdhci_base, dk1.uart_base);
	printf("virt.dtb -> fdt_k1_summary = %d  (sdhci@0x%lx uart@0x%lx)\n",
	    r_virt, dv.sdhci_base, dv.uart_base);

	/* The board-detect contract startup.c relies on: */
	assert(r_k1 == 1 && "real K1 DTB must detect as K1 (-> live MMIO)");
	assert(dk1.sdhci_base != 0 && "K1 detect must yield a real sdhci base");
	assert(r_virt == 0 && "qemu-virt DTB must NOT detect as K1 (-> model)");

	printf("PASS: runtime board-detect distinguishes K1 vs qemu-virt "
	    "(K1->live MMIO, virt->model)\n");
	return (0);
}
