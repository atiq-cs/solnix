#!/usr/bin/env python3
# p5-trap-untrace.py <gate> : trap.c keeps the kernel SError cases (on_trap / t_lofault recovery,
# else die(), whose panic already names it: "BAD TRAP: type=2f (#SERROR SError interrupt) ...
# esr=..." -- the part of b1-06 the orchestrator kept) and loses the aa_ot_* bring-up globals
# (read only by ecam's [AAECAM] trace, removed by p4).  Input = /build/aa64e-b2base/trap.c.
import sys
P = sys.argv[1] + '/usr/src/uts/armv8/os/trap.c'
s = open(P).read()
def rep(a, b, n=1):
    global s
    assert s.count(a) == n, (a[:60], s.count(a)); s = s.replace(a, b)
rep('/* aa64 bring-up diag: last on_trap()-recovered kernel abort */\n'
    'volatile uint32_t aa_ot_ec;\nvolatile uint64_t aa_ot_esr;\n'
    'volatile uintptr_t aa_ot_far;\nvolatile uint32_t aa_ot_count;\n\n', '')
rep('\n\t\t\t\taa_ot_ec = ec; aa_ot_esr = esr; aa_ot_far = (uintptr_t)addr; aa_ot_count++;\n', '\n')
rep('\n\t\t\t\t\taa_ot_ec = ec; aa_ot_esr = esr; aa_ot_far = (uintptr_t)addr; aa_ot_count++;\n', '\n')
assert 'aa_ot' not in s
open(P, 'w').write(s)
print('p5 trap OK')
