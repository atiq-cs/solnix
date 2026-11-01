#!/usr/bin/env python3
# aa-ecam-trace.py <gate-root> : bring-up DIAGNOSTIC on top of aa-ecam-diag.py.
# Prints one line BEFORE and one line AFTER each of the first AA_TRACE_MAX ECAM
# config accesses, so a stall inside PCIe enumeration is localized on the
# console: a dangling '[E>' with no matching '[E<' means the access itself never
# completed; a complete pair as the last output means the stall is in code
# between accesses.  Measurement only: it adds ~90 us/char of console time.
import sys
G = sys.argv[1] + '/usr/src/uts'
f = G + '/aarch64/io/pciex/ecam/ecam.c'
s = open(f).read()
assert 'aa_ecam_n' in s, 'apply aa-ecam-diag.py first'
if 'AA_TRACE_MAX' not in s:
    a = '\tecam_cfgspace_acc_impl(req);\n\td = gethrtime() - t;\n'
    assert s.count(a) == 1
    b = ('\tif (aa_ecam_n < AA_TRACE_MAX) {\n'
         '\t\tcmn_err(CE_CONT, "[E>%u %x:%x.%x r=%x s=%d w=%d]\\n", aa_ecam_n,\n'
         '\t\t    PCI_CFGACC_BUS(req), PCI_CFGACC_DEV(req),\n'
         '\t\t    PCI_CFGACC_FUNC(req), req->offset, (int)req->size,\n'
         '\t\t    (int)req->write);\n'
         '\t}\n'
         '\tecam_cfgspace_acc_impl(req);\n'
         '\td = gethrtime() - t;\n'
         '\tif (aa_ecam_n < AA_TRACE_MAX) {\n'
         '\t\tcmn_err(CE_CONT, "[E<%u v=%llx us=%lld]\\n", aa_ecam_n,\n'
         '\t\t    (u_longlong_t)VAL64(req), (longlong_t)(d / 1000));\n'
         '\t}\n')
    s = s.replace(a, b, 1)
    a2 = 'static uint32_t aa_ecam_n, aa_ecam_rec;\n'
    assert s.count(a2) == 1
    s = s.replace(a2, '#define\tAA_TRACE_MAX\t2048\n' + a2, 1)
    open(f, 'w').write(s)
print('TRACE_OK')
