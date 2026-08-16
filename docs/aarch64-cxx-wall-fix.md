# aarch64-solaris CROSS C++ unwind/mapfile wall — root cause + fix (CRACKED)

## Status: CRACKED

The C++ wall is fixed with a bounded cc-wrapper specs override (no seed-gcc
rebuild). Trivial C++ .so + throw/catch exe link cleanly to real aarch64 ELF
with the unwinder/personality symbols, and 6 real C++ packages build:
gmpxx, fmt, nlohmann_json, pugixml, tinyxml-2, yaml-cpp.

## EXACT root cause

The prior-wave assumption was "Solaris ld can't parse a GNU version-script".
The truth is the INVERSE.

The aarch64 seed cross toolchain contains TWO linkers:

  1. GNU binutils ld 2.43.1 at
     usr/gcc/aarch64-14/aarch64-unknown-solaris2.11/bin/ld
     — the ONLY aarch64-capable linker (emits/links EM_AARCH64).
  2. The Solaris link-editor at opt/onbld/bin/amd64/ld
     — an x86-HOST binary that only knows EM_386/EM_AMD64. It rejects
     aarch64 objects outright:  `ld: fatal: unsupported ELF machine type:
     EM_AARCH64`.  So the "cross Solaris ld" is NOT usable for aarch64.

The cross gcc was configured `--with-gnu-ld=no` (it expects the Solaris
link-editor). Its BUILT-IN `*link:` spec (from config/aarch64/sol2.h) therefore
emits Solaris link-editor syntax for any shared / shared-libgcc link:

    *link:
    ... %{shared|shared-libgcc|G:-M %slibgcc-unwind.map}
        %{mclear-hwcap|fopenmp*:-M %sclearcap.map} ...

`%slibgcc-unwind.map` resolves to the seed's
`.../aarch64-unknown-solaris2.11/lib/libgcc-unwind.map`, which is a Solaris
symbol-scope mapfile:

    $mapfile_version 2
    SYMBOL_SCOPE {
        _Unwind_Backtrace { FLAGS = EXTERN DIRECT };
        ...
    };

But collect2 actually execs the GNU ld (#1, the only aarch64 one). GNU ld
reads `-M FILE` as "print a link map to FILE" then, seeing the file, treats
its contents as a GNU linker script. The Solaris mapfile is not GNU linker-
script syntax, so GNU ld fails:

    ld: .../libgcc-unwind.map: file format not recognized; treating as linker script
    ld: .../libgcc-unwind.map:1: syntax error
    collect2: error: ld returned 1 exit status

Every C++ shared lib / exe (and cmake's C++ compiler probe) fires the
`%{shared|shared-libgcc|G:...}` clause, so every C++ link died. C-only static
links (`--disable-shared`) never fire it — which is exactly why all prior
waves dodged the wall by forcing static.

Which ld / which mapfile / what syntax rejected:
  - ld:      GNU binutils ld 2.43.1 (the aarch64-capable one). The Solaris
             onbld ld can't do aarch64 at all.
  - mapfile: .../aarch64-unknown-solaris2.11/lib/libgcc-unwind.map
             (also clearcap.map for -mclear-hwcap/-fopenmp links).
  - syntax:  Solaris `$mapfile_version 2` / SYMBOL_SCOPE mapfile fed to GNU
             ld via `-M`; GNU ld can't parse it (`syntax error` at line 1).

## The fix (bounded, in cc-wrapper — NO seed rebuild)

The mapfiles only restrict symbol visibility of the libgcc unwinder; dropping
them just gives those symbols default visibility, which is harmless for the
link (they are exported anyway). So neutralize the two `-M %s..map` tokens by
overriding the gcc `*link:` spec via a `-specs=` file baked onto the cross
cc-wrapper's `cc-cflags`. Every cross compile (C and C++) then picks it up.

In entry-aarch64-wave10.nix (cxxNomapCc, applied in aarch64CrossOverlay):

    cxxNomapCc = cc: cc.override (_: {
      extraBuildCommands = (cc.extraBuildCommands or "") + ''
        cat > $out/nix-support/nomap.specs <<'SPECS'
        *link:
        %{h*} %{v:-V}    %{!shared:%{!static:%{!G:%{rdynamic: }}}}    %{static:-dn -Bstatic}    %{shared|G:-G -dy %{!mimpure-text:-z text}}    %{symbolic:-Bsymbolic -G -dy -z text}    %(link_arch)    %{Qy:} %{!Qn:-Qy}

        SPECS
        echo "-specs=$out/nix-support/nomap.specs" >> $out/nix-support/cc-cflags
      '';
    });

i.e. the same built-in `*link:` spec with the two
`%{...:-M %slibgcc-unwind.map}` / `%{...:-M %sclearcap.map}` clauses removed.
Nothing else changes: `-G -dy -z text` (Solaris shared-object flags GNU ld
also accepts), `%(link_arch)`, `-Qy` all stay.

Why safe for the existing 146 rows: C-only static links never emit the
shared clause, so their link line is byte-identical. Only shared / shared-
libgcc / C++ links change, and only by dropping a visibility mapfile.

## Proof

  - Trivial C++ .so (wrapped g++ -shared): EXIT 0, EM_AARCH64 ET_DYN, exports
    `_Z3fooi`.
  - throw/catch C++ exe (wrapped g++): EXIT 0, EM_AARCH64 ET_EXEC, imports
    `__cxa_throw@CXXABI_1.3`, `__gxx_personality_v0@CXXABI_1.3` + DW.ref
    (the unwinder path is exercised — LINK proof; the aarch64 binary can't RUN
    on the x86 host).
  - Packages: libfmt.a (`_ZN3fmt...`), libgmpxx.a (`_ZNSi3getERc` iostream),
    nlohmann_json, pugixml, tinyxml-2, yaml-cpp — all EM_AARCH64.

## Orthogonal (NOT the wall) illumos-portability nits seen while opening the class

  - gmp `--enable-cxx`: printf/doprnt.c uses `isascii` under -std=c99; illumos
    gates it behind __EXTENSIONS__. Fixed with -D__EXTENSIONS__ (a C file, so
    the cmdline define works). gmpxx then builds.
  - spdlog: C++ compiles fine but os-inl.h uses `struct tm`'s `tm_gmtoff`,
    which illumos gates behind __EXTENSIONS__ in a way the C++ feature-test
    macros undo under -std=c++11 — needs an upstream portability patch. SKIP.
  - Catch2 3.x (spdlog test dep): `Catch::isnan` vs `std::isnan` illumos
    <cmath> macro pollution. Test-only; dropped.
  - double-conversion: cmake ninja generator drags native ninja->python3->
    native openssl (fails to build on this node). Build-tool drag, not the wall.

## What this unlocks

The whole C++ class: harfbuzz/pango, nettle-c++, protobuf/abseil, and any
cross pkg that links a C++ shared lib/exe. Follow-on waves can now build
shared C++ libs too (yaml-cpp proved a shared link also works once compiled
-fPIC / forced static as the pkg prefers).
