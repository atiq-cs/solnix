#!/usr/bin/env python3
# aa-ecam-trace-mute.py <gate-root> : on top of aa-ecam-trace.py.  BAR sizing
# clears Memory Access Enable on the device it sizes; when that device is the
# console UART (Graviton 15:00.0), trace lines printed in that window would go
# to a UART that is not decoding.  So: a COMMAND write with MAE clear mutes the
# trace until a COMMAND write with MAE set to the same bdf, or any access to
# another bdf; then one '[E~ muted N bdf]' line says how many were skipped.
import sys
G = sys.argv[1] + '/usr/src/uts'
f = G + '/aarch64/io/pciex/ecam/ecam.c'
s = open(f).read()
assert 'AA_TRACE_MAX' in s, 'apply aa-ecam-trace.py first'
if 'aa_ecam_mute' not in s:
    a = '\tif (aa_ecam_n < AA_TRACE_MAX) {\n\t\tcmn_err(CE_CONT, "[E>'
    assert s.count(a) == 1
    s = s.replace(a,
        '\tif (aa_ecam_mute != 0 && req->bdf != aa_ecam_mute_bdf) {\n'
        '\t\tcmn_err(CE_CONT, "[E~ muted %u %x]\\n", aa_ecam_mute,\n'
        '\t\t    aa_ecam_mute_bdf);\n'
        '\t\taa_ecam_mute = 0;\n'
        '\t}\n'
        '\tif (aa_ecam_n < AA_TRACE_MAX && aa_ecam_mute == 0) {\n'
        '\t\tcmn_err(CE_CONT, "[E>', 1)
    a = '\tif (aa_ecam_n < AA_TRACE_MAX) {\n\t\tcmn_err(CE_CONT, "[E<'
    assert s.count(a) == 1
    s = s.replace(a,
        '\tif (req->write && req->offset == PCI_CONF_COMM) {\n'
        '\t\tif ((VAL16(req) & PCI_COMM_MAE) == 0) {\n'
        '\t\t\taa_ecam_mute_bdf = req->bdf;\n'
        '\t\t\taa_ecam_mute = 1;\n'
        '\t\t} else if (aa_ecam_mute != 0) {\n'
        '\t\t\tcmn_err(CE_CONT, "[E~ muted %u %x]\\n", aa_ecam_mute,\n'
        '\t\t\t    aa_ecam_mute_bdf);\n'
        '\t\t\taa_ecam_mute = 0;\n'
        '\t\t}\n'
        '\t} else if (aa_ecam_mute != 0) {\n'
        '\t\taa_ecam_mute++;\n'
        '\t}\n'
        '\tif (aa_ecam_n < AA_TRACE_MAX && aa_ecam_mute == 0) {\n'
        '\t\tcmn_err(CE_CONT, "[E<', 1)
    a = '\tif ((++aa_ecam_n & 1023) == 0 || aa_ecam_n == 1) {\n'
    assert s.count(a) == 1
    s = s.replace(a, '\tif (((++aa_ecam_n & 1023) == 0 || aa_ecam_n == 1) &&\n\t    aa_ecam_mute == 0) {\n', 1)
    a = 'static uint32_t aa_ecam_n, aa_ecam_rec;\n'
    assert s.count(a) == 1
    s = s.replace(a, a + 'static uint32_t aa_ecam_mute;\nstatic uint16_t aa_ecam_mute_bdf;\n', 1)
    open(f, 'w').write(s)
print('MUTE_OK')
