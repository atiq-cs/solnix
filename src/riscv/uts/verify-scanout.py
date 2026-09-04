#!/usr/bin/env python3
"""
verify-scanout.py -- check that a QMP screendump contains the pattern the guest
painted through the /dev/fb seam.

This is what turns a screendump from a picture into EVIDENCE: the host's display
surface can only contain what the guest pushed through SET_SCANOUT +
TRANSFER_TO_HOST_2D + RESOURCE_FLUSH, so matching pixels prove the whole path
(mmap -> guest stores -> cache maintenance -> device transfer -> host scanout).

Expected pattern (painted by uts/user/fbtest.c and fb.c's selftest):
  top-left RED, top-right GREEN, bottom-left BLUE, bottom-right WHITE,
  plus a WHITE diagonal from (0,0) to (width,height).

Usage: verify-scanout.py <dump.ppm> [--png out.png]
Exit status 0 = pass.
"""
import sys


def read_ppm(path):
    """Minimal binary-PPM (P6) reader. Header fields may be split across lines,
    so tokens are read one whitespace-delimited word at a time."""
    with open(path, "rb") as f:
        data = f.read()
    if not data.startswith(b"P6"):
        raise ValueError(f"{path} is not a binary PPM (P6)")
    pos = 2
    vals = []
    while len(vals) < 3:
        # skip whitespace and comments
        while pos < len(data) and data[pos : pos + 1].isspace():
            pos += 1
        if data[pos : pos + 1] == b"#":
            while pos < len(data) and data[pos : pos + 1] != b"\n":
                pos += 1
            continue
        start = pos
        while pos < len(data) and not data[pos : pos + 1].isspace():
            pos += 1
        vals.append(int(data[start:pos]))
    pos += 1  # single whitespace byte after maxval
    w, h, maxval = vals
    px = data[pos:]
    if len(px) < w * h * 3:
        raise ValueError(f"short pixel data: {len(px)} < {w * h * 3}")
    return w, h, maxval, px


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    w, h, maxval, px = read_ppm(path)
    print(f"screendump: {w}x{h} maxval={maxval} ({len(px)} pixel bytes)")

    def at(x, y):
        o = (y * w + x) * 3
        return tuple(px[o : o + 3])

    def on_diagonal(x, y):
        # fbtest paints white where x*height == y*width; sampling a quadrant
        # must avoid those pixels or it reads the diagonal, not the quadrant.
        return x * h == y * w

    RED, GREEN, BLUE, WHITE = (255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 255)
    ok = True

    # Sample each quadrant at a point deliberately off the diagonal.
    quadrants = [
        ("top-left     RED  ", w // 4, h // 3, RED),
        ("top-right    GREEN", 3 * w // 4, h // 4, GREEN),
        ("bottom-left  BLUE ", w // 4, 3 * h // 4, BLUE),
        ("bottom-right WHITE", 3 * w // 4, 2 * h // 3, WHITE),
    ]
    for name, x, y, exp in quadrants:
        assert not on_diagonal(x, y), f"sample ({x},{y}) lands on the diagonal"
        got = at(x, y)
        good = got == exp
        ok &= good
        print(f"  {'ok  ' if good else 'FAIL'} {name} at ({x},{y}): "
              f"RGB{got} expect RGB{exp}")

    # The diagonal proves stride addressing: a wrong stride shears it.
    hits = 0
    samples = 0
    for i in range(1, 10):
        y = i * h // 10
        x = y * w // h
        if 0 <= x < w:
            samples += 1
            if at(x, y) == WHITE:
                hits += 1
    good = hits == samples
    ok &= good
    print(f"  {'ok  ' if good else 'FAIL'} white diagonal at {hits}/{samples} "
          f"sampled points (proves stride addressing, not width*4)")

    # A blank or uniform dump would pass none of the above, but check anyway:
    # a guest that never presented leaves the host surface all one color.
    distinct = {at(x, y) for x in range(0, w, max(1, w // 40))
                for y in range(0, h, max(1, h // 40))}
    good = len(distinct) >= 4
    ok &= good
    print(f"  {'ok  ' if good else 'FAIL'} {len(distinct)} distinct colors "
          f"sampled (a never-presented frame would be uniform)")

    if len(sys.argv) >= 4 and sys.argv[2] == "--png":
        try:
            import zlib
            import struct

            def chunk(tag, payload):
                c = struct.pack(">I", len(payload)) + tag + payload
                return c + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)

            raw = b"".join(b"\x00" + px[y * w * 3 : (y + 1) * w * 3] for y in range(h))
            png = (b"\x89PNG\r\n\x1a\n"
                   + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                   + chunk(b"IDAT", zlib.compress(raw, 9))
                   + chunk(b"IEND", b""))
            with open(sys.argv[3], "wb") as f:
                f.write(png)
            print(f"  wrote PNG {sys.argv[3]}")
        except Exception as e:  # noqa: BLE001 - reporting is enough here
            print(f"  PNG conversion skipped: {e}")

    print("\nSCREENDUMP VERIFY:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
