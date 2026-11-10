# llvm/ -- LLVM 23.1.4 (the latest release, 2026-10-20) from source, split as nixpkgs' llvmPackages is: llvm (libLLVM +
# tools + the cmake package), clang, lld and lldb, each a standalone cmake build against the llvm output (nixpkgs
# common/{llvm,clang,lld,lldb}/default.nix). Single-output mk-src-pkg recipes, so llvm keeps its headers, static
# component libraries and cmake files in $out (nixpkgs' "dev" output). C++ runtime: gcc's libstdc++ and libgcc, as OI,
# OmniOS and nixpkgs on Linux; no libcxx/compiler-rt yet (illumos is not a compiler-rt target for x86_64 sanitizers).
# Store tools only on PATH (mk-src-pkg nativeTools): cmake, ninja, python3, GNU patch, coreutils/findutils, the world.
# desktop/gtk/llvm.nix (21.1.8, Firefox's bindgen) is a separate, older recipe and is not touched by this one.
{ mkSrcPkg, hostTools, cmake, ninja, python3, gnupatch, world, gate, gcc, ld, libc }:
let
  version = "23.1.4";
  src = { url = "https://github.com/llvm/llvm-project/releases/download/llvmorg-${version}/llvm-project-${version}.src.tar.xz";
          sha256 = "819ecf7351f1a66f76b2d701d8942faaf5faeb324cb90c9d5b090de142434bb2"; };
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
  parts = import ./parts.nix { inherit mkSrcPkg version src nativeTools deps pre common runpath ninjaInstall noBuildDir
    world gate gcc ld libc hostTools; };
in parts
