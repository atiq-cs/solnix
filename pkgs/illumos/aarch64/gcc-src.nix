# gcc-src.nix (aarch64) -- GCC 14.3.0 built FROM SOURCE on aarch64 illumos, the aarch64 twin of
# ../gcc-src.nix. Source: richlowe/gcc il-14_3_0-arm64 (upstream GCC has no aarch64-solaris
# target); that fork already carries OmniOS's 0032 -D_TS_ERRNO libstdc++ patch (checked: the
# repo's copy reports "previously applied"). stage0 = braich developer/gcc14 (the IPS seed, as
# x86 uses /usr/gcc/14); it compiles cc1/cc1plus, then the new xgcc builds libgcc/libstdc++.
# Configure follows the arm64-gate harness (Makefile COMMON_GCC_OPTS + gcc target flags):
# LP64 only, illumos ld (not GNU ld), GNU as, -mno-outline-atomics -mtls-dialect=trad for the
# target libs (illumos aarch64 ld has no TLSDESC relocations: measured on nix's libnixutil).
# Outputs as x86: out = the compiler (build-time only), lib = libstdc++/libgcc_s/libatomic.
{ gate, libcSlice, stage0 ? "/opt/gcc-14", system ? "aarch64-solaris" }:

let
  version = "14.3.0";
  rev = "1e3768925a27b275e083db134dcacd6639501c7b";
  fetch = url: sha256: import <nix/fetchurl.nix> { inherit url sha256; };
  gccSrc = fetch "https://github.com/richlowe/gcc/archive/${rev}.tar.gz"
    "3215ce72913cf5b1d2240dabfe154c598daf0f20611ff53ee1f8216b8854812b";
  gmpSrc = fetch "https://mirrors.kernel.org/gnu/gmp/gmp-6.3.0.tar.xz"
    "a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898";
  mpfrSrc = fetch "https://mirrors.kernel.org/gnu/mpfr/mpfr-4.2.1.tar.xz"
    "277807353a6726978996945af13e52829e3abd7a9a5b7fb2793894e18f1fcbb2";
  mpcSrc = fetch "https://mirrors.kernel.org/gnu/mpc/mpc-1.3.1.tar.gz"
    "ab642492f5cf882b74aa0cb730cd410a81edcdbec895183ce930e706c1c759b8";
  tflags = "-g -O2 -mno-outline-atomics -mtls-dialect=trad";
in
derivation {
  name = "gcc-${version}";
  inherit system gate stage0 gccSrc gmpSrc mpfrSrc mpcSrc version rev tflags;
  libcDir = "${libcSlice}/lib";
  outputs = [ "out" "lib" ];
  builder = "/usr/bin/bash";
  PATH = "/usr/gnu/bin:/usr/bin:/usr/sbin";
  args = [ ./gcc-src-build.sh ];
}
