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
}:

let
  libcLibDirs = [ "${libcStore}/lib/amd64" "${libcStore}/lib" ];
  # dep lib dirs: each dep exposes lib/amd64, lib, usr/lib/amd64, usr/lib
  depLibDirs = builtins.concatLists (map (d: [
    "${d}/lib/amd64" "${d}/lib" "${d}/usr/lib/amd64" "${d}/usr/lib"
  ]) deps);
  depIncDirs = builtins.concatLists (map (d: [ "${d}/include" "${d}/usr/include" ]) deps);
  depBinDirs = builtins.concatLists (map (d: [ "${d}/bin" "${d}/usr/bin" ]) deps);

  # -L / -I flags handed to configure via CPPFLAGS/LDFLAGS so deps are found.
  depL = builtins.concatStringsSep " " (map (d: "-L${d}/lib -L${d}/lib/amd64 -L${d}/usr/lib -L${d}/usr/lib/amd64") deps);
  depI = builtins.concatStringsSep " " (map (d: "-I${d}/include -I${d}/usr/include") deps);
  depRpath = builtins.concatStringsSep " " (map (d: "-Wl,-R,${d}/lib -Wl,-R,${d}/lib/amd64 -Wl,-R,${d}/usr/lib -Wl,-R,${d}/usr/lib/amd64") deps);

  # final RUNPATH baked into every produced ELF.
  finalRunpath = builtins.concatStringsSep ":" (
    [ "$out/lib/amd64" "$out/lib" "$out/usr/lib/amd64" "$out/usr/lib" ]
    ++ depLibDirs ++ libcLibDirs
  );

  envExports = builtins.concatStringsSep "\n"
    (builtins.map (n: "export ${n}=${builtins.getAttr n env}") (builtins.attrNames env));

  wrapper = builtins.path { path = wrapperSrc; name = "oi-cc-wrapper.sh"; };
in
derivation {
  name = "solnix-${pname}-${version}";
  system = builtins.currentSystem;
  builder = "/usr/bin/bash";
  PATH = "/usr/gnu/bin:/usr/bin:/usr/sbin";

  inherit pname version compiler buildSystem installTargets;
  inherit gccStore clangStore libcStore ldStore wrapper;
  srcUrl = src.url;
  srcSha256 = src.sha256;
  configureFlagsStr = builtins.concatStringsSep " " configureFlags;
  makeFlagsStr = builtins.concatStringsSep " " makeFlags;
  installFlagsStr = builtins.concatStringsSep " " installFlags;
  inherit preConfigure postInstall customBuild unpackSubdir envExports;
  inherit depL depI depRpath finalRunpath;
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
    /usr/bin/gtar xf ../src.tar 2>/dev/null || /usr/bin/tar xf ../src.tar
    if [ -n "$unpackSubdir" ]; then
      cd "$unpackSubdir"
    else
      # descend into the single top-level dir if that's the layout
      n=$(ls -1 | wc -l | tr -d ' ')
      if [ "$n" = "1" ] && [ -d "$(ls -1)" ]; then cd "$(ls -1)"; fi
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
    # relocate every dynamic ELF under $out to the store RUNPATH.
    find "$out" -type f 2>/dev/null | while read -r f; do
      if /usr/bin/elfdump -d "$f" 2>/dev/null | grep -Eq 'SONAME|NEEDED|RUNPATH|RPATH'; then
        chmod u+w "$f" 2>/dev/null || true
        # replace RUNPATH wholesale with the store runpath (drops any host leak)
        /usr/gnu/bin/elfedit -e "dyn:runpath $finalRunpath" "$f" 2>/dev/null || \
          /usr/bin/elfedit -e "dyn:runpath $finalRunpath" "$f" 2>/dev/null || true
      fi
    done

    # sanity: $out is non-empty
    [ -n "$(ls -A "$out" 2>/dev/null)" ] || { echo "FATAL: empty \$out" >&2; exit 1; }
    echo "=== built solnix-$pname-$version ($compiler) -> $out ===" >&2
  '' ];
}
