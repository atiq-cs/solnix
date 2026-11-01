#!/usr/bin/env python3
"""byte-oracle.py LOG NAME ORACLE_FILE END_MARKER

Byte-exact compare of a program's console output (between "RVPKG BEGIN NAME" and the
END_MARKER line it prints to stderr) with a reference file from the same program built
for Linux. Kernel [fork]/[exec]/[elf] lines are removed (the kernel writes them, not the
program); serial CRLF is normalised to LF (the console layer adds the CR).
Exit 0 == EQUAL."""
import re
import sys

log, name, oracle, endm = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
raw = open(log, "rb").read()
a = raw.index(b"RVPKG BEGIN " + name.encode())
b = raw.index(endm.encode(), a)
blk = raw[a:b].split(b"\n", 1)[1]
blk = re.sub(rb"\[(fork|exec|elf)\][^\n]*\n", b"", blk).replace(b"\r\n", b"\n")
want = open(oracle, "rb").read().replace(b"\r\n", b"\n")
eq = blk.rstrip(b"\n") == want.rstrip(b"\n")
print("byte-oracle %s: guest %d bytes, oracle %d bytes: %s" %
      (name, len(blk), len(want), "EQUAL" if eq else "DIFFER"))
if not eq:
    i = next((k for k, (x, y) in enumerate(zip(blk, want)) if x != y), min(len(blk), len(want)))
    print("  first diff at byte %d: guest %r oracle %r" % (i, blk[i:i + 32], want[i:i + 32]))
sys.exit(0 if eq else 1)
