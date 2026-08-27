#!/usr/bin/env python3
# Mirror of synth_scan_crs() in dboot_synth_fdt.c, run against the real
# Graviton DSDT to assert the C logic extracts the right PCIe windows.
import struct, sys

WORD, DWORD, QWORD = 0x88, 0x87, 0x8a
RT_MEM, RT_IO, RT_BUS = 0, 1, 2
PRODUCER = 0x01  # general-flags bit0: 1=Consumer, 0=Producer
IO, MEM32, MEM64 = 0x01000000, 0x02000000, 0x03000000

def scan(d):
    # DSDT header is 36 bytes; walk from there.
    off = 36
    n = len(d)
    # find bus-number WordAddressSpace producer
    while off + 3 < n:
        if d[off] == WORD:
            dlen = d[off+1] | (d[off+2] << 8)
            if dlen >= 13 and off+3+dlen <= n and d[off+3] == RT_BUS \
               and (d[off+4] & PRODUCER) == 0:
                off += 3 + dlen
                break
        off += 1
    else:
        return []
    wins = []
    while off + 3 < n and len(wins) < 8:
        tag = d[off]
        if tag == DWORD: fw = 4
        elif tag == QWORD: fw = 8
        elif tag == WORD: fw = 2
        else: break
        dlen = d[off+1] | (d[off+2] << 8)
        if off+3+dlen > n: break
        restype = d[off+3]; gflags = d[off+4]
        fmt = {2:"<H",4:"<I",8:"<Q"}[fw]
        f = [struct.unpack_from(fmt, d, off+6+i*fw)[0] for i in range(5)]
        gran, mn, mx, tra, length = f
        if (gflags & PRODUCER) == 0 and length != 0 and restype in (RT_MEM, RT_IO):
            child, parent, size = mn, mn+tra, length
            if restype == RT_IO: space = IO
            elif (mn >> 32) != 0 or fw == 8: space = MEM64
            else: space = MEM32
            wins.append((space, child, parent, size))
        off += 3 + dlen
    return wins

d = open(sys.argv[1], "rb").read()
w = scan(d)
for space, c, p, s in w:
    nm = {IO:"IO",MEM32:"MEM32",MEM64:"MEM64"}[space]
    print(f"{nm:6s} child={c:#014x} parent={p:#014x} size={s:#x}")

# Assert the exact Graviton windows.
got = {(sp,c,p,s) for sp,c,p,s in w}
exp = {
  (MEM32, 0x80000000, 0x80000000, 0x80000000),
  (IO,    0x00000000, 0x1fff0000, 0x10000),
  (MEM64, 0x400000000000, 0x400000000000, 0x8000000000),
}
assert exp <= got, f"MISSING: {exp - got}"
print("OK: all 3 Graviton _CRS windows parsed correctly")
