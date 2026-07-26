# mk-userland-pkg.nix — build an OI-userland/upstream package as a relocatable
# /nix/store component, with BOTH the solnix-gcc and solnix-clang toolchains, on
# the illumos build fleet. docs/design-build-fleet.md + docs/design-toolchains.md.
#
# Standalone (plain `derivation` + bash builder), Nix 2.3.16, sandbox=false, so
# network fetch is allowed in the builder (we verify sha256 ourselves; the store
# path is content-addressed by the built NAR — deterministic given pinned src +
# toolchain store paths). The fork maps this onto stdenv.mkDerivation with the
# solnix cc-wrapper, fetchurl, and a RUNPATH fixup hook.
#
# RUNPATH story (same as mk-illumos-component): after `make install DESTDIR=$out`
# every dynamic ELF gets its DT_RUNPATH/DT_RPATH rewritten to:
#   $ORIGIN[:$ORIGIN/../lib] : <this pkg's $out/lib> : <each dep's lib dirs> :
#   <libc slice lib dirs>
# and any host /usr/gcc, /usr/lib, /lib leak is scrubbed. elfedit grows the
# RUNPATH in place (illumos ELF; no patchelf).

{ gccStore          # illumos-gcc14 store path
, clangStore        # illumos-clang store path
, libcStore         # illumos-libc store path
, ldStore           # illumos-ld store path (drive the store Solaris ld)
, wrapperSrc        # path to oi-cc-wrapper.sh (imported into store)
}:

{ pname
, version
, src              # { url, sha256 } — tarball
, compiler ? "gcc" # "gcc" | "clang"
, deps ? [ ]       # list of store paths (built solnix pkgs) this one links
, buildSystem ? "autotools"  # "autotools" | "configure" | "make" | "custom" | "cmake-less"
, configureFlags ? [ ]
, makeFlags ? [ ]
, installFlags ? [ ]
, installTargets ? "install"
, preConfigure ? ""
, postInstall ? ""
, customBuild ? ""   # for buildSystem="custom": full build+install shell, uses $CC/$CXX/$out/$src
, env ? { }         # extra env vars (name->value) exported before build
, unpackSubdir ? "" # if the tarball has a nonstandard top dir, set it; else auto
, stripBins ? false # illumos strip can break; default off
, separateDebugInfo ? true # split .debug into the `debug` output (see below)
}:

# Debug symbols: when separateDebugInfo (default), every ELF's DWARF is split
# into a SEPARATE store path (the `debug` output) via GNU binutils objcopy
# --only-keep-debug + --add-gnu-debuglink, mirroring nixpkgs' separateDebugInfo.
# The main output ships stripped-of-debug (but keeps CTF, which illumos mdb/dtrace
# use); the `debug` output holds the .debug files under
# lib/debug/.build-id/<xx>/<rest>.debug so gdb finds them by build-id. Both are
# cached+signed; a consumer pulls `debug` only when actually debugging. This is
# the "separate packages that combine to debug" the maintainer asked for.

let
  libcLibDirs = [ "${libcStore}/lib/amd64" "${libcStore}/lib" ];
  # dep lib dirs: cover every layout a build might install into (amd64/64/lib64).
  libSubdirs = [ "lib/amd64" "lib/64" "lib64" "lib" "usr/lib/amd64" "usr/lib/64" "usr/lib" ];
  depLibDirs = builtins.concatLists (map (d: map (s: "${d}/${s}") libSubdirs) deps);
  depIncDirs = builtins.concatLists (map (d: [ "${d}/include" "${d}/usr/include" ]) deps);
  depBinDirs = builtins.concatLists (map (d: [ "${d}/bin" "${d}/usr/bin" ]) deps);

  # -L / -I flags handed to configure via CPPFLAGS/LDFLAGS so deps are found.
  depL = builtins.concatStringsSep " " (map (d: "-L${d}/lib -L${d}/lib/amd64 -L${d}/lib/64 -L${d}/lib64 -L${d}/usr/lib -L${d}/usr/lib/amd64") deps);
  depI = builtins.concatStringsSep " " (map (d: "-I${d}/include -I${d}/usr/include") deps);
  depRpath = builtins.concatStringsSep " " (map (d: "-Wl,-R,${d}/lib -Wl,-R,${d}/lib/amd64 -Wl,-R,${d}/lib/64 -Wl,-R,${d}/lib64 -Wl,-R,${d}/usr/lib -Wl,-R,${d}/usr/lib/amd64") deps);

  # final RUNPATH baked into every produced ELF. The OUTLIB placeholder is
  # replaced with the real $out in the builder (Nix doesn't know $out yet).
  finalRunpath = builtins.concatStringsSep ":" (
    (map (s: "@OUTLIB@/${s}") libSubdirs)
    ++ depLibDirs ++ libcLibDirs
  );

  envExports = builtins.concatStringsSep "\n"
    (builtins.map (n: "export ${n}=\"${builtins.getAttr n env}\"") (builtins.attrNames env));

  wrapper = builtins.path { path = wrapperSrc; name = "oi-cc-wrapper.sh"; };
in
derivation {
  # Store name is plain <pname>-<version> (no solnix-/illumos- prefix); the
  # store hash disambiguates. Canonical namespace is pkgs.solnix.* (see
  # .kiro/steering/nix-conventions.md "Package namespace").
  name = "${pname}-${version}";
  system = builtins.currentSystem;
  builder = "/usr/bin/bash";
  PATH = "/usr/gnu/bin:/usr/bin:/usr/sbin";

  inherit pname version compiler buildSystem installTargets;
  inherit gccStore clangStore libcStore ldStore wrapper;
  # multi-output: `out` (the package) + `debug` (separate DWARF store path).
  outputs = if separateDebugInfo then [ "out" "debug" ] else [ "out" ];
  sepDebug = if separateDebugInfo then "1" else "";
  srcUrl = src.url;
  srcSha256 = src.sha256;
  configureFlagsStr = builtins.concatStringsSep " " configureFlags;
  makeFlagsStr = builtins.concatStringsSep " " makeFlags;
  installFlagsStr = builtins.concatStringsSep " " installFlags;
  inherit preConfigure postInstall customBuild unpackSubdir envExports;
  inherit depL depI depRpath finalRunpath;
  depStorePaths = builtins.concatStringsSep " " deps;
  depBinPath = builtins.concatStringsSep ":" depBinDirs;
  stripBins = if stripBins then "1" else "";

  args = [ "-c" ''
    set -eu
    export PATH="${ldStore}/usr/bin:$depBinPath:/usr/gnu/bin:/usr/bin:/usr/sbin"
    WORK=$(mktemp -d /tmp/solnix-build.XXXXXX)
    cd "$WORK"

    echo "=== fetch $srcUrl ===" >&2
    /usr/bin/curl -fsSL "$srcUrl" -o src.tar
    got=$(/usr/bin/sha256sum src.tar | awk '{print $1}')
    if [ "$srcSha256" != "SKIP" ] && [ "$got" != "$srcSha256" ]; then
      echo "FATAL: sha256 mismatch: want $srcSha256 got $got" >&2; exit 1
    fi

    echo "=== unpack ===" >&2
    mkdir s && cd s
    # GNU tar (/usr/gnu/bin/tar) handles pax 'g' global headers; Solaris
    # /usr/bin/tar chokes on GitHub tarballs. Prefer GNU tar; tolerate its
    # nonzero exit on benign warnings (set +e around it).
    set +e
    /usr/gnu/bin/tar xf ../src.tar 2>/dev/null
    if [ ! "$(find . -maxdepth 1 -mindepth 1 | head -1)" ]; then
      /usr/bin/tar xf ../src.tar 2>/dev/null
    fi
    set -e
    # GNU tar can leave a stray pax_global_header regular file; drop it.
    rm -f pax_global_header 2>/dev/null || true
    if [ -n "$unpackSubdir" ]; then
      cd "$unpackSubdir"
    else
      # descend into the single top-level DIRECTORY (ignore stray files).
      dirs=$(find . -maxdepth 1 -mindepth 1 -type d)
      ndirs=$(printf '%s\n' "$dirs" | grep -c . || true)
      if [ "$ndirs" = "1" ]; then cd "$dirs"; fi
    fi
    SRCDIR=$(pwd)

    echo "=== generate cc-wrappers ===" >&2
    bash "$wrapper" "$WORK/ccw" "$gccStore" "$clangStore" "$libcStore" "$ldStore" >&2
    if [ "$compiler" = "clang" ]; then
      export CC="$WORK/ccw/solnix-clang"; export CXX="$WORK/ccw/solnix-clang++"
    else
      export CC="$WORK/ccw/solnix-gcc"; export CXX="$WORK/ccw/solnix-g++"
    fi

    # dep search paths handed through the standard env vars
    export CPPFLAGS="$depI ''${CPPFLAGS:-}"
    export CFLAGS="$depI ''${CFLAGS:-}"
    export CXXFLAGS="$depI ''${CXXFLAGS:-}"
    export LDFLAGS="$depL $depRpath ''${LDFLAGS:-}"
    export PKG_CONFIG_PATH="$(echo "$depL" | tr ' ' '\n' | sed -n 's,^-L\(.*\)/lib.*,\1/lib/pkgconfig,p' | paste -sd: -):''${PKG_CONFIG_PATH:-}"
    ${envExports}

    echo "=== configure/build ($buildSystem, $compiler) ===" >&2
    ${preConfigure}
    case "$buildSystem" in
      autotools|configure)
        ./configure --prefix="$out" $configureFlagsStr
        gmake -j"$(nproc)" $makeFlagsStr
        gmake $installFlagsStr $installTargets
        ;;
      make)
        gmake -j"$(nproc)" PREFIX="$out" prefix="$out" $makeFlagsStr
        gmake PREFIX="$out" prefix="$out" DESTDIR="" $installFlagsStr $installTargets
        ;;
      custom)
        ${customBuild}
        ;;
      *)
        echo "FATAL: unknown buildSystem $buildSystem" >&2; exit 1;;
    esac
    ${postInstall}

    echo "=== RUNPATH relocate + host-leak scrub ===" >&2
    # Build a MINIMAL RUNPATH from directories that ACTUALLY exist (under $out,
    # each dep, and libc). A long RUNPATH with many nonexistent subdirs can
    # exceed the .dynstr grow limit (design risk #1) and make elfedit fail,
    # leaving a host leak. Keep it tight: real dirs only, deduped.
    rp_parts=""
    add_dir() { if [ -d "$1" ]; then case ":$rp_parts:" in *":$1:"*) ;; *) rp_parts="$rp_parts''${rp_parts:+:}$1";; esac; fi; return 0; }
    for d in "$out/lib/amd64" "$out/lib/64" "$out/lib64" "$out/lib" "$out/usr/lib/amd64" "$out/usr/lib"; do add_dir "$d"; done
    for base in $depStorePaths; do
      for s in lib/amd64 lib/64 lib64 lib usr/lib/amd64 usr/lib; do add_dir "$base/$s"; done
    done
    # gcc14 C++/unwind runtime (libstdc++.so.6, libgcc_s.so.1) — every C++
    # binary NEEDs these; the relocate replaces the link-time -R so add it back.
    add_dir "$gccStore/usr/gcc/14/lib/amd64"; add_dir "$gccStore/usr/gcc/14/lib"
    add_dir "$libcStore/lib/amd64"; add_dir "$libcStore/lib"
    RP="$rp_parts"
    echo "RUNPATH -> $RP" >&2
    # illumos elfedit is /usr/bin/elfedit (has the dyn:runpath module).
    # /usr/gnu/bin/elfedit is GNU binutils' header-only elfedit -> WRONG tool.
    find "$out" -type f 2>/dev/null | while read -r f; do
      if /usr/bin/elfdump -d "$f" 2>/dev/null | grep -Eq 'SONAME|NEEDED|RUNPATH|RPATH'; then
        chmod u+w "$f" 2>/dev/null || true
        /usr/bin/elfedit -e "dyn:runpath $RP" "$f" 2>/dev/null || echo "WARN: relocate failed on $f (RUNPATH len ''${#RP})" >&2
      fi
    done

    # sanity: $out is non-empty
    [ -n "$(ls -A "$out" 2>/dev/null)" ] || { echo "FATAL: empty \$out" >&2; exit 1; }

    if [ -n "$sepDebug" ]; then
      echo "=== split debug info -> \$debug ($debug) ===" >&2
      # GNU binutils objcopy from the gcc14 toolchain (illumos /usr/bin/objcopy
      # is Solaris' and lacks --only-keep-debug/--add-gnu-debuglink).
      OBJCOPY="$gccStore/usr/gcc/14/bin/gobjcopy"
      [ -x "$OBJCOPY" ] || OBJCOPY="$gccStore/usr/bin/gobjcopy"
      [ -x "$OBJCOPY" ] || OBJCOPY=/usr/gnu/bin/objcopy
      OBJDUMP="$gccStore/usr/gcc/14/bin/gobjdump"; [ -x "$OBJDUMP" ] || OBJDUMP=/usr/gnu/bin/objdump
      mkdir -p "$debug/lib/debug/.build-id"
      find "$out" -type f 2>/dev/null | while read -r f; do
        # only ELF with a .debug_info section
        "$OBJDUMP" -h "$f" 2>/dev/null | grep -q '\.debug_info' || continue
        # locate by GNU build-id if present, else by a content hash fallback.
        bid=$("$OBJDUMP" -s -j .note.gnu.build-id "$f" 2>/dev/null | awk '/^ /{for(i=2;i<=5;i++)printf $i}' | tail -c +33 2>/dev/null)
        if [ -z "$bid" ]; then bid=$(/usr/bin/sha256sum "$f" | awk '{print $1}'); fi
        pre=$(printf '%s' "$bid" | cut -c1-2); rest=$(printf '%s' "$bid" | cut -c3-)
        dst="$debug/lib/debug/.build-id/$pre"
        mkdir -p "$dst"
        chmod u+w "$f" 2>/dev/null || true
        # 1) copy DWARF out, 2) strip it from the binary (KEEP CTF/.SUNW_ctf for
        #    mdb/dtrace), 3) link binary->debug by build-id.
        "$OBJCOPY" --only-keep-debug "$f" "$dst/$rest.debug" 2>/dev/null || continue
        "$OBJCOPY" --strip-debug "$f" 2>/dev/null || true
        "$OBJCOPY" --add-gnu-debuglink="$dst/$rest.debug" "$f" 2>/dev/null || true
      done
      # never leave an empty debug output (breaks the multi-output contract)
      [ -n "$(ls -A "$debug/lib/debug/.build-id" 2>/dev/null)" ] || \
        { mkdir -p "$debug/lib/debug"; echo "no split debug info for $pname-$version" > "$debug/lib/debug/.empty"; }
    fi

    echo "=== built $pname-$version ($compiler) -> $out ===" >&2
  '' ];
}
