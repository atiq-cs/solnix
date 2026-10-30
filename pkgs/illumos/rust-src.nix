# rust-src.nix -- rustc + cargo + std for x86_64-unknown-illumos, built FROM SOURCE
# by x.py: one hop of the N-1 chain (1.97.1 seed -> 1.98.0 -> 1.99.0) in
# docs/rust-illumos-bootstrap.md, as a real derivation instead of a staged
# `nix-store --add` tree (which has no deriver and could not be published).
#
# Like nixpkgs' rustc: the previous hop is the stage0 input, the release tarball
# is offline-vendored, LLVM is the bundled one. Like gcc-src.nix: host build
# tools (python3, cmake, gmake, /usr/bin/ar) under sandbox=false, never shipped.
# The compiler is the from-source gcc; every ELF is linked with a store -R
# (libc, world, gcc.lib, openssl, zlib), so nothing resolves from /usr/gcc or
# /usr/openssl, and those five are the runtime references. rustc carries no
# default linker: it runs `cc` from PATH, as nixpkgs' rustc does with stdenv.cc.
{ version, sha256
, stage0                 # previous hop's output (bin/rustc, bin/cargo, lib/rustlib)
, seedStage0 ? false     # stage0 is the OI 1.97.1 seed tree (prune + re-RUNPATH it)
, gcc, gate, libc, world, openssl, zlib
}:
(a: derivation (a // { buildKey = builtins.substring 0 16 (builtins.hashString "sha256" (builtins.toJSON a)); zeroChecksum = ./zero-checksum.sh; })) {
  name = "rust-${version}";
  system = "x86_64-solaris";
  builder = "/usr/bin/bash";
  args = [ ./rust-src-build.sh ];
  inherit version stage0 gcc gate libc world openssl zlib;
  gccLib = gcc.lib;
  src = import <nix/fetchurl.nix> {
    url = "https://static.rust-lang.org/dist/rustc-${version}-src.tar.xz";
    inherit sha256;
  };
  srcSha256 = sha256;
  seedStage0 = if seedStage0 then "1" else "";
  tsErrnoGate = ./ts-errno-gate.sh;
}
