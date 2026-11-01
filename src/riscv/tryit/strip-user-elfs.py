#!/usr/bin/env python3
"""strip-user-elfs.py HDR OBJCOPY -- strip the debug sections from every ELF byte array in
user_elfs.h, in place (tryit1, no-PII policy: their DWARF named the build host's home directory).
Self-check: each array's PT_LOAD segment bytes and entry point are unchanged, so the kernel
loads exactly the same program."""
import re, struct, subprocess, sys, tempfile, os
hdr, objcopy = sys.argv[1], sys.argv[2]
text = open(hdr).read()
pat = re.compile(r"static const unsigned char (\w+)\[\] = \{\n(.*?)\n\};", re.S)

def loads(b):
    e_entry, e_phoff = struct.unpack_from("<QQ", b, 24)
    phentsize, phnum = struct.unpack_from("<HH", b, 54)
    segs = []
    for i in range(phnum):
        t, f, off, va, pa, fsz, msz, al = struct.unpack_from("<IIQQQQQQ", b, e_phoff + i * phentsize)
        if t == 1:
            segs.append((va, msz, f, b[off:off + fsz]))
    return e_entry, segs

def sub(m):
    name, body = m.group(1), m.group(2)
    data = bytes(int(x) for x in re.findall(r"\d+", body))
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "e")
        open(p, "wb").write(data)
        subprocess.check_call([objcopy, "--strip-debug", p])
        out = open(p, "rb").read()
    assert loads(out) == loads(data), name + ": PT_LOAD/entry changed"
    print("%-16s %6d -> %6d bytes, PT_LOAD identical" % (name, len(data), len(out)))
    rows = ["".join("%d," % c for c in out[i:i + 16]) for i in range(0, len(out), 16)]
    return "static const unsigned char %s[] = {\n%s\n};" % (name, "\n".join(rows))

text, n = pat.subn(sub, text)
assert n >= 12, n
open(hdr, "w").write(text)
