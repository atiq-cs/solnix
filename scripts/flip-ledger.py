#!/usr/bin/env python3
# flip-ledger.py — mark cached=yes + gcc_status=ok for a list of module names in
# build-ledger.tsv. Matches library/perl-5/<name> and library/python/<name>
# (base FMRI and the -39/-313/-314/-538/-540 suffixed variants). Idempotent.
#   flip-ledger.py perl   <names-file>
#   flip-ledger.py python <names-file>
import sys, re
kind, namesfile = sys.argv[1], sys.argv[2]
prefix = "library/perl-5/" if kind == "perl" else "library/python/"
names = set()
for line in open(namesfile):
    n = line.strip()
    if not n: continue
    # normalise: Perl "Foo::Bar" -> "foo-bar"; py "foo_bar" -> "foo-bar"
    n = n.lower().replace("::", "-").replace("_", "-").replace(".", "-")
    names.add(n)
rows = open("docs/registry/build-ledger.tsv").read().splitlines()
out, flipped = [], 0
for i, row in enumerate(rows):
    if i == 0 or not row.strip():
        out.append(row); continue
    c = row.split("\t")
    fmri = c[0]
    if fmri.startswith(prefix):
        base = fmri[len(prefix):]
        # strip trailing -39/-313/-314/-538/-540
        base = re.sub(r"-(39|313|314|538|540)$", "", base)
        if base in names:
            if c[5] != "yes":
                c[5] = "yes"; c[3] = "ok"; flipped += 1
            out.append("\t".join(c)); continue
    out.append(row)
open("docs/registry/build-ledger.tsv", "w").write("\n".join(out) + "\n")
print(f"flipped {flipped} ledger rows to cached=yes ({kind})")
