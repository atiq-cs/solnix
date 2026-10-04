#!/usr/bin/env python3
"""cache-audit-narinfo.py -- READ-ONLY metadata pass over the served solnix cache.

Enumerates narinfos reachable from a seed hash list (served arch-manifest.tsv +
registry tsvs) by BFS over References, fetching every narinfo from
https://cache.solnix.io anonymously. For each object records: HTTP status,
StorePath, System (if any), NarHash, NarSize, FileSize, References, Sig key(s),
whether the fingerprint verifies against each known PUBLIC key, and the HTTP
status of a HEAD on the NAR URL.

Never writes to the cache. Uses only public keys (no secret key is read).

Usage: cache-audit-narinfo.py SEED_HASHES_FILE OUTDIR
  OUTDIR/narinfo/<hash>.narinfo   raw narinfo bodies (200 only)
  OUTDIR/meta.tsv                 one row per hash reached
Needs python3 with pynacl.
"""
import base64, concurrent.futures as cf, os, sys, threading, time, urllib.request, urllib.error

CACHE = os.environ.get("CACHE", "https://cache.solnix.io")
KEYS = {  # name-prefix -> raw ed25519 public key; label is the first 4 chars
    "8UNr": "8UNrVAOSOrI9PGHc8/pD2Yqp265ZeYb3OId+gv4+wm8=",
    "5HAV": "5HAVNxgJW1VK0O6lHSq45MSUwddLO6EM2Rz4NEjRUVk=",
}
WORKERS = int(os.environ.get("WORKERS", "24"))

from nacl.signing import VerifyKey
from nacl.exceptions import BadSignatureError
VK = {lab: VerifyKey(base64.b64decode(k)) for lab, k in KEYS.items()}


def http(method, url, tries=4):
    """Return (status, body). Retries transient failures; 404 is returned as-is."""
    last = None
    for i in range(tries):
        req = urllib.request.Request(url, method=method, headers={"User-Agent": "solnix-cache-audit/1"})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.status, (r.read() if method == "GET" else b"")
        except urllib.error.HTTPError as e:
            if e.code in (404, 403, 410):
                return e.code, b""
            last = e.code
        except Exception as e:  # timeouts, resets
            last = type(e).__name__
        time.sleep(1.5 * (i + 1))
    return f"ERR:{last}", b""


def parse(body):
    d = {}
    for line in body.decode("utf-8", "replace").splitlines():
        if ": " in line:
            k, v = line.split(": ", 1)
            d.setdefault(k, []).append(v)
        elif line.endswith(":"):
            d.setdefault(line[:-1], []).append("")
    return d


def sig_check(d):
    """Return (sigkeys, verifies) where sigkeys like '8UNr,5HAV' / 'none' and
    verifies like '8UNr:ok,5HAV:bad'. A Sig whose key name is cache.solnix.io-1 is
    tried against BOTH public keys, because both keys share that name."""
    sp = d.get("StorePath", [""])[0]
    refs = d.get("References", [""])[0].split()
    fp = "1;%s;%s;%s;%s" % (sp, d.get("NarHash", [""])[0], d.get("NarSize", [""])[0],
                            ",".join("/nix/store/" + r for r in refs))
    keys, res = [], []
    for s in d.get("Sig", []):
        name, _, b64 = s.partition(":")
        try:
            raw = base64.b64decode(b64)
        except Exception:
            res.append(f"{name}:undecodable"); continue
        hit = None
        for lab, vk in VK.items():
            try:
                vk.verify(fp.encode(), raw); hit = lab; break
            except BadSignatureError:
                pass
        if hit:
            keys.append(hit); res.append(f"{hit}:ok")
        else:
            keys.append(f"unknown({name})"); res.append(f"{name}:bad")
    return (",".join(keys) or "none"), (",".join(res) or "-")


def main():
    seedf, out = sys.argv[1], sys.argv[2]
    os.makedirs(f"{out}/narinfo", exist_ok=True)
    seeds = [l.strip() for l in open(seedf) if len(l.strip()) == 32]
    seen, lock = set(seeds), threading.Lock()
    rows = {}
    origin = {h: "seed" for h in seeds}

    def work(h):
        st, body = http("GET", f"{CACHE}/{h}.narinfo")
        if st == 404:  # flaky-negative guard: confirm a 404 once more before trusting it
            time.sleep(2); st, body = http("GET", f"{CACHE}/{h}.narinfo")
        if st != 200:
            return h, {"http": str(st)}, []
        open(f"{out}/narinfo/{h}.narinfo", "wb").write(body)
        d = parse(body)
        url = d.get("URL", [""])[0]
        nst, _ = http("HEAD", f"{CACHE}/{url}") if url else ("nourl", b"")
        sk, sv = sig_check(d)
        refs = d.get("References", [""])[0].split()
        r = {"http": "200",
             "storepath": d.get("StorePath", [""])[0],
             "system": d.get("System", ["-"])[0] or "-",
             "narhash": d.get("NarHash", [""])[0], "narsize": d.get("NarSize", [""])[0],
             "filesize": d.get("FileSize", [""])[0], "compression": d.get("Compression", [""])[0],
             "url": url, "nar_head": str(nst), "sigkeys": sk, "sigverify": sv,
             "nrefs": str(len(refs)), "refs": " ".join(refs),
             "deriver": d.get("Deriver", ["-"])[0]}
        return h, r, [x[:32] for x in refs]

    t0 = time.time()
    with cf.ThreadPoolExecutor(WORKERS) as ex:
        futs = {ex.submit(work, h) for h in seeds}
        while futs:
            done, futs = cf.wait(futs, return_when=cf.FIRST_COMPLETED)
            for f in done:
                h, r, refs = f.result()
                rows[h] = r
                for rh in refs:
                    if rh not in seen:
                        seen.add(rh); origin[rh] = "bfs"
                        futs.add(ex.submit(work, rh))
            if len(rows) % 1000 < len(done):
                print(f"{len(rows)} done, {len(futs)} pending, {time.time()-t0:.0f}s", file=sys.stderr, flush=True)

    cols = ["http", "storepath", "system", "narhash", "narsize", "filesize", "compression", "url",
            "nar_head", "sigkeys", "sigverify", "nrefs", "deriver", "refs"]
    with open(f"{out}/meta.tsv", "w") as fo:
        fo.write("hash\torigin\t" + "\t".join(cols) + "\n")
        for h in sorted(rows):
            fo.write(h + "\t" + origin[h] + "\t" + "\t".join(rows[h].get(c, "") for c in cols) + "\n")
    print(f"wrote {out}/meta.tsv rows={len(rows)} in {time.time()-t0:.0f}s", file=sys.stderr)


if __name__ == "__main__":
    main()
