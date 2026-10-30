#!/usr/bin/env python3
# p13-its-baser-pgsz.py <gate> : aa64vm.  A Nitro VM's ITS (KVM vITS) supports only 64K BASER pages: written PGSZ 4K, it reads
# back 64K ("BASERn[0]: hardware rejected page size (requested 0, got 2)"), gicv3_its failed, ecam had no MSI controller, a
# PCI driver fell back to INTx and the synth FDT (no interrupt-map) hit VERIFY 3 == 1 in ddi_impl.c:1700.  Linux handles the
# same readback by retrying with the page size the ITS reports (irq-gic-v3-its.c its_setup_baser); do the same, once.
import sys
p = sys.argv[1] + '/usr/src/uts/armv8/io/gicv3_its.c'
s = open(p).read()
if 'p13' in s:
    print('p13 already applied'); sys.exit(0)
R = [
 ('\tuint32_t num_pages;\n\n\tbaser_val = its_read64(sc, GITS_BASERn(baser_idx));\n',
  '\tuint32_t num_pages;\n\tboolean_t retried = B_FALSE;\t/* p13 */\n\n\tbaser_val = its_read64(sc, GITS_BASERn(baser_idx));\n'),
 ('\tif (gicv3_contig_alloc(sc->its_dip, table_sz, page_sz,\n\t    vap, pap, dma_hdlp, acc_hdlp) != DDI_SUCCESS) {\n',
  'retry:\n\tif (gicv3_contig_alloc(sc->its_dip, table_sz, page_sz,\n\t    vap, pap, dma_hdlp, acc_hdlp) != DDI_SUCCESS) {\n'),
 ('\tif (GITS_BASERn_PGSZ_VAL(readback) != pgsz_idx) {\n',
  '\tif (GITS_BASERn_PGSZ_VAL(readback) > pgsz_idx &&\n'
  '\t    GITS_BASERn_PGSZ_VAL(readback) <= GITS_BASER_PGSZ_64K && !retried) {\n'
  '\t\t/* p13: the ITS supports only a larger page (KVM vITS: 64K); use it */\n'
  '\t\tgicv3_contig_free(dma_hdlp, acc_hdlp);\n\t\t*vap = NULL;\n'
  '\t\tpgsz_idx = GITS_BASERn_PGSZ_VAL(readback);\n'
  '\t\tpage_sz = gicv3_its_pgsz_to_bytes(pgsz_idx);\n'
  '\t\ttable_sz = P2ROUNDUP(num_entries * entry_sz, page_sz);\n'
  '\t\tnum_pages = table_sz / page_sz;\n\t\tretried = B_TRUE;\n\t\tgoto retry;\n\t}\n\n'
  '\tif (GITS_BASERn_PGSZ_VAL(readback) != pgsz_idx) {\n'),
]
for a, b in R:
    assert s.count(a) == 1, (a[:50], s.count(a)); s = s.replace(a, b)
open(p, 'w').write(s); print('p13 ok')
