# llvm/parts.nix -- the four LLVM 23.1.4 parts (./default.nix has the shared settings and says why).
{ mkSrcPkg, version, src, nativeTools, deps, pre, common, runpath, ninjaInstall, noBuildDir, world, gate, gcc, ld, libc, hostTools }:
rec {
  # llvm: libLLVM.so, the tools, headers, static component libs and lib/cmake/llvm (what clang/lld/lldb build against).
  llvm = mkSrcPkg {
    pname = "llvm"; inherit version src nativeTools deps;
    build = ''
      ${pre}
      patch -p1 < ${./patches/llvm-config-no-build-dir.patch}   # the patch says why
      cmake -S llvm -B _b ${common} -DLLVM_BUILD_LLVM_DYLIB=ON -DLLVM_LINK_LLVM_DYLIB=ON -DLLVM_INSTALL_UTILS=ON \
        -DLLVM_ENABLE_BINDINGS=OFF -DLLVM_BUILD_TOOLS=ON
      ${ninjaInstall}
      # build-tree paths cmake records for in-tree use only: lit (not installed) and llvm-config's obj/src roots
      sed -i '/LLVM_DEFAULT_EXTERNAL_LIT/d' "$out/lib/cmake/llvm/LLVMConfig.cmake"
      ${noBuildDir}
      "$out/bin/llvm-config" --version | grep -qx ${version} || { echo "FATAL: llvm-config --version" >&2; exit 1; }
      printf 'define i32 @main() {\n  ret i32 0\n}\n' > "$TMPDIR/t.ll"
      "$out/bin/llc" -filetype=obj "$TMPDIR/t.ll" -o "$TMPDIR/t.o"
      [ "$(od -An -tx1 -N4 "$TMPDIR/t.o" | tr -d ' \n')" = 7f454c46 ] || { echo "FATAL: llc made no ELF object" >&2; exit 1; }
    '';
  };

  # clang (unwrapped, as nixpkgs' libclang/clang-unwrapped): a standalone build on llvm. The illumos driver patch makes
  # -fuse-ld=lld work (the Solaris driver knew only Solaris ld and GNU ld). libclang.so and libclang-cpp.so ship too.
  clang = mkSrcPkg {
    pname = "clang"; inherit version src nativeTools;
    deps = deps ++ [ llvm ];
    build = ''
      ${pre}
      patch -p1 < ${./patches/clang-lld-23-illumos.patch}
      cmake -S clang -B _b ${runpath [ llvm ]} -DLLVM_DIR=${llvm}/lib/cmake/llvm -DLLVM_TABLEGEN_EXE=${llvm}/bin/llvm-tblgen \
        -DCLANG_LINK_CLANG_DYLIB=ON -DCLANG_INCLUDE_TESTS=OFF -DCLANG_INCLUDE_DOCS=OFF -DCLANG_ENABLE_ARCMT=OFF \
        -DCLANG_DEFAULT_RTLIB=libgcc -DCLANG_DEFAULT_CXX_STDLIB=libstdc++
      ${ninjaInstall}
      ${noBuildDir}
      "$out/bin/clang" --version | grep -q "clang version ${version}" || { echo "FATAL: clang --version" >&2; exit 1; }
      printf '#include <stddef.h>\nstruct s { size_t n; int a[4]; };\n' > "$TMPDIR/t.h"
      "$out/bin/clang" --sysroot=${gate} -fsyntax-only -x c "$TMPDIR/t.h" || { echo "FATAL: clang cannot parse a header" >&2; exit 1; }
    '';
  };

  # lld: ld.lld (and the other flavours) on llvm. The same patch teaches it GNU ld's elf_x86_64_sol2 emulation name.
  lld = mkSrcPkg {
    pname = "lld"; inherit version src nativeTools;
    deps = deps ++ [ llvm ];
    build = ''
      ${pre}
      patch -p1 < ${./patches/clang-lld-23-illumos.patch}
      cmake -S lld -B _b ${runpath [ llvm ]} -DLLVM_DIR=${llvm}/lib/cmake/llvm -DLLVM_TABLEGEN_EXE=${llvm}/bin/llvm-tblgen \
        -DLLD_BUILD_TOOLS=ON
      ${ninjaInstall}
      ${noBuildDir}
      "$out/bin/ld.lld" --version | grep -q "LLD ${version}" || { echo "FATAL: ld.lld --version" >&2; exit 1; }
    '';
  };

  # lldb: the illumos port (patch: host layer, host platform, core files with registers, threads and signals; no live
  # process plugin yet, docs/llvm-illumos.md). No Python/Lua/libedit/curses: no swig in solnix, and the batch and
  # command modes do not need them.
  lldb = mkSrcPkg {
    pname = "lldb"; inherit version src nativeTools;
    deps = deps ++ [ llvm clang ];
    build = ''
      ${pre}
      patch -p1 < ${./patches/lldb-23-illumos.patch}
      # standalone: clang's resource dir is found through Clang_DIR (LLDBStandalone.cmake) and symlinked beside liblldb
      cmake -S lldb -B _b ${runpath [ llvm clang ]} -DLLVM_DIR=${llvm}/lib/cmake/llvm -DClang_DIR=${clang}/lib/cmake/clang \
        -DLLVM_TABLEGEN_EXE=${llvm}/bin/llvm-tblgen -DLLDB_INCLUDE_TESTS=OFF -DLLDB_ENABLE_PYTHON=OFF -DLLDB_ENABLE_LUA=OFF \
        -DLLDB_ENABLE_LIBEDIT=OFF -DLLDB_ENABLE_CURSES=OFF -DLLDB_ENABLE_LZMA=OFF -DLLDB_ENABLE_LIBXML2=OFF \
        -DLLDB_CODESIGN_IDENTITY=
      ${ninjaInstall}
      ${noBuildDir}
      "$out/bin/lldb" --version | grep -qx "lldb version ${version}" || { echo "FATAL: lldb --version" >&2; exit 1; }
      "$out/bin/lldb" -b -o "platform status" 2>&1 | grep -q "Triple: x86_64-pc-solaris2.11" || { echo "FATAL: no host platform" >&2; exit 1; }
    '';
  };

  # clang-wrapper: what nixpkgs' cc-wrapper gives llvmPackages.clang, reduced to what illumos needs (base-src.nix
  # gccWrapper is the gcc twin): the gate proto as sysroot (headers, crt objects, libc), the from-source gcc for
  # libstdc++/libgcc/crtbegin (--gcc-toolchain), the store Solaris ld (-fuse-ld=lld picks ld.lld from lld), and a
  # RUNPATH to gcc.lib so C++ programs find libstdc++ (nothing on the default search path has it).
  clang-wrapper = derivation {
    name = "clang-wrapper-${version}"; system = "x86_64-solaris";
    inherit clang lld gate gcc; gccLib = gcc.lib; ldBin = "${ld}/usr/bin/ld"; llvmBin = "${llvm}/bin";
    builder = "/usr/bin/bash";
    # store-only (wave6 glue drvs): store coreutils/findutils + the world's bins (mkdir chmod ln mktemp printf), gated.
    PATH = builtins.concatStringsSep ":" (map (t: "${t}/bin") hostTools);
    pathGate = ../path-gate.sh;
    args = [ "-c" ''
      set -eu; /usr/bin/bash "$pathGate"
      mkdir -p $out/bin
      for t in clang clang++ clang-cpp; do
        printf '#!/usr/bin/bash\nexec %s/bin/%s --sysroot=%s --gcc-toolchain=%s -fuse-ld=%s -B%s/bin -Wl,-R,%s/lib/amd64:%s/lib "$@"\n' \
          "$clang" "$t" "$gate" "$gcc" "$ldBin" "$lld" "$gccLib" "$gccLib" > "$out/bin/$t"
        chmod +x "$out/bin/$t"
      done
      ln -s clang $out/bin/cc; ln -s clang++ $out/bin/c++
      for t in ld.lld llvm-ar llvm-nm llvm-objdump llvm-readelf llvm-strip llvm-objcopy; do
        [ -e "$lld/bin/$t" ] && ln -s "$lld/bin/$t" $out/bin/$t || ln -s "$llvmBin/$t" $out/bin/$t
      done
      # self-check: C and C++ compile, link and run, with ld and with ld.lld
      cd "$(mktemp -d "''${TMPDIR:-/var/tmp}/clangwrap.XXXXXX")"
      printf '#include <stdio.h>\nint main(void){puts("hello c");return 0;}\n' > h.c
      printf '#include <iostream>\nint main(){std::cout<<"hello c++"<<std::endl;}\n' > h.cc
      $out/bin/clang -o hc h.c; [ "$(./hc)" = "hello c" ]
      $out/bin/clang++ -o hcc h.cc; [ "$(./hcc)" = "hello c++" ]
      $out/bin/clang -fuse-ld=lld -o hcl h.c; [ "$(./hcl)" = "hello c" ]
      $out/bin/clang++ -fuse-ld=lld -o hccl h.cc; [ "$(./hccl)" = "hello c++" ]
      echo "=== clang-wrapper: C and C++ hello run, Solaris ld and ld.lld ===" >&2
    '' ];
  };
}
