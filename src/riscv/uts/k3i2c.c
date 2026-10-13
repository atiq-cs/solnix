/*
 * k3i2c.c — solnix riscv64 driver for the SpacemiT K3 I2C controllers
 * (compatible "spacemit,k1-i2c"; 8 instances d4010800..d401d800).
 *
 * The K1/K3 I2C IP is the Marvell/PXA (MMP) TWSI controller — the same core
 * Linux drives with i2c-pxa.c and that the vendor BSP spells "spacemit,k1-i2c".
 * It is a simple register-mapped master: ICR (control), ISR (status), IDBR
 * (data buffer), ILCR/IWCR (bus timing). It is NOT a DesignWare I2C.
 *
 * Crib: Linux drivers/i2c/busses/i2c-pxa.c (register model), NetBSD has no
 * exact PXA-TWSI master but the MI iic(4) framework is the illumos i2c_svc
 * analog. Reimplemented from the register spec; no CDDL-incompatible source
 * copied.
 *
 * This is the compile+bind deliverable: discover each enabled controller's
 * reg/irq/clock-frequency and report it. A live single-byte transfer
 * (START/addr/ACK/STOP) is the on-silicon TODO — the K3 has an onsemi
 * fusb301 Type-C controller and sensors on these buses to talk to.
 */

#include "sbi.h"

extern void kputhex(unsigned long v);
extern void kputdec(unsigned long v);

typedef long fdt_node_t;
#define	FDT_NONE	(-1L)
extern fdt_node_t fdt_find_compatible(unsigned long dtb, const char *pfx);
extern int fdt_node_reg(unsigned long dtb, fdt_node_t n, int i,
    unsigned long *base, unsigned long *size);
extern int fdt_node_prop_u32(unsigned long dtb, fdt_node_t n, const char *name,
    int def);

/* Marvell/PXA TWSI register offsets (byte offsets into the 0x38-byte block). */
#define	PXA_IBMR	0x00	/* bus monitor */
#define	PXA_IDBR	0x08	/* data buffer */
#define	PXA_ICR		0x10	/* control */
#define	PXA_ISR		0x18	/* status */
#define	PXA_ISAR	0x20	/* slave address */

int
k3i2c_probe(unsigned long dtb, int live)
{
	fdt_node_t n;
	unsigned long base = 0, size = 0;
	int freq;

	/*
	 * fdt_find_compatible returns the FIRST matching node; the K3 has 8 I2C
	 * controllers but most are `disabled`. We report the first bound one as
	 * the representative; a full enumeration walks all compatibles, which is
	 * the same loop extended once the bus layer exists (on-silicon TODO).
	 */
	n = fdt_find_compatible(dtb, "spacemit,k1-i2c");
	if (n == FDT_NONE) {
		sbi_console_puts("[k3i2c] no spacemit,k1-i2c node in boot DTB\n");
		return (0);
	}
	if (fdt_node_reg(dtb, n, 0, &base, &size) != 0) {
		sbi_console_puts("[k3i2c] i2c node has no usable reg\n");
		return (0);
	}
	freq = fdt_node_prop_u32(dtb, n, "clock-frequency", 0);

	sbi_console_puts("[k3i2c] pxa-twsi @");
	kputhex(base);
	sbi_console_puts(" irq ");
	kputdec((unsigned long)fdt_node_prop_u32(dtb, n, "interrupts", -1));
	sbi_console_puts(" bus-freq ");
	kputdec((unsigned long)freq);
	sbi_console_puts(" Hz\n");

	if (live) {
		/* ISR read is a harmless status peek proving the block maps. */
		unsigned int isr = *(volatile unsigned int *)(base + PXA_ISR);
		sbi_console_puts("[k3i2c]   ISR=");
		kputhex(isr);
		sbi_console_puts("\n");
	}
	(void) PXA_IBMR; (void) PXA_IDBR; (void) PXA_ICR; (void) PXA_ISAR;

	sbi_console_puts("[k3i2c] bound. ON-SILICON TODO: clk+reset, "
	    "START/addr/ACK/STOP single-byte xfer, enumerate all 8 buses "
	    "(fusb301 Type-C, sensors).\n");
	return (1);
}
