#!/usr/bin/env python3
# p4-ecam-untrace.py <gate> : ecam.c keeps the on_trap() config-access recovery (the fix,
# docs/aarch64-ecam-ontrap-metal-result.md) and loses the aa64 observers: the [AAECAM]
# first/recovered/summary lines, the per-access [E>n]/[E<n] trace with its mute logic, and the
# aa_ot_* globals from trap.c it read.  Input = the bh tree's ecam.c (fix + trace).
import sys
P = sys.argv[1] + '/usr/src/uts/aarch64/io/pciex/ecam/ecam.c'
s = open(P).read()
def rep(a, b, n=1):
    global s
    assert s.count(a) == n, (a[:60], s.count(a)); s = s.replace(a, b)
a = s.index('extern volatile uint32_t aa_ot_ec;\n')
b = s.index('static void\necam_cfgspace_acc_impl(pci_cfgacc_req_t *req)\n')
rep(s[a:b], '')
rep('static void\necam_cfgspace_acc_impl(pci_cfgacc_req_t *req)\n', 'static void\necam_cfgspace_acc(pci_cfgacc_req_t *req)\n')
a = s.index('\t\tif (++aa_ecam_rec <= 4) {\n')
b = s.index('\t\tif (!req->write) {\n', a)
rep(s[a:b], '')
# the trace wrapper: from its definition to the closing brace before the next function
a = s.index('\nstatic void\necam_cfgspace_acc(pci_cfgacc_req_t *req)\n{\n\thrtime_t t = gethrtime(), d;\n')
b = s.index('\n}\n', a) + 3
rep(s[a:b], '')
assert 'aa_' not in s and 'AAECAM' not in s and '[E>' not in s, 'trace left'
open(P, 'w').write(s)
print('p4 ecam OK')
