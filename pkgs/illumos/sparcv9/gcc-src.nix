# gcc-src.nix (sparcv9) -- GCC 14.3.0 built FROM SOURCE on sparcv9 illumos (zone lixu), the sparcv9 twin of ../gcc-src.nix
# (x86) and ../aarch64/gcc-src.nix. Upstream GCC still has sparc*-*-solaris2.11, so the source is the x86 recipe's tarball
# (the same FOD). stage0 = OI's IPS developer/gcc-13 (/usr/gcc/13), the only gcc in OI's sparc catalog: it compiles cc1/cc1plus,
# then the new xgcc builds libgcc/libstdc++. That stage0 is the `sv9gccseed` marker (../bootstrap-exempt.tsv), as x86's
# /usr/gcc/14 is `gccseed`.
# Configure follows OI's gcc-13 (`/usr/gcc/13/bin/gcc -v` in the zone): illumos ld, GNU as, --with-cpu=ultrasparc,
# __cxa_atexit, initfini-array. LP64 only (--disable-multilib, as aarch64); install.texi's sparcv9-*-solaris2* says --build
# must be given (config.guess misdetects a 64-bit-default gcc). ./gcc-src-build.sh says what differs from x86 and why.
# Outputs as x86: out = the compiler (build-time only), lib = libstdc++/libgcc_s/libatomic in lib/sparcv9.
{ gate, libc, ld, stage0 ? "/usr/gcc/13", system ? "sparcv9-solaris" }:

let
  version = "14.3.0";
  fetch = url: sha256: import <nix/fetchurl.nix> { inherit url sha256; };
  drvAttrs = {
  name = "gcc-${version}";
  inherit system gate stage0 version;
  gccSrc = fetch "https://mirrors.kernel.org/gnu/gcc/gcc-${version}/gcc-${version}.tar.xz"
    "e0dc77297625631ac8e50fa92fffefe899a4eb702592da5c32ef04e2293aca3a";
  gmpSrc = fetch "https://mirrors.kernel.org/gnu/gmp/gmp-6.3.0.tar.xz"
    "a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898";
  mpfrSrc = fetch "https://mirrors.kernel.org/gnu/mpfr/mpfr-4.2.1.tar.xz"
    "277807353a6726978996945af13e52829e3abd7a9a5b7fb2793894e18f1fcbb2";
  mpcSrc = fetch "https://mirrors.kernel.org/gnu/mpc/mpc-1.3.1.tar.gz"
    "ab642492f5cf882b74aa0cb730cd410a81edcdbec895183ce930e706c1c759b8";
  tsErrnoPatch = ../patches/gcc-14/0032-libstdc-must-use-thread-local-errno.patch;   # OI/OmniOS 0032, as x86
  libcDir = "${libc}/lib/sparcv9";
  ldBin = "${ld}/usr/bin/ld";
  SOURCE_DATE_EPOCH = "315532800";
  zeroChecksum = ../exempt/zero-checksum.sh;   # elfedit works on GNU-stripped sparcv9 ELF (measured sv9gcc z12)
  outputs = [ "out" "lib" ];
  builder = "/usr/bin/bash";
  PATH = "/usr/gnu/bin:/usr/bin:/usr/sbin";
  args = [ ./gcc-src-build.sh ];
  };
# buildKey: 1:1 with the drv, the same on every host and under --check (../mk-src-pkg.nix explains why).
in derivation (drvAttrs // { buildKey = builtins.substring 0 16 (builtins.hashString "sha256" (builtins.toJSON drvAttrs)); })
