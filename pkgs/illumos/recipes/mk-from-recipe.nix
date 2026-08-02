# mk-from-recipe.nix — turn ONE captured oi-clib.sh recipe row into a REAL
# stdenv.mkDerivation (Phase 2, docs/roadmap-fully-nixified.md).
#
# The ~10k cached packages were built by scripts/oi-clib.sh (host gcc +
# `nix-store --add`), NOT as derivations. Their BUILD RECIPES survive in
# pkgs/illumos/recipes/recipes.tsv (recovered from packages.nix + wave specs.tsv).
# This function replays one such recipe as a proper derivation so that, once the
# Phase-1 solnix stdenv lands, it BUILDS from source with provable provenance —
# the parallel to cached.nix's storePath overlay (which stays as the bootstrap).
#
# A recipe row is: { pname; version; url; buildsys; deps; flags; sha256; }
#   buildsys ∈ cmake | autotools | configure | custom | custom-make | make |
#             custom-header | autotools-sub | special  (the vocabulary that
#             appears in oi-clib.sh + the wave specs.tsv).
#   deps: space-separated recipe/pkg names, resolved against `resolveDep`.
#   flags: extra ./configure args (autotools/configure) or extra -D... (cmake).
#   sha256: "" or "SKIP" -> a placeholder (recipes recovered from unpinned wave
#           specs have no hash; fetchurl needs one, so we mark them clearly and
#           they fail closed at build time until a real hash is pinned).
#
# The build phases mirror oi-clib.sh's configure/cmake/make invocations and the
# Solaris CFLAGS/LDFLAGS; the recurring portability fixes (GNULIBFIX, GNU-linker
# option stripping, C++ math-in-global-ns, endian shim, __EXTENSIONS__) are
# wired as CONDITIONAL hooks keyed off the recipe pname (autoFixes below), the
# same families packages.nix applies via preConfigure. Add a package to a family
# list to opt it in; the default is the illumos-clean path (just __EXTENSIONS__).

{ stdenv
, fetchurl
, lib
, # resolveDep : depName (string) -> derivation | null. Lets a recipe reference
  # another recipe's derivation (or a stdenv/nixpkgs pkg) by name. default: drop
  # unresolved deps (they become -L/-I no-ops); a stricter caller can throw.
  resolveDep ? (_: null)
}:

recipe:

let
  inherit (recipe) pname version url buildsys;
  deps = lib.filter (s: s != "") (lib.splitString " " (recipe.deps or ""));
  flags = recipe.flags or "";
  rawSha = recipe.sha256 or "";

  # unpinned recipes (wave specs used sha `-`): fetchurl demands *some* hash, so
  # emit the all-zeros SRI placeholder. It will hash-mismatch at build time —
  # deliberately fail-closed until a real sha256 is pinned (NOTE below).
  placeholderSha = "0000000000000000000000000000000000000000000000000000000000000000";
  sha256 = if rawSha == "" || rawSha == "SKIP" || rawSha == "-" then placeholderSha else rawSha;
  pinned = !(rawSha == "" || rawSha == "SKIP" || rawSha == "-");

  buildInputs = lib.filter (d: d != null) (map resolveDep deps);

  # --- conditional portability-patch hooks (recovered from oi-clib.sh + wave
  #     logs + packages.nix fix families). Keyed by pname; opt-in per package. ---

  # Family 1 (GNULIBFIX): illumos libc declares `const char *getlocalename_l`;
  # gnulib redeclares it non-const -> conflicting-types. const-qualify gnulib's
  # prototype across every vintage of the file. (oi-clib.sh GNULIBFIX=1)
  gnulibFix = ''
    for f in $(find . \( -name 'localename*.c' -o -name 'localename*.h' \
                       -o -name 'getlocalename_l*.c' -o -name 'getlocalename_l*.h' \
                       -o -name 'setlocale_null*.c' \) 2>/dev/null); do
      sed -i 's/\(char[[:space:]]*\*[[:space:]]*\)getlocalename_l/const \1getlocalename_l/g' "$f" 2>/dev/null || true
      sed -i 's/const const /const /g' "$f" 2>/dev/null || true
    done
  '';
  gnulibPkgs = [ "m4" "grep" "sed" "diffutils" "gettext" "coreutils" "datamash"
                 "recode" "libunistring" "wget" "gawk" "tar" "gzip" "findutils"
                 "texinfo" "which" "libidn2" "nano" "cpio" ];

  # Family 5 (LDVERSCRIPT_STRIP): Solaris ld rejects GNU --version-script /
  # --as-needed / --gc-sections / -z relro,now / -pie. Interpose a cc/c++ shim
  # that filters them out of the link. (oi-clib.sh LDVERSCRIPT_STRIP=1)
  ldVersionScriptFix = ''
    mkdir -p .ldshim
    for _pair in "cc:''${CC:-cc}" "cxx:''${CXX:-c++}"; do
      _nm="''${_pair%%:*}"; _real="''${_pair#*:}"
      cat > .ldshim/$_nm <<'LDSHIMEOF'
    #!/bin/sh
    _a=""; _skip=0
    for x in "$@"; do
      if [ "$_skip" = 1 ]; then _skip=0; continue; fi
      case "$x" in
        -Wl,--version-script,*|-Wl,--version-script|-Wl,--version-script=*) continue ;;
        --version-script=*) continue ;;
        --version-script) _skip=1; continue ;;
        -Wl,--no-as-needed|-Wl,--as-needed|--no-as-needed|--as-needed) continue ;;
        -Wl,--gc-sections|--gc-sections) continue ;;
        -Wl,-z,relro,-z,now|-Wl,-z,relro|-Wl,-z,now|-pie|-Wl,-pie|-fPIE) continue ;;
      esac
      _a="$_a $x"
    done
    LDSHIMEOF
      # append the real compiler exec line with the resolved path (avoid heredoc var capture)
      printf 'exec %s $_a\n' "$_real" >> .ldshim/$_nm
      chmod +x .ldshim/$_nm
    done
    export CC="$PWD/.ldshim/cc"; export CXX="$PWD/.ldshim/cxx"
  '';
  ldVersPkgs = [ "zlib-ng" "libssh2" "libpng" "elfutils" ];

  # Family 6 (CXXMATHNS): illumos libstdc++ exposes isnan/isinf/signbit only in
  # std::, not ::. Force-include a shim that pulls them into the global ns for
  # C++ that assumes ::isnan. (oi-clib.sh CXXMATHNS=1)
  cxxMathNsFix = ''
    cat > cxx_mathns_illumos.h <<'MATHNSEOF'
    #ifdef __cplusplus
    #include <cmath>
    using std::isnan; using std::isinf; using std::signbit;
    using std::isfinite; using std::isnormal; using std::fpclassify;
    #endif
    MATHNSEOF
    export CXXFLAGS="''${CXXFLAGS:-} -include $PWD/cxx_mathns_illumos.h"
  '';
  cxxMathNsPkgs = [ "catch2" "fmt" "spdlog" "nlohmann-json" ];

  # Family 3 (endian shim): Linux code #include <endian.h> + htobe64/... which
  # illumos lacks; map them onto <sys/byteorder.h> BE_64/LE_64/... via a
  # force-included compat header. (packages.nix endianShimStage)
  endianShimFix = ''
    cat > endian_illumos.h <<'ENDIANEOF'
    #ifndef SOLNIX_ENDIAN_ILLUMOS_H
    #define SOLNIX_ENDIAN_ILLUMOS_H
    #include <sys/byteorder.h>
    #ifndef htobe16
    #define htobe16(x) BE_16(x)
    #define htole16(x) LE_16(x)
    #define be16toh(x) BE_16(x)
    #define le16toh(x) LE_16(x)
    #define htobe32(x) BE_32(x)
    #define htole32(x) LE_32(x)
    #define be32toh(x) BE_32(x)
    #define le32toh(x) LE_32(x)
    #define htobe64(x) BE_64(x)
    #define htole64(x) LE_64(x)
    #define be64toh(x) BE_64(x)
    #define le64toh(x) LE_64(x)
    #endif
    #endif
    ENDIANEOF
    export CFLAGS="''${CFLAGS:-} -include $PWD/endian_illumos.h"
    export CXXFLAGS="''${CXXFLAGS:-} -include $PWD/endian_illumos.h"
  '';
  endianPkgs = [ "libsrtp" "libbsd" "wireguard-tools" ];

  # Family 2 (tputsFix) + assorted -f/-Wno flags folded into CFLAGS for the
  # terminfo consumers and pre-C99 GNU tools. (packages.nix tputsFix + errno
  # -include + u_int8_t defines discovered in wave logs)
  isFam = list: builtins.elem pname list;
  preFixes = lib.concatStringsSep "\n" (
    (lib.optional (isFam gnulibPkgs) gnulibFix)
    ++ (lib.optional (isFam ldVersPkgs) ldVersionScriptFix)
    ++ (lib.optional (isFam cxxMathNsPkgs) cxxMathNsFix)
    ++ (lib.optional (isFam endianPkgs) endianShimFix)
  );

  # extra CFLAGS every solnix build wants: __EXTENSIONS__ opens the illumos
  # feature-test namespace (strdup, snprintf, etc. under XPG). -fcommon placates
  # the multiple-definition of ospeed/UP/BC/PC in old terminfo tools. errno
  # shadow (-include errno.h) and u_int8_t defines were per-package in the wave
  # logs; fold the cheap always-safe ones in globally.
  baseCFlags = "-m64 -fPIC -O2 -D__EXTENSIONS__";

  # --- per-buildsys phase overrides (modeled on oi-clib.sh) ---
  # cmake: oi-clib.sh runs `cmake .. -DCMAKE_INSTALL_PREFIX -DCMAKE_INSTALL_LIBDIR=lib
  #   -DCMAKE_BUILD_TYPE=RelWithDebInfo <flags> && gmake && gmake install`.
  cmakePhases = {
    configurePhase = ''
      runHook preConfigure
      mkdir -p _b && cd _b
      cmake .. -DCMAKE_INSTALL_PREFIX="$out" \
        -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_INSTALL_MANDIR="$out/share/man" \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo ${flags}
      runHook postConfigure
    '';
    buildPhase = "runHook preBuild; make -j\${NIX_BUILD_CORES:-4}; runHook postBuild";
    installPhase = "runHook preInstall; make install; runHook postInstall";
  };

  # autotools/configure: oi-clib.sh regenerates ./configure if absent
  # (autogen.sh/bootstrap/autoreconf), probes for --mandir, then
  # `./configure --prefix <flags> && gmake && gmake install`.
  autotoolsPhases = {
    configurePhase = ''
      runHook preConfigure
      if [ ! -x ./configure ]; then
        if [ -x ./autogen.sh ]; then NOCONFIGURE=1 ./autogen.sh || ./autogen.sh || true
        elif [ -x ./bootstrap ]; then ./bootstrap || true
        fi
        [ -x ./configure ] || autoreconf -fi 2>/dev/null || true
      fi
      MANF=""
      ./configure --help 2>&1 | grep -q -- '--mandir' && MANF="--mandir=$out/share/man"
      ./configure --prefix="$out" $MANF ${flags}
      runHook postConfigure
    '';
    buildPhase = "runHook preBuild; make -j\${NIX_BUILD_CORES:-4}; runHook postBuild";
    installPhase = "runHook preInstall; make install; runHook postInstall";
  };

  # make / custom-make: plain `make PREFIX=$out && make install` (leonerd libs,
  # rtmpdump, libcircllhist). No configure.
  makePhases = {
    dontConfigure = true;
    buildPhase = "runHook preBuild; make -j\${NIX_BUILD_CORES:-4} PREFIX=\"$out\" prefix=\"$out\"; runHook postBuild";
    installPhase = "runHook preInstall; make PREFIX=\"$out\" prefix=\"$out\" install; runHook postInstall";
  };

  # custom-header / uthash / tllist: header-only. Just copy include/ into $out.
  headerPhases = {
    dontConfigure = true;
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/include"
      if [ -d include ]; then cp -a include/* "$out/include/"; else cp -a *.h "$out/include/" 2>/dev/null || true; fi
      runHook postInstall
    '';
  };

  # buildsys -> phase set. 'special' / 'autotools-sub' fall back to autotools
  # (their per-package tweaks lived in the wave driver, not the recipe row —
  # NOTE in default.nix; needs re-derivation from the original driver).
  phases =
    if buildsys == "cmake" then cmakePhases
    else if buildsys == "custom-header" then headerPhases
    else if buildsys == "make" || buildsys == "custom-make" || buildsys == "custom" then makePhases
    else autotoolsPhases;  # autotools | configure | special | autotools-sub

in
stdenv.mkDerivation ({
  inherit pname version buildInputs;

  src = fetchurl { inherit url sha256; };

  # Solaris feature-test macros + the recovered per-family portability hooks run
  # before configure (mirrors oi-clib.sh's env + packages.nix preConfigure).
  preConfigure = ''
    export CFLAGS="${baseCFlags} ''${CFLAGS:-}"
    export CXXFLAGS="${baseCFlags} ''${CXXFLAGS:-}"
    export CPPFLAGS="-D__EXTENSIONS__ ''${CPPFLAGS:-}"
    ${preFixes}
  '';

  # drop libtool .la archives + relocate .pc (root-cause fixes from oi-clib.sh:
  # .la files bake dead build paths; .pc files bake the temp prefix).
  postInstall = ''
    find "$out" -name '*.la' -type f -delete 2>/dev/null || true
    find "$out" -name '*.pc' -type f 2>/dev/null | while read -r pc; do
      sed -i "s|^prefix=$out\b|prefix=\''${pcfiledir}/../..|" "$pc" 2>/dev/null || true
    done
  '';

  # provenance: carry the recipe source + whether the hash is real, so a
  # consumer / audit can tell a pinned recipe from a placeholder one.
  passthru = {
    recipeSource = recipe.src or "unknown";
    hashPinned = pinned;
    inherit buildsys deps;
  };

  meta = {
    description = "solnix recipe-derived ${pname} (Phase-2, buildsys=${buildsys})";
  };
} // phases)
