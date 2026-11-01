#!/usr/bin/env python3
# cosmic-widen-linux.py <vendor> <crate>...: the COSMIC toolkit crates (libcosmic, the pop-os iced
# fork) gate their whole Wayland client side (cctk, layer-shell, the applet module, dbus-config)
# on target_os = "linux" as a proxy for "a Wayland desktop". illumos runs the same Wayland stack,
# so widen those gates to any(linux, illumos) in the named crates only (.rs and Cargo.toml target
# tables; Cargo.lock already lists those deps). Each crate must have >= 1 gate (FATAL otherwise;
# a trailing '?' makes a crate optional: absent or gate-free is fine), and .cargo-checksum.json is re-stamped for every edited file.
import sys, os, json, hashlib
V, crates = sys.argv[1], sys.argv[2:]
OLD, NEW = 'target_os = "linux"', 'any(target_os = "linux", target_os = "illumos")'
total = 0
for c in crates:
    opt = c.endswith("?"); c = c.rstrip("?"); d = os.path.join(V, c)
    if not os.path.isdir(d):
        if opt: continue
        sys.exit("FATAL: widen: crate %s not vendored" % c)
    ck = os.path.join(d, ".cargo-checksum.json"); sums = json.load(open(ck)); n = 0
    for root, _, files in os.walk(d):
        for f in files:
            if not (f.endswith(".rs") or f == "Cargo.toml"): continue
            p = os.path.join(root, f); s = open(p, encoding="utf-8").read()
            if OLD not in s: continue
            # Cargo.toml target tables are 'cfg(target_os = "linux")': same textual rewrite.
            s = s.replace(OLD, NEW); open(p, "w", encoding="utf-8").write(s); n += s.count(NEW)
            rel = os.path.relpath(p, d)
            if rel not in sums["files"]: sys.exit("FATAL: widen: no checksum entry %s/%s" % (c, rel))
            sums["files"][rel] = hashlib.sha256(open(p, "rb").read()).hexdigest()
    if n == 0 and opt: continue
    if n == 0: sys.exit("FATAL: widen: no %s gate in %s (upstream changed?)" % (OLD, c))
    json.dump(sums, open(ck, "w")); total += n
    print("widen %s: %d gates" % (c, n), file=sys.stderr)
print("cosmic-widen-linux: %d crates, %d gates" % (len(crates), total), file=sys.stderr)
