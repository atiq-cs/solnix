#!/usr/bin/env python3
# p6-fakebop-untrace.py <gate> : fakebop.c keeps the boot memlist arena at 128 pages (the A6 fix:
# docs/aarch64-a6-mem-arena-diagnosis.md; 8 pages ran out on Graviton) and loses the A6 bring-up
# prints: the [A6KCON:BOP]/[A6KCON:BCONS] raw UART markers (each pasted twice), the [A6KCON:FR]
# probe, and the [A6MEM] arena counters/dumps.  Input = /build/fakebop.c.base.
import re, sys
P = sys.argv[1] + '/usr/src/uts/armv8/os/fakebop.c'
s = open(P).read()
def cut(a, b):
    global s
    i = s.index(a); j = s.index(b, i) + len(b); s = s[:i] + s[j:]
for _ in range(2):
    cut('\t/*\n\t * A6KCON diagnostic: raw write to the SPCR UART (0x90a0000 on\n', '\t\t\t*dr = (uint32_t)(uint8_t)*m++;\n\t}\n\n')
for _ in range(2):
    cut('\t/*\n\t * A6KCON diagnostic: raw write to the SPCR UART right after\n', '\t\t\t*dr = (uint32_t)(uint8_t)*m++;\n\t}\n\n')
cut('\t/*\n\t * A6KCON diagnostic: the raw markers above blindly write UARTDR\n', '\t\t\t*dr = (uint32_t)(uint8_t)*m++;\n\t}\n\n')
cut('/* A6MEM diagnostic: track boot-memlist arena consumption. */\n', '\t    name, cnt, (unsigned long)bytes);\n}\n')
cut('\t\textern struct memlist *phys_install;\n', '\t\ta6mem_dump_list("bootmem_avail", bootmem_avail);\n')
cut('\ta6mem_nodes_inuse++;\n', '\t\ta6mem_nodes_hwm = a6mem_nodes_inuse;\n')
cut('\tif (a6mem_nodes_inuse > 0)\n', '\t\ta6mem_nodes_inuse--;\n')
cut('\ta6mem_arena_total = sizeof (boot_list) / sizeof (boot_list[0]);\n', '(memlist_t *)xbp->bi_boot_scratch);\n\n')
cut('\n\tbop_printf(NULL, "[A6MEM] init: arena_total=%u inuse_after_dup=%u\\n",\n', '\ta6mem_dump_list("boot_scratch", boot_scratch);\n')
assert not re.search('A6KCON|A6MEM|a6mem', s), re.findall('.*(?:A6KCON|A6MEM|a6mem).*', s)[:3]
assert 'boot_list[MMU_PAGESIZE * 128 / sizeof (memlist_t)]' in s
open(P, 'w').write(s)
print('p6 fakebop OK')
