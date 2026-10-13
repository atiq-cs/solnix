/*
 * k3pwm.c — SpacemiT K3 PWM scaffold (compatible "spacemit,k1-pwm",
 * "marvell,pxa910-pwm"; 21 instances d401a000..). The PXA910 PWM is a tiny
 * register block: PWMCR (control/prescale), PWMDCR (duty), PWMPCR (period).
 * Crib: Linux drivers/pwm/pwm-pxa.c. Compile+bind deliverable: discover the
 * first controller's reg base; a live duty-cycle set is the on-silicon TODO.
 */

#include "sbi.h"

extern void kputhex(unsigned long v);

typedef long fdt_node_t;
#define	FDT_NONE	(-1L)
extern fdt_node_t fdt_find_compatible(unsigned long dtb, const char *pfx);
extern int fdt_node_reg(unsigned long dtb, fdt_node_t n, int i,
    unsigned long *base, unsigned long *size);

int
k3pwm_probe(unsigned long dtb, int live)
{
	fdt_node_t n = fdt_find_compatible(dtb, "spacemit,k1-pwm");
	unsigned long base = 0, size = 0;

	if (n == FDT_NONE)
		n = fdt_find_compatible(dtb, "marvell,pxa910-pwm");
	if (n == FDT_NONE || fdt_node_reg(dtb, n, 0, &base, &size) != 0) {
		sbi_console_puts("[k3pwm] no pwm node in boot DTB\n");
		return (0);
	}
	(void) live;
	sbi_console_puts("[k3pwm] pxa910-pwm @");
	kputhex(base);
	sbi_console_puts(" bound. ON-SILICON TODO: clk, PWMCR/PWMDCR/PWMPCR "
	    "duty+period set.\n");
	return (1);
}
