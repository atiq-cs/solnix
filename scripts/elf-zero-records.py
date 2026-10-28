#!/usr/bin/env python3
# elf-zero-records.py <path>... : flag ELF files with a whole 128 KiB-aligned record of zeros inside an
# allocated, file-backed section (SHT_PROGBITS/.text/.data/.rodata...; not .bss/NOBITS). That is the
# signature of the ZFS mmap+SEEK_HOLE bug (scripts/patches/0009): cp(1) copied a linker-written file's
# unsynced records as holes. Legit zero runs that long inside code/rodata are rare but possible (big
# zero-initialised tables in .data/.rodata), so a hit is a SUSPECT to rebuild and compare, not proof.
import os, struct, sys

REC = 128 * 1024
SKIP = {'.bss', '.tbss', '.noptrbss', '.SUNW_bss'}

def sections(b):
    if b[:4] != b'\x7fELF' or b[4] != 2:   # 64-bit only (every solnix x86_64 output)
        return None
    shoff, = struct.unpack_from('<Q', b, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 0x3a)
    if shoff == 0 or shnum == 0 or shoff + shnum * shentsize > len(b):
        return None
    sh = [struct.unpack_from('<IIQQQQIIQQ', b, shoff + i * shentsize) for i in range(shnum)]
    stro = sh[shstrndx][4]
    def name(o):
        e = b.index(b'\0', stro + o)
        return b[stro + o:e].decode('latin1')
    out = []
    for nm, typ, flags, addr, off, size, *_ in sh:
        if typ == 8 or size == 0 or not (flags & 2):   # SHT_NOBITS or not SHF_ALLOC
            continue
        out.append((name(nm), off, size))
    return out

def scan(path):
    try:
        with open(path, 'rb') as f:
            b = f.read()
    except OSError:
        return []
    secs = sections(b)
    if not secs:
        return []
    zero = bytes(REC)
    hits = []
    for r in range(0, len(b) - REC + 1, REC):
        if b[r:r + REC] != zero:
            continue
        for nm, off, size in secs:
            if nm in SKIP:
                continue
            if off <= r and r + REC <= off + size:
                hits.append((r, nm))
                break
    return hits

def main(argv):
    bad = 0
    for top in argv:
        for d, _, fs in os.walk(top):
            for f in fs:
                p = os.path.join(d, f)
                if os.path.islink(p) or not os.path.isfile(p):
                    continue
                h = scan(p)
                if h:
                    bad += 1
                    print('SUSPECT %s %s' % (p, ', '.join('%#x(%s)' % x for x in h[:4])))
    print('suspect files: %d' % bad)
    return 1 if bad else 0

if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
