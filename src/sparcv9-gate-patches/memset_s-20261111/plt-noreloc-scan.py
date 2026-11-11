#!/usr/bin/env python3
# plt-noreloc-scan.py: find words in a shared object's allocated, non-executable sections that hold an address inside .plt
# with NO relocation at that offset. Only SHF_WRITE sections, and only values equal to a PLT entry start. In an ET_DYN that is always a bug (the object is loaded at a base != 0): the word is the
# PLT's link-time address. This is the shape libld leaves for an absolute reloc against a symbol-capability function
# (relocate.c:1668 -> ld_reloc_plt -> ld_add_actrel). Pure stdlib; parses ELF itself (BE/LE, 32/64).
# usage: plt-noreloc-scan.py FILE...   exit 1 if any finding, 0 if clean, 2 on a file that could not be parsed.
import struct, sys

def scan(path):
    d = open(path, 'rb').read()
    if d[:4] != b'\x7fELF':
        return None
    c64 = d[4] == 2
    en = '>' if d[5] == 2 else '<'
    if c64:
        (e_type, e_mach, _, _, _, e_shoff, _, _, _, _, e_shentsize, e_shnum, e_shstrndx) = struct.unpack(en + 'HHIQQQIHHHHHH', d[16:64])
    else:
        (e_type, e_mach, _, _, _, e_shoff, _, _, _, _, e_shentsize, e_shnum, e_shstrndx) = struct.unpack(en + 'HHIIIIIHHHHHH', d[16:52])
    if e_type != 3:          # ET_DYN only
        return None
    sh = []
    for i in range(e_shnum):
        o = e_shoff + i * e_shentsize
        if c64:
            n, t, fl, addr, off, sz, link, info, al, es = struct.unpack(en + 'IIQQQQIIQQ', d[o:o + 64])
        else:
            n, t, fl, addr, off, sz, link, info, al, es = struct.unpack(en + 'IIIIIIIIII', d[o:o + 40])
        sh.append(dict(n=n, t=t, fl=fl, addr=addr, off=off, sz=sz, link=link, info=info, es=es))
    so = sh[e_shstrndx]['off']
    def nm(s, stroff):
        e = d.index(b'\0', stroff + s)
        return d[stroff + s:e].decode('latin1')
    for s in sh:
        s['name'] = nm(s['n'], so)
    plts = [s for s in sh if s['name'] == '.plt']
    if not plts:
        return []
    plt = plts[0]
    plo, phi = plt['addr'], plt['addr'] + plt['sz']
    W = 8 if c64 else 4
    # every relocation offset in the file, and the PLT slot -> symbol map
    roffs = set()
    slots = {}
    symtabs = {}
    def syms(idx):
        if idx in symtabs:
            return symtabs[idx]
        st = sh[idx]; strs = sh[st['link']]['off']; out = []
        ent = 24 if c64 else 16
        for k in range(st['sz'] // ent):
            o = st['off'] + k * ent
            if c64:
                n, info, oth, shn, val, size = struct.unpack(en + 'IBBHQQ', d[o:o + 24])
            else:
                n, val, size, info, oth, shn = struct.unpack(en + 'IIIBBH', d[o:o + 16])
            out.append((nm(n, strs), val, size, info))
        symtabs[idx] = out
        return out
    jmp = {2: 21, 18: 21, 43: 21, 62: 7, 3: 7}  # EM_SPARC/SPARC32PLUS/SPARCV9: R_SPARC_JMP_SLOT=21; EM_AMD64/EM_386: JUMP_SLOT=7
    pltrel = []
    for s in sh:
        if s['t'] not in (4, 9):     # SHT_RELA, SHT_REL
            continue
        ent = s['es'] or ((24 if s['t'] == 4 else 16) if c64 else (12 if s['t'] == 4 else 8))
        sy = syms(s['link']) if s['link'] else []
        for k in range(s['sz'] // ent):
            o = s['off'] + k * ent
            if c64:
                r_off, r_info = struct.unpack(en + 'QQ', d[o:o + 16]); typ = r_info & 0xff; sym = r_info >> 32
            else:
                r_off, r_info = struct.unpack(en + 'II', d[o:o + 8]); typ = r_info & 0xff; sym = r_info >> 8
            roffs.add(r_off)
            if typ == jmp.get(e_mach) and sym < len(sy):
                pltrel.append((r_off, sy[sym][0]))
    if e_mach in (2, 18, 43):           # SPARC: the JMP_SLOT offset is the PLT entry itself
        for r_off, n in pltrel:
            slots[r_off] = n
    else:                           # x86: PLT entry i+1 (16 bytes each, entry 0 reserved) <-> .rela.plt entry i
        for i, (r_off, n) in enumerate(pltrel):
            slots[plo + 16 * (i + 1)] = n
    # locate the variable that holds a word, from .symtab (or .dynsym)
    st = [i for i, s in enumerate(sh) if s['name'] == '.symtab'] or [i for i, s in enumerate(sh) if s['name'] == '.dynsym']
    objs = [x for x in syms(st[0]) if x[2] > 0] if st else []
    def owner(a):
        for n, v, size, info in objs:
            if v <= a < v + size:
                return '%s+0x%x' % (n, a - v)
        return '?'
    finds = []
    for s in sh:
        # SHF_WRITE|SHF_ALLOC, not SHF_EXECINSTR, has file bytes: where a -ztext object keeps every relocated pointer
        if (s['fl'] & 3) != 3 or (s['fl'] & 4) or s['t'] in (8, 2, 11, 3, 4, 9, 5, 6) or s is plt:
            continue
        a0 = s['addr']; o0 = s['off']
        start = (-a0) % W
        for k in range(start, s['sz'] - W + 1, W):
            v = struct.unpack(en + ('Q' if W == 8 else 'I'), d[o0 + k:o0 + k + W])[0]
            # the value must be exactly a PLT entry's address (a function pointer), not a number that falls in the range
            if v in slots and (a0 + k) not in roffs:
                tgt = slots[v]
                finds.append('%s: %s 0x%x (%s) = 0x%x -> PLT %s, no relocation' % (path, s['name'], a0 + k, owner(a0 + k), v, tgt))
    return finds

rc = 0
for p in sys.argv[1:]:
    try:
        f = scan(p)
    except Exception as e:
        print('%s: PARSE ERROR %s' % (p, e)); rc = max(rc, 2); continue
    if f is None:
        continue
    for x in f:
        print(x)
    if f:
        rc = max(rc, 1)
    else:
        print('%s: clean' % p)
sys.exit(rc)
