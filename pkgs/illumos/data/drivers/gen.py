#!/usr/bin/env python3
# gen.py -- render ../gate-drivers.txt (the pkg(5) `driver` actions of the pinned
# illumos-gate manifests, i386 + common) into the /etc driver database files that
# pkg(5) would write on install. Run from this directory; output is committed.
import shlex, os
os.chdir(os.path.dirname(os.path.abspath(__file__)))
gate_fixed = {'md': 85, 'devinfo': 88, 'asy': 106, 'did': 239}  # the gate proto's own entries
n2m = dict(gate_fixed); used = set(gate_fixed.values()); nxt = 0
al, mp, cl, dp, dl = [], [], [], [], []
for l in open('../gate-drivers.txt').read().split('\n'):
    if not l.strip():
        continue
    # posix shlex but with no escape character: a devlink value's \t and \M0 are
    # devlink.tab(5) syntax and must survive (the default shlex ate the backslashes).
    lx = shlex.shlex(l[len('driver '):], posix=True); lx.whitespace_split = True; lx.escape = ''
    attrs = [t.split('=', 1) for t in lx if '=' in t]
    name = [v for k, v in attrs if k == 'name'][0]
    if name not in n2m:
        while nxt in used:
            nxt += 1
        n2m[name] = nxt; used.add(nxt)
    for k, v in attrs:
        if k == 'alias': al.append('%s "%s"' % (name, v))
        elif k == 'perms': m, rest = v.split(' ', 1); mp.append('%s:%s %s' % (name, m, rest))
        elif k == 'clone_perms': m, rest = v.split(' ', 1); mp.append('clone:%s %s' % (m, rest))
        elif k == 'class': cl.append('%s\t%s' % (name, v))
        elif k == 'policy':
            parts = v.split(); minor = parts.pop(0) if '=' not in parts[0] else '*'
            dp.append(('%s:%s' % (name, minor) if minor != '*' else name) + '\t' + '\t'.join(parts))
        elif k == 'devlink': dl.append(v.replace('\\t', '\t'))
w = lambda f, xs: open(f, "w").write('\n'.join(xs) + '\n')

w('name_to_major', ['%s %d' % kv for kv in sorted(n2m.items(), key=lambda x: x[1])])
w('driver_aliases', al); w('minor_perm', mp); w('driver_classes', cl)
w('device_policy.add', dp); w('devlink.tab.add', dl)
print(len(n2m), 'drivers', len(al), 'aliases')
