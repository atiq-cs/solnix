/*
 * k3rtc.c — SpacemiT K3 RTC scaffold. Two RTCs in the DT:
 *   rtc@d4010000 "mrvl,mmp-rtc"  (Marvell MMP RTC: RCNR count, RTAR alarm)
 *   rpmi_rtc     "riscv,rpmi-rtc" (RTC behind the RPMI mailbox/firmware)
 * Crib: Linux drivers/rtc/rtc-mmp.c. Compile+bind deliverable: discover the
 * mmp-rtc reg; a live RCNR read (seconds counter) is the on-silicon TODO.
 */

#include "sbi.h"

extern void kputhex(unsigned long v);

typedef long fdt_node_t;
#define	FDT_NONE	(-1L)
extern fdt_node_t fdt_find_compatible(unsigned long dtb, const char *pfx);
extern int fdt_node_reg(unsigned long dtb, fdt_node_t n, int i,
    unsigned long *base, unsigned long *size);

#define	MMP_RTC_RCNR	0x00	/* running counter (seconds) */

int
k3rtc_probe(unsigned long dtb, int live)
{
	fdt_node_t n = fdt_find_compatible(dtb, "mrvl,mmp-rtc");
	unsigned long base = 0, size = 0;

	if (n == FDT_NONE || fdt_node_reg(dtb, n, 0, &base, &size) != 0) {
		if (fdt_find_compatible(dtb, "riscv,rpmi-rtc") != FDT_NONE) {
			sbi_console_puts("[k3rtc] riscv,rpmi-rtc present "
			    "(RTC via RPMI mailbox — needs mailbox driver)\n");
			return (1);
		}
		sbi_console_puts("[k3rtc] no rtc node in boot DTB\n");
		return (0);
	}
	sbi_console_puts("[k3rtc] mmp-rtc @");
	kputhex(base);
	if (live) {
		unsigned int rcnr = *(volatile unsigned int *)(base +
		    MMP_RTC_RCNR);
		sbi_console_puts(" RCNR=");
		kputhex(rcnr);
	}
	sbi_console_puts(" bound. ON-SILICON TODO: read/set RCNR, alarm "
	    "(RTAR).\n");
	return (1);
}
