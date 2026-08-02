#!/usr/bin/env python3
# gen-nixpkgs-map.py — (re)generate pkgs/illumos/nixpkgs-map.tsv, the CLASS A/B/C
# classification of the x86_64-solaris cache pnames against the pinned nixpkgs
# attribute universe (roadmap Phase 2 / C2 "reuse nixpkgs" cross-reference).
#
#   CLASS A: exact nixpkgs attr exists           -> reuse upstream + solaris stdenv
#   CLASS B: nixpkgs has it under a different attr -> remap (case/punct/lib/version)
#   CLASS C: NOT in nixpkgs                        -> C1 recipe-codegen overlay
#
# Inputs (regenerate with the nix-eval snippets, or reuse cached JSON):
#   NP=$(nix path-info <solnix-pkgs>#lib.nixpkgsSrc)   # patched nixpkgs source
#   nix eval --impure --json -f attrs.nix > attrs.json  # builtins.attrNames pkgs
#   nix eval --impure --json -f eco.nix   > eco.json    # python3Packages/perlPackages
#   awk -F'\t' '$3=="x86_64-solaris"{print $2}' docs/registry/arch-manifest.tsv \
#     | sed 's#^/nix/store/[a-z0-9]*-##' | grep -v -- '-debug' > x86_full.txt
#
# Usage: gen-nixpkgs-map.py <attrs.json> <eco.json> <x86_full.txt> > nixpkgs-map.tsv
import json, re, sys

def norm(s): return re.sub(r'[-_.]', '', s.lower())

def strip_version(n):
    """IPS store-name (minus hash and -debug) -> base pname."""
    n = re.sub(r'\.\d{4,}$', '', n)  # wave rebuild counter
    while True:
        m = re.match(r'^(.*)-([0-9][0-9A-Za-z.+_]*|v[0-9][0-9A-Za-z.+_]*'
                     r'|master|git[0-9A-Za-z.]*|b\d+|RFC\d+|Recursive)$', n)
        if not m:
            break
        n = m.group(1)
    return n

def build_nmap(names):
    d = {}
    for a in sorted(names, key=lambda s: (len(s), s)):  # deterministic tie-break
        d.setdefault(norm(a), a)
    return d

def build_vmap(names):
    """versioned-attr index: botan3->botan, db62->db (alpha base -> full attr)."""
    d = {}
    for a in sorted(names, key=lambda s: (len(s), s)):
        base = re.sub(r'[0-9]+$', '', a)
        if base and base != a:
            d.setdefault(norm(base), a)
    return d

# short names that collide with unrelated libs under a lib prefix
LIB_SKIP = {'tar', 'unity', 'ast', 'args'}

def classify(pname, top, py, perl, top_n, py_n, perl_n, top_v):
    # nixpkgs 26.11 ships only python3 (=3.13). py313-* is the same interpreter
    # (A on exact attr); py39-* is a version remap onto python3 (B).
    if pname.startswith('py313-') or pname.startswith('py39-'):
        is313 = pname.startswith('py313-')
        base = pname.split('-', 1)[1]; n = norm(base)
        if base in py: return ('A' if is313 else 'B'), 'python3Packages.' + base
        if n in py_n:  return 'B', 'python3Packages.' + py_n[n]
        return 'C', '-'
    if pname.startswith('perl542-'):
        base = pname.split('-', 1)[1]; n = norm(base)
        if base in perl: return 'A', 'perlPackages.' + base
        if n in perl_n:  return 'B', 'perlPackages.' + perl_n[n]
        return 'C', '-'
    if pname in top: return 'A', pname
    n = norm(pname)
    if n in top_n:   return 'B', top_n[n]
    if n in top_v:   return 'B', top_v[n]              # botan -> botan3
    if pname not in LIB_SKIP:                          # aom -> libaom
        if ('lib' + n) in top_n:                    return 'B', top_n['lib' + n]
        if n.startswith('lib') and n[3:] in top_n:  return 'B', top_n[n[3:]]
    return 'C', '-'

def main():
    attrs_json, eco_json, names_txt = sys.argv[1:4]
    top = set(json.load(open(attrs_json)))
    eco = json.load(open(eco_json))
    py, perl = set(eco['py313']), set(eco['perl'])
    top_n, py_n, perl_n = build_nmap(top), build_nmap(py), build_nmap(perl)
    top_v = build_vmap(top)

    pnames = sorted({strip_version(l.rstrip('\n'))
                     for l in open(names_txt) if l.strip()})
    rows = []
    counts = {'A': 0, 'B': 0, 'C': 0}
    for p in pnames:
        c, a = classify(p, top, py, perl, top_n, py_n, perl_n, top_v)
        rows.append((p, c, a)); counts[c] += 1
    for p, c, a in sorted(rows):
        print(f"{p}\t{c}\t{a}")
    sys.stderr.write(f"A {counts['A']}  B {counts['B']}  C {counts['C']}  "
                     f"total {len(rows)}\n")

if __name__ == '__main__':
    main()
