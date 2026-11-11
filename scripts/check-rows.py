#!/usr/bin/env python3
"""check-rows.py -- the pre-send validator for a recipes.tsv rows batch (durable1, 2026-11-11). Every rows batch must pass it.

  check-rows.py --prior <served recipes.tsv> [--replace | --historical] [--pathinfo <json>]... <rows.tsv>
  check-rows.py --selftest

  --prior       the served recipes.tsv the batch is appended to (curl https://cache.solnix.io/registry/recipes.tsv)
  --replace     the batch REPLACES prior rows with the same outs (wave7 -debug v2): those prior rows are dropped first
  --historical  re-check a batch that was already served: prior is cut at the first prior row naming one of its outs
                (recipes.tsv is append-only, so that is the file as it was when the batch was sent)
  --pathinfo    `nix path-info --json` of the batch's outs (a dict or a list; references full or base names). Outs it lacks
                are read from cache.solnix.io's narinfo; an out in neither FAILs (no references known: fail closed)

Checks (rc 1 on any FAIL, rc 2 on bad input):
  C0 shape      the 10-column header; 10 fields a row; out (and debug, when set) a /nix/store path with a 32-char hash
  C1 debug      every debug-column path is some row's out (the batch's or prior's): infra serves a row per output path
  C2 deps/refs  every deps pname is the pname of one of the out's references (infra: "submitted refs omit reviewed deps");
                a -debug row's deps are EXACTLY the pnames its NAR references (its own out's pname, or empty)
  C3 deps first every reference is prior's out or an earlier batch row's (a later row: order; neither, and not served: unrowed);
                every deps pname has a prior row or an earlier batch row of the same system
  C4 dup outs   no out twice in the batch, and none already a prior row's (unless --replace)
"""
import csv, json, os, re, sys, urllib.request, concurrent.futures

HDR = ["pname", "version", "url", "sha256", "buildsys", "deps", "flags", "system", "out", "debug"]
SP = re.compile(r"^/nix/store/[0-9a-df-np-sv-z]{32}-[A-Za-z0-9+._?=-]+$")
CACHE = os.environ.get("CHECK_ROWS_CACHE", "https://cache.solnix.io")
UA = {"User-Agent": "solnix-check-rows/1"}   # cache.solnix.io answers 403 to Python-urllib's UA

def read(p):
    with open(p, newline="") as f: return list(csv.reader(f, delimiter="\t", quoting=csv.QUOTE_NONE))

def narinfo(o):
    """(served, [references as full paths]) from cache.solnix.io, or (False, None)."""
    try:
        with urllib.request.urlopen(urllib.request.Request(f"{CACHE}/{o[11:43]}.narinfo", headers=UA), timeout=30) as r:
            t = r.read().decode()
    except Exception: return False, None
    m = re.search(r"^References:(.*)$", t, re.M)
    return True, ["/nix/store/" + x for x in (m.group(1).split() if m else [])]

def load_pathinfo(files):
    refs = {}
    for f in files:
        j = json.load(open(f))
        it = j.items() if isinstance(j, dict) else ((e.get("path"), e) for e in j)
        for p, e in it:
            if not e: continue
            p = p if p.startswith("/nix/store/") else "/nix/store/" + p
            refs[p] = [r if r.startswith("/nix/store/") else "/nix/store/" + r for r in e.get("references", [])]
    return refs

def check(rows_path, prior_path, pathinfo=(), replace=False, historical=False, fetch=narinfo):
    """-> (fails, warns, n): lists of strings. fetch(out) -> (served, refs|None), a test hook."""
    fails, warns = [], []
    batch, prior = read(rows_path), read(prior_path)
    if not batch or batch[0] != HDR: return [f"C0 {rows_path}: header is not the 10 recipes.tsv columns ({batch[0] if batch else 'empty'})"], [], 0
    if not prior or prior[0] != HDR: return [f"C0 {prior_path}: the prior recipes.tsv has no 10-column header"], [], 0
    batch, prior = batch[1:], [r for r in prior[1:] if len(r) == 10]
    for i, r in enumerate(batch, 2):
        if len(r) != 10: fails.append(f"C0 line {i}: {len(r)} fields, not 10"); continue
        if not SP.match(r[8]): fails.append(f"C0 line {i}: out {r[8]!r} is not a store path")
        if r[9] and not SP.match(r[9]): fails.append(f"C0 line {i}: debug {r[9]!r} is not a store path")
        if not r[0] or not r[7]: fails.append(f"C0 line {i}: empty pname or system")
    batch = [r for r in batch if len(r) == 10]
    bouts = {r[8] for r in batch}
    if historical:
        cut = next((i for i, r in enumerate(prior) if r[8] in bouts), len(prior)); prior = prior[:cut]
    if replace: prior = [r for r in prior if r[8] not in bouts]
    # C4
    seen = {}
    for i, r in enumerate(batch, 2):
        if r[8] in seen: fails.append(f"C4 line {i}: out {r[8]} is also line {seen[r[8]]}")
        seen.setdefault(r[8], i)
    pouts = {r[8]: r for r in prior}
    for i, r in enumerate(batch, 2):
        if r[8] in pouts: fails.append(f"C4 line {i}: out {r[8]} is already a prior row ({pouts[r[8]][0]} {pouts[r[8]][1]}): --replace if this batch replaces it")
    # C1
    allouts = set(pouts) | bouts
    for i, r in enumerate(batch, 2):
        if r[9] and r[9] not in allouts: fails.append(f"C1 line {i}: {r[0]}'s debug {r[9]} has no row of its own (no row's out)")
    # references
    pi = load_pathinfo(pathinfo); refs, served = {}, {}
    need = [r[8] for r in batch if r[8] not in pi]
    with concurrent.futures.ThreadPoolExecutor(16) as ex: got = dict(zip(need, ex.map(fetch, need)))
    for o in bouts: refs[o] = pi.get(o, got.get(o, (False, None))[1])
    debugs = {r[9] for r in prior + batch if r[9]}
    pn_prior = {(r[0], r[7]) for r in prior}
    pname_of = {r[8]: r[0] for r in prior}; order = {}
    for i, r in enumerate(batch, 2): pname_of.setdefault(r[8], r[0]); order.setdefault(r[8], i)
    unknown = {}
    for i, r in enumerate(batch, 2):
        o, deps = r[8], {d for d in r[5].split(",") if d}
        rf = refs.get(o)
        if rf is None: fails.append(f"C2 line {i}: no references known for {o} (not in --pathinfo, not served): pass its path info"); continue
        rf = [x for x in rf if x != o]
        # C3 references: deps first
        for x in rf:
            if x in pouts: continue
            if x in order:
                if order[x] > i: fails.append(f"C3 line {i}: {r[0]} references {x}, rowed LATER (line {order[x]}): order deps first")
                continue
            if x not in unknown: unknown[x] = fetch(x)[0]
            if unknown[x]: warns.append(f"C3 line {i}: {r[0]} references {x}: served, but no row names it (it cannot satisfy a deps pname)")
            else: fails.append(f"C3 line {i}: {r[0]} references {x}: neither served nor rowed (prior or earlier in the batch)")
        # C3 deps pnames
        earlier = {(b[0], b[7]) for b in batch[:i - 2]}
        for d in sorted(deps):
            if (d, r[7]) not in pn_prior and (d, r[7]) not in earlier: fails.append(f"C3 line {i}: deps {d} has no {r[7]} row in prior or earlier in the batch")
        # C2
        rp = {pname_of[x] for x in rf if x in pname_of}
        miss = sorted(deps - rp)
        if miss: fails.append(f"C2 line {i}: {r[0]} {o[44:]} deps {','.join(miss)} name no reference of its NAR (references: {','.join(sorted(rp)) or 'none'})")
        isdbg = o in debugs or o.endswith("-debug")
        extra = sorted(rp - deps - ({r[0]} if not isdbg else set()))
        if isdbg and extra: fails.append(f"C2 line {i}: -debug {o[44:]} deps '{r[5]}' must be exactly its references' pnames '{','.join(sorted(rp))}'")
        elif extra: warns.append(f"C2 line {i}: {r[0]} references pnames not in its deps: {','.join(extra)}")
    return fails, warns, len(batch)

def selftest():
    import tempfile
    d = tempfile.mkdtemp(); bad = 0
    h = lambda c: "/nix/store/" + c * 32
    A, Ad, B, Bd, L = h("a") + "-a-1", h("b") + "-a-1-debug", h("c") + "-b-1", h("d") + "-b-1-debug", h("f") + "-libc"
    def row(p, o, dbg="", deps="", s="x86_64-solaris"): return [p, "1", "u", "s", "autotools", deps, "f", s, o, dbg]
    def w(name, rows):
        with open(f"{d}/{name}", "w") as f: f.write("\n".join("\t".join(r) for r in [HDR] + rows) + "\n")
        return f"{d}/{name}"
    prior = w("prior.tsv", [row("libc", L)])
    REFS = {A: [L, A], Ad: [A], B: [A, L], Bd: []}
    fetch = lambda o: (o in REFS or o == L, REFS.get(o, [] if o == L else None))
    good = [row("a", A, Ad, "libc"), row("a", Ad, "", "a"), row("b", B, Bd, "a,libc"), row("b", Bd, "", "")]
    def t(desc, rows, want, **kw):
        nonlocal bad
        f, wn, n = check(w("b.tsv", rows), kw.pop("prior", prior), fetch=kw.pop("fetch", fetch), **kw)
        ok = (not f) if want is None else any(re.match(want, x) for x in f)
        bad += not ok; print(("ok  " if ok else "BAD ") + desc + ("" if ok else f": {f}"))
    t("a good batch (out + its own -debug row, deps from the NAR refs, deps first): PASS", good, None)
    t("NEG a debug column with no row of its own (wave7 part 1): C1", [good[0], good[2], good[3]], "C1")
    t("NEG a -debug row with its out row's deps (wave7 -debug v1: gcc,libc): C2", [good[0], row("a", Ad, "", "libc"), *good[2:]], "C2")
    t("NEG a -debug row naming its out's pname while its NAR references nothing (sparcv9 zlib-debug 2970): C2",
      [*good[:3], row("b", Bd, "", "b")], "C2")
    t("NEG a -debug row with empty deps while its NAR references its out: C2", [good[0], row("a", Ad, "", ""), *good[2:]], "C2")
    t("NEG an out row whose deps name a pname its NAR does not reference: C2", [row("a", A, Ad, "libc,b"), *good[1:]], "C2")
    t("NEG a reference rowed later in the batch: C3", [good[2], good[3], good[0], good[1]], "C3 .*rowed LATER")
    t("NEG a deps pname with no row anywhere: C3", [row("a", A, Ad, "libc,zz"), *good[1:]], "C3 .*deps zz has no")
    t("NEG an unserved, unrowed reference (a's out, not in this batch, not served): C3", [row("b", B, Bd, "libc"), good[3]], "C3 .*neither served nor rowed",
      fetch=lambda o: (o == L, REFS.get(o) if o != L else []) if o != A else (False, None))
    t("NEG an out twice in the batch: C4", good + [good[3]], "C4")
    t("NEG an out already a prior row: C4", good, "C4", prior=w("p2.tsv", [row("libc", L), row("b", Bd, "", "b")]))
    t("--replace: the same batch replaces that prior row: PASS", good, None, prior=w("p3.tsv", [row("libc", L), row("b", Bd, "", "b")]), replace=True)
    t("--historical: prior cut at the batch's first served row (later rows ignored): PASS", good, None,
      prior=w("p4.tsv", [row("libc", L), *good, row("z", h("z") + "-z-1", "", "a")]), historical=True)
    t("NEG no references known (unserved, no --pathinfo): C2 (fail closed)", good, "C2", fetch=lambda o: (False, None))
    t("NEG a 9-column row: C0", [good[0][:9], *good[1:]], "C0")
    json.dump({A: {"references": [L, A]}, Ad: {"references": [os.path.basename(A)]}}, open(f"{d}/pi.json", "w"))
    t("--pathinfo (full and base-name references) stands in for the narinfo", good[:2], None, pathinfo=[f"{d}/pi.json"], fetch=lambda o: (o == L, [] if o == L else None))
    print("RESULT:", "PASS" if bad == 0 else f"FAIL ({bad})"); return 1 if bad else 0

def main(a):
    if a == ["--selftest"]: return selftest()
    pr, pis, rep, his, rows = None, [], False, False, None
    i = 0
    while i < len(a):
        if a[i] == "--prior": pr = a[i + 1]; i += 2
        elif a[i] == "--pathinfo": pis.append(a[i + 1]); i += 2
        elif a[i] == "--replace": rep = True; i += 1
        elif a[i] == "--historical": his = True; i += 1
        elif rows is None and not a[i].startswith("--"): rows = a[i]; i += 1
        else: print(__doc__); return 2
    if not pr or not rows: print(__doc__); return 2
    f, wn, n = check(rows, pr, pis, rep, his)
    for x in wn: print("WARN", x)
    for x in f: print("FAIL", x)
    print(f"{'FAIL' if f else 'PASS'} {rows}: {n} rows, {len(f)} FAIL, {len(wn)} WARN")
    return 1 if f else 0

if __name__ == "__main__": sys.exit(main(sys.argv[1:]))
