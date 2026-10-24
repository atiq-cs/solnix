#!/usr/bin/env python3
# b1-01-mp-startup-daif.py <gate> : aa64f boot 1, concern 1.
# Secondaries clear only DAIF.I at mp_startup (mp_startup.c:587); the boot CPU clears
# all of DAIF (startup.c enable_irq(), DAIF_SETCLEAR_ALL).  Clear I and A here so an
# SError raised while a secondary runs the kernel is taken at EL1, not deferred to eret.
import sys
G = sys.argv[1] + '/usr/src/uts/'

def edit(path, fn):
    s = open(G + path).read(); t = fn(s)
    assert t != s, path; open(G + path, 'w').write(t)

def rep(s, a, b, n=1):
    assert s.count(a) == n, (a[:60], s.count(a))
    return s.replace(a, b)

edit('armv8/os/mp_startup.c', lambda s: rep(s,
    '\tset_base_spl();\t\t/* Restore the spl to its proper value */\n'
    '\tclear_daif(DAIF_SETCLEAR_IRQ);\n',
    '\tset_base_spl();\t\t/* Restore the spl to its proper value */\n'
    '\t/* aa64f: unmask SError too, as the boot CPU does (startup.c) */\n'
    '\tclear_daif(DAIF_SETCLEAR_IRQ | DAIF_SETCLEAR_SERROR);\n'))
print('b1-01 OK')
