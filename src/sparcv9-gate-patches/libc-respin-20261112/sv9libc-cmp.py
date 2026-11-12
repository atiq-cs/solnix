#!/usr/bin/python3.9
# sv9libc-cmp.py <OI libc.so.1> <new libc.so.1> [allow-size-change-symbols...]
# Gate: SONAME, version definitions (names, order, parents, flags), per-.dynsym-symbol (name, type, bind, visibility, version
# index -> name, size), and function sizes for every FUNC in .symtab, equal to OI's except the listed symbols. Prints every
# difference; exits 1 on any un-allowed one. Uses only elfdump(1) (illumos), so it runs in the zone.
import subprocess, sys, re
def run(*a): return subprocess.run(a, capture_output=True, text=True, check=True).stdout
def verdefs(f):
    out = run("/usr/bin/elfdump", "-v", f)
    sec = out.split("Version Needed")[0]
    rows = []
    for l in sec.splitlines():
        m = re.match(r'\s*\[(\d+)\]\s+(\S+)\s*(.*)$', l)
        if m: rows.append((int(m.group(1)), m.group(2), m.group(3).split()))
    return rows
def syms(f, sect):
    out = run("/usr/bin/elfdump", "-s", "-N", sect, f)
    d = {}
    for l in out.splitlines():
        m = re.match(r'\s*\[(\d+)\]\s+(0x[0-9a-f]+)\s+(0x[0-9a-f]+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)$', l)
        if not m: continue
        idx, val, size, typ, bind, oth, ver, shndx, name = m.groups()
        key = (name, bind == "LOCL" and name or None)
        d.setdefault(name, []).append(dict(size=int(size, 16), type=typ, bind=bind, vis=oth, ver=ver, shndx=shndx))
    return d
def soname(f):
    for l in run("/usr/bin/elfdump", "-d", f).splitlines():
        if "SONAME" in l: return l.split()[-1]
oi, new = sys.argv[1], sys.argv[2]
allow = set(sys.argv[3:])
bad = 0
def rep(kind, msg, allowed=False):
    global bad
    print(("ALLOWED " if allowed else "DIFF    ") + kind + ": " + msg)
    if not allowed: bad += 1
if soname(oi) != soname(new): rep("soname", f"{soname(oi)} vs {soname(new)}")
vo, vn = verdefs(oi), verdefs(new)
if vo != vn:
    rep("verdef", f"{len(vo)} vs {len(vn)} entries; first difference: " +
        str(next(((a, b) for a, b in zip(vo, vn) if a != b), (vo[len(vn):len(vn)+1], vn[len(vo):len(vo)+1]))))
vname_o = {i: n for i, n, _ in vo}; vname_n = {i: n for i, n, _ in vn}
for sect in (".dynsym", ".symtab"):
    so, sn = syms(oi, sect), syms(new, sect)
    names = sorted(set(so) | set(sn))
    nfunc = 0
    for n in names:
        if n == "": continue
        a, b = so.get(n), sn.get(n)
        if a is None or b is None:
            # local-only helpers are reported but judged by the caller (only .dynsym absence fails)
            rep(sect + " presence", f"{n}: {'missing in new' if b is None else 'new only'}",
                allowed=(n in allow) or (sect == ".symtab" and n in allow))
            continue
        if len(a) != len(b):
            rep(sect + " count", f"{n}: {len(a)} vs {len(b)}", allowed=n in allow); continue
        for x, y in zip(sorted(a, key=lambda e: (e['bind'], e['size'])), sorted(b, key=lambda e: (e['bind'], e['size']))):
            for k in ("type", "bind", "vis"):
                if x[k] != y[k]: rep(sect + " " + k, f"{n}: {x[k]} vs {y[k]}", allowed=n in allow)
            if sect == ".dynsym":
                vx = vname_o.get(int(x['ver']), x['ver']) if x['ver'].isdigit() else x['ver']
                vy = vname_n.get(int(y['ver']), y['ver']) if y['ver'].isdigit() else y['ver']
                if vx != vy: rep("versym", f"{n}: {vx} vs {vy}", allowed=n in allow)
            if x['type'] in ("FUNC", "OBJT"):
                if x['type'] == "FUNC": nfunc += 1
                if x['size'] != y['size']:
                    rep(sect + " size", f"{n} ({x['type']}): {x['size']} vs {y['size']}", allowed=n in allow)
    print(f"# {sect}: {len(so)} names in OI, {len(sn)} in new, {nfunc} FUNC compared")
print("RESULT:", "PASS" if bad == 0 else f"FAIL ({bad} un-allowed differences)")
sys.exit(1 if bad else 0)
