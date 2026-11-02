# desktop/gtk/llvm.nix -- LLVM + clang 21.1.8 from source (nixpkgs' rustc.llvmPackages at 7f81d69 is 21.1.8): the
# libclang + clang + resource headers that Firefox's bindgen needs at build time. It is a build input only; no Firefox
# out references it. The cmake recipe is phase3/clang-stdenv.nix's, proven on illumos there (X86 only, shared libLLVM,
# -lsocket -lnsl -lkstat, no terminfo/libxml2/zlib/zstd), on mk-src-pkg's from-source gcc instead of the gcc-10 seed.
{ mkSrcPkg, tools, cmake, python3, world }:
mkSrcPkg {
  pname = "llvm-clang"; version = "21.1.8";
  src = { url = "https://github.com/llvm/llvm-project/releases/download/llvmorg-21.1.8/llvm-project-21.1.8.src.tar.xz";
          sha256 = "4633a23617fa31a3ea51242586ea7fb1da7140e426bd62fc164261fe036aa142"; };
  # world: libkstat.so.1 (LLVM's host CPU probe links -lkstat), as graphics/libs.nix dbus takes it for libbsm
  deps = [ world ];
  build = ''
    export PYTHONDONTWRITEBYTECODE=1   # cmake/ninja run the store python3 (tools.nix says why)
    ${cmake}/bin/cmake -S llvm -B _b -G Ninja -DCMAKE_MAKE_PROGRAM=${tools.ninja}/bin/ninja \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$out" -DCMAKE_INSTALL_LIBDIR=lib \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_SKIP_RPATH=ON \
      -DCMAKE_C_FLAGS=-D__EXTENSIONS__ -DCMAKE_CXX_FLAGS=-D__EXTENSIONS__ \
      "-DCMAKE_EXE_LINKER_FLAGS=-lsocket -lnsl -lkstat" "-DCMAKE_SHARED_LINKER_FLAGS=-lsocket -lnsl -lkstat" \
      "-DCMAKE_MODULE_LINKER_FLAGS=-lsocket -lnsl -lkstat" \
      -DLLVM_ENABLE_PROJECTS=clang -DLLVM_TARGETS_TO_BUILD=X86 \
      -DLLVM_HOST_TRIPLE=x86_64-pc-solaris2.11 -DLLVM_DEFAULT_TARGET_TRIPLE=x86_64-pc-solaris2.11 \
      -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_DOCS=OFF \
      -DCLANG_INCLUDE_TESTS=OFF -DCLANG_INCLUDE_DOCS=OFF -DLLVM_BUILD_TOOLS=ON -DLLVM_INSTALL_UTILS=OFF \
      -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF \
      -DLLVM_ENABLE_LIBPFM=OFF -DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_ENABLE_BINDINGS=OFF -DLLVM_ENABLE_ASSERTIONS=OFF \
      -DLLVM_BUILD_LLVM_DYLIB=ON -DLLVM_LINK_LLVM_DYLIB=ON -DCLANG_LINK_CLANG_DYLIB=ON -DLLVM_PARALLEL_LINK_JOBS=2 \
      -DPython3_EXECUTABLE=${python3}/bin/python3
    ${tools.ninja}/bin/ninja -C _b -j''${NIX_BUILD_CORES:-8} install
    rm -f "$out"/lib/*.a   # static component libs: bindgen needs only libclang.so (nixpkgs keeps them in a dev output)
    # bindgen's path: libclang parses a header with clang's own resource dir (stddef.h)
    printf '#include <stddef.h>\nstruct s { size_t n; int a[4]; };\n' > "$TMPDIR/t.h"
    "$out/bin/clang" -fsyntax-only -x c "$TMPDIR/t.h" || { echo "FATAL: clang cannot parse a header" >&2; exit 1; }
    [ -e "$out/lib/libclang.so" ] || { echo "FATAL: no libclang.so" >&2; exit 1; }
  '';
}
