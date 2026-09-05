# openblas.nix — OpenBLAS 0.3.33 (BLAS + LAPACK) for x86_64-solaris, built via
# OpenBLAS's NATIVE make with the from-source gfortran (gcc14.nix langFortran).
#
# Why native make, not the nixpkgs cmake path: nixpkgs' openblas/default.nix
# keys a `configs.${system}` table with no x86_64-solaris entry (throws
# "unsupported system") and drives a cmake build (CMAKE_Fortran_COMPILER). The
# canonical OpenBLAS build is its own Makefile (make CC=.. FC=.. TARGET=..),
# which is more portable for a fresh port and needs only a working gfortran +
# gcc. We fix a TARGET (no DYNAMIC_ARCH runtime cpu-probe asm, the fragile part
# on a new OS) and BINARY=64.
#
# Illumos build deltas over a stock `make`:
#   * RANLIB=true       — illumos `ar ru` writes the archive index itself; the
#                         cc-wrapper ships no ranlib -> `ranlib: not found`.
#   * build goal `libs netlib shared` (not `all`) — skips OpenBLAS's smoketest
#                         suite, whose test link trips Solaris ld on gfortran's
#                         `-Y P,<paths>` runpath flag (`ld: option -Y has
#                         illegal argument`). The libraries themselves link.
#   * nawk shim         — Makefile.install hardcodes `nawk`; point it at gawk.
#   * FC carries the cc-wrapper's cc-cflags so gfortran links resolve the seed
#     libc/crt exactly like the gcc14 C/C++/Fortran proofs.
{
  stdenv,          # gcc14fStdenv (gcc14.nix langFortran = true, wrapped)
  lib,
  fetchFromGitHub,
  gcc14f,          # the from-source gfortran gcc (gcc14.nix langFortran = true)
  cc14f,           # the wrapped cc for gcc14f (provides bin/cc + cc-cflags)
  gnumake,
  perl,
  which,
  gawk,
  coreutils,
  target ? "NEHALEM",  # generic SSE4.2 x86_64; no AVX512 asm surprises
}:
let
  ccflags = "$(cat ${cc14f}/nix-support/cc-cflags | tr '\\n' ' ')";
in
stdenv.mkDerivation (finalAttrs: {
  pname = "openblas";
  version = "0.3.33";

  src = fetchFromGitHub {
    owner = "OpenMathLib";
    repo = "OpenBLAS";
    rev = "v${finalAttrs.version}";
    hash = "sha256-EArf0K2Gs+w8IRD5wkMOQv79e8yMoTgQfa9kzjXKn3Y=";
  };

  nativeBuildInputs = [ gnumake perl which gawk ];
  hardeningDisable = [ "all" ];
  dontUseCmakeConfigure = true;
  enableParallelBuilding = true;

  buildPhase = ''
    runHook preBuild
    export CC="${cc14f}/bin/cc"
    export FC="${gcc14f}/bin/gfortran ${ccflags}"
    export HOSTCC="${cc14f}/bin/cc"
    make -j$NIX_BUILD_CORES \
      TARGET=${target} BINARY=64 \
      NO_SHARED=0 USE_OPENMP=0 NUM_THREADS=64 NO_LAPACK=0 \
      CC="$CC" FC="$FC" HOSTCC="$HOSTCC" \
      RANLIB=${coreutils}/bin/true \
      MAKE_NB_JOBS=$NIX_BUILD_CORES \
      libs netlib shared
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $TMPDIR/awkbin
    ln -sf ${gawk}/bin/awk $TMPDIR/awkbin/nawk
    export PATH=$TMPDIR/awkbin:$PATH
    make PREFIX=$out install \
      TARGET=${target} BINARY=64 NO_SHARED=0 NO_LAPACK=0 \
      RANLIB=${coreutils}/bin/true \
      CC="${cc14f}/bin/cc" FC="${gcc14f}/bin/gfortran ${ccflags}"
    runHook postInstall
  '';

  meta = {
    description = "OpenBLAS (BLAS + LAPACK) for x86_64-solaris, gfortran-built";
    platforms = [ "x86_64-solaris" ];
  };
})
