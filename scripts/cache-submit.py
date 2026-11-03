#!/usr/bin/env python3
"""cache-submit.py -- submit built store paths to cache.solnix.io through the
documented builder flow (docs/cache-submit-onboarding.md): signed /begin, PUT the
unsigned NAR + narinfo to staging with the per-object capabilities, signed
/finalize, poll the signed status endpoint. The site validates and signs with
cache.solnix.io-1:8UNr...; nothing here signs a narinfo.

Input is a local binary cache directory, as written by
    nix copy --to 'file:///var/tmp/c1-cache?compression=xz' <paths>
(on illumos, where the paths live; then copy the directory here). The NARs in it
are re-hashed (FileHash/FileSize over the .nar.xz, NarHash/NarSize over the
decompressed stream) and, with --pathinfo, the narinfo fields are compared with
`nix path-info --json` from the build host, before anything is offered.

One submission per store path ("one leaf"), deps first: a path is submitted only
when every reference other than itself already verifies under 8UNr, and only when
its store path is an `out` row of the SERVED recipes.tsv. Everything else is
reported and skipped (the site would reject it).

Default is a dry run: plan, build and sign the exact /begin bodies, print them,
POST nothing. --probe-auth makes one read-only signed GET of the status endpoint
for a random submission id (expect 404 "no such submission") plus the same with
a wrong key (expect 403): it proves the key authenticates without creating a
submission. --submit performs the real submissions.

Before a READY path is offered (dry run and --submit alike), its Deriver must pass scripts/drv-gate.sh --leaf here:
the deriver plus every input drv whose out is not served builds from the store only. A path that fails, or whose
deriver is not in this store, is planned DRV-GATE-FAIL and never submitted. This is the submit path only: a
verification rebuild of a served row does not come through here.

A builder id other than site-team (a host publishing its own build: dixi, dixa, lixi) also needs --stamps <dir>:
the stamps scripts/pre-submit-check.sh writes on that host when an out passes every gate, drv-gate --closure (or --leaf, for
the first publish of a served row's out: the stamp's 5th column says which) included (<dir>/<NarHash nix32>.ok, holding the
store path and its NarHash). A path without a stamp naming it and its NarHash is
planned NO-STAMP and never submitted. The stamp is an interlock against skipping the checks, not a security
boundary: anyone who can write the directory can write one.

Signing: the OpenSSH ed25519 private key is converted in memory to PKCS#8 and
handed to `openssl pkeyutl -rawin` through a 0600 temp file that is deleted
after each signature. The key is never printed.

Eval-anchored (protocol v2 (B), fleet4; infra docs/design/eval-anchored-rows.md): --eval ATTR SYSTEM COMMIT BRANCH
[--flake-nar-hash H] submits ONE path that NO served row names, anchored to what packages.SYSTEM.ATTR evaluates to at COMMIT
(on BRANCH: main or 26.11 only); /begin carries {"eval": {attr, system, commit, branch, flake_nar_hash}}. Its stamp must say
drv-closure (the strict gate: no reviewed row stands behind it) and name exactly that eval (6th column); its deriver passes
drv-gate --closure here. A path some row names plans EVAL-HAS-ROW (it goes the row way). It always ends a proposal.

Tier 1 (protocol v2 (b), infra 20261103-v2b-live): a submission ends `proposed` (or `approved`) until an operator reviews
it: the poll returns that state (`result: proposed`), and `--status <id>` polls it again later. /begin at the 2 GiB
proposal cap answers 429 + Retry-After: `result: backoff <secs>` (wait, never a failure).
"""
import argparse, base64, hashlib, json, lzma, os, re, secrets, subprocess, sys, tempfile, time
import urllib.error, urllib.request

API = "https://builders.solnix.io"  # builder routes only (infra 20261101); search.solnix.io still answers until protocol v2 R1
CACHE = "https://cache.solnix.io"
RECIPES = CACHE + "/registry/recipes.tsv"
KEY8UNR = "cache.solnix.io-1:8UNrVAOSOrI9PGHc8/pD2Yqp265ZeYb3OId+gv4+wm8="
TAG = "solnix-cache-submit-v1"
NIX32 = "0123456789abcdfghijklmnpqrsvwxyz"
STORE_RE = re.compile(r"^/nix/store/([0-9abcdfghijklmnpqrsvwxyz]{32})-[A-Za-z0-9+._?=-]{1,211}$")
UA = "solnix-cache-submit/1"
last_headers = {}  # the response headers of the last http() call (Retry-After on a 429)


def die(msg):
    print(f"cache-submit: {msg}", file=sys.stderr)
    sys.exit(2)


def nix32(digest):
    """Nix's base-32 (as in narinfo FileHash/NarHash), little-end-first bit order."""
    n = len(digest) * 8
    out = []
    for i in range((n + 4) // 5 - 1, -1, -1):
        b, j = i * 5 // 8, i * 5 % 8
        c = digest[b] >> j
        if b + 1 < len(digest):
            c |= digest[b + 1] << (8 - j)
        out.append(NIX32[c & 0x1f])
    return "".join(out)


# ---- key / signature -------------------------------------------------------

def _sshstr(buf, off):
    n = int.from_bytes(buf[off:off + 4], "big")
    return buf[off + 4:off + 4 + n], off + 4 + n


def load_seed(path):
    st = os.stat(path)
    if st.st_mode & 0o077:
        die(f"{path}: private key must be mode 0600")
    pem = open(path).read()
    body = "".join(l for l in pem.splitlines() if l and not l.startswith("-----"))
    raw = base64.b64decode(body)
    magic = b"openssh-key-v1\0"
    if not raw.startswith(magic):
        die("not an OpenSSH private key")
    off = len(magic)
    cipher, off = _sshstr(raw, off)
    _kdf, off = _sshstr(raw, off)
    _kdfopt, off = _sshstr(raw, off)
    if cipher != b"none":
        die("encrypted private keys are not supported")
    nkeys = int.from_bytes(raw[off:off + 4], "big"); off += 4
    if nkeys != 1:
        die("expected one key")
    _pub, off = _sshstr(raw, off)
    priv, off = _sshstr(raw, off)
    if priv[0:4] != priv[4:8]:
        die("private key check words differ")
    p = 8
    kt, p = _sshstr(priv, p)
    if kt != b"ssh-ed25519":
        die("not an ed25519 key")
    pub, p = _sshstr(priv, p)
    sk, p = _sshstr(priv, p)
    if len(sk) != 64 or sk[32:] != pub:
        die("malformed ed25519 private key")
    return sk[:32], pub


def sign(seed, msg):
    der = bytes.fromhex("302e020100300506032b657004220420") + seed
    pem = "-----BEGIN PRIVATE KEY-----\n" + base64.b64encode(der).decode() + "\n-----END PRIVATE KEY-----\n"
    fd, kp = tempfile.mkstemp(prefix="cs-key.", dir="/tmp")  # mkstemp: mode 0600
    mfd, mp = tempfile.mkstemp(prefix="cs-msg.", dir="/tmp")
    try:
        os.write(fd, pem.encode()); os.close(fd)
        # ed25519 is one-shot: pkeyutl needs the message as a file, not a pipe.
        os.write(mfd, msg); os.close(mfd)
        r = subprocess.run(["openssl", "pkeyutl", "-sign", "-rawin", "-inkey", kp, "-in", mp],
                           capture_output=True)
    finally:
        os.unlink(kp); os.unlink(mp)
    if r.returncode != 0 or len(r.stdout) != 64:
        die("openssl ed25519 sign failed: " + r.stderr.decode(errors="replace")[:200])
    return base64.b64encode(r.stdout).decode()


def challenge(method, path, builder, nonce, body):
    return f"{TAG}\n{method}\n{path}\n{builder}\n{nonce}\n{hashlib.sha256(body).hexdigest()}\n".encode()


# ---- HTTP ------------------------------------------------------------------

def http(method, url, body=None, headers=None, timeout=120):
    req = urllib.request.Request(url, data=body, method=method, headers={"User-Agent": UA, **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            last_headers.clear(); last_headers.update(r.headers.items())
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        last_headers.clear(); last_headers.update(e.headers.items())
        return e.code, e.read()


def signed(method, path, builder, seed, body=b"", nonce=""):
    sig = sign(seed, challenge(method, path, builder, nonce, body))
    hdr = {"X-Solnix-Builder": builder, "X-Solnix-Submit-Sig": sig}
    if method == "POST":
        hdr["Content-Type"] = "application/json"
    return http(method, API + path, body if method == "POST" else None, hdr)


# ---- local cache + checks ----------------------------------------------------

def parse_narinfo(text):
    f = {}
    for line in text.splitlines():
        k, sep, v = line.partition(": ")
        if not sep:
            k, v = line.rstrip(":"), ""
        f[k] = v
    return f


def load_local(cache_dir):
    objs = {}
    for name in sorted(os.listdir(cache_dir)):
        if not name.endswith(".narinfo"):
            continue
        f = parse_narinfo(open(os.path.join(cache_dir, name)).read())
        sp = f.get("StorePath", "")
        m = STORE_RE.match(sp)
        if not m or m.group(1) + ".narinfo" != name:
            die(f"{name}: bad StorePath {sp!r}")
        objs[sp] = f
    return objs


def check_nar(cache_dir, f):
    """Re-hash the local .nar.xz: FileHash/FileSize over the file, NarHash/NarSize over its xz stream."""
    if f.get("Compression") != "xz":
        return "compression is not xz"
    fh = "sha256:" + f["URL"][len("nar/"):-len(".nar.xz")]
    if not re.fullmatch(r"nar/[0-9a-z]{52}\.nar\.xz", f["URL"]) or fh != f["FileHash"]:
        return f"URL {f['URL']} is not nar/<FileHash>.nar.xz"
    fhash, nhash, fsize, nsize = hashlib.sha256(), hashlib.sha256(), 0, 0
    dec = lzma.LZMADecompressor(format=lzma.FORMAT_XZ)
    try:
        with open(os.path.join(cache_dir, f["URL"]), "rb") as fp:
            while chunk := fp.read(1 << 20):
                fhash.update(chunk); fsize += len(chunk)
                out = dec.decompress(chunk)
                nhash.update(out); nsize += len(out)
    except (OSError, lzma.LZMAError) as e:
        return f"NAR unreadable: {e}"
    if not dec.eof:
        return "truncated xz stream"
    if "sha256:" + nix32(fhash.digest()) != f["FileHash"] or str(fsize) != f["FileSize"]:
        return "FileHash/FileSize mismatch"
    if "sha256:" + nix32(nhash.digest()) != f["NarHash"] or str(nsize) != f["NarSize"]:
        return "NarHash/NarSize mismatch"
    return None


def check_pathinfo(f, pi):
    """narinfo vs `nix path-info --json` from the build host."""
    sri = pi["narHash"]
    want = "sha256:" + nix32(base64.b64decode(sri.split("-", 1)[1])) if sri.startswith("sha256-") else sri
    refs = " ".join(sorted(os.path.basename(r) for r in pi["references"]))
    drv = os.path.basename(pi["deriver"]) if pi.get("deriver") else ""
    bad = [k for k, a, b in (("NarHash", f["NarHash"], want), ("NarSize", f["NarSize"], str(pi["narSize"])),
                             ("References", " ".join(sorted(f.get("References", "").split())), refs),
                             ("Deriver", f.get("Deriver", ""), drv)) if a != b]
    return ("path-info mismatch: " + ",".join(bad)) if bad else None


def unsigned_narinfo(f):
    """The narinfo we stage: the validator's field set, no Sig, no CA (the site signs)."""
    keys = ["StorePath", "URL", "Compression", "FileHash", "FileSize", "NarHash", "NarSize", "References"]
    if f.get("Deriver"):
        keys.append("Deriver")
    return "".join(f"{k}: {f.get(k, '')}\n" for k in keys).encode()


def drv_gate_leaf(f, mode="--leaf"):
    """None if the narinfo's Deriver passes scripts/drv-gate.sh --leaf (eval: --closure) in this store, else why (the FAIL lines)."""
    drv = f.get("Deriver", "")
    if not drv:
        return "no Deriver in the narinfo"
    drv = "/nix/store/" + drv
    if not os.path.exists(drv):
        return f"deriver {drv} is not in this store (drv-gate cannot judge it)"
    gc = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gate-checks.py")
    r = subprocess.run([sys.executable, gc, "drv", mode, drv], capture_output=True, text=True)
    for l in r.stdout.splitlines():
        if l.startswith(("ALLOW ", "EXEMPT ")):
            print("  drv-gate: " + l[:300])
    if r.returncode == 0:
        return None
    fails = [l for l in r.stdout.splitlines() if l.startswith("FAIL ")] or [r.stderr.strip()[-300:]]
    return f"drv-gate {mode}: " + " | ".join(x[:240] for x in fails[:4])


def stamped(d, sp, narhash, ev=None):
    """pre-submit-check.sh passed this exact path with this exact NarHash (stamp <nix32>.ok: path, NarHash, time, host,
    mode, [eval]); ev: the stamp must be drv-closure and name exactly this eval (eval:<attr>:<system>:<commit>:<branch>)."""
    if not narhash.startswith("sha256:"):
        return False
    try:
        cols = open(os.path.join(d, narhash[len("sha256:"):] + ".ok")).read().split("\t")
    except OSError:
        return False
    if len(cols) < 2 or cols[0] != sp:
        return False
    if ev and (len(cols) < 6 or cols[4] != "drv-closure" or cols[5].strip() != ev):
        return False
    h = cols[1]
    if h.startswith("sha256-"):
        h = "sha256:" + nix32(base64.b64decode(h[len("sha256-"):]))
    return h == narhash


def published(path):
    """Installable from cache.solnix.io under 8UNr, with an empty Nix cache (onboarding doc, Client notes)."""
    env = dict(os.environ, XDG_CACHE_HOME=tempfile.mkdtemp(prefix="cs-xdg."))
    r = subprocess.run(["nix", "store", "verify", "--no-contents", "--store", CACHE,
                        "--trusted-public-keys", KEY8UNR, path], env=env, capture_output=True)
    return r.returncode == 0


def served_outs(src=RECIPES):
    if src.startswith("https://"):
        code, body = http("GET", src)
        if code != 200:
            die(f"recipes.tsv: HTTP {code}")
    else:
        body = open(src, "rb").read()
    lines = body.decode().splitlines()
    hdr = lines[0].split("\t")
    want = "pname version url sha256 buildsys deps flags system out debug".split()
    if hdr != want:
        die(f"recipes.tsv header {hdr} != out-schema")
    i = hdr.index("out")
    return {c[i] for c in (l.split("\t") for l in lines[1:]) if len(c) > i and c[i]}, hashlib.sha256(body).hexdigest()


def topo(objs):
    order, seen = [], set()
    def visit(p):
        if p in seen:
            return
        seen.add(p)
        for r in sorted(objs[p].get("References", "").split()):
            q = "/nix/store/" + r
            if q != p and q in objs:
                visit(q)
        order.append(p)
    for p in sorted(objs):
        visit(p)
    return order


# ---- submit ----------------------------------------------------------------

def begin_body(sp, f, ev=None):
    h = STORE_RE.match(sp).group(1)
    common = {"store_path": sp, "nar_hash": f["NarHash"], "nar_size": int(f["NarSize"])}
    b = {"objects": [dict(common, nar_key=f["URL"], compression="xz"), dict(common, nar_key=h + ".narinfo", compression="none")]}
    if ev:
        b["eval"] = ev
    return json.dumps(b, separators=(",", ":")).encode()


EVAL_BRANCHES = ("main", "26.11")  # our review of (B) §2.1: the published branches; a wave branch only when we name one


def eval_obj(a):
    """--eval ATTR SYSTEM COMMIT BRANCH [--flake-nar-hash] -> the /begin eval object, validated as infra's §4 does, or die."""
    attr, system, commit, branch = a.eval
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,127}", attr) or "." in attr:
        die(f"--eval attr {attr!r}: one level, [A-Za-z0-9][A-Za-z0-9._+-]{{0,127}}, no dots")
    if not re.fullmatch(r"[a-z0-9_]+-[a-z]+", system):
        die(f"--eval system {system!r}")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        die(f"--eval commit {commit!r}: 40 lowercase hex")
    if branch not in EVAL_BRANCHES:
        die(f"--eval branch {branch!r} is not one of {', '.join(EVAL_BRANCHES)}")
    ev = {"attr": attr, "system": system, "commit": commit, "branch": branch}
    if a.flake_nar_hash:
        if not re.fullmatch(r"sha256-[A-Za-z0-9+/]{43}=", a.flake_nar_hash):
            die(f"--flake-nar-hash {a.flake_nar_hash!r}: sha256-<base64> (nix flake metadata --json .locked.narHash)")
        ev["flake_nar_hash"] = a.flake_nar_hash
    return ev


def submit_one(a, seed, sp, f, ev=None):
    h = STORE_RE.match(sp).group(1)
    body = begin_body(sp, f, ev)
    code, resp = signed("POST", "/api/v1/cache/submit/begin", a.builder, seed, body)
    print(f"  begin: HTTP {code} {resp[:300].decode(errors='replace') if code != 200 else ''}")
    if code == 429:  # tier 1 over the proposal cap: back off, not a failure
        ra = last_headers.get("Retry-After", "900")
        return f"backoff {ra if ra.isdigit() else 900}"
    if code != 200:
        return "begin-failed"
    b = json.loads(resp)
    sid, nonce, base = b["submission_id"], b["nonce"], b["staging_url"].rstrip("/")
    caps = {o["nar_key"]: o["capability"] for o in b["objects"]}
    print(f"  submission {sid} staging {base}")
    for key, data in ((f["URL"], open(os.path.join(a.cache_dir, f["URL"]), "rb").read()),
                      (h + ".narinfo", unsigned_narinfo(f))):
        code, resp = http("PUT", f"{base}/staging/{sid}/{key}", data,
                          {"X-Solnix-Capability": caps[key], "Content-Length": str(len(data))}, timeout=600)
        print(f"  put {key} ({len(data)} B): HTTP {code} {resp[:200].decode(errors='replace') if code >= 300 else ''}")
        if code >= 300:
            return "upload-failed"
    fbody = json.dumps({"submission_id": sid, "nonce": nonce}, separators=(",", ":")).encode()
    code, resp = signed("POST", "/api/v1/cache/submit/finalize", a.builder, seed, fbody, nonce)
    print(f"  finalize: HTTP {code} {resp[:300].decode(errors='replace')}")
    if code != 200:
        return "finalize-failed"
    return poll_status(a, seed, sid, "finalized")


def poll_status(a, seed, sid, unknown="unknown"):
    """Poll the signed status of submission sid for up to a.poll s: promoted | rejected | proposed | approved (tier 1:
    waiting for /review) | <unknown> (status not answering) | <unknown>-timeout."""
    deadline = time.time() + a.poll
    while True:
        code, resp = signed("GET", f"/api/v1/cache/submit/status/{sid}", a.builder, seed)
        if code != 200:
            print(f"  status: HTTP {code} {resp[:200].decode(errors='replace')} (endpoint not live?)")
            return unknown
        st = json.loads(resp)
        print(f"  status: {st.get('state')} {st.get('reason') or ''}")
        if st.get("state") in ("promoted", "rejected", "proposed", "approved"):
            return st["state"]
        if time.time() >= deadline:
            return unknown + "-timeout"
        time.sleep(15)


def probe_auth(a, seed):
    sid = secrets.token_urlsafe(32)[:43]
    good = signed("GET", f"/api/v1/cache/submit/status/{sid}", a.builder, seed)
    bad = signed("GET", f"/api/v1/cache/submit/status/{sid}", a.builder, secrets.token_bytes(32))
    for label, (code, body) in (("enrolled key", good), ("random key (negative control)", bad)):
        print(f"probe {label}: HTTP {code} {body[:200].decode(errors='replace')}")
    return good, bad


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cache-dir", help="local file:// binary cache holding the NARs (required but with --status)")
    ap.add_argument("--paths", help="file of store paths to consider (default: every narinfo in --cache-dir)")
    ap.add_argument("--pathinfo", help="`nix path-info --json` output from the build host, to cross-check")
    ap.add_argument("--key", help="OpenSSH ed25519 submit key (0600)")
    ap.add_argument("--builder", default="site-team")
    ap.add_argument("--probe-auth", action="store_true", help="read-only signed status GET (no submission)")
    ap.add_argument("--submit", action="store_true", help="really submit (default: dry run)")
    ap.add_argument("--recipes", default=RECIPES,
                    help="authority to plan against (default: the served copy). A local file is for dry runs only:"
                         " the site checks the served copy, so --submit refuses anything else")
    ap.add_argument("--with-refs", action="store_true",
                    help="also submit leaves that have (published) references, alone")
    ap.add_argument("--poll", type=int, default=600, help="seconds to poll status after finalize")
    ap.add_argument("--status", metavar="ID", help="poll an earlier submission's status (for --poll s) and print `result: <state>`")
    ap.add_argument("--stamps", help="pre-submit-check.sh stamp dir (required with --submit for any builder but site-team)")
    ap.add_argument("--eval", nargs=4, metavar=("ATTR", "SYSTEM", "COMMIT", "BRANCH"),
                    help="eval-anchored: one path no row names, = packages.SYSTEM.ATTR at COMMIT on BRANCH (see above)")
    ap.add_argument("--flake-nar-hash", help="with --eval: nix flake metadata --json <flake>?rev=COMMIT .locked.narHash")
    a = ap.parse_args()
    ev = eval_obj(a) if a.eval else None
    evs = "eval:" + ":".join(a.eval) if a.eval else None
    if a.flake_nar_hash and not a.eval:
        die("--flake-nar-hash goes with --eval")
    if ev and not a.status and not (a.paths and a.stamps):
        die("--eval needs --paths (one path) and --stamps (pre-submit-check.sh --eval passed it)")

    seed = None
    if a.key:
        seed, pub = load_seed(a.key)
        print(f"key: ed25519 pub {base64.b64encode(pub).decode()[:12]}... (private half not shown)")
    if (a.submit or a.probe_auth) and not seed:
        die("--submit/--probe-auth need --key")
    if a.submit and a.recipes != RECIPES:
        die("--submit plans only against the served recipes.tsv")
    if a.submit and a.builder != "site-team" and not a.stamps:
        die(f"--submit as builder {a.builder} needs --stamps: run scripts/pre-submit-check.sh on the build host first")
    if a.probe_auth:
        probe_auth(a, seed)
    if a.status:
        if not seed:
            die("--status needs --key")
        print(f"STATUS {a.status}\n  result: {poll_status(a, seed, a.status)}")
        return
    if not a.cache_dir:
        die("--cache-dir is required")

    objs = load_local(a.cache_dir)
    if a.paths:
        want = {l.strip() for l in open(a.paths) if l.strip()}
        missing = want - objs.keys()
        if missing:
            die(f"{len(missing)} paths not in {a.cache_dir}: {sorted(missing)[:3]}")
        objs = {p: f for p, f in objs.items() if p in want}
    if ev and len(objs) != 1:
        die(f"--eval submits exactly one path ({len(objs)} given)")
    pinfo = json.load(open(a.pathinfo)) if a.pathinfo else {}
    outs, rsha = served_outs(a.recipes)
    print(f"recipes.tsv {a.recipes} sha256 {rsha}: {len(outs)} out rows")

    pub_cache = {}
    def is_pub(p):
        if p not in pub_cache:
            pub_cache[p] = published(p)
        return pub_cache[p]

    plan = []
    for sp in topo(objs):
        f = objs[sp]
        why = check_nar(a.cache_dir, f) or (check_pathinfo(f, pinfo[sp]) if sp in pinfo else
                                            ("not in --pathinfo" if pinfo else None))
        if why:
            plan.append((sp, "BAD-LOCAL", why)); continue
        if a.stamps and not stamped(a.stamps, sp, f["NarHash"], evs):
            plan.append((sp, "NO-STAMP", f"no pre-submit stamp for NarHash {f['NarHash']}{' naming ' + evs + ' (drv-closure)' if evs else ''} in {a.stamps}")); continue
        if is_pub(sp):
            plan.append((sp, "PUBLISHED", "verifies under 8UNr")); continue
        refs = [("/nix/store/" + r) for r in f.get("References", "").split()]
        unpub = [r for r in refs if r != sp and not is_pub(r)]
        if ev and sp in outs:
            plan.append((sp, "EVAL-HAS-ROW", "a served row names it: submit it the row way, not --eval"))
        elif not ev and sp not in outs:
            plan.append((sp, "WAIT-AUTHORITY", "not an out row of the served recipes.tsv"))
        elif unpub:
            plan.append((sp, "WAIT-DEPS", "unpublished refs: " + " ".join(os.path.basename(r) for r in unpub)))
        elif [r for r in refs if r != sp] and not a.with_refs:
            # The checkout's cache-promote.sh takes ONE staged narinfo as the leaf and the
            # validator wants the leaf's whole published closure re-staged with it, so a
            # leaf with references sent alone would be rejected. Held until the site
            # confirms how a leaf with references is submitted (--with-refs overrides).
            plan.append((sp, "HOLD-REFS", f"{len(refs)} refs, all published; see --with-refs"))
        else:
            plan.append((sp, "READY", f"{len(refs)} refs, all published"))

    # drv-gate --leaf on every READY path's deriver (the submit path's store-only check; see the module docstring)
    for i, (sp, st, why) in enumerate(plan):
        if st != "READY":
            continue
        bad = drv_gate_leaf(objs[sp], "--closure" if ev else "--leaf")
        if bad:
            plan[i] = (sp, "DRV-GATE-FAIL", bad)

    for sp, st, why in plan:
        print(f"{st:15s} {sp}  {why}")
    counts = {}
    for _, st, _ in plan:
        counts[st] = counts.get(st, 0) + 1
    print("summary:", " ".join(f"{k}={v}" for k, v in sorted(counts.items())))

    ready = [sp for sp, st, _ in plan if st == "READY"]
    # WAIT-DEPS on a path that is READY in this same run clears once that one is promoted;
    # rerun after the status reports promoted rather than chaining (the site is asynchronous).
    for sp in ready:
        f = objs[sp]
        body = begin_body(sp, f, ev)
        if not a.submit:
            print(f"DRY-RUN {sp}\n  begin body {body.decode()}")
            if seed:
                print(f"  challenge sha256 {hashlib.sha256(challenge('POST', '/api/v1/cache/submit/begin', a.builder, '', body)).hexdigest()} signed ok ({len(sign(seed, b'x'))} b64 chars)")
            print("  narinfo to stage:\n    " + unsigned_narinfo(f).decode().replace("\n", "\n    ").rstrip())
            continue
        print(f"SUBMIT {sp}")
        print(f"  result: {submit_one(a, seed, sp, f, ev)}")


if __name__ == "__main__":
    main()
