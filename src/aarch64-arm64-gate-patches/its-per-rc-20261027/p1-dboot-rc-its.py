#!/usr/bin/env python3
# p1-dboot-rc-its.py <dboot_synth_fdt.c> : one ITS node per IORT ITS a root complex uses (aa64g).
# Input = /build/dboot_synth_fdt.c.b2 (aa64c IORT segment-0 ITS fix + its IORT diag property).
# dixa (c6gd.metal): RC segment 2 -> SMMUv3 @0x140 -> ITS 2, but every pcie@ pointed at the
# segment-0 ITS, so nvme1/nvme2's MSI-X went to ITS 0 and was lost.  Segment 0 is unchanged.
import sys
P = sys.argv[1]
s = open(P).read()
def rep(a, b, n=1):
    global s
    assert s.count(a) == n, (a[:70], s.count(a)); s = s.replace(a, b)
# 1. MCFG segment per ECAM window (it names the IORT root complex).
rep('\tuint8_t\t\tbus_end;\n\tbool\t\thave;\n} synth_ecam_t;\n',
    '\tuint8_t\t\tbus_end;\n\tuint16_t\tseg;\t\t/* PCI segment group (IORT RC) */\n\tbool\t\thave;\n} synth_ecam_t;\n')
rep('\t\te[i].bus_end = alloc[i].EndBusNumber;\n',
    '\t\te[i].bus_end = alloc[i].EndBusNumber;\n\t\tmemcpy(&e[i].seg, &alloc[i].PciSegment, sizeof (e[i].seg));\n')
# 2. per-segment ITS lookup; the segment-0 pick is now one call of it.
OLD = s[s.index('static void\nsynth_pick_pci_its(synth_gic_t *g)\n'):s.index('static int\nprop_interrupt(')]
rep(OLD, open(sys.argv[0].replace('p1-dboot-rc-its.py', 'p1-rc-its.c')).read())
# 3. its@ nodes: the default (segment 0's: phandle 2, same name/reg as before) plus one per
#    other ITS an MCFG segment's IORT path ends in, phandle from the node counter (so a
#    segment-0-only platform gets the same FDT phandles as before).  The IORT diag property goes.
a = s.index('\tif (gic.have_its) {\n\t\tsynth_nodename(name, sizeof (name), "its", gic.its);\n')
b = s.index('\t(void) fdt_end_node(fdt);\t\t/* intc */\n')
rep(s[a:b], '\tif (gic.have_its) {\n'
    '\t\tint e, k;\n\n'
    '\t\tsynth_emit_its(fdt, gic.its, SYNTH_PHANDLE_ITS);\n'
    '\t\tfor (e = 0; e < necam; e++) {\n'
    '\t\t\tk = synth_rc_its(&gic, ecam[e].seg);\n'
    '\t\t\tif (k < 0 || gic.its_base[k] == gic.its || its_ph[k] != 0)\n'
    '\t\t\t\tcontinue;\n'
    '\t\t\tits_ph[k] = synth_alloc_phandle();\n'
    '\t\t\tsynth_emit_its(fdt, gic.its_base[k], its_ph[k]);\n'
    '\t\t}\n\t}\n')
rep('\tsynth_ecam_t ecam[8];\n', '\tsynth_ecam_t ecam[8];\n\tuint32_t its_ph[SYNTH_ITS_MAX] = { 0 };\t/* extra ITS phandles */\n')
# 4. each pcie@'s msi-map names its own segment's ITS.
rep('\t\t\t\tfdt32_t mm[4];\n\t\t\t\tmm[0] = cpu_to_fdt32(0);\n\t\t\t\tmm[1] = cpu_to_fdt32(SYNTH_PHANDLE_ITS);\n',
    '\t\t\t\tfdt32_t mm[4];\n'
    '\t\t\t\tint k = synth_rc_its(&gic, ecam[i].seg);\n\n'
    '\t\t\t\tmm[0] = cpu_to_fdt32(0);\n'
    '\t\t\t\tmm[1] = cpu_to_fdt32(k >= 0 && its_ph[k] != 0 ?\n'
    '\t\t\t\t    its_ph[k] : SYNTH_PHANDLE_ITS);\n')
open(P, 'w').write(s)
print('P1_OK')
