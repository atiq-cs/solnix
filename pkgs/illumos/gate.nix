# pkgs.illumos.gate — the illumos-gate proto area as a store path.
#
# GATE A of docs/design-gate-derivation.md §1, PROTO-INGEST variant.
#
# The eventual goal (design §1.5) is a fixed-output derivation that RUNS the
# proven scripts/oi-gate-build.sh recipe inside Nix (~90 min, host-impure build
# inputs, output pinned by outputHash). That is deferred: the gate is already
# built at /code/illumos-gate/proto/root_i386, so for this iteration we INGEST
# the existing proto into the store to prove the proto-as-store-path model and
# feed the downstream slices (GATE B/C). See TODO below for the full FOD recipe.
#
# Standalone expression: plain `derivation` + a bash builder, no nixpkgs stdenv,
# so it iterates fast with the host's Nix 2.3.16 (currentSystem x86_64-solaris,
# sandbox=false). The fork integration (stdenvNoCC.mkDerivation) maps 1:1 onto
# this and is noted in the report.
#
# TODO(P2): replace this ingest with the real build FOD:
#   src = fetchFromGitHub { owner="illumos"; repo="illumos-gate";
#                           rev="ac45d71fc2b04a5422e72a14b54dd1e746e7be07"; hash=...; };
#   buildPhase = <scripts/oi-gate-build.sh recipe: solnix.sh, empty gcc14 shadow,
#                unset ON_CLOSED_BINS, PERL_VERSION=5.42, wrapmake -m serial,
#                nightly solnix.sh || true>;
#   installPhase = cp -a proto/root_i386/. $out/;
#   outputHash = <pin the proto bytes, recompute per recipe/rev change>;

{ protoDir ? /code/illumos-gate/proto/root_i386 }:

let
  # builtins.path imports the proto tree into the store, content-addressed by
  # its NAR hash. No FOD outputHash placeholder needed: the store path IS the
  # pinned artifact, recomputed only if the proto bytes change. This is the
  # ingest analog of the seed FOD (which pins bytes the same way).
  #
  # Hashes discovered on the host (illumos-960edb1c89 host, gate ac45d71fc2,
  # proto 429M -> 491M in store; deterministic: two builds gave the same path):
  #   proto-src NAR : sha256:1nw4pd2kdr9f3ndyfyf1r9jr2432r9nsw9n8zbxwa4crg650dj1l
  #   gate $out     : /nix/store/y9d8x07cnxp9pyhb75v8bsd50cv6h98w-illumos-gate-proto
  # To pin explicitly (fork FOD form), add sha256 = the base32 above to
  # builtins.path; omitted here so a proto rebuild is picked up automatically.
  proto = builtins.path {
    path = protoDir;
    name = "illumos-gate-proto-src";
    # filter: keep everything; the gate proto is what we want verbatim.
  };
in
derivation {
  name = "illumos-gate-proto";
  system = builtins.currentSystem; # x86_64-solaris; builds only on illumos.
  builder = "/usr/bin/bash";
  # cp -a preserves symlinks (usr/lib/amd64/*.so -> ../../../lib/amd64/*.so.N),
  # perms, and — critically — CTF sections in the kernel objects (no strip/fixup).
  PATH = "/usr/gnu/bin:/usr/bin:/usr/sbin";
  args = [ "-c" ''
    set -eu
    mkdir -p "$out"
    cp -a "${proto}/." "$out/"
    # sanity: the proto must contain a real libc, headers, and genunix.
    [ -f "$out/lib/amd64/libc.so.1" ] || { echo "FATAL: no proto libc" >&2; exit 1; }
    [ -d "$out/usr/include" ]         || { echo "FATAL: no proto headers" >&2; exit 1; }
    [ -f "$out/kernel/amd64/genunix" ] || { echo "WARN: genunix not at kernel/amd64/genunix (check layout)" >&2; }
  '' ];

  # passthru-equivalent metadata for downstream slices (read via import + attr
  # access on the calling side, since plain `derivation` has no passthru).
}
