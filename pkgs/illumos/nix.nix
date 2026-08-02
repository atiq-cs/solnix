# pkgs/illumos/nix.nix — pkgs.solnix.nix: the classic Nix 2.3.16 the illumos
# build host runs (scripts/oi-nix-setup.sh, PREFIX=/nix-tools), ingested into the
# store so it ships on the booted image (design \u00a7C). Stage-A install verb is
# `nix-env -iA` (nix 2.3; `nix profile` is 2.4+).
#
# FIRST CUT (the task's allowed fallback): ingest the host's /nix-tools tree as a
# builtins.path store artifact rather than a proper mk-illumos-component RUNPATH
# slice. /nix-tools was built ON the host against its IPS boost/openssl/sqlite/
# curl/... at /usr/lib, so its binaries carry host-absolute RUNPATHs and NEED the
# make-be-staged external libs already present on the image. This proves nix ships
# + resolves on the image without the (involved) per-lib slice + relocation.
#
# TODO(P2): replace this ingest with a real mk-illumos-component slice \u2014 carve
# bin/{nix,nix-env,nix-store,nix-build,nix-instantiate,nix-channel} + the lib
# closure (boost, sqlite, libsodium, openssl, curl, brotli, editline) out of
# /nix-tools and RUNPATH-relocate them into the store (like libc/base-tools), so
# nix has NO host /usr/lib dependency and the closure is self-contained. See
# docs/design-declarative-userland.md \u00a7C + risk #2 (CA-cert / runtime-lib paths).

{ nixToolsDir ? /nix-tools }:

let
  # builtins.path imports the host nix install into the store, content-addressed.
  # No FOD outputHash needed \u2014 the store path IS the pinned artifact (same ingest
  # model as gate.nix). Recomputed only if /nix-tools changes.
  nixTools = builtins.path {
    path = nixToolsDir;
    name = "nix-2.3.16-host-src";
  };
in
derivation {
  name = "nix-2.3.16";
  system = builtins.currentSystem; # x86_64-solaris; ingest runs on illumos.
  builder = "/usr/bin/bash";
  # cp -a preserves the bin/ + lib/ layout and the versioned .so symlinks.
  PATH = "/usr/gnu/bin:/usr/bin:/usr/sbin";
  args = [
    "-c"
    ''
      set -eu
      mkdir -p "$out"
      cp -a "${nixTools}/." "$out/"
      # sanity: the load-bearing verbs must be present (nix-env -iA is Stage-A).
      for b in nix nix-env nix-store nix-build nix-instantiate; do
        [ -e "$out/bin/$b" ] || { echo "FATAL: /nix-tools missing bin/$b" >&2; exit 1; }
      done
    ''
  ];
}
