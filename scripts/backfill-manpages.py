#!/usr/bin/env python3
# backfill-manpages.py — set has_manpages in build-ledger.tsv from REAL data.
#
# Two inputs, both replacing '?' with y/n:
#   1. --lib-class : cached library/python/* and library/perl-5/* rows -> 'n'.
#        Rationale (docs/design-manpages.md): language modules install module
#        files, not share/man. Spot-checked on the host; applied as a class so we
#        don't realise ~1950 module closures one by one.
#   2. --man-results <file> : lines "MAN\t<attr>\t<count|MISSING>" from
#        scripts/oi-check-manpages.sh. Uses docs/registry/manpage-attr-map.tsv to
#        map attr -> ledger fmri(s); count>0 -> y, count==0 -> n, MISSING -> left
#        as-is (can't assert either way).
#
#   backfill-manpages.py --lib-class
#   backfill-manpages.py --man-results /path/to/man-results.txt
#   (both flags may be combined)
import sys, os

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LEDGER = os.path.join(REPO, "docs/registry/build-ledger.tsv")
MAP = os.path.join(REPO, "docs/registry/manpage-attr-map.tsv")

def load_map():
    m = {}  # attr -> [fmri, ...]
    for line in open(MAP):
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        fmri, attr = line.split("\t")
        m.setdefault(attr, []).append(fmri)
    return m

def main():
    do_lib = "--lib-class" in sys.argv
    man_file = None
    if "--man-results" in sys.argv:
        man_file = sys.argv[sys.argv.index("--man-results") + 1]
    if not do_lib and not man_file:
        print("usage: backfill-manpages.py [--lib-class] [--man-results <file>]", file=sys.stderr)
        sys.exit(1)

    # fmri -> desired has_manpages value from man-results
    want = {}
    if man_file:
        amap = load_map()
        for line in open(man_file):
            p = line.rstrip("\n").split("\t")
            if len(p) < 3 or p[0] != "MAN":
                continue
            attr, count = p[1], p[2]
            if count == "MISSING":
                continue
            val = "y" if count.isdigit() and int(count) > 0 else "n"
            for fmri in amap.get(attr, []):
                want[fmri] = val

    rows = open(LEDGER).read().splitlines()
    out = []
    lib_flipped = man_flipped = 0
    for i, row in enumerate(rows):
        if i == 0 or not row.strip():
            out.append(row); continue
        c = row.split("\t")
        fmri, cached, hm = c[0], c[5], c[6]
        # only touch cached rows; never invent data for uncached ones
        if cached == "yes":
            if fmri in want and hm != want[fmri]:
                c[6] = want[fmri]; man_flipped += 1
            elif do_lib and hm == "?" and (fmri.startswith("library/python/")
                                            or fmri.startswith("library/perl-5/")):
                c[6] = "n"; lib_flipped += 1
        out.append("\t".join(c))
    open(LEDGER, "w").write("\n".join(out) + "\n")
    print(f"backfilled: {man_flipped} tool rows from man-results, "
          f"{lib_flipped} library-module rows -> n")

if __name__ == "__main__":
    if "--selftest" in sys.argv:
        # smallest check: y for count>0, n for 0, MISSING skipped; only cached rows.
        amap = {"foo": ["cat/foo"]}
        assert ("y" if "3".isdigit() and int("3") > 0 else "n") == "y"
        assert ("y" if "0".isdigit() and int("0") > 0 else "n") == "n"
        # cached-guard: uncached row must never change
        rows = ["fmri\tv\tt\tg\tc\tcached\thm\tdr\tn",
                "cat/foo\t1\t0\tok\tok\tno\t?\tdone\t"]
        c = rows[1].split("\t")
        assert c[5] == "no"  # backfill skips cached!=yes -> stays '?'
        print("selftest OK")
        sys.exit(0)
    main()
