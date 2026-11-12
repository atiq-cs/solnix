# llvm/ -- LLVM from source, split as nixpkgs' llvmPackages is: llvm (libLLVM + tools + the cmake package), clang, lld and
# lldb, each a standalone cmake build against the llvm output (nixpkgs common/{llvm,clang,lld,lldb}/default.nix), one set
# per release from mkLlvmPackages (nixpkgs' llvmPackages_NN): 23.1.4 (the latest release, 2026-10-20) and 21.1.8 (nixpkgs'
# default llvmPackages). Single-output mk-src-pkg recipes, so llvm keeps its headers, static
# component libraries and cmake files in $out (nixpkgs' "dev" output). C++ runtime: gcc's libstdc++ and libgcc, as OI,
# OmniOS and nixpkgs on Linux; no libcxx/compiler-rt yet (illumos is not a compiler-rt target for x86_64 sanitizers).
# Store tools only on PATH (mk-src-pkg nativeTools): cmake, ninja, python3, GNU patch, coreutils/findutils, the world.
# desktop/gtk/llvm.nix (21.1.8, Firefox's bindgen) is a separate recipe and is not touched by this one.
{ mkSrcPkg, hostTools, cmake, ninja, python3, gnupatch, world, gate, gcc, ld, libc }:
let
  nativeTools = [ cmake ninja python3 gnupatch ] ++ hostTools;
  # world: libkstat.so.1 (LLVM's host CPU probe links -lkstat), as desktop/gtk/llvm.nix does.
  deps = [ world ];
  # Reproducibility: illumos ld sorts output relocations on Sym_desc POINTER values (libld relocate.c reloc_compare), and
  # those heap addresses depend on libumem (ld links it; docs/llvm-illumos.md has the measurements): (1) its per-CPU cache
  # count, 2 x online CPUs, so pin concurrency; (2) its first reap, at the first heap growth after init + 1 s, so the
  # order depended on link speed (same host, same drv: 2 orders). sbrk_minalloc=1g makes the first heap growth big enough
  # for the whole link (peak heap ~380 MB), so the heap never grows again and nothing is reaped mid-link.
  # shortcut: each ld reserves 1 GB of swap; raise it if a link's heap passes 1 GB (pmap shows it), or fix ld's sort key.
  pre = ''
    export PYTHONDONTWRITEBYTECODE=1 UMEM_OPTIONS=concurrency=32,sbrk_minalloc=1g
  '';
  # The cmake flags every part shares (desktop/gtk/llvm.nix's set, proven on illumos: shared libLLVM, -lsocket -lnsl -lkstat).
  # rp: extra RUNPATH dirs for a standalone part. mk-src-pkg's RUNPATH takes a dep's lib/amd64 or lib-64, and LLVM installs to
  # lib/, so without this ld.lld cannot find libLLVM.so (measured, llvm2). "" keeps llvm's own drv text.
  commonFor = rp: ''
    -G Ninja -DCMAKE_MAKE_PROGRAM=${ninja}/bin/ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$out" \
    -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_SKIP_RPATH=ON \
    -DCMAKE_C_FLAGS="-D__EXTENSIONS__ -ffile-prefix-map=$W=/build" -DCMAKE_CXX_FLAGS="-D__EXTENSIONS__ -ffile-prefix-map=$W=/build" \
    "-DCMAKE_EXE_LINKER_FLAGS=-lsocket -lnsl -lkstat${rp}" "-DCMAKE_SHARED_LINKER_FLAGS=-lsocket -lnsl -lkstat${rp}" \
    "-DCMAKE_MODULE_LINKER_FLAGS=-lsocket -lnsl -lkstat${rp}" -DPython3_EXECUTABLE=${python3}/bin/python3 \
    -DLLVM_TARGETS_TO_BUILD=X86 -DLLVM_HOST_TRIPLE=x86_64-pc-solaris2.11 -DLLVM_DEFAULT_TARGET_TRIPLE=x86_64-pc-solaris2.11 \
    -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_ENABLE_LIBPFM=OFF -DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_ENABLE_ASSERTIONS=OFF -DLLVM_PARALLEL_LINK_JOBS=2'';
  common = commonFor "";
  runpath = ds: commonFor (builtins.concatStringsSep "" (map (d: " -Wl,-R,${d}/lib") ds));
  ninjaInstall = ''${ninja}/bin/ninja -C _b -j''${NIX_BUILD_CORES:-8} install'';
  # No build-dir path may ship (infra trials 2026-11-02; NixOS builds in /build). Text files that name $W fail the build.
  noBuildDir = ''
    if grep -rl "$W" "$out" > "$W/bd"; then echo "FATAL: build dir $W named in:" >&2; head "$W/bd" >&2; exit 1; fi
  '';
  # mkLlvmPackages: one release's parts (./parts.nix). clangLldPatch: the illumos clang driver + lld patch for that release;
  # clangFix: shell run on the clang tree after it; lldbPatch: the lldb port, or null (no lldb in the set).
  mkLlvmPackages = { version, sha256, clangLldPatch, clangFix ? "", lldbPatch ? null }: import ./parts.nix {
    inherit mkSrcPkg version nativeTools deps pre common runpath ninjaInstall noBuildDir world gate gcc ld libc hostTools
      clangLldPatch clangFix lldbPatch;
    src = { url = "https://github.com/llvm/llvm-project/releases/download/llvmorg-${version}/llvm-project-${version}.src.tar.xz";
            inherit sha256; };
  };
in {
  inherit mkLlvmPackages;
  llvmPackages_23 = mkLlvmPackages {
    version = "23.1.4"; sha256 = "819ecf7351f1a66f76b2d701d8942faaf5faeb324cb90c9d5b090de142434bb2";
    clangLldPatch = ./patches/clang-lld-23-illumos.patch; lldbPatch = ./patches/lldb-23-illumos.patch;
    clangFix = ''
      # -fuse-ld=bfd|gld (and CLANG_DEFAULT_LINKER=bfd|gld): upstream names the OI path /usr/gnu/bin/ld, a build-host path in
      # libclang-cpp.so (gate B13). GNU ld is the store binutils' gld, found as clang finds every tool (-B dirs, its own dir,
      # PATH), as the lld case above does: the -fuse-ld case looks it up, and the default-linker case (Solaris::getDefaultLinker,
      # which getLinkerPath returns as is) names "gld", which getLinkerPath then looks up the same way.
      f=clang/lib/Driver/ToolChains/Solaris.cpp
      [ "$(grep -c 'return "/usr/gnu/bin/ld";' $f)" = 1 ] && [ "$(grep -c '.Cases({"bfd", "gld"}, "/usr/gnu/bin/ld")' $f)" = 1 ] \
        && [ "$(grep -c '^  return ToolChain.getDefaultLinker();$' $f)" = 1 ] || { echo "FATAL: clang gld anchors" >&2; exit 1; }
      sed -i -e 's|return "/usr/gnu/bin/ld";|return ToolChain.GetProgramPath("gld");|' \
        -e 's|.Cases({"bfd", "gld"}, "/usr/gnu/bin/ld")|.Cases({"bfd", "gld"}, "gld")|' \
        -e 's|^  return ToolChain.getDefaultLinker();$|  const char *DL = ToolChain.getDefaultLinker();\n  return llvm::sys::path::is_absolute(DL) ? std::string(DL) : ToolChain.GetProgramPath(DL);|' $f
      ! grep -n /usr/gnu/ $f || { echo "FATAL: clang still names /usr/gnu/" >&2; exit 1; }'';
  };
  # 21.1.8: patches/21 has the 23 driver + lld patch ported (isLinkerGnuLd reads CLANG_DEFAULT_LINKER there) with the gld fix
  # folded in (21's .Cases form). No lldb: the 23 port does not apply (18 of its 57 files reject on 21.1.8).
  llvmPackages_21 = mkLlvmPackages {
    version = "21.1.8"; sha256 = "4633a23617fa31a3ea51242586ea7fb1da7140e426bd62fc164261fe036aa142";
    clangLldPatch = ./patches/21/clang-lld-21-illumos.patch;
  };
}
