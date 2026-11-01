#!/usr/bin/env python3
# p2-console-uart.py <gate> : the console output path after consconfig (aa64g).
# After prom_io_use_kernel() every prom/cmn_err character goes to sysp_putchar(), which drops it
# when wc has no polled putchar (CONS_FW: there is no tem on this platform), and wcuwsrv() frees
# all userland console text for the same reason (measured aa64e: |D| / |W| echoes).  Give both a
# polled putchar on the boot (SPCR) UART: the same PL011 boot_uart_putchar() drives before
# consconfig, through a kernel device mapping made in prom_io_use_kernel() (the boot identity
# mapping of the UART goes away in release_bootstrap()).  Only used when no other polled output
# exists, so a real console driver (tem, asy) still wins.
import sys
G = sys.argv[1] + '/usr/src/uts/'

def edit(path, fn):
    s = open(G + path).read(); t = fn(s)
    assert t != s, path; open(G + path, 'w').write(t)

def rep(s, a, b, n=1):
    assert s.count(a) == n, (a[:60], s.count(a))
    return s.replace(a, b)

UART = r'''
/*
 * Console output after consconfig() when nothing else provides polled output (no tem, no
 * console tty driver): the boot UART, written as boot_uart_putchar() does (PL011 TXFF poll,
 * bounded; no TXFE drain).  The PA is the SPCR UART dboot handed to the kernel.
 */
uint64_t sysp_uart_pa;			/* set by bop_init() */
static volatile uint32_t *sysp_uart;	/* kernel VA, set by prom_io_use_kernel() */

static void
sysp_uart_putchar(int c)
{
	volatile uint32_t *u = sysp_uart;
	uint32_t cap;

	if (u == NULL)
		return;
	if ((c & 0xff) == '\n')
		sysp_uart_putchar('\r');
	for (cap = 0; (u[0x18 / 4] & (1u << 5)) != 0 && cap < 10000u; cap++)
		__asm__ volatile("yield":::"memory");
	u[0] = (uint32_t)(c & 0xff);
}
'''

def machdep(s):
    s = rep(s, '\nstatic int\nsysp_getchar(void)\n', UART + '\nstatic int\nsysp_getchar(void)\n')
    s = rep(s, '\t/*\n\t * We have no alternative but to drop the output on the floor.\n\t */\n'
            '\tif (cons_polledio == NULL ||\n\t    cons_polledio->cons_polledio_putchar == NULL)\n\t\treturn;\n',
            '\tif (cons_polledio == NULL ||\n\t    cons_polledio->cons_polledio_putchar == NULL) {\n'
            '\t\ts = disable_interrupts();\n\t\tsysp_uart_putchar(c);\n'
            '\t\trestore_interrupts(s);\n\t\treturn;\n\t}\n')
    s = rep(s, 'prom_io_use_kernel(void)\n{\n\tsysp = &kern_sysp;\n',
            'prom_io_use_kernel(void)\n{\n\tif (sysp_uart_pa != 0 && sysp_uart == NULL)\n'
            '\t\tsysp_uart = (volatile uint32_t *)psm_map_phys(sysp_uart_pa,\n'
            '\t\t    0x1000, PROT_READ | PROT_WRITE);\n\tsysp = &kern_sysp;\n')
    return rep(s, '#include <c2/audit.h>\n', '#include <c2/audit.h>\n#include <sys/mman.h>\n')
edit('armv8/os/machdep.c', machdep)

def fakebop(s):
    return rep(s, '\tbsvc_init(xbp);\n',
               '\tbsvc_init(xbp);\n\t{\n\t\textern uint64_t sysp_uart_pa;\t/* machdep.c */\n\n'
               '\t\tif (xbp != NULL)\n\t\t\tsysp_uart_pa = xbp->bi_bsvc_uart_mmio_base;\n\t}\n')
edit('armv8/os/fakebop.c', fakebop)
print('p2 machdep+fakebop OK')
