#!/usr/bin/env python3
# p12-uart-16550.py <gate> : aa64vm.  The Graviton SPCR says InterfaceType 0 (16550, byte registers), and the device is one:
# measured on c6g.large, 8-bit reads at the SPCR base give 16550 state (LSR 0x60) and a 32-bit read of +0x18 (PL011 FR)
# gives 0xffffffff.  dboot forced PL011 for OEM AMAZON, so every console character paid the 10000-poll TXFF cap
# (~3 us per trapped read on a VM = ~30 ms/char).  Keep the SPCR's type: add XBI_BSVC_UART_NS16550 (= SPCR 0) and drive
# it as a 16550 (THR +0, LSR +5, byte access, reg-shift 0) in boot_uart.c and in the post-consconfig sysp_uart_putchar.
import sys
G = sys.argv[1] + '/usr/src/uts/'

def edit(path, pairs):
    s = open(G + path).read()
    if 'p12' in s:
        print('p12 already applied', path); return
    for a, b in pairs:
        assert s.count(a) == 1, (path, a[:50], s.count(a)); s = s.replace(a, b)
    open(G + path, 'w').write(s); print('p12 ok', path)

edit('aarch64/sys/bootinfo.h', [(
    '\tXBI_BSVC_UART_NONE\t= 0x0,\n',
    '\tXBI_BSVC_UART_NONE\t= 0x0,\n\tXBI_BSVC_UART_NS16550\t= 0x0100,\t/* p12: SPCR type 0, byte regs */\n')])

edit('armv8/boot/boot_uart.c', [
 ('#define\tSBSA_UARTFR_RXFE\t\t(1 << 4)\n',
  '#define\tSBSA_UARTFR_RXFE\t\t(1 << 4)\n\n/* p12: 16550 (SPCR type 0), byte-wide registers, reg-shift 0 */\n'
  '#define\tNS_LSR\t\t\t\t5\n#define\tNS_LSR_DR\t\t\t(1 << 0)\n#define\tNS_LSR_THRE\t\t\t(1 << 5)\n'
  '#define\tNS_REG(r)\t(*(volatile uint8_t *)(boot_uart_mmio_base + (r)))\n'),
 ('\tif (boot_uart_mmio_base == NULL)\n\t\treturn (0);\n\n\treturn (!(boot_uart_readreg32(SBSA_UARTFR) & SBSA_UARTFR_RXFE));\n',
  '\tif (boot_uart_mmio_base == NULL)\n\t\treturn (0);\n\n\tif (boot_uart_type == XBI_BSVC_UART_NS16550)\n\t\treturn ((NS_REG(NS_LSR) & NS_LSR_DR) != 0);\n\n'
  '\treturn (!(boot_uart_readreg32(SBSA_UARTFR) & SBSA_UARTFR_RXFE));\n'),
 ('\treturn (boot_uart_readreg32(SBSA_UARTDR) & 0xff);\n',
  '\tif (boot_uart_type == XBI_BSVC_UART_NS16550)\n\t\treturn (NS_REG(0));\n\n\treturn (boot_uart_readreg32(SBSA_UARTDR) & 0xff);\n'),
 ('\tif (boot_uart_mmio_base == NULL)\n\t\treturn;\n\n\t/*\n\t * Wait for space, bounded.',
  '\tif (boot_uart_mmio_base == NULL)\n\t\treturn;\n\n\tif (boot_uart_type == XBI_BSVC_UART_NS16550) {\n'
  '\t\tfor (cap = 0; !(NS_REG(NS_LSR) & NS_LSR_THRE) && cap < 10000u; cap++)\n\t\t\tboot_uart_yield();\n'
  "\t\tif ((c & 0xff) == '\\n')\n\t\t\tboot_uart_putchar('\\r');\n\t\tNS_REG(0) = (uint8_t)c;\n\t\treturn;\n\t}\n\n"
  '\t/*\n\t * Wait for space, bounded.'),
])
s = open(G + 'armv8/boot/boot_uart.c').read()
import re
if 'case XBI_BSVC_UART_NS16550' not in s:
    s2, n = re.subn(r'(\t+)case XBI_BSVC_UART_PL011:\t/\* fallthrough \*/\n',
                    lambda m: m.group(1) + 'case XBI_BSVC_UART_NS16550:\t/* fallthrough */\n' + m.group(0), s)
    assert n == 2, n
    open(G + 'armv8/boot/boot_uart.c', 'w').write(s2)

# dboot: keep a 16550 SPCR as a 16550 (was forced to PL011 for OEM AMAZON); hand it to the boot UART as NS16550.
edit('armv8/dboot/dboot_synth_fdt.c', [
 ('\tuint8_t\t\tiface;\t\t/* raw SPCR/DBG2 InterfaceType */\n',
  '\tuint8_t\t\tiface;\t\t/* raw SPCR/DBG2 InterfaceType */\n\tbool\t\tns16550;\t/* p12: SPCR said 16550 (type 0/1) */\n'),
 ('\tiface = spcr->InterfaceType;\n',
  '\tiface = spcr->InterfaceType;\n\tu->ns16550 = (iface == 0x00 || iface == 0x01);\t/* p12 */\n'),
 ('\t\t\tbi->bi_bsvc_uart_type =\n\t\t\t    (xbi_bsvc_uart_type_t)uart.iface;\n',
  '\t\t\t/*\n\t\t\t * p12: the FDT compat stays arm,pl011 (unbound, as\n'
  '\t\t\t * before), but the boot UART accesses the device the\n'
  '\t\t\t * SPCR names: Graviton\'s is a 16550 (measured c6g.large).\n\t\t\t */\n'
  '\t\t\tbi->bi_bsvc_uart_type = uart.ns16550 ?\n\t\t\t    XBI_BSVC_UART_NS16550 :\n\t\t\t    (xbi_bsvc_uart_type_t)uart.iface;\n'),
])

# kernel after consconfig: the same 16550 path in sysp_uart_putchar.
edit('armv8/os/fakebop.c', [
 ('\t\textern uint64_t sysp_uart_pa;\t/* machdep.c */\n\n\t\tif (xbp != NULL)\n\t\t\tsysp_uart_pa = xbp->bi_bsvc_uart_mmio_base;\n',
  '\t\textern uint64_t sysp_uart_pa;\t/* machdep.c */\n\t\textern uint32_t sysp_uart_type;\t/* p12 */\n\n'
  '\t\tif (xbp != NULL) {\n\t\t\tsysp_uart_pa = xbp->bi_bsvc_uart_mmio_base;\n\t\t\tsysp_uart_type = xbp->bi_bsvc_uart_type;\n\t\t}\n'),
])
edit('armv8/os/machdep.c', [
 ('#include <sys/bootsvcs.h>\n', '#include <sys/bootsvcs.h>\n#include <sys/bootinfo.h>\t/* p12: XBI_BSVC_UART_NS16550 */\n'),
 ('uint64_t sysp_uart_pa;\t\t\t/* set by bop_init() */\n',
  'uint64_t sysp_uart_pa;\t\t\t/* set by bop_init() */\nuint32_t sysp_uart_type;\t\t/* p12: XBI_BSVC_UART_*, set by bop_init() */\n'),
 ("\t\tsysp_uart_putchar('\\r');\n\tfor (cap = 0;",
  "\t\tsysp_uart_putchar('\\r');\n\tif (sysp_uart_type == XBI_BSVC_UART_NS16550) {\n"
  '\t\tvolatile uint8_t *b = (volatile uint8_t *)u;\n\n'
  '\t\tfor (cap = 0; (b[5] & (1u << 5)) == 0 && cap < 10000u; cap++)\n'
  '\t\t\t__asm__ volatile("yield":::"memory");\n\t\tb[0] = (uint8_t)c;\n\t\treturn;\n\t}\n\tfor (cap = 0;'),
])
