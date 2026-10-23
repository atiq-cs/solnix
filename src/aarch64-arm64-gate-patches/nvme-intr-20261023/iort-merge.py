#!/usr/bin/env python3
# iort-merge.py <console>... : merge '[IORT]' dumps damaged by dropped console characters.
# Token rules: 2 chars = exact byte; 4 chars = two exact bytes (space lost); 1 char = byte with one lost digit (unknown);
# anything else -> line rejected. A line is used only if it decodes to exactly 32 bytes (8 for the last at 0x220):
# every way of losing characters other than one digit or one space between two full bytes changes that count.
# The k-th dump line of a capture is offset 32*k (printed offsets are themselves damaged). Reports cross-capture conflicts.
import re, struct, sys
exact, conflicts, used = {}, [], 0
for fn in sys.argv[1:]:
    txt = open(fn, errors='replace').read()
    i = txt.find('GICv3 ITS: Devbits'); j = txt.find('gicv3_its0 at', i)
    if i < 0: continue
    parts = re.split(r'\[?IO?R?T?\]? ?([0-9a-f]{3,4}):? ?', txt[txt.find('\n', i):j if j > 0 else None])
    offs, segs = parts[1::2], parts[2::2]
    if len(segs) != 18:
        # a whole line (or its prefix) was lost: line index != offset/32, so this capture cannot be placed safely
        print('skip %s: %d dump lines, expected 18' % (fn, len(segs))); continue
    for k, seg in enumerate(segs):
        toks, out, ok = seg.split('\n')[0].split(), [], True
        for t in toks:
            if not re.fullmatch(r'[0-9a-f]+', t): ok = False; break
            if len(t) == 2: out.append(int(t, 16))
            elif len(t) == 4: out += [int(t[:2], 16), int(t[2:], 16)]
            elif len(t) == 1: out.append(None)
            else: ok = False; break
        if not ok or len(out) != (8 if k == 17 else 32): continue
        used += 1
        for n, v in enumerate(out):
            if v is None: continue
            o = 32 * k + n
            if o in exact and exact[o] != v: conflicts.append((fn, hex(o), exact[o], v))
            exact.setdefault(o, v)
print('lines used=%d exact bytes=%d of 0x228 conflicts=%d %s' % (used, len(exact), len(conflicts), conflicts[:5]))
def u32(o):
    b = [exact.get(o + i) for i in range(4)]
    return '?' if None in b else '0x%x' % struct.unpack('<I', bytes(b))[0]
def u64(o):
    b = [exact.get(o + i) for i in range(8)]
    return '?' if None in b else '0x%x' % struct.unpack('<Q', bytes(b))[0]
for name, node in (('SMMUv3', 0x90), ('SMMUv3', 0xe8), ('SMMUv3', 0x140), ('SMMUv3', 0x198)):
    m = node + 0x44
    print('  nmap=%s mapoff=%s idmapidx=%s' % (u32(node + 8), u32(node + 12), u32(node + 0x40)))
    print('%s@0x%x type=%s len=%s base=%s flags=%s | map in=%s count=%s out=%s ref=%s mflags=%s' % (name, node, exact.get(node), exact.get(node+1),
          u64(node + 16), u32(node + 24), u32(m), u32(m + 4), u32(m + 8), u32(m + 12), u32(m + 16)))
rc = 0x1f0
print('PCI_RC@0x1f0 type=%s len=%s nmap=%s mapoff=%s memprop=%s ats=%s seg=%s | map in=%s count=%s out=%s ref=%s mflags=%s' % (
      exact.get(rc), exact.get(rc+1), u32(rc+8), u32(rc+12), u64(rc+16), u32(rc+24), u32(rc+28),
      u32(rc+0x24), u32(rc+0x28), u32(rc+0x2c), u32(rc+0x30), u32(rc+0x34)))
for g in (0x30, 0x48, 0x60, 0x78):
    print('ITS_GROUP@0x%x type=%s count=%s id=%s' % (g, exact.get(g), u32(g + 16), u32(g + 20)))
