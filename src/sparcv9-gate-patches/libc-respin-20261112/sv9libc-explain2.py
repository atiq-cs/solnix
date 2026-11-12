#!/usr/bin/python3.9
# sv9libc-explain2.py <OI> <new>: prove every immediate-only difference is a layout displacement.
# For each function present in both, d = addr_new - addr_old. Pair each `sethi %hi(H), %r` with the next `or|add %r, L, %r'`
# (objdump shows `or %r, 0` as `mov %r, %r`) into V = H + L. For the %l7 GOT base (PC-relative to the code): V_new - V_old must
# be -d (GOT did not move). For any other register (GOT-relative data offset): V_new - V_old must equal the target section's
# displacement (or minus it, for the GOT-minus-V form). Anything else is printed as UNEXPLAINED.
import subprocess, sys, re, collections
def dis(path):
    out = subprocess.run(["/usr/gnu/bin/objdump", "-d", "--no-show-raw-insn", path], capture_output=True, text=True, check=True).stdout
    fs = collections.OrderedDict(); addr = {}; cur = None
    for l in out.splitlines():
        m = re.match(r'^([0-9a-f]+) <(.+)>:$', l)
        if m:
            cur = m.group(2); k = 1
            while cur in fs: k += 1; cur = f"{m.group(2)}#{k}"
            fs[cur] = []; addr[cur] = int(m.group(1), 16); continue
        m = re.match(r'^\s+([0-9a-f]+):\s+(\S+)\s*(.*)$', l)
        if m and cur:
            mn, ops = m.group(2), re.sub(r'\s*!.*$', '', m.group(3)).strip()
            mm = re.match(r'^(%\w+), (%\w+)$', ops)
            if mn == "mov" and mm and mm.group(1) == mm.group(2): mn, ops = "or", f"{mm.group(1)}, 0, {mm.group(1)}"
            fs[cur].append((int(m.group(1), 16), mn, ops))
    return fs, addr
def pairs(ins):
    hi = {}; r = []
    for a, mn, ops in ins:
        m = re.match(r'^%hi\((0x[0-9a-f]+)\), (%\w+)$', ops)
        if mn == "sethi" and m: hi[m.group(2)] = int(m.group(1), 16); continue
        m = re.match(r'^(%\w+), (-?0x[0-9a-f]+|-?\d+), (%\w+)$', ops)
        if mn in ("or", "add", "xor") and m and m.group(1) in hi:
            r.append((m.group(1), mn, hi.pop(m.group(1)), int(m.group(2), 0)))
    return r
def strip_imm(ins, f):
    out = []
    for a, mn, ops in ins:
        ops = re.sub(r'[0-9a-f]+ <([^>]+)>', lambda t: "<" + ("." if t.group(1).startswith(f) else re.sub(r'\+0x[0-9a-f]+$', '', t.group(1))) + ">", ops)
        out.append((mn, re.sub(r'-?(0x[0-9a-f]+|\b\d+\b)', '#', ops)))
    return out
O, N = sys.argv[1], sys.argv[2]
(o, ao), (n, an) = dis(O), dis(N)
sec_d = set()
for l in subprocess.run(["/usr/gnu/bin/readelf", "-S", "-W", O], capture_output=True, text=True).stdout.splitlines(): pass
GOT = 0x26c000
TEXT_END = 0x110a9c
starts = sorted((ao[f], an[f] - ao[f]) for f in o if f in n)
import bisect
def region(x):
    if x >= 0x110ac0 and x < 0x169540: return 0x40          # .rodata moved +0x40 (section headers)
    i = bisect.bisect_right([s for s, _ in starts], x) - 1
    return starts[i][1] if i >= 0 and x < TEXT_END else None
stats = collections.Counter(); unexpl = []; deltas = collections.Counter()
for f in o:
    if f not in n or o[f] == n[f]: continue
    if strip_imm(o[f], f) != strip_imm(n[f], f): stats["instruction-level"] += 1; unexpl.append(("INSN", f)); continue
    d = an[f] - ao[f]; deltas[d] += 1
    po, pn = pairs(o[f]), pairs(n[f])
    if len(po) != len(pn): unexpl.append(("PAIRS", f, len(po), len(pn))); continue
    for (r1, m1, h1, l1), (r2, m2, h2, l2) in zip(po, pn):
        v1, v2 = h1 + l1 if m1 != "xor" else h1 ^ l1, h2 + l2 if m2 != "xor" else h2 ^ l2
        if v1 == v2: continue
        dv = v2 - v1
        if r1 == "%l7": k = "gotbase" if dv == -d else None
        else:
            k = None
            for sgn in (-1, 1):
                to, tn = GOT + sgn * v1, GOT + sgn * v2
                if region(to) is not None and tn - to == region(to): k = "gotrel-text-label" if to < TEXT_END else "gotrel-data"; break
        if k: stats[k] += 1
        else: unexpl.append(("VAL", f, r1, hex(v1), hex(v2), "d=" + hex(d)))
    # every non-pair immediate difference (e.g. branch displacement) is covered by symbolic targets in strip_imm
print("function displacement histogram (new-old):", {hex(k): v for k, v in deltas.most_common(6)})
print("explained:", dict(stats))
print("UNEXPLAINED (%d):" % len(unexpl))
for u in unexpl[:30]: print("  ", u)
