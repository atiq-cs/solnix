# clang-stdenv.nix — LLVM/clang 22.1.8 as a real hermetic x86_64-solaris
# derivation, plus a clang cc-wrapper and a clangStdenv usable to build packages.
#
# Applied as an overlay in the phase-3 tranche entry (tranche-entry-224.nix on
# Nix 2.24, or tranche-toolchain.nix on the 2.3.16 host). It exposes:
#   solnixClang        — the built clang+llvm (LLVM_ENABLE_PROJECTS=clang, X86
#                        target, shared libLLVM/libclang-cpp), a real hermetic
#                        derivation built WITH the pure gcc-10 illumos stdenv.
#   solnixClangWrapper — a minimal illumos clang cc-wrapper (clang/clang++/cc/c++)
#                        that bakes the illumos sysroot + gcc-10 toolchain flags
#                        proven by the C/C++ hello gate, so `clang foo.c -o foo`
#                        just works and the binary runs host-free.
#   solnixClangStdenv  — the pure illumos stdenv with its cc replaced by the
#                        clang wrapper; a real package (zlib) builds on it.
#
# WHY a hand-built wrapper (not nixpkgs wrapCCWith): the nixpkgs cc-wrapper drags
# bash-interactive -> readline -> ncurses -> gettext, a graph currently broken on
# the port; the hand wrapper is a 4-line shell shim and sidesteps it.
#
# illumos porting notes (all applied below):
#   - LLVM's default wrapped llvmPackages_N.clang assumes a null bintools chain
#     on this config and fails the wrapper assertion; we build the UNWRAPPED
#     clang+llvm ourselves via cmake/ninja and wrap it separately.
#   - LLVM_ENABLE_PROJECTS=clang only (minimal working C/C++ clang); compiler-rt/
#     libcxx/lld are NOT built (sanitizer bits + libcxx-on-illumos are follow-on
#     work). clang targets gcc-10's libstdc++ via -stdlib=libstdc++.
#   - Triple x86_64-pc-solaris2.11 (matches the seed gcc). X86 target only.
#   - H2: -L<gcc-10>/usr/gcc/10/lib/amd64 so the H1 cc-wrapper runpath pass bakes
#     -R for libstdc++/libgcc_s (C++ binaries run host-free).
#   - H6/H26b: LLVM links -lkstat (host CPU/mem probe) and its MD5 path pulls the
#     seed libnsl (DT_NEEDED libmd.so.1/libmp.so.2). Those are base platform ABI
#     libs (like libc): their .so.1 live in /lib/amd64 and resolve at runtime from
#     /lib/64, but the seed toolchain has no unversioned .so on the link path.
#     A small `syslibs` slice supplies the bare .so (for -l) + the versioned
#     soname (for transitive NEEDED) at link time.
#   - Solaris ld GNU-flag probes (--version-script, -z gnu-version-script-compat,
#     long-plt, ...) fail at configure; cmake handles those failures gracefully.
{
  # store paths of the pre-built, working build tools + seed pieces (Nix 2.3.16
  # host: the current tranche graph rebuilds cmake/ninja/python through a broken
  # gettext path, so reference the already-built working outputs directly).
  # On a clean 2.24 tree these become `final.cmakeMinimal`/`final.ninja`/
  # `final.python3` and the storePath pins drop out.
  cmakeMinimal ? builtins.storePath /nix/store/x5jrhiml1xrcrny886ghl8lz7wrx6c0s-cmake-minimal-4.3.4,
  ninja ? builtins.storePath /nix/store/zxzvpvk05xvhh98x1p3ais51dsf2nk9a-ninja-1.13.2,
  python3 ? builtins.storePath /nix/store/6wgv92y7k2xqxvwwank4s18r1scrm381-python3-3.14.6,
  # the full LLVM monorepo src (fetchFromGitHub llvmorg-22.1.8 via the fork's
  # eval-time fetch shim; realise once with `nix-build -A llvmPackages_22.<x>`).
  monorepoSrc ? builtins.storePath /nix/store/kh7qq6nn9walm1lk9mfjg42i1r11a6fv-source,
}:
final: prev:
let
  lib = final.lib;
  stdenv = final.stdenv;

  # seed gcc-10 (its usr/gcc/10 is the --gcc-toolchain: crt, libgcc, libstdc++,
  # C++ headers) and the seed libc sysroot (bootstrapLibs: libc headers/crt/.so).
  gcc = stdenv.cc.cc; # gcc-unwrapped
  bl = builtins.storePath /nix/store/fcikgn2ap30cdak1m0gcz5spcjhl430q-bootstrapLibs;

  gccPrefix = "${gcc}/usr/gcc/10";
  gccRt = "${gccPrefix}/lib/amd64";
  inc = "${bl}/usr/include";
  crt = "${bl}/usr/lib/amd64";
  libcLib = "${bl}/lib/amd64";
  triple = "x86_64-pc-solaris2.11";

  syslibs = final.runCommand "illumos-llvm-syslibs" { } ''
    mkdir -p "$out/lib/amd64"
    ln -s /lib/amd64/libkstat.so.1  "$out/lib/amd64/libkstat.so"
    ln -s /lib/amd64/libsocket.so.1 "$out/lib/amd64/libsocket.so"
    ln -s /lib/amd64/libnsl.so.1    "$out/lib/amd64/libnsl.so"
    ln -s /lib/amd64/libmd.so.1     "$out/lib/amd64/libmd.so"
    ln -s /lib/amd64/libmd.so.1     "$out/lib/amd64/libmd.so.1"
    ln -s /lib/amd64/libmp.so.2     "$out/lib/amd64/libmp.so"
    ln -s /lib/amd64/libmp.so.2     "$out/lib/amd64/libmp.so.2"
  '';

  solnixClang = stdenv.mkDerivation {
    pname = "clang";
    version = "22.1.8";
    src = monorepoSrc;
    sourceRoot = "source/llvm";
    nativeBuildInputs = [ cmakeMinimal ninja python3 ];

    NIX_CFLAGS_COMPILE = "-L${gccRt} -L${syslibs}/lib/amd64";
    dontUseCmakeConfigure = true;

    configurePhase = ''
      runHook preConfigure
      mkdir -p build && cd build
      cmake -G Ninja ../ \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=$out \
        -DCMAKE_C_COMPILER=$CC -DCMAKE_CXX_COMPILER=$CXX \
        -DCMAKE_C_FLAGS="-D__EXTENSIONS__" -DCMAKE_CXX_FLAGS="-D__EXTENSIONS__" \
        -DCMAKE_EXE_LINKER_FLAGS="-L${syslibs}/lib/amd64 -lsocket -lnsl -lkstat" \
        -DCMAKE_SHARED_LINKER_FLAGS="-L${syslibs}/lib/amd64 -lsocket -lnsl -lkstat" \
        -DCMAKE_MODULE_LINKER_FLAGS="-L${syslibs}/lib/amd64 -lsocket -lnsl -lkstat" \
        -DLLVM_ENABLE_PROJECTS=clang \
        -DLLVM_TARGETS_TO_BUILD=X86 \
        -DLLVM_HOST_TRIPLE=${triple} -DLLVM_DEFAULT_TARGET_TRIPLE=${triple} \
        -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
        -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_ZLIB=OFF \
        -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_LIBPFM=OFF -DLLVM_ENABLE_LIBEDIT=OFF \
        -DLLVM_ENABLE_BINDINGS=OFF -DLLVM_ENABLE_ASSERTIONS=OFF \
        -DLLVM_BUILD_LLVM_DYLIB=ON -DLLVM_LINK_LLVM_DYLIB=ON -DCLANG_LINK_CLANG_DYLIB=ON \
        -DLLVM_PARALLEL_LINK_JOBS=4 \
        -DPython3_EXECUTABLE=${python3}/bin/python3
      runHook postConfigure
    '';
    buildPhase = ''
      runHook preBuild
      ninja -j$NIX_BUILD_CORES
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      ninja install
      runHook postInstall
    '';
    enableParallelBuilding = true;
  };

  # Minimal illumos clang cc-wrapper. Bakes the sysroot + gcc-10 toolchain flags
  # proven by the C/C++ hello gate. -idirafter (not -isystem) puts the libc
  # headers AFTER the C++ headers so <cstdlib>'s #include_next <stdlib.h> works.
  solnixClangWrapper = final.runCommand "clang-wrapper-illumos-22.1.8"
    {
      passthru = {
        isClang = true;
        cc = solnixClang;
        inherit (stdenv.cc) bintools libc;
        targetPrefix = "";
      };
    }
    ''
      mkdir -p $out/bin $out/nix-support
      COMMON="-target ${triple} --gcc-toolchain=${gccPrefix} -idirafter ${inc} -B ${crt} -L ${libcLib} -L ${crt} -L ${gccRt} -Wl,-R,${libcLib} -Wl,-R,${gccRt}"
      for c in clang cc; do
        printf '#!%s\nexec %s/bin/clang %s "$@"\n' "${stdenv.shell}" "${solnixClang}" "$COMMON" > $out/bin/$c
      done
      for c in clang++ c++; do
        printf '#!%s\nexec %s/bin/clang++ %s -stdlib=libstdc++ "$@"\n' "${stdenv.shell}" "${solnixClang}" "$COMMON" > $out/bin/$c
      done
      chmod +x $out/bin/*
      echo "${solnixClang}" > $out/nix-support/orig-cc
    '';

  # clangStdenv: the pure illumos stdenv with CC/CXX = the clang wrapper. A real
  # package (zlib) builds on it by forcing CC/CXX to the wrapper in its phases.
  solnixClangStdenv = stdenv.override (_: {
    cc = solnixClangWrapper // {
      isClang = true;
      inherit (stdenv.cc) bintools libc;
    };
  });
in
{
  inherit solnixClang solnixClangWrapper solnixClangStdenv;
}
