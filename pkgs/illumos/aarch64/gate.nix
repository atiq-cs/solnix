# pkgs.illumos.aarch64.gate — the richlowe/arm64-gate proto/root_aarch64 as a
# store path. MIRRORS pkgs/illumos/gate.nix (the x86_64 proto ingest) for the
# aarch64 proto restored from the solnix.io archive (A3).
#
# GATE A of docs/design-gate-derivation.md §1, PROTO-INGEST variant, aarch64.
#
# The aarch64 proto is the richlowe arm64-gate output (gate rev 73466454),
# restored onto an ouch builder from:
#   https://s3.solnix.io/solnix-cache/archive/aarch64/aarch64-proto-73466454.tar.zst
#   (sha256 b4c89fadde66db90936b98f403cb293358551590b2a9afbd61a75a684b23e3db)
# untarred to /aarch64/arm64-gate/illumos-gate/proto/root_aarch64. We INGEST
# that existing proto into the store (builtins.path) to feed the aarch64 world
# slices, exactly like the x86_64 ingest.
#
# TODO(A4/P2): replace this ingest with the real build FOD that RUNS the
# richlowe arm64-gate `make download/setup/illumos` cross-build (needs the cross
# gcc / $CROSS, which was NOT in the archived proto — it died with numa). Until
# the gate is rebuilt, this ingest of the restored proto is the source of truth.

# protoDir: a local proto tree (the cross build host's /aarch64/arm64-gate/illumos-gate/proto/root_aarch64).
# null (the default): the banked proto tarball, so a pure (flake) eval works anywhere. builtins.fetchTarball with
# the NAR hash gives the SAME source path as builtins.path of the unpacked tree (vrl03md6..-illumos-aarch64-gate-proto-src,
# name + NAR hash), so every aarch64 drv stays the one the image was built from (gcc y5hyjz05, nix chain).
# shortcut: an eval-time fetch (122 MB) where the path is not already in the store (x86's gate moved to an FOD,
# fetch-tarball.nix, which would change every aarch64 drv hash); upgrade when the aarch64 set is rebuilt anyway.
{ protoDir ? null, system ? builtins.currentSystem }:

let
  proto = if protoDir != null then builtins.path {
    path = protoDir;
    name = "illumos-aarch64-gate-proto-src";
  } else builtins.fetchTarball {
    # aa64tls (2026-10-29): the 20260912 proto with three objects rebuilt from the same gate pin: lib/libc.so.1 +
    # lib/ld.so.1 (variant-1 static TLS: each module its own block) and lib/libld.so.4 (an executable keeps GD TLS
    # as GD). Diffs: src/aarch64-arm64-gate-patches/static-tls-20261029/. Until infra hosts this URL, pass protoDir
    # = the unpacked tarball (same store path, sqf397cb..); bank floki ~/solnix-bank/aa64tls-20261029/proto.
    url = "https://s3.solnix.io/solnix-cache/ami/aarch64-proto-aa64tls-20261029/proto-root_aarch64.tar.gz";  # flat sha256 81192a7c..
    sha256 = "0d1szk5cf282m1c8220s0iy3hk043nicyhm56fw4wa9rhr9zgwwz";
    name = "illumos-aarch64-gate-proto-src";
  };
in
derivation {
  name = "illumos-aarch64-gate-proto";
  inherit system; # the x86 host (cross slicing) or aarch64-solaris (native, aa64nix)
  builder = "/usr/bin/bash";
  # cp -a preserves symlinks (lib/64 -> ., usr/lib/*.so -> *.so.N), perms, and
  # CTF sections in the aarch64 kernel objects (no strip/fixup).
  PATH = "/usr/gnu/bin:/usr/bin:/usr/sbin";
  args = [ "-c" ''
    set -eu
    mkdir -p "$out"
    cp -a "${proto}/." "$out/"
    # sanity: aarch64 libc, headers, kernel unix + genunix (LP64, no amd64).
    [ -f "$out/lib/libc.so.1" ]                        || { echo "FATAL: no aarch64 proto libc" >&2; exit 1; }
    [ -d "$out/usr/include" ]                          || { echo "FATAL: no aarch64 proto headers" >&2; exit 1; }
    [ -f "$out/platform/armv8/kernel/aarch64/unix" ]   || { echo "FATAL: no aarch64 unix" >&2; exit 1; }
    [ -f "$out/kernel/aarch64/genunix" ]               || { echo "WARN: genunix not at kernel/aarch64/genunix" >&2; }
  '' ];
}
