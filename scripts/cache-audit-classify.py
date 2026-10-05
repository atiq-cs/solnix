#!/usr/bin/env python3
"""cache-audit-classify.py -- classify every audited cache object (READ-ONLY, offline).

Inputs (all produced by cache-audit-narinfo.py / cache-audit-nar-scan.py):
  WORK/meta/meta.tsv            narinfo metadata, one row per hash reached
  WORK/scan/<hash>.json.gz      NAR listing + ELF dynamic info per object
  WORK/served-arch-manifest.tsv hash, store path, declared system
  WORK/illumos-base-sonames.txt sonames shipped by the illumos gate proto
  WORK/illumos-base-sonames.<arch>.txt  optional per-arch override
Output:
  OUT.tsv   one row per object with class + reasons
  stdout    counts per class / per arch / per reason

Nix-correctness rule per dynamic ELF (DT_NEEDED-bearing, non-debuginfo):
  * every RUNPATH/RPATH entry is a /nix/store path or $ORIGIN-relative;
    anything else (/usr/lib, /usr/gcc, /opt, //lib, /var/tmp build dirs) is impure;
  * every store entry's hash is in the object's declared References;
  * every DT_NEEDED resolves, walking RUNPATH store/$ORIGIN dirs, to a file inside
    the object itself or a declared reference; failing that, a soname in the
    illumos base set counts as "base" (recorded) and anything else is unresolved.
Classes: keep (correct + 8UNr) / resign (correct + 5HAV only) / regenerate / drop / absent.
"""
import collections, glob, gzip, json, os, posixpath, re, sys

WORK, OUT = sys.argv[1], sys.argv[2]
FAM = {"EM_X86_64": "x86_64-solaris", "EM_386": "x86_64-solaris",
       "EM_SPARCV9": "sparcv9-solaris", "EM_SPARC": "sparcv9-solaris", "EM_SPARC32PLUS": "sparcv9-solaris",
       "EM_AARCH64": "aarch64-solaris"}
SOLARIS_INTERP = re.compile(r"^/(usr/)?lib/((amd64|64|sparcv9|aarch64)/)?ld\.so\.1$")
STORE = re.compile(r"^/nix/store/([0-9a-z]{32})-[^/]+(/.*)?$")

meta = {}
with open(f"{WORK}/meta/meta.tsv") as f:
    hdr = f.readline().rstrip("\n").split("\t")
    for l in f:
        r = dict(zip(hdr, l.rstrip("\n").split("\t")))
        meta[r["hash"]] = r
manifest = {}
for l in open(f"{WORK}/served-arch-manifest.tsv"):
    p = l.rstrip("\n").split("\t")
    if len(p) == 3:
        manifest[p[0]] = p[2]
base = set(l.strip() for l in open(f"{WORK}/illumos-base-sonames.txt"))
# Per-arch base sets (gate proto / seed sysroot listings); fall back to the x86 set.
base_arch = {}
for a in ("x86_64-solaris", "aarch64-solaris", "sparcv9-solaris"):
    fp = f"{WORK}/illumos-base-sonames.{a}.txt"
    if os.path.exists(fp):
        base_arch[a] = base | set(l.strip() for l in open(fp) if l.strip())  # gate sonames are arch-independent
regarch = {}
if os.path.exists(f"{WORK}/registry-arch.tsv"):
    for l in open(f"{WORK}/registry-arch.tsv"):
        h, a = l.rstrip("\n").split("\t")
        regarch.setdefault(h, a)
tranche = {}
if os.path.exists(f"{WORK}/tranche-map.tsv"):
    for l in open(f"{WORK}/tranche-map.tsv"):
        h, t = l.rstrip("\n").split("\t", 1)
        tranche.setdefault(h, t)

_clo = {}
def closure(h):
    """Transitive References of h (excluding h), from served narinfos only."""
    if h in _clo:
        return _clo[h]
    seen, stack = set(), [h]
    while stack:
        x = stack.pop()
        for r in (meta.get(x, {}).get("refs") or "").split():
            r = r[:32]
            if r != h and r not in seen:
                seen.add(r); stack.append(r)
    _clo[h] = seen
    return seen

regpath = {}
if os.path.exists(f"{WORK}/registry-paths.txt"):
    for l in open(f"{WORK}/registry-paths.txt"):
        l = l.strip(); regpath.setdefault(l[11:43], l)

def name_arch(sp):
    if re.search(r"aarch64", sp): return "aarch64-solaris"
    if re.search(r"sparc", sp): return "sparcv9-solaris"
    return None

def load(h):
    p = f"{WORK}/scan/{h}.json.gz"
    if not os.path.exists(p):
        return None
    try:
        return json.load(gzip.open(p))
    except Exception:
        return None

# ---- pass 1: compact index of every scanned object's files (for NEEDED lookups)
index = {}  # hash -> {relpath: ("f"|"x"|"l", target|size)} restricted to libs + symlinks
for h, r in meta.items():
    if r["http"] != "200":
        continue
    d = load(h)
    if not d:
        continue
    idx = {}
    for p, v in d["files"].items():
        if v[0] == "l" or ".so" in posixpath.basename(p):
            idx[p] = tuple(v)
    index[h] = idx
print(f"indexed {len(index)} objects", file=sys.stderr)

def lookup(h, rel, depth=0):
    """Resolve rel (absolute within store object h) following symlinks, also
    through intermediate directory symlinks. Returns (hash, rel) of a regular
    file, or (None, why)."""
    if depth > 12:
        return None, "symlink-loop"
    idx = index.get(h)
    if idx is None:
        return None, "object-not-scanned"
    parts = [x for x in rel.split("/") if x]
    cur = ""
    for i, comp in enumerate(parts):
        cur = f"{cur}/{comp}"
        ent = idx.get(cur)
        if ent and ent[0] == "l":
            tgt = ent[1]
            rest = "/".join(parts[i + 1:])
            if tgt.startswith("/"):
                m = STORE.match(tgt)
                if not m:
                    return None, f"symlink-out-of-store:{tgt}"
                nh, nrel = m.group(1), (m.group(2) or "")
                return lookup(nh, f"{nrel}/{rest}" if rest else nrel or "/", depth + 1)
            nrel = posixpath.normpath(posixpath.join(posixpath.dirname(cur), tgt))
            if nrel.startswith(".."):
                return None, "symlink-escapes-object"
            return lookup(h, f"{nrel}/{rest}" if rest else nrel, depth + 1)
    ent = idx.get(cur)
    if ent and ent[0] in ("f", "x"):
        return h, cur
    return None, "not-found"

def classify(h, r):
    reasons, notes = [], collections.Counter()
    refs = set(x[:32] for x in r["refs"].split())
    sp = r["storepath"]
    # narinfo-level
    if not r["sigverify"].endswith("ok") or "bad" in r["sigverify"]:
        reasons.append("bad-fingerprint")
    if r["nar_head"] != "200":
        reasons.append("nar-404")
    missing = sorted(x for x in refs if x != h and (x not in meta or meta[x]["http"] != "200"))
    if missing:
        reasons.append(f"missing-ref:{len(missing)}")
    d = load(h)
    machines, impure_ents, unres, undecl, basehits = collections.Counter(), collections.Counter(), collections.Counter(), collections.Counter(), collections.Counter()
    linux = False; interp_ext = collections.Counter(); nelf = ndyn = 0; residue = []
    fams = set(); declared = manifest.get(h) or regarch.get(h) or name_arch(sp)
    if d is None and r["nar_head"] == "200":
        reasons.append("not-scanned")
    elif d is not None:
        if d.get("error"):
            reasons.append("nar-unreadable")
        elif not d.get("nar_hash_ok"):
            reasons.append("narhash-mismatch")
        # Hollow = no payload besides directories, .manifest-* markers and the
        # stray top-level self-symlink (e.g. empty bin/ + .manifest-man).
        real = [p for p, v in d["files"].items() if v[0] != "d" and not re.search(r"/\.manifest-[a-z]+$", p)
                and not (v[0] == "l" and p.count("/") == 1 and p[1:33] == h)]
        if not real:
            residue.append("empty-nar")
        for p, e in d["elf"].items():
            if "error" in e:
                notes["elf-parse-error"] += 1; continue
            nelf += 1
            machines[e["machine"]] += 1
            if e["osabi"] in ("ELFOSABI_LINUX", "ELFOSABI_GNU") or (e.get("interp") or "").find("ld-linux") >= 0 \
                    or "libc.so.6" in e["needed"]:
                linux = True
            if e.get("interp") and not SOLARIS_INTERP.match(e["interp"]) and not STORE.match(e["interp"]):
                interp_ext[e["interp"][:60]] += 1
            if not e["dyn"]:
                continue
            if e["type"] == "ET_REL":
                # kernel modules: DT_NEEDED names krtld module deps (misc/mac, drv/ip),
                # resolved by the kernel's module path, not by ld.so.1.
                notes["kmod"] += 1
                continue
            ndyn += 1
            ents = []
            for k in ("runpath", "rpath"):
                for x in (e.get(k) or "").split(":"):
                    if x and x not in ents:
                        ents.append(x)
            dirs = []  # (hash, rel) store dirs in search order
            for x in ents:
                if x.startswith("$ORIGIN") or x.startswith("${ORIGIN}"):
                    rel = posixpath.normpath(posixpath.join(posixpath.dirname(p), x.split("/", 1)[1] if "/" in x else "."))
                    if rel.startswith(".."):
                        impure_ents["$ORIGIN-escapes"] += 1
                    else:
                        dirs.append((h, rel))
                    continue
                m = STORE.match(x)
                if not m:
                    impure_ents[x] += 1; continue
                xh = m.group(1)
                if xh != h and xh not in refs:
                    undecl[f"runpath:{xh}"] += 1
                dirs.append((xh, m.group(2) or "/"))
            for n in e["needed"]:
                if "/" in n:
                    m = STORE.match(n)
                    if not m:
                        unres[f"abs:{n}"] += 1
                    elif m.group(1) != h and m.group(1) not in refs:
                        undecl[f"needed:{m.group(1)}"] += 1
                    continue
                hit = None
                for (dh, drel) in dirs:
                    rh, rrel = lookup(dh, f"{drel.rstrip('/')}/{n}")
                    if rh:
                        hit = rh; break
                if hit:
                    # first hop (the RUNPATH dir) must be declared -- checked above;
                    # the final file may sit deeper in the closure via symlinks.
                    if hit != h and hit not in refs and hit not in closure(h):
                        undecl[f"resolved-outside-closure:{hit}"] += 1
                elif n in base_arch.get(declared, base):
                    basehits[n] += 1
                else:
                    unres[n] += 1
        # Script interpreters: /bin/sh and /usr/bin/env are base illumos; anything else
        # outside /nix/store is a host-path leak (advisory -- it does not change class,
        # since python/perl module trees commonly carry unused test/example scripts).
        # A /nix/store interpreter, by contrast, is a runtime dependency exactly like a
        # store RUNPATH entry: Nix only substitutes what References names, so a script
        # whose interpreter is not declared lands without it and cannot run. MEASURED:
        # py313-json5 (References empty) has #!/nix/store/kvl140jb...-python3.13, that
        # path 404s, and `nix copy` installs the package with no interpreter.
        for f, l in (d.get("shebang") or {}).items():
            i = l.split()[0] if l.split() else ""
            m = STORE.match(i)
            if m:
                if m.group(1) != h and m.group(1) not in refs:
                    undecl[f"shebang:{m.group(1)}"] += 1
            elif i and i not in ("/bin/sh", "/usr/bin/env", "/sbin/sh"):
                notes["host-shebang"] += 1
        fams = set(FAM.get(m, m) for m in machines)
        if linux:
            residue.append("linux-elf")
        declared = declared or (next(iter(fams)) if len(fams) == 1 else None)
        if fams and declared and any(f != declared for f in fams):
            if len(fams) == 1:
                residue.append(f"arch-mismatch:{declared}->{','.join(sorted(fams))}")
            else:
                notes["mixed-arch"] += 1
    if impure_ents:
        reasons.append("impure-runpath")
    if unres:
        reasons.append("unresolved-needed")
    if undecl:
        reasons.append("undeclared-store-dep")
    if residue:
        cls = "drop"
    elif reasons:
        cls = "regenerate"
    elif "8UNr" in r["sigkeys"].split(","):
        cls = "keep"
    else:
        cls = "resign"
    arch = declared or ("noarch" if not machines else "unknown")
    src = "manifest" if h in manifest else "registry" if h in regarch else "name/elf" if declared else "-"
    return {
        "class": cls, "arch": arch, "arch_src": src,
        "reasons": ",".join(residue + reasons) or "-",
        "elf_machines": ",".join(f"{k}:{v}" for k, v in machines.most_common()) or "-",
        "n_elf": nelf, "n_dyn": ndyn,
        "impure_runpath": "|".join(f"{k}x{v}" for k, v in impure_ents.most_common(6)) or "-",
        "unresolved_needed": ",".join(f"{k}x{v}" for k, v in unres.most_common(8)) or "-",
        "undeclared": ",".join(f"{k}x{v}" for k, v in undecl.most_common(4)) or "-",
        "base_sonames": ",".join(sorted(basehits)) or "-",
        "missing_refs": ",".join(missing) or "-",
        "nonsolaris_interp": "|".join(interp_ext) or "-",
        "notes": ",".join(f"{k}:{v}" for k, v in notes.items()) or "-",
    }

cols = ["hash", "storepath", "class", "arch", "arch_src", "tranche", "origin", "in_manifest", "sigkeys", "sigverify",
        "narhash", "narsize", "filesize", "nar_head", "nrefs", "reasons", "elf_machines", "n_elf", "n_dyn",
        "impure_runpath", "unresolved_needed", "undeclared", "missing_refs", "base_sonames", "nonsolaris_interp", "closure_blockers", "notes", "refs"]
tally = collections.Counter(); reas = collections.Counter(); basecnt = collections.Counter()
rows = {}
for h in sorted(meta):
    r = meta[h]
    if r["http"] != "200":
        r = dict(r); r["storepath"] = regpath.get(h, "-")
        row = {"class": "absent", "arch": manifest.get(h) or regarch.get(h) or name_arch(r.get("storepath") or "") or "unknown",
               "arch_src": "manifest" if h in manifest else "registry" if h in regarch else "-",
               "reasons": f"narinfo-{r['http']}"}
        row.update({k: "-" for k in cols if k not in row})
    else:
        row = classify(h, r)
    row.update({"hash": h, "storepath": r.get("storepath") or "-", "tranche": tranche.get(h, "-"),
                "origin": r["origin"], "in_manifest": "y" if h in manifest else "n"})
    if r["http"] == "200":
        for k in ("sigkeys", "sigverify", "narhash", "narsize", "filesize", "nar_head", "nrefs", "refs"):
            row[k] = r.get(k) or "-"
    rows[h] = row
# pass 2: an object whose own bytes are fine is still unusable when anything in its
# closure must be regenerated/dropped or is absent; it needs a re-sign only AFTER
# those are fixed (and its own hash changes if a dependency is rebuilt).
own = {h: rw["class"] for h, rw in rows.items()}
for h, rw in rows.items():
    if own[h] in ("resign", "keep"):
        bad = sorted(x for x in closure(h) if own.get(x, "absent") in ("regenerate", "drop", "absent"))
        if bad:
            rw["closure_blockers"] = f"{len(bad)}:" + ",".join(bad[:6])
            rw["class"] = "regenerate"
            rw["reasons"] = "closure-only"
# pass 3: a split -debug output whose matching out must be rebuilt gets a new hash
# with that rebuild, so re-signing the old one is wasted -- rebuild it with its out.
byname = collections.defaultdict(list)
for h, rw in rows.items():
    byname[(rw["arch"], (rw["storepath"] or "")[44:])].append(h)
for h, rw in rows.items():
    m = re.match(r"(.*)-debug(\.\d+)?$", (rw["storepath"] or "")[44:])
    if rw["class"] == "resign" and m:
        outs = byname.get((rw["arch"], m.group(1)), [])
        if outs and all(rows[o]["class"] in ("regenerate", "drop", "absent") for o in outs):
            rw["class"] = "regenerate"; rw["reasons"] = "debug-of-rebuilt-out"
with open(OUT, "w") as fo:
    fo.write("\t".join(cols) + "\n")
    for h, row in rows.items():
        fo.write("\t".join(str(row.get(c, "-")) for c in cols) + "\n")
        tally[(row["class"], row["arch"])] += 1
        for x in row["reasons"].split(","):
            if x != "-":
                reas[(row["class"], x.split(":")[0])] += 1
        if row.get("base_sonames", "-") != "-":
            for s in row["base_sonames"].split(","):
                basecnt[s] += 1
print("== class x arch")
for (c, a), n in sorted(tally.items()):
    print(f"{c}\t{a}\t{n}")
print("== class x reason (an object can carry several)")
for (c, x), n in sorted(reas.items()):
    print(f"{c}\t{x}\t{n}")
print("== own-bytes class (before closure demotion)")
for c, n in collections.Counter(own.values()).most_common():
    print(f"{c}\t{n}")
print("== base sonames relied on (objects)")
print(", ".join(f"{s}:{n}" for s, n in basecnt.most_common()))
