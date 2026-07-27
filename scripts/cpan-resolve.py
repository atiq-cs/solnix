#!/usr/bin/env python3
"""cpan-resolve.py — map illumos FMRI dash-names (library/perl-5/<name>) to a
CPAN dist tarball URL via MetaCPAN's case-insensitive distribution.lowercase
term query. Emits `Module::Name=url` lines that oi-plmod.sh consumes.
Reads dash-names on stdin (one per line).
"""
import json, sys, time, urllib.request

API = "https://fastapi.metacpan.org/v1/release/_search"

def resolve(dash):
    body = json.dumps({
        "query": {"bool": {"must": [
            {"term": {"distribution.lowercase": dash.lower()}},
            {"term": {"status": "latest"}},
        ]}},
        "size": 1, "_source": ["distribution", "download_url"],
    }).encode()
    req = urllib.request.Request(API, data=body,
                                headers={"Content-Type": "application/json",
                                         "User-Agent": "solnix-cpan-resolve/2"})
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            d = json.load(r)
        hits = d.get("hits", {}).get("hits", [])
        if hits:
            src = hits[0]["_source"]
            du, dist = src.get("download_url"), src.get("distribution")
            if du and dist:
                return dist.replace("-", "::"), du
    except Exception as e:
        print("# ERR\t%s\t%s" % (dash, e), file=sys.stderr)
    return None, None

def main():
    ok = fail = 0
    for line in sys.stdin:
        dash = line.strip()
        if not dash:
            continue
        mod, url = resolve(dash)
        if url:
            print("%s=%s" % (mod, url)); ok += 1
        else:
            print("# UNRESOLVED\t%s" % dash, file=sys.stderr); fail += 1
        time.sleep(0.12)
    print("# resolved=%d unresolved=%d" % (ok, fail), file=sys.stderr)

if __name__ == "__main__":
    main()
