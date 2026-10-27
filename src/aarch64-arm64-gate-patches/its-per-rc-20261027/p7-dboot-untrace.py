#!/usr/bin/env python3
# p7-dboot-untrace.py <dboot_synth_fdt.c> : after p1.  dboot keeps its fixes (multi-region GICR,
# SSDT _CRS windows, SPCR UART handoff, IORT ITS per root complex) and loses the bring-up
# observers: the raw-UART [A6GIC] dump (synth_gicr_diag) and [A6CRS] verdict lines, and the
# aa64e solnix,acpi-gtdt root property (only the removed aa64e machdep observer read it).
# The dboot_printf "synth FDT n of m bytes" / "synthesised FDT" summaries stay: they are the
# normal dboot -v output (they do not reach the metal console at all: SPCR comment above them).
import sys
P = sys.argv[1]
s = open(P).read()
def cut(a, b):
    global s
    assert s.count(a) == 1, (a[:60], s.count(a))
    i = s.index(a); j = s.index(b, i) + len(b); s = s[:i] + s[j:]
if 'NOTE: diagnostic.  Copy the raw ACPI GTDT' in s:	# aa64e's addition, absent from .b2
    cut('\t{\n\t\t/*\n\t\t * NOTE: diagnostic.  Copy the raw ACPI GTDT', '\t\t\t    gtdt, (int)glen);\n\t\t}\n\t}\n')
cut('\t\tsynth_gicr_diag(bi, &gic, nr);\n', '\n')
cut('\n\t/*\n\t * Repeat the verdict on the RAW SPCR UART, because dboot_printf() output\n',
    '\t\t\tsynth_uart_puts(dr, "\\n");\n\t\t}\n\t}\n')
# the helpers now have no caller
cut('static void\nsynth_gicr_diag(struct xboot_info *bi, const synth_gic_t *g, uint32_t nr)\n{\n', '\n}\n')
cut('/*\n * Emit the GICR topology to the console.\n', '\tsynth_uart_puts(dr, buf);\n}\n\n\n')
for k in ('[A6GIC]', '[A6CRS]', 'solnix,acpi-gtdt', 'solnix,acpi-iort', 'synth_gicr_diag', 'synth_uart_put'):
    assert k not in s, k
open(P, 'w').write(s)
print('p7 dboot OK')
