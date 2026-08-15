#!/usr/bin/env python3
#
# mkinitramfs.py -- R-P27: pack userland files into a tiny in-memory archive
# (an initramfs blob) that build-kernel embeds via .incbin.  The kernel's
# ramfs.c reads this blob and resolves exec(path) by name.
#
# Format (little-endian, the smallest thing a kernel lookup loop needs):
#   magic   : 8 bytes  "SOLRAMFS"
#   records : repeated, each:
#       u32 namelen        (0 terminates the archive)
#       u32 datalen
#       name  namelen bytes  (NOT nul-terminated; the leading '/' kept)
#       data  datalen bytes
#       pad   to 8-byte boundary after data
#   terminator: u32 0
#
# CRIB PROVENANCE: a name+size+bytes record archive read straight out of memory
# by the kernel is the illumos boot_archive / Linux initramfs (newc cpio) idiom
# reduced to the minimal fields a lookup-by-path loop needs.

import sys, struct

def main():
    out = sys.argv[1]
    # remaining args are pairs: <archive-path> <host-file>
    pairs = sys.argv[2:]
    if len(pairs) % 2 != 0:
        sys.exit("usage: mkinitramfs.py OUT (ARCHPATH HOSTFILE)...")
    blob = bytearray(b"SOLRAMFS")
    for i in range(0, len(pairs), 2):
        name = pairs[i].encode()
        with open(pairs[i + 1], "rb") as f:
            data = f.read()
        blob += struct.pack("<II", len(name), len(data))
        blob += name
        blob += data
        while len(blob) % 8 != 0:
            blob += b"\x00"
    blob += struct.pack("<I", 0)   # terminator: namelen 0
    with open(out, "wb") as f:
        f.write(blob)
    print("  initramfs: %d bytes, %d files" % (len(blob), len(pairs) // 2))

if __name__ == "__main__":
    main()
