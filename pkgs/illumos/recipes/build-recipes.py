#!/usr/bin/env python3
"""Build normalized recipe table from packages.nix (nix eval JSON) + wave specs.tsv.

Columns: pname  version  url  buildsys  deps  flags
- deps: space-separated pname refs (resolved from attr refs / shell-var refs where possible)
- dedup by pname, keep the most complete/recent (packages.nix wins over specs; url-bearing wins)
"""
import json, re, glob, os, sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../.."))  # the repo root

# --- 1. packages.nix recipes (nix eval JSON) ---
with open("/tmp/pkgsnix-recipes.json") as f:
    pkgsnix = json.load(f)

# parse dep attr-names from packages.nix source: for each `X = pkg {` block,
# capture `deps = [ self.A.gcc self.B.gcc ]`.
src = open(os.path.join(ROOT, "pkgs/illumos/packages.nix")).read()
dep_map = {}  # attr -> [dep pnames]
# find each top-level attr block: NAME = pkg {  ... };  (also perlModule wrapper)
for m in re.finditer(r'^    (\w+) = pkg \{(.*?)\n    \};', src, re.S | re.M):
    attr, body = m.group(1), m.group(2)
    dm = re.search(r'deps = \[([^\]]*)\]', body)
    if dm:
        # tokens like self.zlib.gcc, self.ncurses.gcc, or store-path strings/Cached
        deps = re.findall(r'self\.(\w+)\.gcc', dm.group(1))
        dep_map[attr] = deps

# attr -> pname map (deps in packages.nix are attr refs like self.openssl3;
# recipes are keyed by pname like openssl-3 -> normalize deps to pnames).
attr_to_pname = {r["n"]: r["pname"] for r in pkgsnix}

recipes = {}  # pname -> dict
for r in pkgsnix:
    attr = r["n"]
    pname = r["pname"]
    deps = [attr_to_pname.get(d, d) for d in dep_map.get(attr, [])]
    recipes[pname] = {
        "pname": pname,
        "version": r["version"],
        "url": r["url"],
        "buildsys": r["buildSystem"] or "autotools",
        "deps": " ".join(deps),
        "flags": r["cflags"].strip(),
        "sha256": r.get("sha256", ""),
        "src": "packages.nix",
    }

# --- 2. wave specs.tsv recipes ---
# shell-var dep names -> pname, from deps.sh files (VAR=/nix/store/hash-pname-ver)
var_to_pname = {}
for dsh in glob.glob(os.path.join(ROOT, "artifacts/**/deps.sh"), recursive=True):
    for line in open(dsh):
        m = re.match(r'(\w+)=/nix/store/[a-z0-9]{32}-([a-zA-Z0-9._+-]+?)-[0-9]', line)
        if m:
            var_to_pname.setdefault(m.group(1), m.group(2))

def resolve_deps(depstr):
    out = []
    for tok in depstr.split():
        tok = tok.strip()
        if not tok:
            continue
        if tok.startswith("$"):
            v = tok[1:]
            p = var_to_pname.get(v, v.lower())
            out.append(attr_to_pname.get(p, p))
        elif tok.startswith("/nix/store/"):
            m = re.match(r'/nix/store/[a-z0-9]{32}-([a-zA-Z0-9._+-]+?)-[0-9]', tok)
            out.append(m.group(1) if m else tok)
        else:
            out.append(tok)
    # drop the cmake toolchain dep (it's a build tool, added by fire.sh, not a lib)
    return [d for d in out if d not in ("cmake", "CMAKE")]

spec_count = 0
for spec in sorted(glob.glob(os.path.join(ROOT, "artifacts/**/specs.tsv"), recursive=True)):
    for line in open(spec):
        cols = line.rstrip("\n").split("\t")
        if len(cols) < 5:
            continue
        _, pname, version, url, buildsys = cols[0], cols[1], cols[2], cols[3], cols[4]
        if not re.match(r'^(https?|ftp)://', url):
            continue  # header / malformed row
        deps = cols[5] if len(cols) > 5 else ""
        flags = cols[6] if len(cols) > 6 else ""
        spec_count += 1
        # normalize buildsys to what mk-from-recipe understands
        bs = buildsys
        rec = {
            "pname": pname, "version": version, "url": url,
            "buildsys": bs, "deps": " ".join(resolve_deps(deps)),
            "flags": flags.strip(), "sha256": "", "src": "specs.tsv",
        }
        # dedup: packages.nix (has sha256) wins; else keep the one with a url;
        # else last-wins (specs are roughly chronological wave16->26).
        if pname in recipes:
            ex = recipes[pname]
            if ex["src"] == "packages.nix":
                continue  # curated recipe wins
        recipes[pname] = rec

# --- 3. emit recipes.tsv ---
out_path = os.path.join(ROOT, "pkgs/illumos/recipes/recipes.tsv")
os.makedirs(os.path.dirname(out_path), exist_ok=True)
with open(out_path, "w") as f:
    f.write("# pname\tversion\turl\tbuildsys\tdeps\tflags\tsha256\tsource\n")
    for pname in sorted(recipes):
        r = recipes[pname]
        f.write("\t".join([r["pname"], r["version"], r["url"], r["buildsys"],
                           r["deps"], r["flags"], r["sha256"], r["src"]]) + "\n")

print(f"packages.nix recipes: {len(pkgsnix)}")
print(f"specs.tsv rows scanned: {spec_count}")
print(f"distinct recipes written: {len(recipes)}")
print(f"  with sha256 pin: {sum(1 for r in recipes.values() if r['sha256'])}")
print(f"  buildsys breakdown:")
from collections import Counter
for bs, c in Counter(r['buildsys'] for r in recipes.values()).most_common():
    print(f"    {bs}: {c}")
