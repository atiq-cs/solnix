#!/usr/bin/env python3
"""gate-checks.py: the defensive checks on what may reach cache.solnix.io (stdlib only, Python >= 3.9).

  gate-checks.py drv [--closure|--leaf] <drv>...   A. every derivation in the .drv closure of <drv> (--leaf: only those
                                         not yet served) builds from the store only
  gate-checks.py nar <out> [<nar>]       B. the published bytes: walk the NAR (nix-store --dump <out>, or a .nar/.nar.xz)
  gate-checks.py store <out>...          B5/B11 on the host's store copy (the NAR cannot carry them; see below)
  gate-checks.py closure <out>...        B12. no path of the runtime closure is marked not-for-cache
  gate-checks.py log <out> <log|->       L. the build log shows no host tool found or used (LOOPHOLES classes 1-3, 5)
  gate-checks.py stampkey <NarHash>      the stamp name pre-submit-check.sh writes and cache-submit.py --stamps requires
  gate-checks.py selftest                every check against a crafted bad input (must FAIL) and a good one (must PASS)

Prints one line per finding: "FAIL <check> <path>: <why>", "EXEMPT <check> <path>: <why>" or "WARN ...", then
"PASS|FAIL <path>". Exit 0 iff no FAIL. The exemption lists below are the only exemptions; each names its reason.

Why some checks are store-side (measured on dixi, nix 2.24.15, 2026-11-02): the NAR format records only "executable"
for a regular file, so chmod 4755, 0755 and 0777 dump to the same NAR, and nix-store --dump of a FIFO fails
("unsupported type"). setuid/setgid/sticky/world-writable bits, devices, FIFOs, sockets, owners and mtimes therefore
can never reach the cache in a NAR; on the host they mean the store path is not in Nix's canonical form (or was
tampered with after registration), which is what `store` checks before the host exports it.
"""
import io, json, lzma, os, re, stat, subprocess, sys

STORE = "/nix/store/"
HASH = r"[0-9a-df-np-sv-z]{32}"
STORE_RE = re.compile(r"/nix/store/(" + HASH + r")-([A-Za-z0-9+._?=-]+)")

# ---- exemptions (the only ones) ------------------------------------------------------------------------------------
# Two files, one list each (orchestrator 2026-11-03): the bootstrap set is pkgs/illumos/bootstrap-exempt.tsv (wave6's
# closed list: name regex + structural marker), and exact store paths are scripts/gate2-exemptions.tsv. Nothing else.
HERE = os.path.dirname(os.path.abspath(__file__))
def _rows(p):
    with open(p) as f:
        return [l.rstrip("\n").split("\t") for l in f if l.strip() and not l.startswith("#")]

def exempt_outs():
    p = os.environ.get("GATE_EXEMPT_PATHS") or os.path.join(HERE, "gate2-exemptions.tsv")
    return {r[0]: (r[1] if len(r) > 1 else "") for r in _rows(p)}

def bootstrap_rules():
    p = os.environ.get("GATE_BOOTSTRAP_EXEMPT") or os.path.join(HERE, "..", "pkgs", "illumos", "bootstrap-exempt.tsv")
    return [(re.compile(r[0]), r[1], r[2] if len(r) > 2 else "") for r in _rows(p)]

def _marker(m, d, clo):
    """The markers of bootstrap-exempt.tsv, exactly as wave6's pkgs/illumos/path-gate.sh --exempt-check applies them."""
    env = d["env"]
    if m == "seed": return "btPath" in env and env["btPath"] == ""
    if m == "gccseed": return env.get("stage0") == "/usr/gcc/14" and "gccSrc" in env and "btPath" not in env
    if m == "slice": return "gate" in env and "filesArg" in env
    if m == "world": return "gate" in env and "dirsArg" in env and "sharedLibsArg" in env
    if m == "fod": return env.get("outputHashMode") == "recursive" and len(env.get("outputHash", "")) + 1 > 40 and "btPath" not in env
    if m == "seedenv":   # every path it links is an output of an input drv that is itself seed, gccseed or seedenv
        ps = (env.get("paths", "") + " " + env.get("gnutar", "")).split()
        if not ps: return False
        for p in ps:
            if not any(p in {o["path"] for o in clo[i]["outputs"].values()} and
                       any(_marker(x, clo[i], clo) for x in ("seed", "gccseed", "seedenv"))
                       for i in d["inputDrvs"] if i in clo):
                return False
        return True
    raise ValueError(f"bootstrap-exempt.tsv: unknown marker {m!r}")

def bootstrap_class(name, d, clo, rules=None):
    """The bootstrap-exempt.tsv reason a derivation is exempt for, or None: its name matches a rule AND the marker holds."""
    for rx, m, why in (rules if rules is not None else bootstrap_rules()):
        if rx.fullmatch(name) and _marker(m, d, clo):
            return f"{m}: {why}"
    return None

_LANE = None
def ca_lane():
    """Fixed-output CA-lane paths, exempt by exact path (pinned by hash; the infra team stages them: the gate proto and
    sources). The SERVED registry/ca-lane.tsv is the one list; GATE_CA_LANE names a local file instead (tests, offline)."""
    global _LANE
    if _LANE is not None: return _LANE
    src = os.environ.get("GATE_CA_LANE")
    try:
        if src: text = open(src).read()
        else:
            import urllib.request
            req = urllib.request.Request("https://cache.solnix.io/registry/ca-lane.tsv", headers={"User-Agent": "solnix-gate-checks/1"})
            with urllib.request.urlopen(req, timeout=60) as r: text = r.read().decode()
        _LANE = {l.split("\t")[0] for l in text.splitlines() if l.startswith(STORE)}
    except OSError as e:
        print(f"WARN ca-lane: cannot read {src or 'the served ca-lane.tsv'} ({e}); no CA-lane exemption", file=sys.stderr)
        _LANE = set()
    return _LANE

# ---- ATerm .drv parser ---------------------------------------------------------------------------------------------
def parse_drv(text):
    """Derive([outputs],[inputDrvs],[inputSrcs],system,builder,[args],[env]) -> dict."""
    i = 0
    def ws():
        nonlocal i
        while i < len(text) and text[i] in " \n\t": i += 1
    def expect(s):
        nonlocal i
        ws()
        if not text.startswith(s, i): raise ValueError(f"drv parse: expected {s!r} at {i}: {text[i:i+30]!r}")
        i += len(s)
    def string():
        nonlocal i
        expect('"'); out = []
        while text[i] != '"':
            c = text[i]
            if c == "\\":
                i += 1; c = {"n": "\n", "t": "\t", "r": "\r"}.get(text[i], text[i])
            out.append(c); i += 1
        i += 1
        return "".join(out)
    def lst(item):
        nonlocal i
        expect("["); r = []; ws()
        if text[i] == "]": i += 1; return r
        while True:
            r.append(item()); ws()
            if text[i] == ",": i += 1; continue
            expect("]"); return r
    def tup(*items):
        expect("("); r = []
        for k, it in enumerate(items):
            if k: expect(",")
            r.append(it())
        expect(")"); return r
    expect("Derive")
    expect("(")
    outs = lst(lambda: tup(string, string, string, string)); expect(",")
    idrvs = lst(lambda: tup(string, lambda: lst(string))); expect(",")
    srcs = lst(string); expect(",")
    system = string(); expect(",")
    builder = string(); expect(",")
    args = lst(string); expect(",")
    env = dict(lst(lambda: tup(string, string))); expect(")")
    return {"outputs": {o[0]: {"path": o[1], "hashAlgo": o[2], "hash": o[3]} for o in outs},
            "inputDrvs": {d: o for d, o in idrvs}, "inputSrcs": srcs, "system": system,
            "builder": builder, "args": args, "env": env}

FAKE = {}   # selftest: path -> text, consulted before the filesystem

def read_text(p):
    if p in FAKE: return FAKE[p]
    with open(p, errors="replace") as f:
        return f.read()

def read_drv(p):
    return parse_drv(read_text(p))

def drv_closure(roots):
    seen, todo = {}, list(roots)
    while todo:
        p = todo.pop()
        if p in seen: continue
        seen[p] = read_drv(p)
        todo.extend(seen[p]["inputDrvs"])
    return seen

# ---- A: derivation checks ------------------------------------------------------------------------------------------
HOST_DIR = re.compile(r"^/(usr|opt|var|tmp|bin|sbin|lib|etc|home|root|export|sw|run|Users)(/|$)")
# PATH entries that are the builder's own scratch, not the host: build dir variables and $out.
OWN = re.compile(r"^\$\{?(W|PWD|TMPDIR|NIX_BUILD_TOP|SRC|S|S0|T|out|HOME|D|B|dir|tmp|bdir|srcdir|here)\}?(/|$)")
TOOL_VARS = ("MAKE", "SHELL", "CONFIG_SHELL", "M4", "INSTALL")
COMPILERS = re.compile(r"(^|/)(gcc|g\+\+|cc|c\+\+|clang|rustc|go|ld|as|gas|cpp)$")

def expand(s, env, depth=0):
    """Expand $x / ${x} / ${x:+word} from the drv env (what the builder starts with); unknown vars stay literal."""
    def rep(m):
        name, alt = m.group(1) or m.group(3), m.group(2)
        if name not in env: return m.group(0)
        v = env[name]
        if alt is not None: return expand(alt, env, depth + 1) if v else ""
        return expand(v, env, depth + 1) if depth < 4 else v
    return re.sub(r"\$\{(\w+):\+([^{}]*)\}|\$\{?(\w+)\}?", rep, s)

def path_assignments(text):
    """Every PATH=... in builder text: (value, line). Shell comments are dropped first."""
    out = []
    for line in text.splitlines():
        code = line if not line.lstrip().startswith("#") else ""
        code = re.sub(r"\s#.*$", "", code)
        for m in re.finditer(r"(?<![\w$])PATH=(\"[^\"]*\"|'[^']*'|[^\s;)&|]*)", code):
            out.append((m.group(1).strip("\"'"), line.strip()[:160]))
    return out

def tool_assignments(text):
    out = []
    for line in text.splitlines():
        code = re.sub(r"\s#.*$", "", line if not line.lstrip().startswith("#") else "")
        for m in re.finditer(r"(?<![\w$./-])(" + "|".join(TOOL_VARS) + r")=(\"[^\"]*\"|'[^']*'|[^\s;)&|]*)", code):
            out.append((m.group(1), m.group(2).strip("\"'"), line.strip()[:160]))
    return out

def bad_path_entries(value, env):
    bad = []
    for e in expand(value, env).split(":"):
        if e.startswith(STORE) or e in ("$PATH", "${PATH}") or OWN.match(e) or e == "": continue
        if "$" in e and not HOST_DIR.match(e): continue   # an unexpanded var we cannot resolve: not provably host
        if HOST_DIR.match(e) or not e.startswith("/"): bad.append(e)
    return bad

def builder_texts(d):
    """The builder's code: -c args, and every inputSrc .sh file passed as an argument or in env (the shared builders)."""
    texts = [a for a in d["args"]]
    for s in d["inputSrcs"]:
        if s.endswith(".sh") and (s in d["args"] or s in d["env"].values()):
            try: texts.append(read_text(s))
            except OSError: pass
    return texts

def check_drv(dp, d, ca_ok):
    """-> list of (level, check, why). level FAIL | WARN."""
    env, r = d["env"], []
    # A1: the builder's PATH
    if "PATH" in env:
        bad = bad_path_entries(env["PATH"], env)
        if bad: r.append(("FAIL", "A1-path", f"env PATH has host entries {' '.join(bad)}"))
    for t in builder_texts(d):
        for val, line in path_assignments(t):
            bad = bad_path_entries(val, env)
            if bad: r.append(("FAIL", "A1-path", f"builder sets PATH with host entries {' '.join(sorted(set(bad)))}: {line}"))
        for var, val, line in tool_assignments(t):
            v = expand(val, env)
            if v.startswith("/") and not v.startswith(STORE):
                r.append(("FAIL", "A1-tool", f"{var}={v} is a host path: {line}"))
    for var in TOOL_VARS:
        v = env.get(var)
        if v and v.startswith("/") and not v.startswith(STORE): r.append(("FAIL", "A1-tool", f"env {var}={v}"))
    # A2: impure environment
    for k, v in env.items():
        if re.match(r"^(LD_LIBRARY_PATH|LD_PRELOAD|LD_AUDIT|LD_CONFIG)", k): r.append(("FAIL", "A2-env", f"env {k}={v[:60]}"))
        if k in ("NIX_REMOTE", "NIX_PATH", "NIX_SSL_CERT_FILE_HOST"): r.append(("FAIL", "A2-env", f"env {k}={v[:60]}"))
        if k in ("TMPDIR", "TMP", "TEMP", "HOME") and HOST_DIR.match(v) and v != "/homeless-shelter":
            r.append(("FAIL", "A2-env", f"env {k}={v} (a host path)"))
    for t in builder_texts(d):
        for line in t.splitlines():
            code = re.sub(r"\s#.*$", "", line if not line.lstrip().startswith("#") else "")
            for m in re.finditer(r"(?<![\w$])(LD_PRELOAD\w*|LD_AUDIT\w*|NIX_REMOTE|NIX_PATH)=([^\s;]+)", code):
                r.append(("FAIL", "A2-env", f"builder sets {m.group(1)}={m.group(2)[:60]}"))
            for m in re.finditer(r"(?<![\w$])(LD_LIBRARY_PATH\w*)=(\"[^\"]*\"|[^\s;]+)", code):
                v = expand(m.group(2).strip('"'), env)
                if any(HOST_DIR.match(x) for x in v.split(":")):
                    r.append(("FAIL", "A2-env", f"builder sets {m.group(1)} to a host dir: {line.strip()[:120]}"))
            for m in re.finditer(r"(?<![\w$])(HOME|TMPDIR)=(\"[^\"]*\"|[^\s;]+)", code):
                v = expand(m.group(2).strip('"'), env)
                if HOST_DIR.match(v) and not v.startswith(("/var/tmp/", "/tmp/")) and v != "/homeless-shelter":
                    r.append(("FAIL", "A2-env", f"builder sets {m.group(1)}={v}"))
    # A3: builder + inputs are store paths
    b = d["builder"]
    if not (b.startswith(STORE) or b.startswith("builtin:") or b == "/usr/bin/bash"):
        r.append(("FAIL", "A3-builder", f"builder {b} is not a store path"))
    # A3b: a store path the builder names must be one Nix knows it depends on (an input drv's output, an inputSrc,
    # or its own output). Anything else is a builtins.storePath-style smuggle or a hard-coded path from another host:
    # Nix neither builds nor substitutes it, so the build only works where it happens to exist.
    known = {s[:44] for s in d["inputSrcs"]} | {o["path"][:44] for o in d["outputs"].values()}
    for idp, onames in d["inputDrvs"].items():
        try: dd = read_drv(idp)
        except OSError: continue
        known |= {dd["outputs"][o]["path"][:44] for o in onames if o in dd["outputs"]}
    named = {m.group(0)[:44] for t in list(env.values()) + d["args"] for m in STORE_RE.finditer(t)}
    for n in sorted(named - known):
        r.append(("FAIL", "A3-undeclared", f"names {n} but it is not an input of the derivation"))
    for s in d["inputSrcs"]:
        if not s.startswith(STORE): r.append(("FAIL", "A3-input", f"input {s} is not a store path")); continue
        ok = ca_ok(s)
        if ok is False: r.append(("FAIL", "A3-input", f"inputSrc {s} is neither content-addressed nor the output of a derivation (builtins.storePath of a built path?)"))
        if ok is None: r.append(("WARN", "A3-input", f"inputSrc {s}: not in this store, CA not checked"))
    # A4: fixed-output derivations
    if any(o["hashAlgo"] and not o["hash"] for o in d["outputs"].values()):
        r.append(("FAIL", "A4-fod", "content-addressed output without a pinned hash (no outputHash: floating CA, not used here)"))
    fod = [o for o in d["outputs"].values() if o["hash"]]
    if fod:
        if any(set(o["hash"]) <= {"0"} for o in fod) or set(env.get("outputHash", "x").split("-")[-1]) <= {"0", "A", "="}:
            r.append(("FAIL", "A4-fod", "fixed-output drv with the all-zero placeholder hash (lib.fakeHash): nothing is pinned"))
        hd = sorted({e for val in [env.get("PATH", "")] + [v for t in builder_texts(d) for v, _ in path_assignments(t)]
                     for e in expand(val, env).split(":") if e.startswith(("/usr/", "/opt/"))})
        if hd: r.append(("FAIL", "A4-fod", f"FOD builder PATH has host dirs {' '.join(hd)} (a fetcher may run only store fetch tools)"))
        for t in builder_texts(d):
            for m in re.finditer(r"(?<![\w$./-])(/usr/[\w/.+-]*|/opt/[\w/.+-]*)", t):
                if COMPILERS.search(m.group(1)): r.append(("FAIL", "A4-fod", f"FOD builder runs host compiler {m.group(1)}"))
    seen, uniq = set(), []
    for f in r:
        if f not in seen: seen.add(f); uniq.append(f)
    return uniq

def served_narinfo(p, _cache={}):
    """True iff cache.solnix.io has a narinfo for store path p (HTTP 200), False on 404, None if unreachable."""
    if p in _cache: return _cache[p]
    import urllib.request, urllib.error
    url = "https://cache.solnix.io/" + p[len(STORE):len(STORE) + 32] + ".narinfo"
    try:
        # a User-Agent is required: the cache answers 403 to Python's default one (measured 2026-11-03; curl gets 200)
        req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "solnix-gate-checks/1"})
        with urllib.request.urlopen(req, timeout=30) as r: _cache[p] = r.status == 200
    except urllib.error.HTTPError as e: _cache[p] = False if e.code == 404 else None
    except OSError: _cache[p] = None
    return _cache[p]

LEGACY_ENV_PATH = "/usr/gnu/bin:/usr/bin:/usr/sbin"
def allow_envpath(d):
    """shortcut: --leaf only, TEMPORARY. Delete this function and its one call in the commit where mk-src-pkg stops
    emitting the legacy drv attr PATH="/usr/gnu/bin:/usr/bin:/usr/sbin" (the wave6 merge; on wave6's checklist).
    The served rows recipes1 made hermetic still carry that attr, but their builder replaces PATH before it runs any
    command (orchestrator 2026-11-03: they need their NARs). Exact condition, anything else FAILs: the builder is
    /usr/bin/bash, env PATH is exactly the legacy value, no BASH_ENV/ENV, and the -c text's first statement is a PATH=
    that passes A1, with only `set -<flags>` (a builtin: no PATH lookup) allowed before it."""
    env = d["env"]
    if d["builder"] != "/usr/bin/bash" or env.get("PATH") != LEGACY_ENV_PATH or "BASH_ENV" in env or "ENV" in env:
        return False
    if len(d["args"]) != 2 or d["args"][0] != "-c":
        return False
    for line in d["args"][1].splitlines():
        for stmt in re.split(r"\s*;\s*", line.strip()):
            if not stmt or stmt.startswith("#"): break
            if re.fullmatch(r"set -[euxo]+( pipefail)?", stmt): continue
            m = re.match(r"(?:export\s+)?PATH=(\"[^\"]*\"|'[^']*'|[^\s;]*)(\s|$)", stmt)
            return bool(m) and not bad_path_entries(m.group(1).strip("\"'"), env)
    return False

def run_drv(drvs, out=print, ca_ok=None, mode="closure", served=None):
    """mode closure (strict; host first publishing via pre-submit-check.sh): every drv in the deriver's closure.
    mode leaf (the orchestrator's cache-submit path): the deriver plus every input drv with an output that is NOT served
    (what a substituting build would actually run); served inputs were judged when they were submitted. Leaf mode prints
    the closure's host-PATH drv count as INFO so the debt stays visible."""
    nix_ok = subprocess.run(["sh", "-c", "command -v nix-store"], capture_output=True).returncode == 0
    served = served or served_narinfo
    cache = {}
    def _ca_ok(p):
        if p in cache: return cache[p]
        if not nix_ok or not os.path.exists(p): cache[p] = None; return None
        q = subprocess.run(["nix-store", "-q", "--deriver", p], capture_output=True, text=True)
        j = subprocess.run(["nix", "--extra-experimental-features", "nix-command", "path-info", "--json", p],
                           capture_output=True, text=True)
        try:
            info = json.loads(j.stdout); info = info[p] if isinstance(info, dict) else info[0]
            cache[p] = bool(info.get("ca")) or (q.stdout.strip() not in ("", "unknown-deriver") and q.stdout.strip().endswith(".drv"))
        except (ValueError, KeyError, IndexError, TypeError):
            cache[p] = None
        return cache[p]
    ca_ok = ca_ok or _ca_ok
    rc = 0; lane = ca_lane(); exact = exempt_outs(); rules = bootstrap_rules()
    for root in drvs:
        if not (root.startswith(STORE) and root.endswith(".drv") and (root in FAKE or os.path.exists(root))):
            out(f"FAIL A0 {root}: not an existing .drv"); rc = 1; continue
        clo = drv_closure([root]); nfail = nex = 0; exempt_roots = set(); by_class = {}
        if mode == "leaf":
            # the probe must see a served path as served, else 'unserved' means nothing (the urllib User-Agent 403 made
            # every input look unserved, 2026-11-03): a CA-lane path is served by definition
            ctl = sorted(lane)[:1]
            if not ctl or served(ctl[0]) is not True:
                out(f"FAIL A0 {root}: the served-state probe does not see the served CA-lane path {ctl[0] if ctl else '(none: ca-lane.tsv unreadable)'}; leaf mode cannot judge")
                rc = 1; continue
            # walk from the root, descending only into input drvs that have an unserved output
            judged, todo, unknown = set(), [root], 0
            while todo:
                dp = todo.pop()
                if dp in judged: continue
                judged.add(dp)
                for idp, onames in clo[dp]["inputDrvs"].items():
                    if idp in judged: continue
                    ops = [clo[idp]["outputs"][o]["path"] for o in onames if o in clo[idp]["outputs"]]
                    sv = [served(op) for op in ops]
                    if None in sv: unknown += 1
                    if not all(sv): todo.append(idp)
            if unknown:
                out(f"FAIL A0 {root}: {unknown} input(s) with unknown served state (cache unreachable or refusing): leaf mode cannot judge")
                nfail += 1
        else:
            judged = set(clo)
        host_debt = 0
        for dp, d in sorted(clo.items()):
            outs = {o["path"] for o in d["outputs"].values()}
            name = d["env"].get("name", dp[44:-4])
            findings = check_drv(dp, d, ca_ok)
            if mode == "leaf" and dp in judged and allow_envpath(d):
                envf = [f for f in findings if f[1] == "A1-path" and f[2].startswith("env PATH")]
                if envf:
                    findings = [f for f in findings if f not in envf]
                    out(f"ALLOW A1-envpath {dp}: {name}: legacy env PATH {LEGACY_ENV_PATH}, replaced by the builder's first statement (temporary, --leaf only)")
            hard = [f for f in findings if f[0] == "FAIL"]
            if dp not in judged:
                host_debt += bool(hard); continue
            ex = next((exact[o] for o in outs if o in exact), None)
            if not ex and outs & lane and all(o["hash"] for o in d["outputs"].values()):
                ex = "CA-lane fixed-output path (pinned by hash, served ca-lane.tsv)"
            bc = bootstrap_class(name, d, clo, rules) if hard and not ex else None
            if hard and (ex or bc):
                nex += 1; exempt_roots.add(dp)
                if ex and not ex.startswith("CA-lane"):
                    # an exact-path exemption is always listed by path (orchestrator, 2026-11-02)
                    out(f"EXEMPT {dp}: {name} by exact out path ({'; '.join(sorted(set(h[1] for h in hard)))}): {ex}")
                else:
                    by_class.setdefault(ex or bc, []).append(name)
                continue
            for lvl, chk, why in findings:
                out(f"{lvl} {chk} {dp}: {name}: {why}")
            if hard: nfail += 1
        for why_, names_ in sorted(by_class.items()):
            out(f"EXEMPT class {why_}: {len(names_)} drvs: {' '.join(sorted(set(names_)))}")
        if mode == "leaf":
            out(f"INFO A0 {root}: leaf mode judged {len(judged)} of {len(clo)} drvs (the rest have served outs); "
                f"{host_debt} served drvs in the closure fail A1-A4 (judged when they were submitted: the debt)")
        verdict = "PASS" if nfail == 0 else "FAIL"
        out(f"{verdict} {root} ({mode} mode: {len(judged)} drvs judged of {len(clo)}: {nfail} failing, {nex} exempt"
            f"{'; the root itself is EXEMPT' if root in exempt_roots else ''})")
        rc |= nfail != 0
    return rc


# ---- B: out checks over the NAR (the published bytes) ------------------------------------------------------------------
class NarError(Exception): pass

def nar_entries(f):
    """Yield (relpath, kind, info) for a NAR stream: kind in 'dir' 'reg' 'link'; info = {'exec': bool, 'data': bytes} for
    reg (data = the whole contents; files here are < 1 GB), {'target': str} for link. Raises NarError on bad framing."""
    def rd(n):
        b = f.read(n)
        if len(b) != n: raise NarError("truncated NAR")
        return b
    def num(): return int.from_bytes(rd(8), "little")
    def string():
        n = num(); b = rd(n); rd((8 - n % 8) % 8); return b
    def expect(x):
        got = string()
        if got != x: raise NarError(f"expected {x!r}, got {got[:40]!r}")
    expect(b"nix-archive-1")
    def node(path):
        expect(b"("); expect(b"type"); t = string()
        if t == b"regular":
            ex, tag = False, string()
            if tag == b"executable": expect(b""); ex = True; tag = string()
            if tag != b"contents": raise NarError("no contents")
            n = num(); data = rd(n); rd((8 - n % 8) % 8); expect(b")")
            yield path, "reg", {"exec": ex, "data": data}
        elif t == b"symlink":
            expect(b"target"); tg = string().decode("utf-8", "surrogateescape"); expect(b")")
            yield path, "link", {"target": tg}
        elif t == b"directory":
            yield path, "dir", {}
            while True:
                tag = string()
                if tag == b")": break
                if tag != b"entry": raise NarError("bad directory entry")
                expect(b"("); expect(b"name"); name = string().decode("utf-8", "surrogateescape"); expect(b"node")
                yield from node(f"{path}/{name}" if path else name)
                expect(b")")
        else:
            raise NarError(f"unknown node type {t!r}")
    yield from node("")

def open_nar(src):
    """src: a store path (nix-store --dump), or a .nar / .nar.xz file."""
    if src.endswith(".nar.xz"): return lzma.open(src, "rb")
    if src.endswith(".nar"): return open(src, "rb")
    pr = subprocess.Popen(["nix-store", "--dump", src], stdout=subprocess.PIPE)
    return io.BufferedReader(pr.stdout, 1 << 20)

# B13: absolute host paths that configure/libtool bake (jq 1.8.2 MAKE=/usr/gnu/bin/make; diffutils /usr/gnu/bin/pr).
HOST_STR = re.compile(rb"(/usr/gnu/|/opt/ooce|/opt/nixboot|/usr/gcc/|/usr/local/|/var/tmp/big)")
# /usr/local is the upstream default everywhere (XDG_DATA_DIRS fallback /usr/local/share:/usr/share, libtool's search
# table, wgetrc/neomuttrc examples): nixpkgs ships the same strings (measured: dbus-1.14.10 bin/dbus-daemon, wget-1.25.0
# etc/wgetrc) and neither dixi nor a NixOS host has it, so it is WARN. The others exist only on an OI build host.
WARN_ONLY = (b"/usr/local/",)
# Upstream compiled-in defaults: a whole NUL-terminated C string in an ELF, exactly one of these, is an upstream search
# default, not a tool path configure baked. GNU make's src/read.c default_include_directories ("/usr/gnu/include" beside
# "/usr/local/include", "/usr/include") is in the served x86 gnumake yc7i5s3r and aarch64 kipf3wwd, and in nixpkgs' make.
# Exact strings only: anything else under /usr/gnu still FAILs.
UPSTREAM_DEFAULTS = {b"/usr/gnu/include"}
def upstream_default(data, at):
    a = data.rfind(b"\0", 0, at) + 1; b = data.find(b"\0", at); b = len(data) if b < 0 else b
    return data[a:b] in UPSTREAM_DEFAULTS
TOKEN_CH = set(b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.+-/${}()")
def search_list(data, at):
    """True if the hit sits in a ':'-separated list of >= 4 absolute dirs inside one NUL-terminated string: an upstream
    compiled-in search path (texinfo's DEFAULT_INFOPATH /usr/local/info:...:/usr/gnu/info:/opt/gnu/info, measured in
    nixpkgs texinfo-interactive-7.2 too), not a tool path configure baked."""
    a = data.rfind(b"\0", 0, at) + 1; b = data.find(b"\0", at); b = len(data) if b < 0 else b
    parts = [x for x in data[a:b].split(b":") if x not in (b"", b".", b"PATH")]   # texinfo's list starts with its "PATH" placeholder
    return len(parts) >= 4 and all(x.startswith(b"/") for x in parts)

def host_hits(data):
    """HOST_STR matches that are a host path, not a subpath of a store path (/nix/store/<h>-world/usr/gnu/...) or of a
    variable ($out/usr/local, ${prefix}/usr/gnu): scan back to the start of the token and skip those two."""
    for m in HOST_STR.finditer(data):
        i = m.start()
        while i > 0 and data[i - 1] in TOKEN_CH: i -= 1
        tok = data[i:m.start()]
        tok = tok.lstrip(b"-").lstrip(b"ILRDW").lstrip(b",") if tok[:1] == b"-" else tok   # -L/opt/ooce, -Wl,-R/usr/gcc
        if tok.startswith(b"/nix/store/") or tok.startswith(b"$") or tok.startswith(b"@"): continue
        if tok and not tok.startswith(b"/") and tok[:1] not in (b"=", b"'", b'"'):
            if b"/" in tok: continue   # a relative path that ends in .../usr/gnu/: under some prefix, not the host's
        yield m
# B8: build-dir strings: the unmapped fixed build dirs of our builders FAIL. /build/ is the prefix-map target
# (-ffile-prefix-map=$W=/build, NixOS's sandbox build dir): NixOS ships it outside debug files too (measured on floki:
# nixpkgs zstd-1.5.7 bin has /build/source/programs/util.c from an assert's __FILE__; python3-3.13.14 /build/deepfreeze.py),
# so it is counted (INFO), not failed.
BUILD_STR = re.compile(rb"/var/tmp/(srcpkg|cargo|go|rust|gccsrc|gate-build|proto)-[A-Za-z0-9.]+|(?:(?<![A-Za-z0-9_.+/-])|(?<=-[IL]))/build/")
# B8 split (orchestrator 2026-11-03). DRV-KEYED: our builders' fixed dir /var/tmp/<kind>-<buildKey>, buildKey = 16 hex of
# sha256(drv attrs) (mk-src-pkg.nix), so the string is the same on every host and every run (jq/wget/socat: identical NARs
# from two hosts). HOST/RUN-SPECIFIC: anything else (a random mktemp suffix, Nix's /tmp/nix-build-<name>-<n>, the
# big-disk scratch, a home dir): those FAIL.
DRV_KEYED = re.compile(rb"^/var/tmp/(srcpkg|cargo|go|rust|gccsrc)-[0-9a-f]{16}$")
# A home dir counts only for the accounts that build or check here (gburd on floki/dixi/lixi, root on the OI hosts,
# the nixbld users); upstream example text names other homes (gdb's "/home/user/hello.c", CPAN's "/home/ftp/", also in
# nixpkgs gdb-16.3's bin/gdb), so a general /home/* rule failed real outs (measured 2026-11-03). GATE_HOME_USERS adds
# names (space-separated).
_HOMES = sorted({"gburd", "nixbld"} | set(os.environ.get("GATE_HOME_USERS", "").split()))
RUN_DIR_STR = re.compile(rb"(?:/private)?/tmp/nix-build-[A-Za-z0-9+._?=-]+|/var/tmp/big(?=/|\b)"
                         rb"|(?<![A-Za-z0-9_.+-])/(?:export/)?home/(?:" + "|".join(re.escape(h) for h in _HOMES).encode() + rb")[0-9]*(?=/|\b)"
                         # root's build caches only: a path INTO them is what a root build leaks (cargo registry sources, a
                         # rustup toolchain, go's build cache); "rm /root/.cache/nix/..." in nix's globals.hh comment and
                         # flyctl's help text (also in nixpkgs flyctl-0.4.108) is upstream text (measured 2026-11-03)
                         rb"|(?<![A-Za-z0-9_.+-])/root/\.(?:cargo/(?:registry|git)|rustup/toolchains|cache/go-build|cache/go-mod)/")
# B9: #! interpreters allowed outside the store (POSIX sh and env, as in nixpkgs before patchShebangs). /usr/bin/sh too:
# on illumos /bin is a symlink to /usr/bin, so it is the same always-present system shell as /bin/sh (orchestrator
# 2026-11-03, quilt spec-filters/obs). Only that one: /usr/bin/bash, /usr/bin/perl, /usr/bin/python* still FAIL.
SHEBANG_OK = {"/bin/sh", "/usr/bin/sh", "/usr/bin/env"}
# B13 allowlist: text that merely MENTIONS a host path (documentation), not a path the program uses.
DOC_RE = re.compile(r"(^|/)share/(man|info|doc|gtk-doc|help|licenses)/|(^|/)(man|doc)/|\.(1|3|5|7|8|[1-9][a-z]*|info|html|txt|md|rst|pdf)(\.gz)?$")

def is_elf(b): return b[:4] == b"\x7fELF"

def elf_live_strings(data):
    """For a 64/32-bit little-endian ELF: the .dynstr byte range and a predicate 'offset is the start of, or inside, a
    string some DT_NEEDED/SONAME/RPATH/RUNPATH entry points at'. None if it cannot be parsed. Used only to tell a stale
    string (the gate's original RUNPATH left behind when elfedit wrote the store one: measured on rtld libld.so.4, the
    /usr/gcc/10/lib/amd64 at .dynstr+0x4ca5 with DT_RUNPATH at +0x4cbb) from a live one."""
    import struct
    try:
        if data[4] not in (1, 2) or data[5] != 1: return None
        is64 = data[4] == 2
        if is64: shoff, shentsize, shnum = struct.unpack_from("<Q", data, 0x28)[0], *struct.unpack_from("<HH", data, 0x3A)
        else: shoff, shentsize, shnum = struct.unpack_from("<I", data, 0x20)[0], *struct.unpack_from("<HH", data, 0x2E)
        secs = []
        for i in range(shnum):
            o = shoff + i * shentsize
            if is64: _, typ, _, _, off, size, link = struct.unpack_from("<IIQQQQI", data, o)
            else: _, typ, _, _, off, size, link = struct.unpack_from("<IIIIIII", data, o)
            secs.append((typ, off, size, link))
        dyn = next((s for s in secs if s[0] == 6), None)   # SHT_DYNAMIC
        if not dyn: return None
        _, doff, dsize, link = dyn; _, soff, ssize, _ = secs[link]
        ent = 16 if is64 else 8; used = []
        for k in range(dsize // ent):
            tag, val = struct.unpack_from("<qQ" if is64 else "<iI", data, doff + k * ent)
            if tag in (1, 14, 15, 29): used.append(soff + val)   # NEEDED SONAME RPATH RUNPATH
        ends = {u: data.index(b"\0", u) for u in used}
        return {"dynstr": range(soff, soff + ssize), "used": lambda x: any(u <= x < e for u, e in ends.items())}
    except (struct.error, IndexError, ValueError):
        return None

def check_nar(out, src=None):
    """-> (findings, counts). findings: (level, check, why)."""
    r, n = [], {"files": 0, "links": 0, "dirs": 0, "shebang_exceptions": {}}
    inside = lambda t: t.startswith(STORE)
    names, links = set(), {}
    def resolve(rel):
        """Follow rel (a symlink in the out) component by component: 'in' (lands on an entry of this out), 'store'
        (an absolute /nix/store/ path that exists here or whose store path is absent, so unknown), or a failure:
        'host', 'dangling', 'out-of-tree', 'loop'."""
        st, comps, hops = [], rel.split("/") if rel else [], 0
        if rel == "":   # the out itself is a symlink
            t = links[""]; return "store" if inside(t) else "host"
        while comps:
            x = comps.pop(0)
            if x in ("", "."): continue
            if x == "..":
                if not st: return "out-of-tree"
                st.pop(); continue
            st.append(x); cur = "/".join(st)
            if cur in links:
                hops += 1
                if hops > 40: return "loop"
                t = links[cur]; st.pop()
                if t.startswith("/"):
                    if t == out or t.startswith(out + "/"):
                        st, comps = [], t[len(out) + 1:].split("/") + comps; continue
                    if not inside(t): return "host"
                    full = t + ("/" + "/".join(comps) if comps else "")
                    top = STORE + t[len(STORE):].split("/")[0]
                    return "dangling" if os.path.isdir(top) and not os.path.lexists(full) else "store"
                comps = t.split("/") + comps
            elif cur not in names:
                return "dangling"
        return "in"
    shebangs = {}
    try:
      for rel, kind, info in nar_entries(open_nar(src or out)):   # streamed: one file's data in memory at a time
        names.add(rel)
        if kind == "dir": n["dirs"] += 1; continue
        if kind == "link":
            n["links"] += 1; links[rel] = info["target"]; r.extend(server_checks(rel, target=info["target"])); continue
        n["files"] += 1
        data, top = info["data"], rel.split("/")[0]
        r.extend(server_checks(rel, data=data))
        r.extend(config_record_findings(rel, data))
        # B7: bin/ and sbin/ hold executables (libtool 2.5.4 shipped bin/libtool 0444; gzip zgrep)
        if top in ("bin", "sbin") and rel.count("/") == 1 and not info["exec"]:
            r.append(("FAIL", "B7-exec", f"{rel} is not executable"))
        dbg = "/lib/debug/" in "/" + rel or rel.endswith(".debug")
        # B8: build directories
        b8 = None
        for m in BUILD_STR.finditer(data):
            if m.group(0) == b"/build/":
                n["mapped_build"] = n.get("mapped_build", 0) + (0 if dbg else 1); continue
            if DRV_KEYED.match(m.group(0)):
                # shortcut: WARN while mk-src-pkg's configure/compile strings name the $W/cc64 shim; becomes FAIL once wave6
                # makes them name the store compiler wrapper (on wave6's checklist, gate2 2026-11-03).
                b8 = b8 or ("WARN", "B8-builddir", f"{rel} names {m.group(0).decode()} (drv-keyed build dir: same on every host)")
            else:
                b8 = ("FAIL", "B8-builddir", f"{rel} names {m.group(0).decode(errors='replace')} (a build dir that is not drv-keyed)"); break
        m = RUN_DIR_STR.search(data)
        if m:
            b8 = ("FAIL", "B8-builddir", f"{rel} names {m.group(0).decode(errors='replace')} (a host- or run-specific dir)")
        if b8: r.append(b8)
        # B9: #! interpreter of an EXECUTABLE file (what the kernel runs; NixOS patchShebangs also only touches executables).
        # A relative interpreter (#!perl, #!./perl in perl's own .pm templates) names no host path: not checked.
        if data[:2] == b"#!" and info["exec"]:
            line = data[2:200].split(b"\n")[0].strip().decode(errors="replace")
            interp = line.split()[0] if line.split() else ""
            if interp.startswith("/") and not inside(interp):
                if interp in SHEBANG_OK: shebangs[interp] = shebangs.get(interp, 0) + 1
                else: r.append(("FAIL", "B9-shebang", f"{rel}: #!{line[:80]}"))
        # B10: bytecode
        if rel.endswith((".pyc", ".pyo")):
            # PEP 552 flags word at bytes 4..8: 0 = timestamp pyc (host mtime baked; an install-time or root import
            # wrote it); 1/3 = hash-based (deterministic, what NixOS and wave3's python-nopyc ship).
            if len(data) >= 16 and int.from_bytes(data[4:8], "little") == 0:
                r.append(("FAIL", "B10-pyc", f"{rel}: timestamp-mode pyc (written by an import during the build, not compileall --invalidation-mode checked-hash)"))
        # B13: host tool paths baked into the out: report the first FAIL-class hit, else the first WARN-class one
        hits = list(host_hits(data))
        if hits:
            elf = is_elf(data)
            live = elf_live_strings(data) if elf else None
            def lvl(m):
                if m.group(0) in WARN_ONLY: return "WARN"
                if elf and search_list(data, m.start()): return "WARN"
                if elf and upstream_default(data, m.start()): return "WARN"
                if elf and live is not None and m.start() in live["dynstr"] and not live["used"](m.start()): return "INFO"
                return "WARN" if (not elf and DOC_RE.search(rel)) else "FAIL"
            order = {"FAIL": 0, "WARN": 1, "INFO": 2}
            m = min(hits, key=lambda h: (order[lvl(h)], h.start()))
            L_ = lvl(m)
            if elf: ctx = data[m.start():m.end() + 40].split(b"\0")[0].decode(errors="replace")
            else: ctx = "..." + data[max(0, m.start() - 30):m.end() + 30].decode(errors="replace").replace("\n", " ") + "..."
            why = " (a stale .dynstr string no dynamic entry uses)" if L_ == "INFO" else ""
            r.append((L_, "B13-hostpath", f"{rel}{' (ELF)' if elf else ''} names {ctx}{why}"))
    except NarError as e:
        return [("FAIL", "B0-nar", f"NAR unreadable: {e}")], n
    for rel in sorted(links):
        v = resolve(rel)
        if v == "host": r.append(("FAIL", "B6-symlink", f"{rel} -> {links[rel]} (outside the store)"))
        elif v not in ("in", "store"): r.append(("FAIL", "B6-symlink", f"{rel} -> {links[rel]} ({v})"))
    n["shebang_exceptions"] = shebangs
    if n.get("mapped_build"):
        r.append(("INFO", "B8-builddir", f"{n['mapped_build']} non-debug files name the mapped build dir /build/ (prefix map; NixOS normal)"))
    if shebangs:
        r.append(("INFO", "B9-shebang", "exceptions: " + ", ".join(f"#!{k} x{v}" for k, v in sorted(shebangs.items()))))
    # cap repeated findings per check so one bad tree stays readable
    capped, per = [], {}
    for f in r:
        per[f[1]] = per.get(f[1], 0) + 1
        if per[f[1]] <= 20: capped.append(f)
    for k, v in per.items():
        if v > 20: capped.append(("INFO", k, f"... {v - 20} more"))
    return capped, n

# ---- S: mirror of the server's NAR content gate (infra k8s/validate-nar-content.py, 05e799c; 20261103-v2b-live s6) --------
# Enforced for tier 1, log-only for tier 2. Ours is at least as strict, so nothing we submit is rejected there.
#  S1 every DT_RUNPATH / DT_RPATH entry is under /nix/store/ or starts with $ORIGIN
#  S2 PT_INTERP is under /nix/store/, or {/lib,/usr/lib}/{,64/,amd64/,sparcv9/,aarch64/}ld.so.1, $ORIGIN/..., empty, or
#     /.SUNWnative/usr/lib/... (the sn1 brand)
#  S3 build-host strings in any file or symlink target, case-insensitive: *.compute.internal, *.ec2.internal,
#     solnix-builder-build
#  S4 host names, case-sensitive, not inside a longer word: dixi dixa dixr lixi floki
INTERP_OK = re.compile(r"^(/nix/store/.*|(/lib|/usr/lib)/(64/|amd64/|sparcv9/|aarch64/)?ld\.so\.1|\$ORIGIN.*|/\.SUNWnative/usr/lib/.*|)$")
BUILDHOST_RE = re.compile(rb"compute\.internal|ec2\.internal|solnix-builder-build", re.I)
HOSTNAME_RE = re.compile(rb"(?<![A-Za-z0-9_])(dixi|dixa|dixr|lixi|floki)(?![A-Za-z0-9_])")

def elf_dynamic(data):
    """(runpath entries [(tag, value)], interp or None) for an ELF of either class/endianness, or None if unparseable."""
    import struct
    try:
        if data[:4] != b"\x7fELF": return None
        is64, end = data[4] == 2, "<" if data[5] == 1 else ">"
        if is64:
            phoff, shoff = struct.unpack_from(end + "QQ", data, 0x20)
            phentsize, phnum, shentsize, shnum = struct.unpack_from(end + "HHHH", data, 0x36)
        else:
            phoff, shoff = struct.unpack_from(end + "II", data, 0x1C)
            phentsize, phnum, shentsize, shnum = struct.unpack_from(end + "HHHH", data, 0x2A)
        interp, rp = None, []
        for i in range(phnum):
            o = phoff + i * phentsize
            typ = struct.unpack_from(end + "I", data, o)[0]
            if typ == 3:   # PT_INTERP
                off, size = (struct.unpack_from(end + "QQQQ", data, o + 8)[0], struct.unpack_from(end + "Q", data, o + 32)[0]) if is64 \
                    else (struct.unpack_from(end + "I", data, o + 4)[0], struct.unpack_from(end + "I", data, o + 16)[0])
                interp = data[off:off + size].split(b"\0")[0].decode(errors="replace")
        secs = []
        for i in range(shnum):
            o = shoff + i * shentsize
            if is64: _, typ, _, _, off, size, link = struct.unpack_from(end + "IIQQQQI", data, o)
            else: _, typ, _, _, off, size, link = struct.unpack_from(end + "IIIIIII", data, o)
            secs.append((typ, off, size, link))
        for typ, off, size, link in secs:
            if typ != 6: continue   # SHT_DYNAMIC
            soff = secs[link][1]; ent = 16 if is64 else 8
            for k in range(size // ent):
                tag, val = struct.unpack_from(end + ("qQ" if is64 else "iI"), data, off + k * ent)
                if tag == 0: break
                if tag in (15, 29):   # DT_RPATH, DT_RUNPATH
                    v = data[soff + val:data.index(b"\0", soff + val)].decode(errors="replace")
                    rp.append(("DT_RPATH" if tag == 15 else "DT_RUNPATH", v))
        return rp, interp
    except (struct.error, IndexError, ValueError):
        return None

def server_checks(rel, data=None, target=None):
    """-> [(level, check, why)] for one NAR entry: a regular file (data) or a symlink (target)."""
    r = []
    if target is not None:
        if BUILDHOST_RE.search(target.encode(errors="surrogateescape")):
            r.append(("FAIL", "S3-buildhost", f"{rel}: symlink target {target} names a build host"))
        if HOSTNAME_RE.search(target.encode(errors="surrogateescape")):
            r.append(("FAIL", "S4-hostname", f"{rel}: symlink target {target} names a host"))
        return r
    if data[:4] == b"\x7fELF":
        dyn = elf_dynamic(data)
        if dyn:
            rp, interp = dyn
            for tag, v in rp:
                for e in v.split(":"):
                    if not (e.startswith(STORE) or e.startswith("$ORIGIN")):
                        r.append(("FAIL", "S1-runpath", f"{rel}: {tag} entry {e!r} is not under /nix/store or $ORIGIN"))
            if interp is not None and not INTERP_OK.match(interp):
                r.append(("FAIL", "S2-interp", f"{rel}: PT_INTERP {interp} is not the store or the illumos ld.so.1"))
    m = BUILDHOST_RE.search(data)
    if m: r.append(("FAIL", "S3-buildhost", f"{rel}: contains {m.group(0).decode(errors='replace')!r} (@{m.start()})"))
    m = HOSTNAME_RE.search(data)
    if m:
        ctx = data[max(0, m.start() - 20):m.end() + 20].decode(errors="replace").replace("\n", " ")
        r.append(("FAIL", "S4-hostname", f"{rel}: names host {m.group(0).decode()!r}: ...{ctx}..."))
    return r


# ---- L: the build log (LOOPHOLES.md classes 1, 2, 3, 5: a store-only PATH that still reached the host) ----------------
# The log exists only where the out was built (nix log <drv>), so pre-submit-check.sh runs this on the host. Each rule
# is a line shape a real build printed (recipes1 LOOPHOLES.md + chef logs, 2026-11-03); the store-only wave6 jq
# fvf9shlz log matches none of them (negative control on real data).
# Classified by WHERE the path points (measured on dixi + chef logs, 2026-11-03):
#  OI-only dirs (/usr/gnu /opt /usr/gcc /usr/local /usr/sfw /usr/ccs): never on a solnix host, so a hit means the build
#    used the OI host's tool: FAIL (jq "checking whether /usr/gnu/bin/make sets $(MAKE)"; automake sh=/usr/gnu/bin/sh).
#  other system dirs (/usr/bin /usr/sbin /usr/xpg4 /bin /sbin): mostly configure's hard-coded runtime defaults (w3m's
#    /usr/bin/firefox and rsync's /usr/bin/fakeroot do not exist on dixi; openssh's /usr/sbin/groupadd): WARN, listed.
#  /bin/sh, /usr/bin/sh: the system shell (as B9): not reported.
#  cmake/meson "Found X: /usr/..." is their own system-prefix search past PATH (LOOPHOLES class 5): FAIL for any host
#    path, since those are tools the build then runs.
# Only a line whose result is a path (+ flags) counts: "checking for X... /bin/sh ./libtool --mode=..." is make output
# interleaved into configure's line (gdb), not a result.
OI_ONLY = re.compile(r"^/(usr/(gnu|gcc|local|sfw|ccs)|opt)(/|$)")
SYS_SHELL = ("/bin/sh", "/usr/bin/sh")
_CONF_RES = re.compile(r"^checking (.*?)\.\.\. (?:\(cached\) )?(/[^\s]+)((?:\s+-[\w-]+)*)\s*$")
_CONF_WHETHER = re.compile(r"^checking whether (/[^\s]+) ")
_CMAKE = re.compile(r"^-- (?:Found|Check for working|Looking for|Using) .*?(?<![\w./-])(/(?:usr|opt|bin|sbin)/[\w.+/-]+)")
_MESON = re.compile(r"^Program .* found: YES \((/(?:usr|opt|bin|sbin)/[^)\s]+)")

def _classify(path):
    if path.startswith(STORE) or path in SYS_SHELL: return None
    if OI_ONLY.match(path): return "FAIL"
    if re.match(r"^/(usr/(bin|sbin|xpg4|xpg6|ucb)|bin|sbin)(/|$)", path): return "WARN"
    return None

def _log_line(line):
    """-> [(level, check, why)] for one log line."""
    m = _CONF_RES.match(line) or _CONF_WHETHER.match(line)
    if m:
        path = m.group(2) if m.re is _CONF_RES else m.group(1)
        lv = _classify(path)
        if lv: return [(lv, "L1-configure", f"configure used {'an OI-host' if lv == 'FAIL' else 'a system'} path {path}")]
    m = _CMAKE.match(line) or _MESON.match(line)
    if m and not m.group(1).startswith(STORE) and m.group(1) not in SYS_SHELL:
        return [("FAIL", "L5-cmake" if m.re is _CMAKE else "L5-meson", f"found on the host past PATH: {m.group(1)}")]
    if re.match(r"^Configure: ignoring -D \w+=", line):
        # not a defect by itself: perl-5.42.2 (no-sys-dirs) prints it with a clean Config; B15 judges the recorded Config
        return [("WARN", "L2-configure-ignored", "perl Configure ignored a -D (use -U); B15 checks what Config recorded")]
    m = re.match(r"^Checking compatibility between (/\S+)", line)
    if m and _classify(m.group(1)) == "FAIL": return [("FAIL", "L2-configure-host", f"perl Configure probed {m.group(1)}")]
    if re.search(r"no POSIX shell found|: command not found$", line):
        return [("FAIL", "L3-missing", "a tool the store PATH lacks")]
    return []

def check_log(text):
    r, seen = [], {}
    for n, line in enumerate(text.splitlines(), 1):
        line = re.sub(r"^[\w.+-]+> ", "", line).rstrip()   # nix-build's "<name>> " prefix
        for lv, chk, why in _log_line(line):
            k = (lv, chk); seen[k] = seen.get(k, 0) + 1
            if seen[k] <= 5: r.append((lv, chk, f"line {n}: {why}: {line.strip()[:160]}"))
    for (lv, chk), k in seen.items():
        if k > 5: r.append(("INFO", chk, f"... {k - 5} more {lv} lines"))
    return r

# ---- B15: configuration records that bake link/include dirs (LOOPHOLES class 2: perl Config_heavy.pl) -------------------
# A tool's recorded build config is what downstream builds read back (ExtUtils::MakeMaker uses perl's ldflags/libpth,
# pkg-config reads .pc, libtool .la, cmake *Config.cmake, python _sysconfigdata). A host dir there leaks into the next
# build on every host. nixpkgs perl (no-sys-dirs.patch) records store paths or /no-such-path (measured on floki).
PERL_LINK_VARS = ("libpth", "glibpth", "loclibpth", "locincpth", "xlibpth", "libspath", "ldflags", "lddlflags",
                  "ccflags", "cppflags", "ldflags_nolargefiles", "ccdlflags", "incpth")
HOST_DIR_TOKEN = re.compile(r"(?:^|[\s'\"=,:;])(?:-[LIR]|-Wl,-R)?(/(?:usr|opt|lib|bin|sbin)(?:/[\w.+-]+)*)(?=$|[\s'\":;,])")

def config_record_findings(rel, data):
    r = []
    if re.search(r"/Config(_heavy)?\.p[lm]$", rel) and b"perl" in data[:4096].lower() + data[-4096:].lower():
        for m in re.finditer(rb"^(\w+)='([^']*)'", data, re.M):
            var = m.group(1).decode()
            if var not in PERL_LINK_VARS: continue
            hosts = sorted({h for h in HOST_DIR_TOKEN.findall(m.group(2).decode(errors="replace")) if h not in ("/no-such-path",)})
            if hosts: r.append(("FAIL", "B15-config", f"{rel}: {var}='{m.group(2).decode(errors='replace')[:100]}' names host dirs {' '.join(hosts[:4])}"))
    elif rel.endswith((".pc", ".la")) or re.search(r"(Config|-config)\.cmake$|/_sysconfigdata[^/]*\.py$|/[\w.+-]+-config$", rel):
        txt = data.decode(errors="replace")
        for line in txt.splitlines():
            if line.lstrip().startswith("#"): continue
            for tok in re.findall(r"(?:-[LIR]|-Wl,-R|libdir=|includedir=|dependency_libs=')\s*'?(/(?:usr/(?:gnu|local|gcc|sfw|ccs)|opt)/[\w./+-]*)", line):
                r.append(("FAIL", "B15-config", f"{rel}: link/include dir {tok} in a config record: {line.strip()[:120]}")); break
            if len(r) >= 3: break
    return r

# ---- B5 / B11: the host's store copy is in Nix's canonical form ----------------------------------------------------------
def check_store(out, want_uid=None):
    """Nix canonicalises a registered path (canonicalisePathMetaData): mtime 1, owner root (or the daemon's user in a
    single-user store), no setuid/setgid/sticky/group- or world-writable bits, only dir/regular/symlink. A path that
    is not is not what Nix built, and its NAR would not show it (the NAR has no such fields: see the module docstring)."""
    r = []
    if not os.path.lexists(out): return [("FAIL", "B11-store", f"{out} is not in this store")]
    st0 = os.lstat(out); owner = st0.st_uid
    bad_owner = bad_mtime = 0
    for root, dirs, files in os.walk(out):
        for nm in [""] + dirs + files:
            p = os.path.join(root, nm) if nm else root
            if not nm and root != out: continue
            st = os.lstat(p); m = st.st_mode; rel = p[len(out) + 1:] or "."
            if not (stat.S_ISDIR(m) or stat.S_ISREG(m) or stat.S_ISLNK(m)):
                r.append(("FAIL", "B5-type", f"{rel}: {stat.filemode(m)} (device, FIFO, socket or door)")); continue
            if stat.S_ISLNK(m): continue
            if m & (stat.S_ISUID | stat.S_ISGID | stat.S_ISVTX):
                r.append(("FAIL", "B5-mode", f"{rel}: {stat.filemode(m)} (setuid/setgid/sticky)"))
            if m & 0o022:
                r.append(("FAIL", "B5-mode", f"{rel}: {stat.filemode(m)} (group/world-writable)"))
            if int(st.st_mtime) != 1: bad_mtime += 1; bad_mtime == 1 and r.append(("FAIL", "B11-mtime", f"{rel}: mtime {int(st.st_mtime)} (Nix normal form is 1)"))
            if st.st_uid != owner: bad_owner += 1; bad_owner == 1 and r.append(("FAIL", "B11-owner", f"{rel}: uid {st.st_uid} != the path's {owner}"))
    if want_uid is None: want_uid = 0 if os.lstat("/nix/store").st_uid == 0 else os.lstat("/nix/store").st_uid
    if owner != want_uid:
        r.append(("FAIL", "B11-owner", f"{out} is owned by uid {owner}, not {want_uid} (Nix canonicalises a registered path to the store's owner)"))
    if bad_mtime > 1: r.append(("INFO", "B11-mtime", f"{bad_mtime} entries in all"))
    if bad_owner > 1: r.append(("INFO", "B11-owner", f"{bad_owner} entries in all"))
    return r

# ---- B12: closure denylist ------------------------------------------------------------------------------------------------
def denylist():
    p = os.environ.get("GATE_DENYLIST") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "not-for-cache.tsv")
    rules = []
    for line in open(p):
        if not line.strip() or line.startswith("#"): continue
        kind, pat, why = (line.rstrip("\n").split("\t") + ["", ""])[:3]
        rules.append((kind, re.compile(pat), why))
    return rules

def check_closure(out, closure=None, lane=None):
    """closure: the runtime closure (nix-store -qR); lane: CA-lane paths that may appear even if a rule names them."""
    if closure is None:
        q = subprocess.run(["nix-store", "-qR", out], capture_output=True, text=True)
        if q.returncode: return [("FAIL", "B12-closure", f"nix-store -qR failed: {q.stderr.strip()[:120]}")]
        closure = q.stdout.split()
    lane = ca_lane() if lane is None else lane
    r = []
    for kind, rx, why in denylist():
        for p in closure:
            name = p[44:] if p.startswith(STORE) else p
            hit = rx.search(p) if kind == "path" else rx.search(name)
            if hit and kind == "unfree" and os.environ.get("GATE_ALLOW_UNFREE") == "1":
                r.append(("INFO", "B12-closure", f"closure has {p}: {why} (allowed: GATE_ALLOW_UNFREE=1, the row says unfree)")); continue
            if hit and not (p in lane and kind != "path"):
                r.append(("FAIL", "B12-closure", f"closure has {p}: {why}"))
    return r


def report(path, findings, out=print, extra=""):
    for lvl, chk, why in findings:
        out(f"{lvl} {chk} {path}: {why}")
    bad = any(f[0] == "FAIL" for f in findings)
    out(f"{'FAIL' if bad else 'PASS'} {path}{extra}")
    return 1 if bad else 0

def run_out(cmd, args, out=print):
    rc = 0
    if cmd == "nar":
        o = args[0]; src = args[1] if len(args) > 1 else None
        f, n = check_nar(o, src)
        return report(o, f, out, f" (nar: {n['files']} files, {n['links']} symlinks, {n['dirs']} dirs)")
    for o in args:
        f = check_store(o) if cmd == "store" else check_closure(o)
        rc |= report(o, f, out)
    return rc

def nar_bytes(tree):
    """tree: {'type':'dir','entries':{name: node}} | {'type':'reg','exec':bool,'data':bytes} | {'type':'link','target':str}"""
    b = io.BytesIO()
    def s(x):
        x = x.encode() if isinstance(x, str) else x
        b.write(len(x).to_bytes(8, "little")); b.write(x); b.write(b"\0" * ((8 - len(x) % 8) % 8))
    def node(t):
        s("("); s("type")
        if t["type"] == "reg":
            s("regular")
            if t.get("exec"): s("executable"); s("")
            s("contents"); s(t["data"])
        elif t["type"] == "link":
            s("symlink"); s("target"); s(t["target"])
        else:
            s("directory")
            for k in sorted(t["entries"]):
                s("entry"); s("("); s("name"); s(k); s("node"); node(t["entries"][k]); s(")")
        s(")")
    s("nix-archive-1"); node(tree)
    return b.getvalue()

# ---- selftest: every check must FAIL a crafted bad input and PASS a good one -------------------------------------------
def aterm(outs, idrvs, srcs, builder, args, env, system="x86_64-solaris"):
    q = lambda x: '"' + x.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t") + '"'
    L = lambda xs: "[" + ",".join(xs) + "]"
    return ("Derive(" + L("(" + ",".join(q(x) for x in o) + ")" for o in outs) + "," +
            L("(" + q(d) + "," + L(q(o) for o in os_) + ")" for d, os_ in idrvs) + "," + L(q(x) for x in srcs) + "," +
            q(system) + "," + q(builder) + "," + L(q(a) for a in args) + "," +
            L("(" + q(k) + "," + q(v) + ")" for k, v in sorted(env.items())) + ")")

def fake_drv(tag, args=None, env=None, builder="/usr/bin/bash", srcs=(), idrvs=(), out=None, fod=None, name=None):
    h = (tag * 32)[:32].translate(str.maketrans("eotu", "abcd"))
    name = name or f"t-{tag}"
    dp = f"{STORE}{h}-{name}.drv"; op = out or f"{STORE}{h[::-1]}-{name}"
    e = {"name": name, "out": op, "builder": builder, "system": "x86_64-solaris"}; e.update(env or {})
    o = [("out", op, "r:sha256" if fod is not None else "", fod or "")]
    FAKE[dp] = aterm(o, [(d, ["out"]) for d in idrvs], list(srcs), builder, args if args is not None else ["-c", "true"], e)
    return dp

def selftest():
    global _LANE
    _LANE = {STORE + "l" * 32 + "-ca-lane"}   # no network in the selftest; one CA-lane path for the leaf probe control
    T = STORE + "t" * 0 + "0" * 32 + "-tools"
    cu = STORE + "1" * 32 + "-coreutils"
    tools = fake_drv("tools", ["-c", 'export PATH="$coreutils/bin"; mkdir $out'], {"coreutils": cu}, srcs=[cu], out=T)
    FAKE_CA = {STORE + "2" * 32 + "-good.sh": True, STORE + "3" * 32 + "-smuggled": False}
    good_sh = STORE + "2" * 32 + "-good.sh"; FAKE[good_sh] = 'export PATH="$tools/bin:$W/w:$PATH"\nMAKE=$tools/bin/gmake\n'
    bad_sh = STORE + "4" * 32 + "-bad.sh"; FAKE[bad_sh] = '# PATH=/usr/bin in a comment is fine\nexport PATH=/opt/ooce/bin:$PATH\n'
    FAKE_CA[bad_sh] = True
    def D(tag, **kw):
        kw.setdefault("idrvs", [tools]); kw.setdefault("env", {}); kw["env"].setdefault("tools", T)
        return fake_drv(tag, **kw)
    sdz = D("sdz", name="gzip-1.13", env={"PATH": "/usr/bin", "btPath": ""})
    sdz_out = parse_drv(FAKE[sdz])["outputs"]["out"]["path"]
    cases = [  # (label, drv, expect PASS?, check id that must appear)
        ("good: store-only PATH, store MAKE, CA .sh", D("good", args=[good_sh], srcs=[good_sh], env={"PATH": T + "/bin"}), True, None),
        ("A1 env PATH=/usr/bin", D("a1env", env={"PATH": T + "/bin:/usr/bin"}), False, "A1-path"),
        ("A1 export PATH with /usr/gnu/bin in -c", D("a1arg", args=["-c", 'export PATH="${btPath:+$btPath:}/usr/gnu/bin:/usr/bin"']), False, "A1-path"),
        ("A1 export PATH=/opt/ooce in the builder .sh", D("a1sh", args=[bad_sh], srcs=[bad_sh]), False, "A1-path"),
        ("A1 PATH via an env var holding /usr/sbin", D("a1var", args=["-c", "export PATH=$tp:$tools/bin"], env={"tp": "/usr/sbin"}), False, "A1-path"),
        ("A1 PATH with a relative entry", D("a1rel", args=["-c", "PATH=bin:$tools/bin make"]), False, "A1-path"),
        ("A1 PATH with $HOME/.cargo/bin as the host's home", D("a1home", env={"PATH": "/home/gburd/.cargo/bin"}), False, "A1-path"),
        ("A1-tool MAKE=/usr/gnu/bin/make (jq 1.8.2 class)", D("a1mk", args=["-c", "./configure MAKE=/usr/gnu/bin/make"]), False, "A1-tool"),
        ("A1-tool env CONFIG_SHELL=/usr/bin/bash", D("a1cs", env={"CONFIG_SHELL": "/usr/bin/bash"}), False, "A1-tool"),
        ("A2 env LD_LIBRARY_PATH", D("a2ld", env={"LD_LIBRARY_PATH": "/usr/lib"}), False, "A2-env"),
        ("A2 env NIX_PATH", D("a2np", env={"NIX_PATH": "nixpkgs=/home/x/nixpkgs"}), False, "A2-env"),
        ("A2 env HOME=/home/gburd", D("a2home", env={"HOME": "/home/gburd"}), False, "A2-env"),
        ("A2 builder export LD_PRELOAD", D("a2pre", args=["-c", "export LD_PRELOAD=/usr/lib/libumem.so; make"]), False, "A2-env"),
        ("A2 builder LD_LIBRARY_PATH_64=/usr/lib/64", D("a2l64", args=["-c", "LD_LIBRARY_PATH_64=/usr/lib/64 ./t"]), False, "A2-env"),
        ("A2 builder TMPDIR=/export/home/x", D("a2tmp", args=["-c", "export TMPDIR=/export/home/x"]), False, "A2-env"),
        ("A3 builder outside the store", D("a3b", builder="/usr/local/bin/bash"), False, "A3-builder"),
        ("A3 inputSrc that is not CA (builtins.storePath)", D("a3sp", srcs=[STORE + "3" * 32 + "-smuggled"]), False, "A3-input"),
        ("A3 undeclared store path in args", D("a3und", args=["-c", "cp " + STORE + "5" * 32 + "-elsewhere/bin/x $out"]), False, "A3-undeclared"),
        ("A4 FOD with /usr/bin on PATH", D("a4p", fod="1b" * 32, env={"PATH": "/usr/bin"}), False, "A4-fod"),
        ("A4 CA output without a pinned hash", D("a4h", fod="", env={"outputHashMode": "recursive"}), False, "A4-fod"),
        ("A4 FOD with the all-zero placeholder hash", D("a4z", fod="0" * 64, env={"outputHash": "0" * 64}), False, "A4-fod"),
        ("good FOD: pinned hash, store fetch tools only", D("a4ok", fod="1a" * 32, env={"PATH": T + "/bin"}), True, None),
        ("closure: a bad INPUT fails the root", D("clo", idrvs=[tools, D("cloin", env={"PATH": "/usr/bin"})]), False, "A1-path"),
        ("exempt: seed zlib (btPath empty, stage0 /usr/gcc/14)", D("seedz", name="zlib-1.3.2", env={"PATH": "/usr/gnu/bin:/usr/bin", "btPath": "", "stage0": "/usr/gcc/14"}), True, "EXEMPT"),
        ("NOT exempt: seed marker on a name outside the list", D("seedq", name="jq-1.8.2", env={"PATH": "/usr/gnu/bin:/usr/bin", "btPath": ""}), False, "A1-path"),
        ("exempt: slice libc (gate + filesArg)", D("slc", name="libc", env={"PATH": "/usr/gnu/bin:/usr/bin", "gate": STORE + "c" * 32 + "-illumos-gate-proto", "filesArg": "lib/libc.so.1"}), True, "EXEMPT"),
        ("NOT exempt: libc without the slice marker", D("slc2", name="libc", env={"PATH": "/usr/gnu/bin:/usr/bin"}), False, "A1-path"),
        ("exempt: seed farm linking only a seed out (seedenv)", D("farm", name="solnix-seed-build-tools", idrvs=[tools, sdz], env={"PATH": "/usr/bin", "paths": sdz_out}), True, "EXEMPT"),
        ("NOT exempt: seed farm linking a non-seed out", D("farm2", name="solnix-seed-build-tools", env={"PATH": "/usr/bin", "paths": T}), False, "A1-path"),
        ("NOT exempt: same name with store build tools", D("sysz", name="zlib-1.3.2", env={"PATH": "/usr/gnu/bin:/usr/bin", "btPath": T + "/bin", "stage0": "/usr/gcc/14"}), False, "A1-path"),
        ("exempt: hostfix-tools g08y7agf by exact out", D("hf", name="solnix-hostfix-tools", out="/nix/store/g08y7agf6jn204kj1gqm6nhjmc81m046-solnix-hostfix-tools", env={"PATH": "/usr/gnu/bin:/usr/bin:/usr/sbin"}), True, "EXEMPT"),
        ("NOT exempt: hostfix-tools with another hash", D("hf2", name="solnix-hostfix-tools", env={"PATH": "/usr/gnu/bin:/usr/bin:/usr/sbin"}), False, "A1-path"),
    ]
    ca = lambda p: FAKE_CA.get(p, True)
    bad = selftest_out() + selftest_log()
    # leaf mode: a host-PATH input whose out IS served is not judged (counted as debt); one whose out is NOT served is
    hostin = fake_drv("hostin", ["-c", "true"], {"PATH": "/usr/bin"})
    hostout = parse_drv(FAKE[hostin])["outputs"]["out"]["path"]
    leafroot = fake_drv("leafr", ["-c", 'export PATH="$tools/bin"'], {"tools": T}, idrvs=[tools, hostin])
    for label, srv, want_pass in (("leaf: host-PATH input already served -> not judged", {hostout: True}, True),
                                  ("leaf: host-PATH input NOT served -> judged, FAIL", {hostout: False}, False)):
        lines = []
        rc = run_drv([leafroot], out=lines.append, ca_ok=ca, mode="leaf", served=lambda p, srv=srv: srv.get(p, True))
        ok = (rc == 0) == want_pass and any(l.startswith("INFO A0") and ("1 served drvs" in l) == want_pass for l in lines)
        bad += not ok
        print(f"{'ok ' if ok else 'BAD'} drv  {label}: {'PASS' if rc == 0 else 'FAIL'}" + ("" if ok else "\n    " + "\n    ".join(lines)))
    lines = []; rc = run_drv([leafroot], out=lines.append, ca_ok=ca, mode="closure", served=lambda p: True)
    ok = rc != 0; bad += not ok
    print(f"{'ok ' if ok else 'BAD'} drv  closure mode judges the served host-PATH input too: {'PASS' if rc == 0 else 'FAIL'}")
    # the temporary ALLOW A1-envpath (leaf only): each of its limits must be load-bearing
    sp = 'export PATH="${btPath:+$btPath:}$ntPath" CONFIG_SITE=x'
    lenv = {"PATH": LEGACY_ENV_PATH, "btPath": T + "/bin", "ntPath": T + "/bin"}
    allow_cases = [
        ("ALLOW: legacy env PATH, store PATH first (recipes1 class)", dict(args=["-c", "set -eu\n" + sp + "\nmake"], env=dict(lenv)), "leaf", True),
        ("ALLOW never in closure mode", dict(args=["-c", "set -eu\n" + sp + "\nmake"], env=dict(lenv)), "closure", False),
        ("no ALLOW: a command before the PATH statement", dict(args=["-c", "set -eu\nmkdir $out\n" + sp], env=dict(lenv)), "leaf", False),
        ("no ALLOW: env PATH not exactly the legacy value", dict(args=["-c", sp], env=dict(lenv, PATH="/usr/bin:/usr/gnu/bin")), "leaf", False),
        ("no ALLOW: BASH_ENV set", dict(args=["-c", sp], env=dict(lenv, BASH_ENV="/etc/x")), "leaf", False),
        ("no ALLOW: the first PATH still has /usr/bin", dict(args=["-c", 'export PATH="$ntPath:/usr/bin"'], env=dict(lenv)), "leaf", False),
        ("no ALLOW: builder is not /usr/bin/bash", dict(args=["-c", sp], env=dict(lenv), builder="/usr/gnu/bin/bash"), "leaf", False),
    ]
    for i, (label, kw, mode, want_pass) in enumerate(allow_cases):
        kw.setdefault("idrvs", [tools]); kw["env"]["tools"] = T
        dp = fake_drv(f"al{i}", **kw)
        lines = []
        rc = run_drv([dp], out=lines.append, ca_ok=ca, mode=mode, served=lambda p: True if p.startswith(T) or "-lane" in p else False)
        allowed = any(l.startswith("ALLOW A1-envpath") for l in lines)
        ok = (rc == 0) == want_pass and allowed == want_pass
        bad += not ok
        print(f"{'ok ' if ok else 'BAD'} drv  {label}: {'PASS' if rc == 0 else 'FAIL'}" + ("" if ok else "\n    " + "\n    ".join(lines)))
    # leaf mode refuses to judge when the probe cannot see a served path, or any input's state is unknown
    for label, srv in (("leaf: probe blind (CA-lane path not seen served) -> hard FAIL", lambda p: False),
                       ("leaf: an input's served state unknown -> hard FAIL", lambda p: True if "-lane" in p else None)):
        lines = []; rc = run_drv([leafroot], out=lines.append, ca_ok=ca, mode="leaf", served=srv)
        ok = rc != 0 and any(l.startswith("FAIL A0") for l in lines); bad += not ok
        print(f"{'ok ' if ok else 'BAD'} drv  {label}: {'PASS' if rc == 0 else 'FAIL'}" + ("" if ok else "\n    " + "\n    ".join(lines)))
    # zlib 63big3dz: path-info narHash (SRI) and its narinfo NarHash name the same stamp
    k1 = stamp_key("sha256-aQCIZKWVcv6X8XFLJrazY5D6jm/QH5YUZd/iN3EJvB8=")
    ok = k1 == stamp_key("sha256:" + k1) and len(k1) == 52
    bad += not ok; print(f"{'ok ' if ok else 'BAD'} stamp key: SRI and nix32 forms agree ({k1[:12]}...)")
    for label, dp, want_pass, must in cases:
        lines = []
        rc = run_drv([dp], out=lines.append, ca_ok=ca)
        got_pass = rc == 0
        hit = must is None or any(l.startswith(must) or f" {must} " in l for l in lines)
        ok = got_pass == want_pass and hit
        bad += not ok
        print(f"{'ok ' if ok else 'BAD'} drv  {label}: {'PASS' if got_pass else 'FAIL'}" + ("" if ok else "\n    " + "\n    ".join(lines)))
    return bad


def mkelf(stale, live):
    """A minimal 64-bit LE ELF: a .dynstr holding <stale><live> and a .dynamic whose DT_RUNPATH points at <live>."""
    import struct
    dynstr = b"\0" + stale + live
    dynamic = struct.pack("<qQ", 29, 1 + len(stale)) + struct.pack("<qQ", 0, 0)
    body = dynstr + b"\0" * ((8 - len(dynstr) % 8) % 8)
    stroff, dynoff = 64, 64 + len(body)
    shoff = dynoff + len(dynamic)
    hdr = b"\x7fELF" + bytes([2, 1, 1]) + b"\0" * 9 + struct.pack("<HHIQQQIHHHHHH", 3, 62, 1, 0, 0, shoff, 0, 64, 0, 0, 64, 3, 0)
    sh = lambda typ, off, size, link: struct.pack("<IIQQQQIIQQ", 0, typ, 0, 0, off, size, link, 0, 1, 0)
    return hdr + body + dynamic + sh(0, 0, 0, 0) + sh(3, stroff, len(dynstr), 0) + sh(6, dynoff, len(dynamic), 1)

def mkelf_interp(interp):
    """A minimal 64-bit LE ELF with one PT_INTERP program header and no sections."""
    import struct
    body = interp + b"\0"
    phoff = 64; off = phoff + 56
    hdr = b"\x7fELF" + bytes([2, 1, 1]) + b"\0" * 9 + struct.pack("<HHIQQQIHHHHHH", 2, 62, 1, 0, phoff, 0, 0, 64, 56, 1, 64, 0, 0)
    ph = struct.pack("<IIQQQQQQ", 3, 4, off, 0, 0, len(body), len(body), 1)
    return hdr + ph + body

def selftest_log():
    bad = 0
    good = "\n".join(["jq> checking for gcc... /var/tmp/srcpkg-d259544faa76e83d/cc64",
                      "checking for a BSD-compatible install... /nix/store/1dh4mvfqri4jqmgjk6vgi79d1gq2cbqp-coreutils-9.12/bin/install -c",
                      "checking for ld used by cc64... /nix/store/a5rnsv8dyxqmy11jy9p0v5nc0l65azvp-ld/usr/bin/ld",
                      "-- Found Perl: /nix/store/d6fjxi7wnf8blph569v7kzpl5q410z3k-perl-5.42.0/bin/perl (found version \"5.42.0\")"])
    cases = [("store-only wave6 jq log (real lines)", good, True, None),
             ("L1 jq 1.8.2 MAKE=/usr/gnu/bin/make (real line)", "checking whether /usr/gnu/bin/make sets $(MAKE)... yes", False, "L1-configure"),
             ("L1 configure found /usr/gnu/bin/install (real line)", "checking for a BSD-compatible install... /usr/gnu/bin/install -c", False, "L1-configure"),
             ("L2 perl Configure ignoring -D: WARN only (perl-5.42.2 prints it with a clean Config)", "perl> Configure: ignoring -D loclibpth=", True, "L2-configure-ignored"),
             ("L1 not hit: make output interleaved (gdb, real line)", "checking for localeconv... /bin/sh ./libtool  --tag=CC   --mode=link /var/tmp/srcpkg-059b7c750b714417/cc64 -W", True, None),
             ("L1 not hit: the system shell (autoconf, real line)", "checking for a shell whose -n mode is known to work... /bin/sh", True, None),
             ("L1 WARN: a configure runtime default (w3m, real line)", "checking which external browser is used by default... /usr/bin/firefox", True, "L1-configure"),
             ("L1 FAIL: automake sh=/usr/gnu/bin/sh (chef, real line)", "checking for sh... /usr/gnu/bin/sh", False, "L1-configure"),
             ("L2 perl probing /usr/gnu/bin/echo (real line)", "Checking compatibility between /usr/gnu/bin/echo and builtin echo (if any)...", False, "L2-configure-host"),
             ("L3 automake: no POSIX shell (real message)", "configure: error: no POSIX shell found that is good enough to be used in our testsuite", False, "L3-missing"),
             ("L5 cmake Found PkgConfig: /usr/bin/pkg-config (fortune-mod, real line)", '-- Found PkgConfig: /usr/bin/pkg-config (found version "0.29.2")', False, "L5-cmake"),
             ("L5 meson host program", "Program python3 found: YES (/usr/bin/python3)", False, "L5-meson")]
    for label, text, want_pass, must in cases:
        lines = []; rc = report("log", check_log(text), lines.append)
        ok = (rc == 0) == want_pass and (must is None or any(f" {must} " in l for l in lines))
        bad += not ok
        print(f"{'ok ' if ok else 'BAD'} log  {label}: {'PASS' if rc == 0 else 'FAIL'}" + ("" if ok else "\n    " + "\n    ".join(lines)))
    return bad

def selftest_out():
    import tempfile
    O = STORE + "6" * 32 + "-t-out"
    R = lambda data, ex=False: {"type": "reg", "exec": ex, "data": data}
    L = lambda t: {"type": "link", "target": t}
    Dd = lambda **e: {"type": "dir", "entries": e}
    good = Dd(bin=Dd(tool=R(b"#!" + (STORE + "7" * 32 + "-bash/bin/bash").encode() + b"\necho hi\n", True),
                     sh=R(b"#!/bin/sh\necho\n", True), envy=R(b"#!/usr/bin/env python3\n", True), t2=L("tool"),
                     up=L("../lib/libx"), self_=L(O + "/lib/libx"), viadir=L("../lib/l2/libx")),
              lib=Dd(libx=R(b"\x7fELF....." + b"/nix/store/" + b"8" * 32 + b"-libc/lib\0"), l=L("libx"),
                     s=L(STORE + "8" * 32 + "-libc/lib/libc.so.1"), py=Dd(__pycache__=Dd(**{"m.cpython-313.pyc": R(b"\xf3\r\r\n\x03\0\0\0" + b"h" * 8 + b"data")})),
                     debug=Dd(x=R(b"DW /build/src/main.c"))),
              share=Dd(man=Dd(man1=Dd(**{"t.1": R(b".TH T 1\\nedit /usr/local/etc/t.conf\n")}))),
              )
    good["entries"]["lib"]["entries"]["l2"] = L(".")
    def mut(path, node):
        import copy
        t = copy.deepcopy(good); cur = t
        parts = path.split("/")
        for x in parts[:-1]: cur = cur["entries"].setdefault(x, Dd())
        cur["entries"][parts[-1]] = node
        return t
    cases = [
        ("good out", good, True, None),
        ("B6 symlink to /usr/lib", mut("lib/h", L("/usr/lib/libz.so.1")), False, "B6-symlink"),
        ("B6 dangling relative symlink", mut("lib/d", L("nothere")), False, "B6-symlink"),
        ("B6 symlink climbing out of the out", mut("lib/e", L("../../../etc/passwd")), False, "B6-symlink"),
        ("B6 symlink through a symlinked dir to a missing file", mut("bin/f", L("../lib/l2/missing")), False, "B6-symlink"),
        ("B6 top-level symlink with ..", mut("up", L("../lib/libx")), False, "B6-symlink"),
        ("B6 symlink loop", mut("lib/a", L("a")), False, "B6-symlink"),
        ("B7 bin/ file without x (libtool 0444)", mut("bin/libtool", R(b"#!/bin/sh\n")), False, "B7-exec"),
        ("B8 a non-drv-keyed /var/tmp/srcpkg- dir (8 hex) in a .pc", mut("lib/z.pc", R(b"prefix=/var/tmp/srcpkg-0123abcd/out")), False, "B8-builddir"),
        ("B8 drv-keyed /var/tmp/srcpkg-<16 hex> (jq CC= class): WARN, not FAIL", mut("bin/jq2", R(b"\x7fELF\0CC=/var/tmp/srcpkg-4424febabee4a39c/cc64\0", True)), True, "WARN B8-builddir"),
        ("B8 Nix's /tmp/nix-build-<name>-<n> dir: FAIL", mut("lib/x.la", R(b"libdir='/tmp/nix-build-xyz-1.0.drv-0/src/.libs'")), False, "FAIL B8-builddir"),
        ("B8 a mktemp-suffixed dir /var/tmp/cargo-Ab3xQz: FAIL", mut("bin/c", R(b"\x7fELF\0/var/tmp/cargo-Ab3xQz/target\0", True)), False, "FAIL B8-builddir"),
        ("B8 a build user's home /home/gburd/: FAIL", mut("lib/y.pc", R(b"prefix=/home/gburd/src/y")), False, "FAIL B8-builddir"),
        ("B8 root's cargo registry /root/.cargo/registry/: FAIL", mut("bin/rc", R(b"\x7fELF\0/root/.cargo/registry/src/x.rs\0", True)), False, "FAIL B8-builddir"),
        ("B8 not hit: upstream help text 'rm /root/.cache/nix/' (nix globals.hh, flyctl)", mut("include/g.hh", R(b"# rm /root/.cache/nix/binary-cache-v*.sqlite*\n")), True, None),
        ("B8 not hit: upstream example text /home/user/hello.c (gdb)", mut("bin/gdb2", R(b"\x7fELF\0The base name of \"/home/user/hello.c\" is\0", True)), True, None),
        ("B8 /var/tmp/big scratch: FAIL", mut("lib/w.cmake", R(b"set(X /var/tmp/big/build)")), False, "FAIL B8-builddir"),
        ("B8 /build/ outside lib/debug: counted INFO, not failed (NixOS ships it)", mut("lib/libz.la", R(b"libdir='/build/src/.libs'")), True, "INFO B8-builddir"),
        ("B13 stale .dynstr string in an ELF: INFO", mut("lib/libs.so", R(mkelf(b"/usr/gcc/10/lib/amd64\0", b"/nix/store/x/lib\0"))), True, "INFO B13-hostpath"),
        ("B13 live RUNPATH /usr/gcc/10 in an ELF: FAIL", mut("lib/libt.so", R(mkelf(b"", b"/usr/gcc/10/lib/amd64\0"))), False, "FAIL B13-hostpath"),
        ("B8 /var/tmp/cargo- (not 16 hex) in an ELF", mut("bin/r", R(b"\x7fELF\0/var/tmp/cargo-1234/target", True)), False, "B8-builddir"),
        ("B9 #!/usr/bin/perl", mut("bin/p", R(b"#!/usr/bin/perl -w\n", True)), False, "B9-shebang"),
        ("B9 not hit: a non-executable .pm with #!/bin/false", mut("share/x/M.pm", R(b"#!/bin/false\n")), True, None),
        ("B9 not hit: a relative #!perl", mut("bin/rel", R(b"#!perl -w\n", True)), True, None),
        ("B13 WARN: a compiled-in search list (texinfo INFOPATH)", mut("bin/info", R(b"\x7fELF\0PATH:/usr/local/info:/usr/info:/usr/gnu/info:/opt/gnu/info:/usr/share/info\0", True)), True, "WARN B13-hostpath"),
        ("B9 #!/usr/gnu/bin/bash", mut("bin/q", R(b"#! /usr/gnu/bin/bash\n", True)), False, "B9-shebang"),
        ("B9 #!/usr/bin/bash still FAILs", mut("bin/b", R(b"#!/usr/bin/bash\n", True)), False, "B9-shebang"),
        ("B9 #!/usr/bin/python3 still FAILs", mut("bin/py3", R(b"#!/usr/bin/python3\n", True)), False, "B9-shebang"),
        ("B9 #!/usr/bin/sh is allowed (= /bin/sh on illumos; quilt)", mut("share/q/obs", R(b"#!/usr/bin/sh\n", True)), True, None),
        ("B10 timestamp pyc", mut("lib/py/__pycache__/n.cpython-313.pyc", R(b"\xf3\r\r\n\0\0\0\0" + b"\x01" * 8 + b"x")), False, "B10-pyc"),
        ("B13 MAKE=/usr/gnu/bin/make in a Makefile (jq class)", mut("share/jq/Makefile", R(b"MAKE = /usr/gnu/bin/make\n")), False, "B13-hostpath"),
        ("B13 /usr/gnu/bin/pr baked in an ELF (diffutils class)", mut("bin/diff", R(b"\x7fELF\0/usr/gnu/bin/pr\0", True)), False, "B13-hostpath"),
        ("B13 /opt/ooce in a .pc", mut("lib/pkgconfig/a.pc", R(b"Libs: -L/opt/ooce/lib")), False, "B13-hostpath"),
        ("B13 not hit: a store subpath .../usr/gnu/", mut("lib/w.txt", R(b"x=" + STORE.encode() + b"7" * 32 + b"-world/usr/gnu/bin/x")), True, None),
        ("B0 corrupt NAR", None, False, "B0-nar"),
        # S: the server content gate (infra's 3 findings are the positive controls on real NARs; these are synthetic)
        ("S1 DT_RUNPATH /usr/gcc/10/lib (ppp/minconn.so class)", mut("lib/minconn.so", R(mkelf(b"", b"/usr/gcc/10/lib\0"))), False, "FAIL S1-runpath"),
        ("S1 DT_RUNPATH $ORIGIN:<store> passes", mut("lib/ok.so", R(mkelf(b"", b"$ORIGIN/../lib:/nix/store/x/lib\0"))), True, None),
        ("S2 PT_INTERP /usr/local/lib/ld.so.1", mut("bin/i1", R(mkelf_interp(b"/usr/local/lib/ld.so.1"), True)), False, "FAIL S2-interp"),
        ("S2 PT_INTERP /usr/lib/amd64/ld.so.1 passes", mut("bin/i2", R(mkelf_interp(b"/usr/lib/amd64/ld.so.1"), True)), True, None),
        ("S3 solnix-builder-build in a DOF record", mut("lib/libz2.so", R(b"\x7fELF\0SunOS\0solnix-builder-build\0")), False, "FAIL S3-buildhost"),
        ("S3 ip-10-0-1-23.EC2.Internal (case-insensitive)", mut("BUILDINFO", R(b"host=ip-10-0-1-23.EC2.Internal")), False, "FAIL S3-buildhost"),
        ("S3 a symlink target naming compute.internal", mut("lib/hl", L("/nix/store/" + "8" * 32 + "-x/ip-1.compute.internal")), False, "FAIL S3-buildhost"),
        ("S4 host name dixi as a word", mut("etc/conf", R(b"built on dixi by gburd")), False, "FAIL S4-hostname"),
        ("S4 not hit: dixi inside a longer word (dixie)", mut("etc/conf2", R(b"dixieland floki_x lixir")), True, None),
        ("S4 case-sensitive: DIXI is not a host name", mut("etc/conf3", R(b"DIXI FLOKI")), True, None),
        # B15: config records (LOOPHOLES class 2: perl Configure recorded -L/usr/gnu/lib; served perl-5.42.0 fwpxqmsj)
        ("B15 perl Config_heavy.pl lddlflags -L/usr/gnu/lib", mut("lib/perl5/5.42.0/i86pc/Config_heavy.pl", R(b"# perl config\nlddlflags='-shared -m64 -L/usr/gnu/lib'\nperl5='/usr/bin/perl'\n")), False, "FAIL B15-config"),
        ("B15 perl glibpth with host dirs", mut("lib/perl5/5.42.0/i86pc/Config_heavy.pl", R(b"# perl\nglibpth='/usr/shlib /usr/lib /usr/ccs/lib'\n")), False, "FAIL B15-config"),
        ("B15 not hit: nixpkgs-style perl Config (store + /no-such-path, pager=/usr/ucb/more)", mut("lib/perl5/5.42.0/i86pc/Config_heavy.pl", R(b"# perl\nlibpth='/nix/store/x/lib /no-such-path/lib'\nglibpth=''\npager='/usr/ucb/more'\n")), True, None),
        ("B15 a .pc with -L/opt/ooce/lib", mut("lib/pkgconfig/b.pc", R(b"Libs: -L/opt/ooce/lib -lb\n")), False, "FAIL B15-config"),
        ("B15 a .la dependency_libs with /usr/gnu/lib", mut("lib/libb.la", R(b"dependency_libs=' -L/usr/gnu/lib -lintl'\n")), False, "FAIL B15-config"),
    ]
    bad = 0
    with tempfile.TemporaryDirectory() as td:
        for label, tree, want_pass, must in cases:
            f = os.path.join(td, "x.nar")
            open(f, "wb").write(nar_bytes(good)[:100] if tree is None else nar_bytes(tree))   # None: a truncated NAR
            lines = []
            rc = run_out("nar", [O, f], out=lines.append)
            ok = (rc == 0) == want_pass and (must is None or any(f" {must} " in l or l.startswith(must + " ") for l in lines))
            if label == "good out":   # the exception counts and the doc WARN must be reported, not silently passed
                ok = ok and any("B9-shebang" in l and "#!/bin/sh x1" in l and "#!/usr/bin/env x1" in l for l in lines) \
                        and any(l.startswith("WARN B13-hostpath") for l in lines)
            bad += not ok
            print(f"{'ok ' if ok else 'BAD'} nar  {label}: {'PASS' if rc == 0 else 'FAIL'}" + ("" if ok else "\n    " + "\n    ".join(lines)))
        # B5 / B11 on a real directory (the store copy): canonical, then one defect at a time
        def mk(tag):
            o = os.path.join(td, tag); os.makedirs(o + "/bin")
            with open(o + "/bin/t", "w") as fh: fh.write("x")
            for p_ in (o + "/bin/t", o + "/bin", o):
                os.chmod(p_, 0o555 if p_ != o + "/bin/t" else 0o555); os.utime(p_, (1, 1))
            return o
        scases = [("canonical store copy", lambda o: None, True, None),
                  ("B5 setuid file", lambda o: os.chmod(o + "/bin/t", 0o4555), False, "B5-mode"),
                  ("B5 world-writable file", lambda o: os.chmod(o + "/bin/t", 0o557), False, "B5-mode"),
                  ("B5 FIFO", lambda o: (os.chmod(o + "/bin", 0o755), os.mkfifo(o + "/bin/p"), os.utime(o + "/bin/p", (1, 1)), os.utime(o + "/bin", (1, 1)), os.chmod(o + "/bin", 0o555)), False, "B5-type"),
                  ("B11 mtime not 1", lambda o: os.utime(o + "/bin/t", (5, 5)), False, "B11-mtime")]
        for label, f, want_pass, must in scases:
            o = mk(label.split()[0] + str(abs(hash(label)))); f(o)
            lines = []; rc = report(o, check_store(o, want_uid=os.getuid()), lines.append)
            ok = (rc == 0) == want_pass and (must is None or any(f" {must} " in l for l in lines))
            bad += not ok
            print(f"{'ok ' if ok else 'BAD'} store {label}: {'PASS' if rc == 0 else 'FAIL'}" + ("" if ok else "\n    " + "\n    ".join(lines)))
            for r_, ds, fs in os.walk(o):
                for x in ds + [""]: os.chmod(os.path.join(r_, x), 0o755)
        # B12 closure denylist
        C = lambda *names: [STORE + "9" * 32 + "-" + n for n in names]
        ccases = [("closure of plain libs", C("zlib-1.3.2", "libc"), True, None),
                  ("B12 a system toplevel in the closure", C("zlib-1.3.2", "solnix-system-dixi-26.11"), False, "B12-closure"),
                  ("B12 a home-manager generation", C("home-manager-generation"), False, "B12-closure"),
                  ("B12 the gate proto as a built path", C("illumos-gate-proto"), False, "B12-closure"),
                  ("B12 unfree firmware without the row flag", C("iwm-firmware-20250410"), False, "B12-closure"),
                  ("B12 the host gcc14 slice", C("gcc14"), False, "B12-closure")]
        for label, clo, want_pass, must in ccases:
            lines = []; rc = report(clo[0], check_closure(clo[0], clo, lane=set()), lines.append)
            ok = (rc == 0) == want_pass and (must is None or any(f" {must} " in l for l in lines))
            bad += not ok
            print(f"{'ok ' if ok else 'BAD'} clos {label}: {'PASS' if rc == 0 else 'FAIL'}" + ("" if ok else "\n    " + "\n    ".join(lines)))
        lane = {STORE + "9" * 32 + "-illumos-gate-proto"}
        rc = report("lane", check_closure("x", C("illumos-gate-proto"), lane=lane), lambda l: None)
        bad += rc != 0; print(f"{'ok ' if rc == 0 else 'BAD'} clos the gate proto as its CA-lane path: {'PASS' if rc == 0 else 'FAIL'}")
    return bad

# ---- stamps: pre-submit-check.sh writes <key>.ok on PASS; cache-submit.py --submit requires it ---------------------------
NIX32 = "0123456789abcdfghijklmnpqrsvwxyz"
def nix32(digest):
    n, out = len(digest) * 8, []
    for i in range((n + 4) // 5 - 1, -1, -1):
        b, j = i * 5 // 8, i * 5 % 8
        c = digest[b] >> j
        if b + 1 < len(digest): c |= digest[b + 1] << (8 - j)
        out.append(NIX32[c & 0x1f])
    return "".join(out)

def stamp_key(nar_hash):
    """sha256-<base64> (path-info) or sha256:<nix32> (narinfo) -> the nix32 digest, the stamp file's name."""
    import base64
    if nar_hash.startswith("sha256-"): return nix32(base64.b64decode(nar_hash[7:]))
    if nar_hash.startswith("sha256:") and re.fullmatch(r"[0-9a-df-np-sv-z]{52}", nar_hash[7:]): return nar_hash[7:]
    raise ValueError(f"unrecognised NarHash {nar_hash!r}")

# ---- main ------------------------------------------------------------------------------------------------------------
def main(argv):
    if len(argv) < 2: print(__doc__); return 2
    cmd, rest = argv[1], argv[2:]
    if cmd == "drv":
        mode = "closure"
        if rest and rest[0] in ("--closure", "--leaf"): mode = rest[0][2:]; rest = rest[1:]
        return run_drv(rest, mode=mode)
    if cmd == "stampkey": print(stamp_key(rest[0])); return 0
    if cmd == "selftest":
        bad = selftest(); print(f"SELFTEST {'PASS' if bad == 0 else 'FAIL'} ({bad} bad)"); return 1 if bad else 0
    if cmd in ("nar", "store", "closure") and rest: return run_out(cmd, rest)
    if cmd == "log" and rest:
        # gate-checks.py log <out> <logfile|->: the build log of the out's deriver (nix log <drv>)
        text = sys.stdin.read() if rest[1] == "-" else open(rest[1], errors="replace").read()
        return report(rest[0], check_log(text), extra=f" (log: {len(text.splitlines())} lines)")
    print(__doc__); return 2

if __name__ == "__main__":
    sys.exit(main(sys.argv))
