#!/usr/bin/env python3
# iort-decode.py <console.txt> : rebuild the IORT from '[IORT] off: hex' lines and decode nodes + ID mappings.
import re, struct, sys
b = {}
for l in open(sys.argv[1], errors='replace'):
    m = re.match(r'^\[IORT\] ([0-9a-f]{4}):((?: [0-9a-f]{2})+)\s*$', l.rstrip('\n'))
    if m:
        b[int(m.group(1), 16)] = bytes(int(x, 16) for x in m.group(2).split())
if not b: sys.exit('no [IORT] lines')
data = bytearray()
for o in sorted(b):
    if o != len(data): sys.exit('gap/garble at 0x%x (have 0x%x)' % (o, len(data)))
    data += b[o]
sig, ln = data[0:4].decode(errors='replace'), struct.unpack_from('<I', data, 4)[0]
csum = sum(data[:ln]) & 0xff if len(data) >= ln else None
print('sig=%s len=%d got=%d checksum_ok=%s' % (sig, ln, len(data), csum == 0))
ncount, noff = struct.unpack_from('<II', data, 36)
names = {0: 'ITS_GROUP', 1: 'NAMED_COMP', 2: 'PCI_RC', 3: 'SMMU', 4: 'SMMUv3', 5: 'PMCG'}
o = noff
for i in range(ncount):
    t, l, rev, _, nm, mo = struct.unpack_from('<BHBIII', data, o)
    extra = ''
    if t == 0:
        n = struct.unpack_from('<I', data, o + 16)[0]
        extra = ' its_ids=%s' % list(struct.unpack_from('<%dI' % n, data, o + 20))
    elif t == 2:
        mem, ats, seg = struct.unpack_from('<QII', data, o + 16)
        extra = ' segment=%d ats=%d' % (seg, ats)
    elif t == 4:
        base = struct.unpack_from('<Q', data, o + 16)[0]
        extra = ' base=0x%x' % base
    print('node@0x%x type=%s len=%d nmap=%d%s' % (o, names.get(t, t), l, nm, extra))
    for k in range(nm):
        ib, cnt, ob, ref, fl = struct.unpack_from('<IIIII', data, o + mo + 20 * k)
        print('   map in=0x%x count=0x%x -> out=0x%x ref=node@0x%x flags=%d' % (ib, cnt, ob, ref, fl))
    o += l
