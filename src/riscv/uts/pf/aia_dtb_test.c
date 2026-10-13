/*
 * aia_dtb_test.c -- host-side negative-controlled proof of the DTB-driven AIA
 * fix (R-P17). Compiles the REAL fdt.c (fdt_k1_summary) and asserts that the
 * K3 boot DTB yields the K3 controller bases + UART IRQ that aia_configure()
 * will adopt -- NOT the compiled-in qemu-virt fallbacks.
 *
 *   k3.dtb -> imsic@0xe0400000, aplic@0xe0804000, uart@0xd4017000, irq 42
 *
 * Negative control: a qemu-virt DTB must yield DIFFERENT bases (the qemu ones),
 * proving the parse is reading the DTB, not returning a constant. If given only
 * k3.dtb we still assert the K3 values != the qemu fallbacks, which fails if
 * someone reverts to a hardcode.
 *
 * Build/run on the board:
 *   cc -I.. pf/aia_dtb_test.c -o /tmp/adt && /tmp/adt k3.dtb [virt.dtb]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

void sbi_console_puts(const char *s) { (void) s; }
void kputhex(unsigned long v) { (void) v; }
void kputdec(unsigned long v) { (void) v; }

#include "../fdt.c"

/* The qemu-virt fallbacks aia.c keeps -- the K3 DTB must NOT match these. */
#define QEMU_IMSIC 0x28000000UL
#define QEMU_APLIC 0x0d000000UL
#define QEMU_UART  0x10000000UL
#define QEMU_IRQ   10UL

static void *
load(const char *path)
{
	FILE *f = fopen(path, "rb");
	if (!f) { perror(path); exit(2); }
	fseek(f, 0, SEEK_END);
	long n = ftell(f);
	fseek(f, 0, SEEK_SET);
	void *buf = malloc((size_t)n);
	if (fread(buf, 1, (size_t)n, f) != (size_t)n) { perror("read"); exit(2); }
	fclose(f);
	return (buf);
}

int
main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: %s k3.dtb [virt.dtb]\n", argv[0]);
		return (2);
	}
	struct k1_devs k3;
	void *b = load(argv[1]);
	(void) fdt_k1_summary((unsigned long)b, &k3);

	printf("k3.dtb -> imsic@0x%lx aplic@0x%lx uart@0x%lx irq %lu "
	    "(shift=%u io32=%d)\n", k3.imsic_base, k3.aplic_base, k3.uart_base,
	    k3.uart_irq, k3.uart_shift, k3.uart_io32);

	/* The real K3 bases the fix must deliver to aia_configure. */
	assert(k3.imsic_base == 0xe0400000UL && "K3 IMSIC base from DTB");
	assert(k3.aplic_base == 0xe0804000UL && "K3 APLIC base from DTB");
	assert(k3.uart_base  == 0xd4017000UL && "K3 UART base from DTB");
	assert(k3.uart_irq   == 42UL         && "K3 UART IRQ from DTB");
	assert(k3.uart_shift == 2            && "K3 UART reg-shift from DTB");
	assert(k3.uart_io32  == 1            && "K3 UART 32-bit MMIO from DTB");

	/* Negative control: the K3 values are NOT the qemu fallbacks (so a
	 * revert to a hardcode would flip this to FAIL). */
	assert(k3.imsic_base != QEMU_IMSIC && k3.aplic_base != QEMU_APLIC &&
	    k3.uart_base != QEMU_UART && k3.uart_irq != QEMU_IRQ &&
	    "K3 DTB must differ from the qemu-virt fallbacks");

	if (argc >= 3) {
		struct k1_devs v;
		void *vb = load(argv[2]);
		(void) fdt_k1_summary((unsigned long)vb, &v);
		printf("virt.dtb -> imsic@0x%lx aplic@0x%lx uart@0x%lx irq %lu\n",
		    v.imsic_base, v.aplic_base, v.uart_base, v.uart_irq);
		/* Different DTB => different bases: proves the parse reads the
		 * blob, not a constant. */
		assert((v.uart_base != k3.uart_base ||
		    v.imsic_base != k3.imsic_base) &&
		    "two DTBs must yield different bases (parse, not constant)");
	}

	printf("PASS: fdt_k1_summary yields the K3 AIA bases + UART IRQ that "
	    "aia_configure adopts (DTB-driven, not hardcoded)\n");
	return (0);
}
