#!/usr/bin/env python3
# wgpu-illumos.py <vendor>: turn on wgpu's Vulkan and GLES backends for target_os = "illumos" (vk1, 2026-11-11).
# wgpu 28 enables a native backend only where its cfg lists name the OS: any(windows, linux, android, freebsd) in
# wgpu/build.rs (vulkan, gles), wgpu-core/build.rs (windows_linux_android), wgpu-core/Cargo.toml and
# wgpu-core-deps-windows-linux-android/Cargo.toml (the target dep that carries wgpu-hal's backend features).
# illumos matches none, so Instance::new panics "No wgpu backend feature ... was enabled" (wgpu/src/api/instance.rs:62)
# and the COSMIC apps were built without wgpu. wgpu-hal's Vulkan code is plain unix (ash dlopens libvulkan.so.1, drm.rs
# uses libc::fstat/makedev, which illumos libc has), so adding illumos next to freebsd is the whole port.
# Every anchor must match exactly the expected number of times (FATAL otherwise), and .cargo-checksum.json is
# re-stamped for every edited file.
import sys, os, json, hashlib
V = sys.argv[1]
FB, IL = 'target_os = "freebsd"', 'target_os = "freebsd", target_os = "illumos"'
edits = [("wgpu", "build.rs", 2), ("wgpu-core", "build.rs", 1), ("wgpu-core", "Cargo.toml", 1),
         ("wgpu-core-deps-windows-linux-android", "Cargo.toml", 1)]
for crate, rel, want in edits:
    d = os.path.join(V, crate); p = os.path.join(d, rel)
    s = open(p, encoding="utf-8").read()
    if IL in s: sys.exit("FATAL: wgpu-illumos: %s/%s already names illumos" % (crate, rel))
    n = s.count(FB)
    if n != want: sys.exit("FATAL: wgpu-illumos: %s/%s has %d freebsd gates, want %d (upstream changed?)" % (crate, rel, n, want))
    s = s.replace(FB, IL); open(p, "w", encoding="utf-8").write(s)
    ck = os.path.join(d, ".cargo-checksum.json"); sums = json.load(open(ck))
    if rel not in sums["files"]: sys.exit("FATAL: wgpu-illumos: no checksum entry %s/%s" % (crate, rel))
    sums["files"][rel] = hashlib.sha256(open(p, "rb").read()).hexdigest(); json.dump(sums, open(ck, "w"))
    print("wgpu-illumos %s/%s: %d gates" % (crate, rel, n), file=sys.stderr)
