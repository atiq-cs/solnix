# packages.nix — the solnix userland package registry (tiers 0-2 core).
#
# Each entry is a spec consumed by mk-userland-pkg.nix. `callPackage` here just
# threads the toolchain store paths + the cc-wrapper source into every package,
# and lets a package reference already-built deps by attr name.
#
# Toolchain store paths are pinned to the CURRENTLY-BUILT slices on the fleet
# (docs/design-toolchains.md). If a slice hash changes, update here.
#
# Build a single package+compiler with:
#   nix-build packages.nix -A <pname>.gcc     # gcc-14 build
#   nix-build packages.nix -A <pname>.clang   # clang-21 build
# The driver script (oi-fleet-build.sh) fans these out across the fleet.

let
  gccStore   = "/nix/store/p01s2ssdblk0sfwck8cjyhv2j6l31aq0-gcc14";
  clangStore = "/nix/store/wfak3vr0n022gdk7j8c9ca5l20a6z0zv-clang";
  libcStore  = "/nix/store/mxarmh176whch3gf8bin54z97nbrass9-libc";
  ldStore    = "/nix/store/00xm2wgdcg6nv7lwlia7i93nmamahg5k-ld";
  wrapperSrc = ./../../scripts/oi-cc-wrapper.sh;

  mkPkg = import ./mk-userland-pkg.nix {
    inherit gccStore clangStore libcStore ldStore wrapperSrc;
  };

  # a package = { gcc = <drv>; clang = <drv>; } so the driver can pick either.
  pkg = spec: {
    gcc   = mkPkg (spec // { compiler = "gcc"; });
    clang = mkPkg (spec // { compiler = "clang"; });
  };

  # gnulib-on-illumos fix: illumos /usr/include/locale.h:98 declares
  #   extern const char *getlocalename_l(int, locale_t);
  # but the gnulib bundled in GNU tarballs (m4/grep/sed/diffutils/gettext/
  # coreutils/datamash/recode/libunistring/...) redeclares it `char *` under its
  # `#if defined __sun && HAVE_GETLOCALENAME_L` block -> conflicting-types error.
  # const-qualify gnulib's prototype to match libc across EVERY gnulib file that
  # carries the decl. gnulib has moved this decl across vintages
  # (localename.c -> localename-unsafe.c -> getlocalename_l-unsafe.c) and also
  # ships it in the matching *.h; sweep all of lib/ so the fix is vintage-proof.
  # Idempotent, safe if absent. (Family 1, wave 19 — docs/design-pkgsrc-patches.md)
  gnulibFix = ''
    for f in $(find . \( -name 'localename*.c' -o -name 'localename*.h' \
                       -o -name 'getlocalename_l*.c' -o -name 'getlocalename_l*.h' \
                       -o -name 'setlocale_null*.c' \) 2>/dev/null); do
      sed -i 's/extern char \* *getlocalename_l/extern const char *getlocalename_l/;s/^char \* *getlocalename_l/const char *getlocalename_l/' "$f" || true
    done
  '';

  # tputs-on-illumos fix (Family 2): illumos <term.h> declares
  #   tputs(char *, int, int (*)(char))
  # (the putc callback takes `char`), but ncurses/portable code passes
  # int(*)(int). gcc-14 promotes the incompatible-pointer mismatch to a hard
  # ERROR. Downgrade it to a warning. -fcommon also placates the multiple-def of
  # ospeed/UP/BC/PC that terminfo tools carry (gcc-10+ default -fno-common).
  # Used by texinfo (already), hwloc/lstopo, wdiff, and any terminfo consumer.
  tputsFix = "-Wno-error=incompatible-pointer-types -fcommon";

  # endian.h-on-illumos fix (Family 3): Linux code #include <endian.h> and uses
  # htobe64/htole64/be64toh/... which illumos lacks; illumos ships the same
  # primitives as BE_64/LE_64/... in <sys/byteorder.h>. Force-include a compat
  # shim (endian_illumos.h, staged into every build root by endianShimStage)
  # that maps the glibc names onto the illumos ones. -include it via CFLAGS so
  # the macros exist regardless of the source's #ifdef __linux__ guards.
  endianShimStage = ''
    cat > endian_illumos.h <<'ENDIANEOF'
    #ifndef SOLNIX_ENDIAN_ILLUMOS_H
    #define SOLNIX_ENDIAN_ILLUMOS_H
    /* solnix compat shim: glibc <endian.h> names on illumos <sys/byteorder.h>. */
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
    export CPPFLAGS="''${CPPFLAGS:-} -include $PWD/endian_illumos.h"
  '';

  # illumos feature-test macro fix: many portable C tools use strcasecmp/
  # strncasecmp (<strings.h>) or POSIX symbols that Solaris libc hides behind
  # __EXTENSIONS__ / _XOPEN_SOURCE. Append (not clobber) the search-path CFLAGS
  # set by mk-userland. Use in preConfigure.
  illumosExt = ''
    export CFLAGS="''${CFLAGS:-} -D__EXTENSIONS__ -D_XOPEN_SOURCE=600 -D_XOPEN_SOURCE_EXTENDED=1"
    export CPPFLAGS="''${CPPFLAGS:-} -D__EXTENSIONS__ -D_XOPEN_SOURCE=600"
  '';

  # GNU-linker version-script fix (Family 5, wave 22): Solaris ld does NOT accept
  # GNU's `--version-script <file>`; it uses a different `-M <mapfile>` syntax
  # entirely -> `ld: fatal: unrecognized option '--version-script'`. Many libs
  # (zlib-ng, and any lib doing GNU symbol versioning via a .map/.sym file) pass
  # `-Wl,--version-script,zlib.map` on EVERY platform. Translating the map to a
  # Solaris mapfile is per-file and fragile; the reusable fix DROPS the version
  # script on illumos. Consequence: symbols keep their default global scope
  # (no per-version symbol scoping) — harmless for a userland library on illumos
  # where nothing consumes the GNU version tags. Interposes a CC/CXX wrapper that
  # filters `-Wl,--version-script,*` / `--version-script <f>` out of the link.
  # In preConfigure it installs $PWD/.ldshim/{cc,c++} and points CC/CXX at them;
  # for the native oi-clib.sh path set LDVERSCRIPT_STRIP=1 (clib installs the
  # same shim). Idempotent.
  ldVersionScriptFix = ''
    mkdir -p .ldshim
    _REALCC="''${CC:-cc}"; _REALCXX="''${CXX:-c++}"
    for _pair in "cc:$_REALCC" "c++:$_REALCXX"; do
      _nm="''${_pair%%:*}"; _real="''${_pair#*:}"
      cat > .ldshim/$_nm <<LDSHIMEOF
    #!/bin/sh
    # solnix ldVersionScriptFix: strip GNU --version-script (Solaris ld rejects it).
    _a=""; _skip=0
    for x in "\$@"; do
      if [ "\$_skip" = 1 ]; then _skip=0; continue; fi
      case "\$x" in
        -Wl,--version-script,*|-Wl,--version-script) continue ;;
        --version-script=*) continue ;;
        --version-script) _skip=1; continue ;;
      esac
      _a="\$_a \$x"
    done
    exec $_real \$_a
    LDSHIMEOF
      chmod +x .ldshim/$_nm
    done
    export CC="$PWD/.ldshim/cc"; export CXX="$PWD/.ldshim/c++"
  '';

  # C++ global-namespace C-math-name fix (Family 6, wave 22): modern C++ code
  # (catch2, and libs that #include <math.h> then call bare isnan/isinf/signbit)
  # assumes the C math names are also visible in the GLOBAL namespace. illumos
  # libstdc++ (<cmath>) only exposes them in `std::`, NOT `::` -> errors like
  # "'isnan' is not a member of 'Catch'" / "'::isnan' has not been declared".
  # Fix: force-include <cmath> and pull the three names into the global ns with a
  # `using std::...;` compat header, so ::isnan/::isinf/::signbit resolve. Applied
  # via CXXFLAGS `-include`; harmless when the names are already global. For the
  # native oi-clib.sh path set CXXMATHNS=1 (clib stages the same header).
  cxxMathNsStage = ''
    cat > cxx_mathns_illumos.h <<'MATHNSEOF'
    #ifndef SOLNIX_CXX_MATHNS_ILLUMOS_H
    #define SOLNIX_CXX_MATHNS_ILLUMOS_H
    /* solnix compat: bring C math names into the global ns for C++ that assumes
       ::isnan/::isinf/::signbit (illumos libstdc++ only exposes them in std::). */
    #ifdef __cplusplus
    #include <cmath>
    using std::isnan; using std::isinf; using std::signbit;
    using std::isfinite; using std::isnormal; using std::fpclassify;
    #endif
    #endif
    MATHNSEOF
    export CXXFLAGS="''${CXXFLAGS:-} -include $PWD/cxx_mathns_illumos.h"
  '';

  # pre-C99 GNU libc-fallback fix (Family 7, wave 22): ancient GNU tools ship
  # their own K&R replacement memcpy.c/memmove.c/strcasecmp.c etc. guarded by
  # `#ifndef HAVE_MEMCPY`. Their K&R signatures (`char *memcpy()`) conflict with
  # <string.h> once we force-include it (or gcc-14 rejects the pre-C99 defs).
  # illumos libc HAS all of these, so configure should just DETECT them and skip
  # the bundled fallbacks. Fix: pre-seed the autoconf cache so configure records
  # the libc functions as present (ac_cv_func_<fn>=yes) — the bundled .c is then
  # #ifndef-compiled out. Reusable across pre-C99 GNU tools (enscript, ...).
  libcFallbackFix = ''
    export ac_cv_func_memcpy=yes ac_cv_func_memmove=yes ac_cv_func_memset=yes
    export ac_cv_func_strcasecmp=yes ac_cv_func_strncasecmp=yes
    export ac_cv_func_strchr=yes ac_cv_func_strrchr=yes ac_cv_func_strdup=yes
    export ac_cv_func_strstr=yes ac_cv_func_strerror=yes ac_cv_func_bcopy=yes
  '';

  # convenience: refer to a dep's gcc-built store path for RUNPATH/search.
  # We link deps built with gcc (ABI-compatible: OI clang uses gcc's libstdc++).
  self = rec {

    # ---- cached imaging/security libs (wave10, published to the cache) -----
    # Referenced by wave-14 pkgs as raw store paths (they're not packages.nix
    # attrs). mk-userland-pkg treats a dep as a store-path string for -L/-I/-R +
    # RUNPATH; oi-tool.sh pulls any referenced store path from the cache.
    libpngCached = "/nix/store/6xj178rds6hxacanq0wvi7lxw90vk5xv-libpng-1.6.44";
    caresCached  = "/nix/store/kw0zwqy0kqnvrzax4mw44haxw6zc4gpw-c-ares-1.34.4";
    pcre1Cached  = "/nix/store/4mgr68kazbylx2imvwsg022k97maqxz2-pcre-8.45";
    jpegCached     = "/nix/store/6xlixn6x697y6izlymrkwdph6rzxkqgs-libjpeg-turbo-3.0.4";
    freetypeCached = "/nix/store/li0kv2ik8aaydw9qplc9a68a6jrmjaky-freetype-2.13.3";
    lcms2Cached    = "/nix/store/m261cgrlq9xs4q94ibj130mi1xxiy0lm-lcms2-2.16";
    tiffCached     = "/nix/store/xa5d79ck4vw76jk5vsfjpipj40h8p4zg-libtiff-4.7.0";
    webpCached     = "/nix/store/6pdw7d3b9ww89icflalj56jg59ldwasy-libwebp-1.4.0";

    # ---- Tier 0/1 leaf libs (no userland deps) -----------------------------
    zlib = pkg {
      pname = "zlib"; version = "1.3.1";
      src = { url = "https://zlib.net/fossils/zlib-1.3.1.tar.gz";
              sha256 = "9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23"; };
      # zlib's configure is hand-rolled (not autoconf) but accepts --prefix.
      configureFlags = [ "--64" ];
    };

    bzip2 = pkg {
      pname = "bzip2"; version = "1.0.8";
      src = { url = "https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz";
              sha256 = "ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269"; };
      buildSystem = "custom";
      customBuild = ''
        gmake -j"$(nproc)" CC="$CC" || gmake CC="$CC"
        gmake -f Makefile-libbz2_so CC="$CC" || true
        gmake install PREFIX="$out"
        mkdir -p "$out/lib"
        cp -a libbz2.so* "$out/lib/" 2>/dev/null || true
      '';
    };

    xz = pkg {
      pname = "xz"; version = "5.6.3";
      src = { url = "https://github.com/tukaani-project/xz/releases/download/v5.6.3/xz-5.6.3.tar.gz";
              sha256 = "b1d45295d3f71f25a4c9101bd7c8d16cb56348bbef3bbc738da0351e17c73317"; };
      configureFlags = [ "--disable-static" "--enable-shared" ];
    };

    m4 = pkg {
      pname = "m4"; version = "1.4.19";
      src = { url = "https://mirrors.kernel.org/gnu/m4/m4-1.4.19.tar.xz";
              sha256 = "63aede5c6d33b6d9b13511cd0be2cac046f2e70fd0a07aa9573a04a82783af96"; };
      preConfigure = gnulibFix;
    };

    gmp = pkg {
      pname = "gmp"; version = "6.3.0";
      src = { url = "https://mirrors.kernel.org/gnu/gmp/gmp-6.3.0.tar.xz";
              sha256 = "a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898"; };
      configureFlags = [ "--enable-cxx" ];
    };

    libffi = pkg {
      pname = "libffi"; version = "3.4.6";
      src = { url = "https://github.com/libffi/libffi/releases/download/v3.4.6/libffi-3.4.6.tar.gz";
              sha256 = "b0dea9df23c863a7a50e825440f3ebffabd65df1497108e5d437747843895a4e"; };
    };

    pcre2 = pkg {
      pname = "pcre2"; version = "10.47";
      src = { url = "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.47/pcre2-10.47.tar.gz";
              sha256 = "c08ae2388ef333e8403e670ad70c0a11f1eed021fd88308d7e02f596fcd9dc16"; };
      configureFlags = [ "--enable-pcre2-16" "--enable-pcre2-32" ];
    };

    # pcre (pcre1): still wanted by tools that predate pcre2 (the_silver_searcher
    # 2.2.0). Autotools; ships libpcre.pc. illumos-clean.
    pcre = pkg {
      pname = "pcre"; version = "8.45";
      src = { url = "https://sourceforge.net/projects/pcre/files/pcre/8.45/pcre-8.45.tar.bz2/download";
              sha256 = "4dae6fdcd2bb0bb6c37b5f97c33c2be954da743985369cddac3546e3218bffb8"; };
      preConfigure = illumosExt;
      configureFlags = [ "--enable-pcre8" "--enable-utf" "--enable-unicode-properties" "--disable-static" ];
    };

    # boehm-gc (bdwgc): conservative garbage collector; w3m links it. Autotools;
    # needs libatomic_ops bundled (the release tarball ships it). illumos-clean
    # with the feature-test macros.
    boehmgc = pkg {
      pname = "gc"; version = "8.2.6";
      src = { url = "https://github.com/ivmai/bdwgc/releases/download/v8.2.6/gc-8.2.6.tar.gz";
              sha256 = "b9183fe49d4c44c7327992f626f8eaa1d8b14de140f243edb1c9dcff7719a7fc"; };
      preConfigure = illumosExt;
      configureFlags = [ "--enable-threads=posix" "--enable-cplusplus" "--disable-static" ];
    };

    expat = pkg {
      pname = "expat"; version = "2.6.4";
      src = { url = "https://github.com/libexpat/libexpat/releases/download/R_2_6_4/expat-2.6.4.tar.gz";
              sha256 = "fd03b7172b3bd7427a3e7a812063f74754f24542429b634e0db6511b53fb2278"; };
    };

    pkgconf = pkg {
      pname = "pkgconf"; version = "2.3.0";
      src = { url = "https://distfiles.ariadne.space/pkgconf/pkgconf-2.3.0.tar.xz";
              sha256 = "3a9080ac51d03615e7c1910a0a2a8df08424892b5f13b0628a204d3fcce0ea8b"; };
      # provide pkg-config compat symlink
      postInstall = ''
        ln -sf pkgconf "$out/bin/pkg-config" 2>/dev/null || true
      '';
    };

    ninja = pkg {
      pname = "ninja"; version = "1.12.1";
      src = { url = "https://github.com/ninja-build/ninja/archive/refs/tags/v1.12.1.tar.gz";
              sha256 = "821bdff48a3f683bc4bb3b6f0b5fe7b2d647cf65d52aeb63328c91a6c6df285a"; };
      buildSystem = "custom";
      customBuild = ''
        python3 ./configure.py --bootstrap
        mkdir -p "$out/bin"
        cp -a ninja "$out/bin/"
      '';
    };

    # ---- Tier 1/2 libs that depend on the leaves ---------------------------
    ncurses = pkg {
      pname = "ncurses"; version = "6.5";
      src = { url = "https://mirrors.kernel.org/gnu/ncurses/ncurses-6.5.tar.gz";
              sha256 = "136d91bc269a9a5785e5f9e980bc76ab57428f604ce3e5a5a90cebc767971cc6"; };
      buildSystem = "custom";
      # Build the widec libs but WITHOUT the termlib split (which made the
      # form/menu/panel libs link the host libncurses.so.5). --with-termlib
      # dropped. Build+install only libraries/headers/progs (test/ won't link).
      customBuild = ''
        ./configure --prefix="$out" --with-shared --without-debug --enable-widec \
          --enable-pc-files --without-ada --without-tests --with-normal
        gmake -j"$(nproc)" libs
        gmake -C progs || true
        gmake install.libs install.includes install.data
        gmake -C progs install || true
      '';
    };

    readline = pkg {
      pname = "readline"; version = "8.2";
      src = { url = "https://mirrors.kernel.org/gnu/readline/readline-8.2.tar.gz";
              sha256 = "3feb7171f16a84ee82ca18a36d7b9be109a52c04f492a053331d7d1095007c35"; };
      deps = [ self.ncurses.gcc ];
      # illumos <termcap.h> declares tputs with int(*)(char), clashing with
      # readline's int(*)(int). Force readline to use its bundled/ncurses
      # termcap via the ncurses term.h, and make the tputs-decl mismatch a
      # warning not an error (its own rltty.c prototype is the correct one).
      configureFlags = [ "--with-curses" "--enable-shared" ];
      env = { CFLAGS = "-fcommon -Wno-error -DNCURSES_WIDECHAR=1"; };
      preConfigure = ''
        # drop illumos /usr/include/termcap.h from the search by preferring the
        # ncurses one: readline includes <termcap.h>; point it at ncurses'.
        export CPPFLAGS="-I${self.ncurses.gcc}/include -I${self.ncurses.gcc}/include/ncursesw $CPPFLAGS"
      '';
    };

    openssl3 = pkg {
      pname = "openssl-3"; version = "3.4.0";
      src = { url = "https://github.com/openssl/openssl/releases/download/openssl-3.4.0/openssl-3.4.0.tar.gz";
              sha256 = "e15dda82fe2fe8139dc2ac21a36d4ca01d5313c75f99f46c4e8a27709b7294bf"; };
      deps = [ self.zlib.gcc ];
      # openssl installs into solaris64 lib/64 with many large shared objects;
      # the generic split-debug pass aborts on them (objcopy/build-id extraction
      # under the strict builder shell), which blocked every consumer
      # (curl/git/cmake) from rebuilding openssl3. openssl keeps CTF for mdb, so
      # skip the separate DWARF `debug` output for openssl3 only.
      separateDebugInfo = false;
      buildSystem = "custom";
      customBuild = ''
        ./Configure solaris64-x86_64-gcc --prefix="$out" --openssldir="$out/ssl" \
          no-tests shared zlib "-I${self.zlib.gcc}/include" "-L${self.zlib.gcc}/lib" \
          "-Wl,-R,${self.zlib.gcc}/lib"
        gmake -j"$(nproc)" build_sw
        gmake install_sw
      '';
    };

    libxml2 = pkg {
      pname = "libxml2"; version = "2.12.9";
      src = { url = "https://download.gnome.org/sources/libxml2/2.12/libxml2-2.12.9.tar.xz";
              sha256 = "59912db536ab56a3996489ea0299768c7bcffe57169f0235e7f962a91f483590"; };
      deps = [ self.zlib.gcc self.xz.gcc ];
      configureFlags = [ "--without-python" "--with-zlib=${self.zlib.gcc}" "--with-lzma=${self.xz.gcc}" ];
    };

    zstd = pkg {
      pname = "zstd"; version = "1.5.6";
      src = { url = "https://github.com/facebook/zstd/releases/download/v1.5.6/zstd-1.5.6.tar.gz";
              sha256 = "8c29e06cf42aacc1eafc4077ae2ec6c6fcb96a626157e0593d5e82a34fd403c1"; };
      buildSystem = "custom";
      customBuild = ''
        gmake -j"$(nproc)" CC="$CC" PREFIX="$out"
        gmake -C lib install-static install-shared install-includes CC="$CC" PREFIX="$out"
        gmake -C programs install CC="$CC" PREFIX="$out" || {
          mkdir -p "$out/bin"; cp -a programs/zstd "$out/bin/" 2>/dev/null || true; }
      '';
    };

    # ---- Tier build tools --------------------------------------------------
    gnumake = pkg {
      pname = "gnu-make"; version = "4.4.1";
      src = { url = "https://mirrors.kernel.org/gnu/make/make-4.4.1.tar.gz";
              sha256 = "dd16fb1d67bfab79a72f5e8390735c49e3e8e70b4945a15ab1f81ddb78658fb3"; };
    };

    autoconf = pkg {
      pname = "autoconf"; version = "2.72";
      src = { url = "https://mirrors.kernel.org/gnu/autoconf/autoconf-2.72.tar.xz";
              sha256 = "ba885c1319578d6c94d46e9b0dceb4014caafe2490e437a0dbca3f270a223f5a"; };
      deps = [ self.m4.gcc ];
    };

    automake = pkg {
      pname = "automake"; version = "1.16.5";
      src = { url = "https://mirrors.kernel.org/gnu/automake/automake-1.16.5.tar.xz";
              sha256 = "f01d58cd6d9d77fbdca9eb4bbd5ead1988228fdb73d6f7a201f5f8d6b118b469"; };
      deps = [ self.autoconf.gcc self.m4.gcc ];
    };

    libtool = pkg {
      pname = "libtool"; version = "2.4.7";
      src = { url = "https://mirrors.kernel.org/gnu/libtool/libtool-2.4.7.tar.xz";
              sha256 = "4f7f217f057ce655ff22559ad221a0fd8ef84ad1fc5fcb6990cecc333aa1635d"; };
      deps = [ self.m4.gcc ];
    };

    flex = pkg {
      pname = "flex"; version = "2.6.4";
      src = { url = "https://github.com/westes/flex/releases/download/v2.6.4/flex-2.6.4.tar.gz";
              sha256 = "e87aae032bf07c26f85ac0ed3250998c37621d95f8bd748b31f15b33c45ee995"; };
      deps = [ self.m4.gcc ];
      configureFlags = [ "--disable-static" ];
    };

    bison = pkg {
      pname = "bison"; version = "3.8.2";
      src = { url = "https://mirrors.kernel.org/gnu/bison/bison-3.8.2.tar.xz";
              sha256 = "9bba0214ccf7f1079c5d59210045227bcf619519840ebfa80cd3849cff5a5bf2"; };
      deps = [ self.m4.gcc ];
      preConfigure = gnulibFix;
    };

    diffutils = pkg {
      pname = "diffutils"; version = "3.10";
      src = { url = "https://mirrors.kernel.org/gnu/diffutils/diffutils-3.10.tar.xz";
              sha256 = "90e5e93cc724e4ebe12ede80df1634063c7a855692685919bfe60b556c9bd09e"; };
      preConfigure = gnulibFix;
    };

    grep = pkg {
      pname = "grep"; version = "3.11";
      src = { url = "https://mirrors.kernel.org/gnu/grep/grep-3.11.tar.xz";
              sha256 = "1db2aedde89d0dea42b16d9528f894c8d15dae4e190b59aecc78f5a951276eab"; };
      deps = [ self.pcre2.gcc ];
      preConfigure = gnulibFix;
    };

    less = pkg {
      pname = "less"; version = "668";
      src = { url = "https://www.greenwoodsoftware.com/less/less-668.tar.gz";
              sha256 = "2819f55564d86d542abbecafd82ff61e819a3eec967faa36cd3e68f1596a44b8"; };
      deps = [ self.ncurses.gcc ];
    };

    # ---- extra tier-1/2 leaf libs (autotools/make) -------------------------
    sqlite = pkg {
      pname = "sqlite-3"; version = "3.47.2";
      src = { url = "https://www.sqlite.org/2024/sqlite-autoconf-3470200.tar.gz";
              sha256 = "f1b2ee412c28d7472bc95ba996368d6f0cdcf00362affdadb27ed286c179540b"; };
      deps = [ self.zlib.gcc self.readline.gcc self.ncurses.gcc ];
      configureFlags = [ "--enable-shared" ];
    };

    libyaml = pkg {
      pname = "libyaml"; version = "0.2.5";
      src = { url = "https://github.com/yaml/libyaml/releases/download/0.2.5/yaml-0.2.5.tar.gz";
              sha256 = "c642ae9b75fee120b2d96c712538bd2cf283228d2337df2cf2988e3c02678ef4"; };
    };

    libtasn1 = pkg {
      pname = "libtasn1"; version = "4.19.0";
      src = { url = "https://mirrors.kernel.org/gnu/libtasn1/libtasn1-4.19.0.tar.gz";
              sha256 = "1613f0ac1cf484d6ec0ce3b8c06d56263cc7242f1c23b30d82d23de345a63f7a"; };
      preConfigure = gnulibFix;
    };

    lz4 = pkg {
      pname = "lz4"; version = "1.10.0";
      src = { url = "https://github.com/lz4/lz4/releases/download/v1.10.0/lz4-1.10.0.tar.gz";
              sha256 = "537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b"; };
      buildSystem = "custom";
      customBuild = ''
        gmake -j"$(nproc)" CC="$CC" PREFIX="$out"
        gmake install PREFIX="$out" CC="$CC"
      '';
    };

    libgpgerror = pkg {
      pname = "libgpg-error"; version = "1.50";
      src = { url = "https://www.gnupg.org/ftp/gcrypt/libgpg-error/libgpg-error-1.50.tar.bz2";
              sha256 = "69405349e0a633e444a28c5b35ce8f14484684518a508dc48a089992fe93e20a"; };
      # illumos doesn't declare `environ` in unistd.h; libgpg-error's
      # spawn-posix.c uses it bare -> 'environ undeclared'. Inject the extern.
      preConfigure = gnulibFix + ''
        for f in $(find . -name 'spawn-posix.c'); do
          sed -i '1i extern char **environ;' "$f" || true
        done
      '';
      configureFlags = [ "--enable-shared" "--disable-doc" "--disable-tests" ];
    };

    # ======================================================================
    # WAVE 2 — interpreters + tier-2/3 libs & tools
    # ======================================================================

    # ---- tier-2 libs, layer 2 (deps now cached) ----------------------------
    mpfr = pkg {
      pname = "mpfr"; version = "4.2.1";
      src = { url = "https://mirrors.kernel.org/gnu/mpfr/mpfr-4.2.1.tar.xz";
              sha256 = "277807353a6726978996945af13e52829e3abd7a9a5b7fb2793894e18f1fcbb2"; };
      deps = [ self.gmp.gcc ];
      configureFlags = [ "--with-gmp=${self.gmp.gcc}" "--enable-shared" ];
    };

    mpc = pkg {
      pname = "mpc"; version = "1.3.1";
      src = { url = "https://mirrors.kernel.org/gnu/mpc/mpc-1.3.1.tar.gz";
              sha256 = "ab642492f5cf882b74aa0cb730cd410a81edcdbec895183ce930e706c1c759b8"; };
      deps = [ self.gmp.gcc self.mpfr.gcc ];
      configureFlags = [ "--with-gmp=${self.gmp.gcc}" "--with-mpfr=${self.mpfr.gcc}" "--enable-shared" ];
    };

    libunistring = pkg {
      pname = "libunistring"; version = "1.2";
      src = { url = "https://mirrors.kernel.org/gnu/libunistring/libunistring-1.2.tar.xz";
              sha256 = "632bd65ed74a881ca8a0309a1001c428bd1cbd5cd7ddbf8cedcd2e65f4dcdc44"; };
      preConfigure = gnulibFix;
      configureFlags = [ "--enable-shared" ];
    };

    libidn2 = pkg {
      pname = "libidn2"; version = "2.3.7";
      src = { url = "https://mirrors.kernel.org/gnu/libidn/libidn2-2.3.7.tar.gz";
              sha256 = "4c21a791b610b9519b9d0e12b8097bf2f359b12f8dd92647611a929e6bfd7d64"; };
      deps = [ self.libunistring.gcc ];
      preConfigure = gnulibFix;
      configureFlags = [ "--enable-shared" "--with-libunistring-prefix=${self.libunistring.gcc}" ];
    };

    libedit = pkg {
      pname = "libedit"; version = "20240808-3.1";
      src = { url = "https://thrysoee.dk/editline/libedit-20240808-3.1.tar.gz";
              sha256 = "5f0573349d77c4a48967191cdd6634dd7aa5f6398c6a57fe037cc02696d6099f"; };
      deps = [ self.ncurses.gcc ];
      configureFlags = [ "--enable-shared" ];
      # libedit ships its own termcap prototypes; ncurses' ncursesw/termcap.h
      # conflicts (tgetstr/tgetflag/tgetnum sigs). Use ncurses' plain include
      # dir only (not ncursesw) so libedit's own decls win.
      env = { CPPFLAGS = "-I${self.ncurses.gcc}/include"; };
    };

    jsonc = pkg {
      pname = "json-c"; version = "0.17";
      src = { url = "https://s3.amazonaws.com/json-c_releases/releases/json-c-0.17.tar.gz";
              sha256 = "7550914d58fb63b2c3546f3ccfbe11f1c094147bd31a69dcd23714d7956159e6"; };
      buildSystem = "custom";
      # json-c is cmake-only upstream; but it also ships an autotools path in
      # older releases. 0.17 is cmake. Build with a tiny cmake-less approach is
      # painful, so use the bundled autotools tag if present, else fall back.
      customBuild = ''
        if [ -x ./configure ]; then
          ./configure --prefix="$out" --enable-shared
          gmake -j"$(nproc)"; gmake install
        else
          echo "FATAL: json-c needs cmake (deferred to cmake wave)" >&2; exit 1
        fi
      '';
    };

    gdbm = pkg {
      pname = "gdbm"; version = "1.24";
      src = { url = "https://mirrors.kernel.org/gnu/gdbm/gdbm-1.24.tar.gz";
              sha256 = "695e9827fdf763513f133910bc7e6cfdb9187943a4fec943e57449723d2b8dbf"; };
      deps = [ self.readline.gcc self.ncurses.gcc ];
      preConfigure = gnulibFix;
      configureFlags = [ "--enable-shared" "--enable-libgdbm-compat" ];
    };

    berkeleydb = pkg {
      pname = "berkeley-db"; version = "5.3.28";
      src = { url = "https://download.oracle.com/berkeley-db/db-5.3.28.tar.gz";
              sha256 = "e0a992d740709892e81f9d93f06daf305cf73fb81b545afe72478043172c3628"; };
      buildSystem = "custom";
      # BDB's dist/configure lives under build_unix; the atomic-ops inline asm
      # in dbinc/atomic.h uses __atomic_compare_exchange which clashes with a
      # macro on some toolchains — the standard OI fix renames the member.
      # illumos: BDB 4.8+ removed FCNTL mutexes; force POSIX pthread mutexes.
      customBuild = ''
        sed -i 's/__atomic_compare_exchange/__db_atomic_compare_exchange/g' src/dbinc/atomic.h 2>/dev/null || true
        cd build_unix
        ../dist/configure --prefix="$out" --enable-shared --disable-static --enable-cxx \
          --with-mutex=POSIX/pthreads
        gmake -j"$(nproc)"
        gmake install
      '';
    };

    nspr = pkg {
      pname = "nspr"; version = "4.35";
      src = { url = "https://ftp.mozilla.org/pub/nspr/releases/v4.35/src/nspr-4.35.tar.gz";
              sha256 = "7ea3297ea5969b5d25a5dd8d47f2443cda88e9ee746301f6e1e1426f8a6abc8f"; };
      buildSystem = "custom";
      customBuild = ''
        cd nspr
        ./configure --prefix="$out" --enable-64bit
        gmake -j"$(nproc)"
        gmake install
      '';
    };

    libpsl = pkg {
      pname = "libpsl"; version = "0.21.5";
      src = { url = "https://github.com/rockdaboot/libpsl/releases/download/0.21.5/libpsl-0.21.5.tar.gz";
              sha256 = "1dcc9ceae8b128f3c0b3f654decd0e1e891afc6ff81098f227ef260449dae208"; };
      deps = [ self.libidn2.gcc self.libunistring.gcc ];
      configureFlags = [ "--enable-shared" ];
    };

    gettext = pkg {
      pname = "gettext"; version = "0.22.5";
      src = { url = "https://mirrors.kernel.org/gnu/gettext/gettext-0.22.5.tar.gz";
              sha256 = "ec1705b1e969b83a9f073144ec806151db88127f5e40fe5a94cb6c8fa48996a0"; };
      deps = [ self.libunistring.gcc self.ncurses.gcc ];
      preConfigure = gnulibFix;
      configureFlags = [ "--enable-shared" "--disable-java" "--disable-csharp"
                         "--without-emacs" "--disable-openmp" ];
    };

    # ---- tier-2/3 tools ----------------------------------------------------
    gawk = pkg {
      pname = "gawk"; version = "5.3.1";
      src = { url = "https://mirrors.kernel.org/gnu/gawk/gawk-5.3.1.tar.xz";
              sha256 = "694db764812a6236423d4ff40ceb7b6c4c441301b72ad502bb5c27e00cd56f78"; };
      deps = [ self.gmp.gcc self.mpfr.gcc self.readline.gcc self.ncurses.gcc ];
      preConfigure = gnulibFix;
      configureFlags = [ "--disable-nls" ];
    };

    gsed = pkg {
      pname = "gsed"; version = "4.9";
      src = { url = "https://mirrors.kernel.org/gnu/sed/sed-4.9.tar.xz";
              sha256 = "6e226b732e1cd739464ad6862bd1a1aba42d7982922da7a53519631d24975181"; };
      preConfigure = gnulibFix;
    };

    gtar = pkg {
      pname = "gnu-tar"; version = "1.35";
      src = { url = "https://mirrors.kernel.org/gnu/tar/tar-1.35.tar.xz";
              sha256 = "4d62ff37342ec7aed748535323930c7cf94acf71c3591882b26a7ea50f3edc16"; };
      preConfigure = gnulibFix;
      configureFlags = [ "--disable-nls" ];
      # builds run as root in the illumos builder; tar's configure refuses root
      # unless told the fifo-mknod check is safe to skip.
      env = { FORCE_UNSAFE_CONFIGURE = "1"; };
    };

    gzip = pkg {
      pname = "gzip"; version = "1.14";
      src = { url = "https://mirrors.kernel.org/gnu/gzip/gzip-1.14.tar.xz";
              sha256 = "01a7b881bd220bfdf615f97b8718f80bdfd3f6add385b993dcf6efd14e8c0ac6"; };
      preConfigure = gnulibFix;
      configureFlags = [ "--disable-nls" ];
    };

    help2man = pkg {
      pname = "help2man"; version = "1.49.3";
      src = { url = "https://mirrors.kernel.org/gnu/help2man/help2man-1.49.3.tar.xz";
              sha256 = "4d7e4fdef2eca6afe07a2682151cea78781e0a4e8f9622142d9f70c083a2fd4f"; };
      preConfigure = gnulibFix;
    };

    texinfo = pkg {
      pname = "texinfo"; version = "7.1";
      src = { url = "https://mirrors.kernel.org/gnu/texinfo/texinfo-7.1.tar.xz";
              sha256 = "deeec9f19f159e046fdf8ad22231981806dac332cc372f1c763504ad82b30953"; };
      deps = [ self.ncurses.gcc ];
      preConfigure = gnulibFix;
      # illumos <term.h> declares tputs' putc arg as int(*)(char); ncurses uses
      # int(*)(int). gcc-14 makes the mismatch a hard error — downgrade it.
      env = { CFLAGS = "-Wno-error=incompatible-pointer-types -fcommon"; };
      configureFlags = [ "--disable-nls" ];
    };

    samurai = pkg {
      pname = "samurai"; version = "1.2";
      src = { url = "https://github.com/michaelforney/samurai/releases/download/1.2/samurai-1.2.tar.gz";
              sha256 = "3b8cf51548dfc49b7efe035e191ff5e1963ebc4fe8f6064a5eefc5343eaf78a5"; };
      buildSystem = "custom";
      customBuild = ''
        # illumos: samurai's log.c uses getline() which needs __EXTENSIONS__.
        # Do NOT set _POSIX_C_SOURCE — it renames struct timespec tv_nsec ->
        # __tv_nsec and breaks graph.c. __EXTENSIONS__ alone gives both.
        gmake -j"$(nproc)" CC="$CC" CFLAGS="-D__EXTENSIONS__ -O2"
        mkdir -p "$out/bin"; cp -a samu "$out/bin/"
        ln -sf samu "$out/bin/ninja" 2>/dev/null || true
      '';
    };

    luajit = pkg {
      pname = "luajit"; version = "2.1";
      src = { url = "https://github.com/LuaJIT/LuaJIT/archive/refs/heads/v2.1.tar.gz";
              sha256 = "SKIP"; };
      buildSystem = "custom";
      # LuaJIT: plain make; needs the store CC. Solaris build works with
      # TARGET_SYS=SunOS auto-detected. Install to $out.
      customBuild = ''
        gmake -j"$(nproc)" CC="$CC" PREFIX="$out" amalg
        gmake install PREFIX="$out" CC="$CC"
      '';
    };

    tcl = pkg {
      pname = "tcl"; version = "8.6.14";
      src = { url = "https://prdownloads.sourceforge.net/tcl/tcl8.6.14-src.tar.gz";
              sha256 = "5880225babf7954c58d4fb0f5cf6279104ce1cd6aa9b71e9a6322540e1c4de66"; };
      buildSystem = "custom";
      deps = [ self.zlib.gcc ];
      # build the tcl CORE only; the bundled pkgs/ (itcl, sqlite3, thread, tdbc)
      # fail on illumos (alloca implicit decl). Core tclsh + libtcl is what the
      # module ecosystem needs; add-on pkgs can build separately later.
      customBuild = ''
        cd unix
        ./configure --prefix="$out" --enable-64bit --enable-shared
        gmake -j"$(nproc)" binaries libraries
        gmake install-binaries install-libraries install-headers
      '';
    };

    scons = pkg {
      pname = "scons"; version = "4.8.1";
      src = { url = "https://github.com/SCons/scons/archive/refs/tags/4.8.1.tar.gz";
              sha256 = "9735ac24f345a11c76561991e3c3bdf943f97c772ded54156243e7f4ea5f4bc5"; };
      buildSystem = "custom";
      # scons is a pure-python tool; install as a python zipapp-ish package
      # under $out. Needs python3 present (host has 3.9). Defer full packaging;
      # just stage the scons tree + a launcher.
      customBuild = ''
        mkdir -p "$out/lib/scons" "$out/bin"
        cp -a . "$out/lib/scons/"
        cat > "$out/bin/scons" <<EOF
#!/usr/bin/env bash
exec python3 "$out/lib/scons/scripts/scons.py" "\$@"
EOF
        chmod +x "$out/bin/scons"
      '';
    };

    # ---- WAVE 4 tier-3 TOOLS (autotools/make against cached deps) ----------
    # NOTE: plain <pname>-<version> store names (mk-userland-pkg). Built via
    # nix-build on a builder that has pulled the renamed toolchain + deps.
    jq = pkg {
      pname = "jq"; version = "1.7.1";
      src = { url = "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-1.7.1.tar.gz";
              sha256 = "478c9ca129fd2e3443fe27314b455e211e0d8c60bc8ff7df703873deeee580c2"; };
      # Link the CACHED external oniguruma (wave-6) instead of the bundled copy:
      # jq's vendored oniguruma hits an illumos regcomp portability wall. The
      # external lib is already ported (alloca fix) + cached. deps supply
      # -I/-L/-R oniguruma; --with-oniguruma=<prefix> points configure at it.
      deps = [ self.oniguruma.gcc ];
      preConfigure = illumosExt;
      configureFlags = [ "--with-oniguruma=${self.oniguruma.gcc}" "--disable-maintainer-mode" ];
    };

    tree = pkg {
      pname = "tree"; version = "2.1.3";
      src = { url = "https://gitlab.com/OldManProgrammer/unix-tree/-/archive/2.1.3/unix-tree-2.1.3.tar.gz";
              sha256 = "f554a1b62233b96fa8eaa2d85e91bc62cad80ee441fd591380f16cdfbe3e8868"; };
      buildSystem = "custom";
      # illumos declares `struct comment` in a system header pulled in via
      # tree's includes; tree.h defines its own `struct comment` -> redefinition
      # error. Rename tree's struct (and its uses) to `tree_comment` throughout
      # the sources so it can't collide. Keep __EXTENSIONS__ for strcasecmp.
      customBuild = ''
        for f in *.c *.h; do
          [ -f "$f" ] || continue
          sed -i 's/struct comment/struct tree_comment/g' "$f"
        done
        gmake -j"$(nproc)" CC="$CC" CFLAGS="-D__EXTENSIONS__ -O2 -m64" MANDIR="$out/share/man" PREFIX="$out"
        gmake install PREFIX="$out" MANDIR="$out/share/man"
      '';
    };

    nano = pkg {
      pname = "nano"; version = "8.2";
      src = { url = "https://www.nano-editor.org/dist/v8/nano-8.2.tar.xz";
              sha256 = "d5ad07dd862facae03051c54c6535e54c7ed7407318783fcad1ad2d7076fffeb"; };
      deps = [ self.ncurses.gcc ];
      preConfigure = illumosExt;
      configureFlags = [ "--disable-nls" "--enable-utf8" ];
    };

    wget = pkg {
      pname = "wget"; version = "1.24.5";
      src = { url = "https://mirrors.kernel.org/gnu/wget/wget-1.24.5.tar.gz";
              sha256 = "fa2dc35bab5184ecbc46a9ef83def2aaaa3f4c9f3c97d4bd19dcb07d4da637de"; };
      deps = [ self.openssl3.gcc self.zlib.gcc self.pcre2.gcc ];
      preConfigure = gnulibFix + illumosExt;
      configureFlags = [ "--with-ssl=openssl" "--disable-nls" "--without-libpsl" ];
    };

    rsync = pkg {
      pname = "rsync"; version = "3.3.0";
      src = { url = "https://download.samba.org/pub/rsync/src/rsync-3.3.0.tar.gz";
              sha256 = "7399e9a6708c32d678a72a63219e96f23be0be2336e50fd1348498d07041df90"; };
      deps = [ self.zlib.gcc self.zstd.gcc self.lz4.gcc self.openssl3.gcc ];
      # bundled popt; skip external xxhash. Man pages: rsync ships pre-built
      # *.1 in the tarball; DON'T pass --disable-md2man (it zeroes MAKE_MAN and
      # skips installing even the shipped man). commonmark isn't needed to
      # install the pre-generated pages.
      preConfigure = illumosExt;
      configureFlags = [ "--disable-xxhash" "--with-included-popt" ];
    };

    htop = pkg {
      pname = "htop"; version = "3.3.0";
      src = { url = "https://github.com/htop-dev/htop/releases/download/3.3.0/htop-3.3.0.tar.xz";
              sha256 = "a69acf9b42ff592c4861010fce7d8006805f0d6ef0e8ee647a6ee6e59b743d5c"; };
      deps = [ self.ncurses.gcc ];
      # illumos math.h hides NAN/isgreater behind __C99FEATURES__.
      preConfigure = ''
        export CFLAGS="''${CFLAGS:-} -D__EXTENSIONS__ -D__C99FEATURES__"
        export CPPFLAGS="''${CPPFLAGS:-} -D__EXTENSIONS__ -D__C99FEATURES__"
      '';
      configureFlags = [ "--disable-unicode" "--enable-static" ];
    };

    # ---- INTERPRETERS (highest leverage) -----------------------------------
    # perl 5.42 — the OI runtime perl. Configure is perl's own metaconfig
    # `Configure`, not autoconf. -de = non-interactive defaults; pass hints
    # via -D. Link against store zlib/bzip2/gdbm. RUNPATH relocated by the
    # standard mk-userland fixup.
    perl = pkg {
      pname = "perl"; version = "5.42.0";
      src = { url = "https://www.cpan.org/src/5.0/perl-5.42.0.tar.gz";
              sha256 = "e093ef184d7f9a1b9797e2465296f55510adb6dab8842b0c3ed53329663096dc"; };
      deps = [ self.zlib.gcc self.bzip2.gcc self.gdbm.gcc ];
      buildSystem = "custom";
      customBuild = ''
        # perl's Configure wants a plain compiler string; hand it the wrapper.
        sh Configure -des \
          -Dprefix="$out" \
          -Dcc="$CC" \
          -Dld="$CC" \
          -Duseshrplib \
          -Dusethreads \
          -Dcccdlflags='-fPIC' \
          -Dlddlflags='-G' \
          -Doptimize='-O2' \
          -Dccflags="$CFLAGS" \
          -Dldflags="$LDFLAGS" \
          -A ccflags="-I${self.zlib.gcc}/include -I${self.bzip2.gcc}/include -I${self.gdbm.gcc}/include" \
          -Ud_dosuid
        gmake -j"$(nproc)"
        gmake install
      '';
    };

    # python 3.9 — the OI default runtime python. autoconf. Link the full
    # optional-module dep set so the stdlib C extensions build.
    python39 = pkg {
      pname = "python-39"; version = "3.9.20";
      src = { url = "https://www.python.org/ftp/python/3.9.20/Python-3.9.20.tar.xz";
              sha256 = "6b281279efd85294d2d6993e173983a57464c0133956fbbb5536ec9646beaf0c"; };
      deps = [ self.zlib.gcc self.bzip2.gcc self.xz.gcc self.libffi.gcc
               self.openssl3.gcc self.ncurses.gcc self.readline.gcc
               self.sqlite.gcc self.expat.gcc self.gdbm.gcc ];
      buildSystem = "custom";
      customBuild = ''
        export CFLAGS="$CFLAGS -DHAVE_CLOCK_GETTIME=1"
        export LDFLAGS="$LDFLAGS -lsocket -lnsl -lresolv"
        ./configure --prefix="$out" \
          --enable-shared \
          --with-openssl=${self.openssl3.gcc} \
          --with-system-ffi \
          --with-system-expat \
          --with-ensurepip=install \
          --without-static-libpython \
          ac_cv_func_wait3=yes ac_cv_func_wait4=yes
        gmake -j"$(nproc)"
        gmake install COMPILEALL_OPTS="-j1"
        # precompile stdlib .pyc so first import doesn't mutate the store path
        "$out/bin/python3.9" -m compileall -q -f "$out/lib/python3.9" 2>/dev/null || true
      '';
    };

    # python 3.13 — the newer OI runtime python.
    # NOTE: bzip2 dropped from deps — wave-1 bzip2 ships only static libbz2.a
    # (no PIC .so), so linking _bz2.so fails. python39 silently skips _bz2 for
    # the same reason. TODO(wave-3): rebuild wave-1 bzip2 with a shared libbz2.so
    # in wave-3, then re-add here + to python39 to get the _bz2 stdlib module.
    python313 = pkg {
      pname = "python-313"; version = "3.13.1";
      src = { url = "https://www.python.org/ftp/python/3.13.1/Python-3.13.1.tar.xz";
              sha256 = "9cf9427bee9e2242e3877dd0f6b641c1853ca461f39d6503ce260a59c80bf0d9"; };
      deps = [ self.zlib.gcc self.xz.gcc self.libffi.gcc
               self.openssl3.gcc self.ncurses.gcc
               self.sqlite.gcc self.expat.gcc self.gdbm.gcc self.mpc.gcc ];
      buildSystem = "custom";
      customBuild = ''
        # illumos: _socket.so references hstrerror (libresolv) + socket/nsl
        # symbols; python's ext link doesn't add them by default -> load-time
        # relocation error. Force them onto the link line.
        export LDFLAGS="$LDFLAGS -lsocket -lnsl -lresolv"
        ./configure --prefix="$out" \
          --enable-shared \
          --with-openssl=${self.openssl3.gcc} \
          --with-system-ffi \
          --with-system-expat \
          --with-ensurepip=install \
          --without-static-libpython \
          --disable-test-modules
        gmake -j"$(nproc)"
        # illumos has no multiprocessing 'forkserver' start method; python
        # 3.13's install-time compileall defaults to it -> ValueError. Force
        # sequential compile with COMPILEALL_OPTS=-j0.
        gmake install COMPILEALL_OPTS="-j1"
        "$out/bin/python3.13" -m compileall -q -f -j1 "$out/lib/python3.13" 2>/dev/null || true
      '';
    };

    # ======================================================================
    # WAVE 3 PROOF — one Perl XS module + one Python C-ext module, to prove
    # the module mega-cycle recipe works against the cached interpreters.
    # These are the uniform recipes wave-3 fans out: perl Makefile.PL / pip.
    # ======================================================================

    # Perl XS module: List::Util is core, so use a real CPAN XS dist that many
    # modules depend on — Time::HiRes is core too; pick Params::Util (XS).
    perlParamsUtil = pkg {
      pname = "perl-params-util"; version = "1.102";
      src = { url = "https://cpan.metacpan.org/authors/id/R/RE/REHSACK/Params-Util-1.102.tar.gz";
              sha256 = "499bb1b482db24fda277a51525596ad092c2bd51dd508fa8fec2e9f849097402"; };
      deps = [ self.perl.gcc ];
      buildSystem = "custom";
      customBuild = ''
        PERL=${self.perl.gcc}/bin/perl
        "$PERL" Makefile.PL PREFIX="$out" INSTALL_BASE="$out"
        gmake -j"$(nproc)"
        gmake install
      '';
    };

    # Python C-ext module via pip (proves pip + wheel build + C compile against
    # the cached python). MarkupSafe has a small C speedup ext.
    pyMarkupSafe = pkg {
      pname = "python39-markupsafe"; version = "2.1.5";
      src = { url = "https://files.pythonhosted.org/packages/87/5b/aae44c6655f3801e81aa3eef09dbbf012431987ba564d7231722f68df02d/MarkupSafe-2.1.5.tar.gz";
              sha256 = "d283d37a890ba4c1ae73ffadf8046435c76e7bc2247bbb63c00bd1a709c6544b"; };
      deps = [ self.python39.gcc ];
      buildSystem = "custom";
      customBuild = ''
        PY=${self.python39.gcc}/bin/python3.9
        export CC="$CC"
        "$PY" -m pip install --no-build-isolation --no-index --prefix="$out" . 2>&1 | tail -20
      '';
    };

    # ======================================================================
    # WAVE 3 module fan-out helpers (135 modules built+cached with these,
    # scripts/oi-{pymod,plmod}.sh is the imperative form; these are the
    # declarative pkg{} form for wave-4). gcc-14 is the REAL compiler: the
    # cached interpreters' sysconfig/Config cc points at a dead build-time
    # wrapper, so C-ext / XS builds MUST force CC or they fall back / fail.
    # ======================================================================

    # ---- WAVE 6 heavy tier-3 tools (deferred from wave 5) ------------------
    libevent = pkg {
      pname = "libevent"; version = "2.1.12";
      src = { url = "https://github.com/libevent/libevent/releases/download/release-2.1.12-stable/libevent-2.1.12-stable.tar.gz";
              sha256 = "92e6de1be9ec176428fd2367677e61ceffc2ee1cb119035037a27d346b0403bb"; };
      preConfigure = illumosExt;
      configureFlags = [ "--disable-samples" "--disable-openssl" ];
    };

    tmux = pkg {
      pname = "tmux"; version = "3.4";
      src = { url = "https://github.com/tmux/tmux/releases/download/3.4/tmux-3.4.tar.gz";
              sha256 = "551ab8dea0bf505c0ad6b7bb35ef567cdde0ccb84357df142c254f35a23e19aa"; };
      deps = [ self.libevent.gcc self.ncurses.gcc ];
      # The STORE ncurses ships widec headers ONLY under include/ncursesw/
      # (curses.h, term.h, ...), no bare include/ncurses.h. tmux's configure
      # otherwise finds the HOST /usr/include/ncurses/ncurses.h and emits
      # `#include <ncurses/ncurses.h>`, which then fails on the sliced include
      # path (host ncurses_dll.h not reachable). Force the header probes:
      # reject the host <ncurses/ncurses.h> and <ncurses.h>, accept the store's
      # <curses.h> (from include/ncursesw, put FIRST on CPPFLAGS). Point
      # pkg-config at libevent + ncursesw too.
      # The STORE ncurses ships widec headers ONLY under include/ncursesw/
      # and a pkg-config file named ncursesw.pc (no bare ncurses.pc). tmux's
      # configure does PKG_CHECK_MODULES([ncurses]) (bare name) -> misses the
      # store, falls back to a manual probe that finds HOST
      # /usr/include/ncurses and hardcodes -I/usr/include/ncurses into the
      # Makefile (before our store -I), so <ncurses.h> resolves to the host
      # header whose ncurses_dll.h is unreachable on the sliced include path.
      # Fix: expose an ncurses.pc -> ncursesw.pc alias in a private
      # PKG_CONFIG_PATH dir so tmux's pkg-config check hits the STORE ncurses.
      preConfigure = illumosExt + ''
        mkdir -p "$WORK/pc"
        for p in ${self.ncurses.gcc}/lib/pkgconfig/*.pc; do
          b=$(basename "$p"); ln -sf "$p" "$WORK/pc/$b"
        done
        ln -sf ${self.ncurses.gcc}/lib/pkgconfig/ncursesw.pc "$WORK/pc/ncurses.pc"
        export PKG_CONFIG_PATH="$WORK/pc:${self.libevent.gcc}/lib/pkgconfig:''${PKG_CONFIG_PATH:-}"
        export CPPFLAGS="-I${self.ncurses.gcc}/include/ncursesw ''${CPPFLAGS:-}"
        export CFLAGS="-I${self.ncurses.gcc}/include/ncursesw ''${CFLAGS:-}"
      '';
      configureFlags = [
        "ac_cv_header_ncurses_ncurses_h=no"
        "ac_cv_header_ncurses_h=no"
        "ac_cv_header_curses_h=yes"
      ];
    };

    zsh = pkg {
      pname = "zsh"; version = "5.9";
      src = { url = "https://sourceforge.net/projects/zsh/files/zsh/5.9/zsh-5.9.tar.xz/download";
              sha256 = "9b8d1ecedd5b5e81fbf1918e876752a7dd948e05c1a0dba10ab863842d45acd5"; };
      deps = [ self.ncurses.gcc self.pcre2.gcc ];
      # zsh's termcap.c defines its OWN boolcodes/numcodes/strcodes arrays
      # (`char *[]`) guarded by #ifndef HAVE_{BOOL,NUM,STR}CODES. Configure's
      # probe (`char **test = boolcodes`) fails to COMPILE against the store
      # ncurses term.h (which declares them `const char * const[]`), so it
      # leaves the macros undefined and zsh emits its conflicting copies ->
      # "conflicting types for 'boolcodes'". Since the store term.h DOES provide
      # them, define the HAVE_* macros directly so zsh uses ncurses' arrays.
      preConfigure = illumosExt + ''
        export CPPFLAGS="-DHAVE_BOOLCODES=1 -DHAVE_NUMCODES=1 -DHAVE_STRCODES=1 ''${CPPFLAGS:-}"
        export CFLAGS="-DHAVE_BOOLCODES=1 -DHAVE_NUMCODES=1 -DHAVE_STRCODES=1 -Wno-implicit-function-declaration -Wno-error=implicit-function-declaration ''${CFLAGS:-}"
      '';
      configureFlags = [
        "--disable-gdbm" "--enable-multibyte" "--with-tcsetpgrp"
      ];
    };

    curl = pkg {
      pname = "curl"; version = "8.9.1";
      src = { url = "https://curl.se/download/curl-8.9.1.tar.xz";
              sha256 = "f292f6cc051d5bbabf725ef85d432dfeacc8711dd717ea97612ae590643801e5"; };
      deps = [ self.openssl3.gcc self.zlib.gcc ];
      preConfigure = illumosExt;
      configureFlags = [
        "--with-openssl=${self.openssl3.gcc}"
        "--with-zlib=${self.zlib.gcc}"
        "--without-libpsl" "--disable-ldap"
        "--without-libidn2" "--without-nghttp2" "--without-brotli" "--without-zstd"
        # curl auto-detects host -lgsasl but we lack gsasl.h in the sandbox.
        # The flag is --without-libgsasl (NOT --without-gsasl); belt-and-braces
        # also pin the search-cache var so the probe can't re-enable it.
        "--without-libgsasl" "ac_cv_search_gsasl_init=no"
      ];
    };

    libxslt = pkg {
      pname = "libxslt"; version = "1.1.39";
      src = { url = "https://download.gnome.org/sources/libxslt/1.1/libxslt-1.1.39.tar.xz";
              sha256 = "2a20ad621148339b0759c4d4e96719362dee64c9a096dbba625ba053846349f0"; };
      deps = [ self.libxml2.gcc self.zlib.gcc ];
      configureFlags = [
        "--without-python"
        "--with-libxml-prefix=${self.libxml2.gcc}"
        "--without-crypto"
      ];
    };

    oniguruma = pkg {
      pname = "oniguruma"; version = "6.9.9";
      src = { url = "https://github.com/kkos/oniguruma/releases/download/v6.9.9/onig-6.9.9.tar.gz";
              sha256 = "60162bd3b9fc6f4886d4c7a07925ffd374167732f55dce8c491bfd9cd818a6cf"; };
      # illumos: alloca needs <alloca.h>; map to the gcc builtin so regint.h compiles.
      preConfigure = illumosExt + ''
        export CFLAGS="''${CFLAGS:-} -Dalloca=__builtin_alloca"
      '';
    };

    cmake = pkg {
      pname = "cmake"; version = "3.29.6";
      src = { url = "https://github.com/Kitware/CMake/releases/download/v3.29.6/cmake-3.29.6.tar.gz";
              sha256 = "1391313003b83d48e2ab115a8b525a557f78d8c1544618b48d1d90184a10f0af"; };
      deps = [ self.openssl3.gcc self.zlib.gcc self.expat.gcc self.bzip2.gcc self.xz.gcc self.zstd.gcc self.ncurses.gcc ];
      buildSystem = "custom";
      # cmake bootstraps itself; use bundled libs to avoid a system-lib hunt.
      customBuild = ''
        ${illumosExt}
        ./bootstrap --prefix="$out" --parallel="$(nproc)" --no-qt-gui \
          -- -DCMAKE_USE_OPENSSL=ON -DOPENSSL_ROOT_DIR=${self.openssl3.gcc}
        gmake -j"$(nproc)"
        gmake install
      '';
    };

    git = pkg {
      pname = "git"; version = "2.45.2";
      src = { url = "https://mirrors.edge.kernel.org/pub/software/scm/git/git-2.45.2.tar.xz";
              sha256 = "51bfe87eb1c02fed1484051875365eeab229831d30d0cec5d89a14f9e40e9adb"; };
      deps = [ self.openssl3.gcc self.zlib.gcc self.curl.gcc self.expat.gcc self.pcre2.gcc ];
      preConfigure = illumosExt;
      # git's gitweb install shells out to /usr/ucb/install (absent here) and
      # its Makefiles otherwise assume a BSD/GNU install(1). Disable gitweb and
      # point INSTALL at GNU install (git honours the INSTALL make var). NO_TCLTK
      # for the (already-disabled) gui. Threaded through make + install phases.
      makeFlags = [ "NO_GITWEB=1" "NO_TCLTK=1" "INSTALL=/usr/gnu/bin/install" ];
      installFlags = [ "NO_GITWEB=1" "NO_TCLTK=1" "INSTALL=/usr/gnu/bin/install" ];
      configureFlags = [
        "--with-openssl=${self.openssl3.gcc}"
        "--with-zlib=${self.zlib.gcc}"
        "--with-curl=${self.curl.gcc}"
        "--with-expat=${self.expat.gcc}"
        "--with-libpcre2=${self.pcre2.gcc}"
        "--without-tcltk" "--without-iconv"
        "ac_cv_fread_reads_directories=no" "ac_cv_snprintf_returns_bogus=no"
      ];
    };

    # ---- pkgsrc illumos-patch mining (see docs/design-pkgsrc-patches.md) ----
    # Each of these was stuck/unbuilt in prior waves; NetBSD pkgsrc's per-package
    # patches/ + Makefile SunOS conditionals carry the illumos portability fix.
    # Harvested via scripts/pkgsrc-harvest.sh; patch files live in
    # pkgs/illumos/patches/pkgsrc/. This is the wave-8 pattern generalised.

    # aspell: Solaris /usr/include/locale.h pulls in libintl.h which #defines
    # printf/vprintf -> collides with common/ostream.hpp method names (a
    # "macro/redefinition" class illumos build break). pkgsrc's patch-an #undefs
    # them after <libintl.h>; patch-prog_aspell.cpp reorders errors.hpp before
    # aspell.h so the C++ compile succeeds. Needs ncurses.
    aspell = pkg {
      pname = "aspell"; version = "0.60.8.2";
      src = { url = "https://ftpmirror.gnu.org/aspell/aspell-0.60.8.2.tar.gz";
              sha256 = "57fe4863eae6048f72245a8575b44b718fb85ca14b9f8c0afc41b254dfd76919"; };
      deps = [ self.ncurses.gcc ];
      patches = [ ./patches/pkgsrc/aspell-libintl-macros.patch
                  ./patches/pkgsrc/aspell-errors-hpp-order.patch ];
      preConfigure = illumosExt;
      configureFlags = [ "--disable-static" ];
    };

    # socat: needs the illumos feature-test macros (__EXTENSIONS__/_XOPEN_SOURCE)
    # for the POSIX network + termios symbols Solaris libc hides. pkgsrc builds it
    # with no source patch once OPSYS=SunOS sets the right defines; illumosExt is
    # our equivalent. Unbuilt Hipster-current tail (net/socat).
    socat = pkg {
      pname = "socat"; version = "1.8.0.3";
      src = { url = "http://www.dest-unreach.org/socat/download/socat-1.8.0.3.tar.gz";
              sha256 = "a9f9eb6cfb9aa6b1b4b8fe260edbac3f2c743f294db1e362b932eb3feca37ba4"; };
      preConfigure = illumosExt;
      # socat's configure auto-probes optional libs; keep the surface to base libc
      # + openssl off (no readline/openssl in the sandbox include path here).
      configureFlags = [ "--disable-openssl" "--disable-readline" ];
    };

    # file / libmagic: portable C, but Solaris libc needs __EXTENSIONS__ for
    # some str* + the fts/getopt_long symbols. pkgsrc sysutils/file builds clean
    # with the feature-test macros; illumosExt supplies them. High-value base
    # (libmagic is a common dependency). Unbuilt.
    file = pkg {
      pname = "file"; version = "5.46";
      src = { url = "https://astron.com/pub/file/file-5.46.tar.gz";
              sha256 = "c9cc77c7c560c543135edc555af609d5619dbef011997e988ce40a3d75d86088"; };
      deps = [ self.zlib.gcc ];
      preConfigure = illumosExt;
      configureFlags = [ "--disable-static" "--enable-zlib" ];
    };

    # GNU libiconv: on Solaris the linker errors if libintl.so refers to a
    # libiconv.so in $prefix/lib while we also link ../lib/.libs (two libiconv.so).
    # pkgsrc's patch-src_Makefile.in avoids ../lib/libiconv.la at install; we build
    # standalone (no libintl in the sandbox) so the plain configure suffices +
    # illumosExt. A base charset lib many tools want. Not in the Hipster ledger
    # under this name (illumos ships its own iconv), but a clean pkgsrc-informed
    # build proves the workflow on a GNU-libtool package.
    libiconv = pkg {
      pname = "libiconv"; version = "1.18";
      src = { url = "https://ftpmirror.gnu.org/libiconv/libiconv-1.18.tar.gz";
              sha256 = "3b08f5f4f9b4eb82f151a7040bfd6fe6c6fb922efe4b1659c66ea933276965e8"; };
      preConfigure = illumosExt;
      configureFlags = [ "--disable-static" "--enable-shared" ];
    };

    # apr (Apache Portable Runtime): on illumos the network resolver symbols are
    # in libnsl, split out of libc. pkgsrc devel/apr sets LIBS.SunOS+=-lnsl (plus
    # its .if OPSYS==SunOS block). Thread -lnsl -lsocket into LDFLAGS + the
    # feature-test macros. Base dep for httpd/subversion/log4cxx/many. Unbuilt.
    apr = pkg {
      pname = "apr"; version = "1.7.6";
      src = { url = "https://archive.apache.org/dist/apr/apr-1.7.6.tar.gz";
              sha256 = "6a10e7f7430510600af25fabf466e1df61aaae910bf1dc5d10c44a4433ccc81d"; };
      preConfigure = illumosExt + ''
        export LDFLAGS="-lnsl -lsocket ''${LDFLAGS:-}"
      '';
      # apr's configure caches a few probes wrong on illumos; keep defaults + let
      # it detect. --disable-static keeps the shared libapr-1.so.
      configureFlags = [ "--disable-static" ];
    };

    # hunspell (spell-check library + tool; complements aspell): Solaris libc
    # gates some wide-char/locale symbols behind _XPG6. pkgsrc textproc/hunspell
    # sets CPPFLAGS.SunOS+=-D_XPG6; add it + illumosExt. Uses the 1.7.2 release
    # tarball (ships a generated ./configure; the github tag needs autogen). C++,
    # so exercises the gcc-14 C++ toolchain like aspell. Needs ncurses (readline
    # UI probe) — keep it minimal. Unbuilt.
    hunspell = pkg {
      pname = "hunspell"; version = "1.7.2";
      src = { url = "https://github.com/hunspell/hunspell/releases/download/v1.7.2/hunspell-1.7.2.tar.gz";
              sha256 = "11ddfa39afe28c28539fe65fc4f1592d410c1e9b6dd7d8a91ca25d85e9ec65b8"; };
      deps = [ self.ncurses.gcc ];
      preConfigure = illumosExt + ''
        export CPPFLAGS="-D_XPG6 ''${CPPFLAGS:-}"
        export CXXFLAGS="-D_XPG6 ''${CXXFLAGS:-}"
      '';
      configureFlags = [ "--disable-static" "--without-readline" ];
    };

    # ---- wave-14 pkgsrc illumos-patch mining (scale-up; see docs/design-pkgsrc-patches.md) ----
    # Hard-tail Hipster-current userland stuck on plain builds. NetBSD pkgsrc's
    # per-package Makefile SunOS conditionals (feature-test macros, -lnsl/-lsocket,
    # configure knobs) carry the illumos fix. Versions + knobs harvested via a
    # blobless sparse pkgsrc clone; SunOS blocks recorded in artifacts/wave14/.
    # Cached imaging/security libs (wave10) referenced by raw store path.

    # lynx: Solaris curses text browser. pkgsrc www/lynx sets
    # CONFIGURE_ENV.SunOS+=cf_cv_xopen_source=no (lynx's own xopen probe misfires
    # on illumos); we pass it + illumosExt. ncurses + zlib + gettext deps.
    lynx = pkg {
      pname = "lynx"; version = "2.9.2";
      src = { url = "https://invisible-mirror.net/archives/lynx/tarballs/lynx2.9.2.tar.bz2";
              sha256 = "7374b89936d991669e101f4e97f2c9592036e1e8cdaa7bafc259a77ab6fb07ce"; };
      deps = [ self.ncurses.gcc self.zlib.gcc ];
      preConfigure = illumosExt + ''
        # ncurses ships headers under include/ncursesw + ncursesw6-config; point
        # lynx's curses probe at them so it doesn't fall back to a host
        # ncurses5-config leak.
        for d in ${self.ncurses.gcc}/include/ncursesw ${self.ncurses.gcc}/include; do
          [ -d "$d" ] && export CPPFLAGS="-I$d ''${CPPFLAGS:-}"
        done
        export PATH="${self.ncurses.gcc}/bin:$PATH"
      '';
      configureFlags = [ "--with-screen=ncursesw" "--with-zlib" "--disable-nls" "--without-bzlib" "--without-brotli" ];
      env = { cf_cv_xopen_source = "no"; };
    };

    # links: twibright text-mode WWW browser (no X). pkgsrc www/links builds
    # clean on SunOS with the feature-test macros; disable graphics/X to keep it
    # text-only. libevent + openssl3 + zlib.
    links = pkg {
      pname = "links"; version = "2.30";
      src = { url = "http://links.twibright.com/download/links-2.30.tar.bz2";
              sha256 = "c4631c6b5a11527cdc3cb7872fc23b7f2b25c2b021d596be410dadb40315f166"; };
      deps = [ self.zlib.gcc self.openssl3.gcc self.libevent.gcc ];
      preConfigure = illumosExt;
      configureFlags = [ "--enable-graphics=no" "--without-x" ];
    };

    # screen: terminal multiplexer. screen 5.0.0's configure hard-requires
    # openpty() which illumos lacks; 4.9.1 detects the SVR4 /dev/ptmx path and
    # builds. pkgsrc sets CPPFLAGS+=-D_XOPEN_SOURCE=600 -D__EXTENSIONS__ under
    # SunOS (illumosExt). termcap from ncurses.
    screen = pkg {
      pname = "screen"; version = "4.9.1";
      src = { url = "https://mirror.csclub.uwaterloo.ca/gnu/screen/screen-4.9.1.tar.gz";
              sha256 = "26cef3e3c42571c0d484ad6faf110c5c15091fbf872b06fa7aa4766c7405ac69"; };
      deps = [ self.ncurses.gcc ];
      preConfigure = illumosExt + ''
        # screen 4.9.1 bundles a putenv.c that omits <string.h>; gcc-14 makes the
        # implicit strlen/strcpy a hard error. Force the header + downgrade to a
        # warning so the bundled fallback compiles (illumos has libc putenv).
        export CFLAGS="-include string.h -Wno-error=implicit-function-declaration ''${CFLAGS:-}"
      '';
      configureFlags = [ "--enable-telnet" "--enable-colors256" ];
      env = { ac_cv_func_putenv = "yes"; };
    };

    # the_silver_searcher (ag): fast code search. pcre2 + xz(lzma) + zlib + pthread.
    # Portable C; Solaris libc needs __EXTENSIONS__ for the fts/strn* symbols
    # (illumosExt). Autotools via ./configure (release tarball ships it).
    # the_silver_searcher (ag): fast code search. ag 2.2.0 uses the pcre1 API
    # (libpcre.pc), not pcre2 -> link the cached pcre-8.45 (wave10) + xz(lzma) +
    # zlib. Point pkg-config at the cached pcre's .pc. Solaris libc needs
    # __EXTENSIONS__ for fts/strn*. Autotools via ./configure.
    the_silver_searcher = pkg {
      pname = "the_silver_searcher"; version = "2.2.0";
      src = { url = "https://geoff.greer.fm/ag/releases/the_silver_searcher-2.2.0.tar.gz";
              sha256 = "d9621a878542f3733b5c6e71c849b9d1a830ed77cb1a1f6c2ea441d4b0643170"; };
      deps = [ self.pcre.gcc self.xz.gcc self.zlib.gcc ];
      preConfigure = illumosExt + ''
        export PKG_CONFIG_PATH="${self.pcre.gcc}/lib/pkgconfig:''${PKG_CONFIG_PATH:-}"
        # ag 2.2.0 has tentative-definition globals in headers; gcc-14 defaults to
        # -fno-common -> multiply-defined symbols. -fcommon restores the old ABI.
        export CFLAGS="-fcommon ''${CFLAGS:-}"
      '';
    };

    # cvs: classic version control. pkgsrc devel/scmcvs (cvs-1.12.13) — old GNU
    # autotools source; needs __EXTENSIONS__/_XOPEN_SOURCE for the getline/rpc
    # symbols. zlib. --disable-nls sidesteps the bundled-gettext gnulib break.
    cvs = pkg {
      pname = "cvs"; version = "1.12.13";
      src = { url = "https://ftp.halifax.rwth-aachen.de/gnu/non-gnu/cvs/source/feature/1.12.13/cvs-1.12.13.tar.bz2";
              sha256 = "78853613b9a6873a30e1cc2417f738c330e75f887afdaf7b3d0800cb19ca515e"; };
      deps = [ self.zlib.gcc ];
      preConfigure = illumosExt + gnulibFix;
      configureFlags = [ "--disable-nls" "--with-external-zlib" ];
    };

    # ncdu: ncurses disk-usage analyzer. pkgsrc sysutils/ncdu (1.19, C) needs only
    # curses; illumosExt for the feature-test macros. Autotools.
    ncdu = pkg {
      pname = "ncdu"; version = "1.19";
      src = { url = "https://dev.yorhel.nl/download/ncdu-1.19.tar.gz";
              sha256 = "30363019180cde0752c7fb006c12e154920412f4e1b5dc3090654698496bb17d"; };
      deps = [ self.ncurses.gcc ];
      preConfigure = illumosExt + ''
        for d in ${self.ncurses.gcc}/include/ncursesw ${self.ncurses.gcc}/include; do
          [ -d "$d" ] && export CPPFLAGS="-I$d ''${CPPFLAGS:-}"
        done
      '';
    };

    # tcsh: C shell with completion. Portable C; Solaris libc needs the feature
    # test macros for the termios/tty symbols. ncurses for termcap. illumos-clean.
    tcsh = pkg {
      pname = "tcsh"; version = "6.24.14";
      src = { url = "https://astron.com/pub/tcsh/tcsh-6.24.14.tar.gz";
              sha256 = "36880f258a63fc11fe72a65098b585ebc4ecdee24388b8ebec97e6ae8e485318"; };
      deps = [ self.ncurses.gcc ];
      preConfigure = illumosExt;
    };

    # nnn: fast ncurses file manager (Makefile build). ncurses + readline;
    # illumos needs the feature-test macros + ncursesw include path. O_2 make.
    nnn = pkg {
      pname = "nnn"; version = "5.0";
      src = { url = "https://github.com/jarun/nnn/releases/download/v5.0/nnn-v5.0.tar.gz";
              sha256 = "ba82d6c685bb3687521de2f576244f82558a4af9afeeedda434d5ecb1c029520"; };
      deps = [ self.ncurses.gcc self.readline.gcc ];
      buildSystem = "make";
      unpackSubdir = "nnn-v5.0";
      preConfigure = illumosExt + ''
        for d in ${self.ncurses.gcc}/include/ncursesw ${self.ncurses.gcc}/include; do
          [ -d "$d" ] && export CPPFLAGS="-I$d ''${CPPFLAGS:-}"
        done
        export PKG_CONFIG_PATH="${self.ncurses.gcc}/lib/pkgconfig:''${PKG_CONFIG_PATH:-}"
        export LDFLAGS="-lnsl -lsocket ''${LDFLAGS:-}"
      '';
      makeFlags = [ "O_NORL=0" ];
    };
    # (libpng/jpeg-turbo/freetype/lcms2/libtiff/libwebp) by raw store path +
    # zlib/xz/bzip2. pkgsrc graphics/ImageMagick sets LDFLAGS.SunOS+=-lsendfile
    # (illumos sendfile lives in libsendfile). Feature-test macros. No X/GTK.
    imagemagick = pkg {
      pname = "ImageMagick"; version = "7.1.2-21";
      src = { url = "https://imagemagick.org/archive/releases/ImageMagick-7.1.2-21.tar.xz";
              sha256 = "SKIP"; };
      deps = [ self.zlib.gcc self.xz.gcc self.bzip2.gcc self.libiconv.gcc
               libpngCached jpegCached freetypeCached lcms2Cached tiffCached webpCached ];
      preConfigure = illumosExt + ''
        export LDFLAGS="-lsendfile -lnsl -lsocket ''${LDFLAGS:-}"
      '';
      configureFlags = [ "--without-x" "--disable-static" "--without-modules"
                         "--with-png" "--with-jpeg" "--with-freetype" "--with-lcms"
                         "--with-tiff" "--with-webp" "--without-gvc" "--without-rsvg"
                         "--without-gslib" "--without-fontconfig" "--without-wmf"
                         "--without-magick-plus-plus" ];
    };

    # GraphicsMagick: ImageMagick fork. Same cached imaging libs + -lsendfile knob.
    graphicsmagick = pkg {
      pname = "GraphicsMagick"; version = "1.3.47";
      src = { url = "https://sourceforge.net/projects/graphicsmagick/files/graphicsmagick/1.3.47/GraphicsMagick-1.3.47.tar.xz/download";
              sha256 = "SKIP"; };
      deps = [ self.zlib.gcc self.xz.gcc self.bzip2.gcc self.libiconv.gcc
               libpngCached jpegCached freetypeCached lcms2Cached tiffCached webpCached ];
      preConfigure = illumosExt + ''
        export LDFLAGS="-lsendfile -lnsl -lsocket ''${LDFLAGS:-}"
      '';
      configureFlags = [ "--without-x" "--disable-static" "--with-png" "--with-jpeg"
                         "--with-ttf" "--with-lcms2" "--with-tiff" "--with-webp"
                         "--without-wmf" "--without-magick-plus-plus" ];
    };

    # groff: GNU roff document formatter (C++). No external deps beyond the C++
    # runtime; Solaris libc needs the feature-test macros for the wide-char
    # symbols. 1.23.0 (latest GNU release). Exercises gcc-14 C++.
    groff = pkg {
      pname = "groff"; version = "1.23.0";
      src = { url = "https://ftpmirror.gnu.org/groff/groff-1.23.0.tar.gz";
              sha256 = "6b9757f592b7518b4902eb6af7e54570bdccba37a871fddb2d30ae3863511c13"; };
      preConfigure = illumosExt + gnulibFix;
      configureFlags = [ "--without-x" ];
    };

    # plotutils: GNU vector-graphics utilities (libplot). pkgsrc graphics/plotutils
    # links libpng (cached wave10) + libiconv; build --without-x (no X11 libplotter).
    # Solaris libc needs __EXTENSIONS__. C++ libplotter too.
    plotutils = pkg {
      pname = "plotutils"; version = "2.6";
      src = { url = "https://ftpmirror.gnu.org/plotutils/plotutils-2.6.tar.gz";
              sha256 = "4f4222820f97ca08c7ea707e4c53e5a3556af4d8f1ab51e0da6ff1627ff433ab"; };
      deps = [ self.libiconv.gcc libpngCached ];
      preConfigure = illumosExt + gnulibFix;
      configureFlags = [ "--without-x" "--enable-libplotter" "--disable-static" ];
    };

    # neon: HTTP/WebDAV client library. pkgsrc www/neon links openssl + expat +
    # zlib + gettext. Base for cadaver/subversion. Solaris resolver in libnsl
    # -> thread -lnsl -lsocket. Feature-test macros via illumosExt.
    neon = pkg {
      pname = "neon"; version = "0.33.0";
      src = { url = "https://notroj.github.io/neon/neon-0.33.0.tar.gz";
              sha256 = "659a5cc9cea05e6e7864094f1e13a77abbbdbab452f04d751a8c16a9447cf4b8"; };
      deps = [ self.openssl3.gcc self.expat.gcc self.zlib.gcc ];
      preConfigure = illumosExt + ''
        export LDFLAGS="-lnsl -lsocket ''${LDFLAGS:-}"
      '';
      configureFlags = [ "--with-ssl=openssl" "--with-expat" "--enable-shared" "--disable-static" "--disable-nls" ];
    };

    # cadaver: WebDAV client. cadaver 0.23.3 only accepts neon 0.27-0.29, not
    # our 0.33 -> build its BUNDLED neon (--with-included-neon). readline UI +
    # expat + openssl + zlib. -lnsl -lsocket + feature-test macros.
    cadaver = pkg {
      pname = "cadaver"; version = "0.23.3";
      src = { url = "https://notroj.github.io/cadaver/cadaver-0.23.3.tar.gz";
              sha256 = "fd4ce68a3230ba459a92bcb747fc6afa91e46d803c1d5ffe964b661793c13fca"; };
      deps = [ self.readline.gcc self.ncurses.gcc self.expat.gcc self.openssl3.gcc self.zlib.gcc ];
      preConfigure = illumosExt + ''
        # illumos: socket/nsl are separate libs; configure's link probe needs them
        # in LIBS (not just LDFLAGS) so its AC_SEARCH_LIBS(socket) test links.
        export LIBS="-lsocket -lnsl ''${LIBS:-}"
        export LDFLAGS="-lnsl -lsocket ''${LDFLAGS:-}"
      '';
      configureFlags = [ "--with-included-neon" "--with-ssl=openssl" "--disable-nls" ];
      # illumos socket/nsl split: force the AC_SEARCH_LIBS(socket) cache result
      # so cadaver's bundled-neon configure stops rejecting the platform.
      env = { ac_cv_search_socket = "-lsocket"; ac_cv_search_gethostbyname = "-lnsl"; };
    };

    # aria2: multi-protocol download utility (C++). pkgsrc net/aria2 sets
    # --disable-epoll + ac_cv_func_getaddrinfo=yes under SunOS (illumos lacks
    # Linux epoll; its getaddrinfo probe misfires). c-ares (cached wave10) +
    # openssl3 + expat + zlib + libiconv. -lnsl -lsocket for the resolver.
    aria2 = pkg {
      pname = "aria2"; version = "1.37.0";
      src = { url = "https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0.tar.xz";
              sha256 = "60a420ad7085eb616cb6e2bdf0a7206d68ff3d37fb5a956dc44242eb2f79b66b"; };
      deps = [ self.openssl3.gcc self.expat.gcc self.zlib.gcc self.libiconv.gcc caresCached ];
      preConfigure = illumosExt + ''
        # illumos resolver in libnsl/libsocket; aria2's openssl link needs the
        # libs named explicitly (configure detects headers but omits -lssl/-lcrypto).
        export LDFLAGS="-lssl -lcrypto -lnsl -lsocket ''${LDFLAGS:-}"
      '';
      configureFlags = [ "--disable-epoll" "--with-openssl" "--without-gnutls"
                         "--with-libexpat" "--with-libcares" "--without-libssh2"
                         "--disable-static" ];
      env = { ac_cv_func_getaddrinfo = "yes"; };
    };

    # gnuplot: plotting program. pkgsrc graphics/gnuplot with readline + curses;
    # build --without-x (no X11 term) to avoid the GTK/X wall. libiconv. Feature
    # test macros for the terminal symbols.
    gnuplot = pkg {
      pname = "gnuplot"; version = "6.0.4";
      src = { url = "https://sourceforge.net/projects/gnuplot/files/gnuplot/6.0.4/gnuplot-6.0.4.tar.gz/download";
              sha256 = "458d94769625e73d5f6232500f49cbadcb2b183380d43d2266a0f9701aeb9c5b"; };
      deps = [ self.readline.gcc self.ncurses.gcc self.libiconv.gcc ];
      preConfigure = illumosExt + ''
        export LDFLAGS="-liconv ''${LDFLAGS:-}"
      '';
      configureFlags = [ "--without-x" "--with-readline=builtin" "--disable-wxwidgets"
                         "--without-qt" "--without-cairo" ];
    };

    # mutt: text mail client. pkgsrc mail/mutt (2.4.1) sets
    # CONFIGURE_ARGS.SunOS+=--disable-filemonitor (illumos lacks the
    # inotify/kqueue file monitor) + a patch-configure fixing the Kerberos/setgid
    # build under Solaris (repo mutt-solaris-gssapi.patch, -p0). ncurses + iconv +
    # zlib + openssl (IMAP/POP TLS). Feature-test macros via illumosExt.
    mutt = pkg {
      pname = "mutt"; version = "2.4.1";
      src = { url = "http://ftp.mutt.org/pub/mutt/mutt-2.4.1.tar.gz";
              sha256 = "5624321f0b1cc1eff6cab9ef08f25954ff64c51b33d4bf3b99484cf1edd8cfff"; };
      deps = [ self.ncurses.gcc self.libiconv.gcc self.zlib.gcc self.openssl3.gcc ];
      patches = [ ./patches/pkgsrc/mutt-solaris-gssapi.patch ];
      preConfigure = illumosExt + ''
        # force OUR ncurses headers first; the libc slice ships a stub
        # /usr/include/curses.h that lacks cchar_t and breaks mutt_curses.h.
        for d in ${self.ncurses.gcc}/include/ncursesw ${self.ncurses.gcc}/include; do
          [ -d "$d" ] && export CPPFLAGS="-I$d ''${CPPFLAGS:-}"
        done
        export LDFLAGS="-lnsl -lsocket ''${LDFLAGS:-}"
      '';
      configureFlags = [ "--disable-filemonitor" "--enable-pop" "--enable-imap"
                         "--with-ssl" "--with-curses=${self.ncurses.gcc}"
                         "--enable-external-dotlock" "--disable-nls" ];
      # mutt 2.4 auto-probes system libidn (a host /usr/lib leak) but its header
      # is absent -> HAVE_LIBIDN half-set -> main.c fails on stringprep. Force the
      # link probe to find nothing so IDN stays off.
      env = { ac_cv_search_stringprep_check_version = "no";
              ac_cv_search_idna_to_ascii_8z = "no"; };
    };

    # w3m: pager/text WWW browser. pkgsrc www/w3m links boehm-gc + ncurses +
    # openssl + zlib; Solaris resolver in libnsl/libsocket/libresolv. Feature-test
    # macros. Uses the rkta fork 0.5.6 (ships ./configure). GC include dir passed
    # explicitly (w3m probes for gc.h).
    w3m = pkg {
      pname = "w3m"; version = "0.5.6";
      src = { url = "https://git.sr.ht/~rkta/w3m/archive/v0.5.6.tar.gz";
              sha256 = "8dd652cd3f31817d68c7263c34eeffb50118c80be19e1159bf8cbf763037095e"; };
      deps = [ self.boehmgc.gcc self.ncurses.gcc self.openssl3.gcc self.zlib.gcc ];
      unpackSubdir = "w3m-v0.5.6";
      preConfigure = illumosExt + ''
        export CPPFLAGS="-I${self.boehmgc.gcc}/include ''${CPPFLAGS:-}"
        export LDFLAGS="-lnsl -lsocket -lresolv ''${LDFLAGS:-}"
      '';
      configureFlags = [ "--with-ssl" "--disable-nls" "--disable-image" "--disable-w3mimg"
                         "--with-gc=${self.boehmgc.gcc}" ];
    };

    # ===================================================================
    # Wave 19 — recurring pkgsrc-patch FAMILY fixes (docs/design-pkgsrc-patches.md).
    # ONE fix per family unblocks MANY packages. Fixes are the shared helpers
    # above: gnulibFix (F1), tputsFix (F2), endianShimStage (F3).
    # ===================================================================

    # --- Family 1: gnulib getlocalename_l redeclaration ----------------------
    # datamash: statistical CLI over text; bundles gnulib. The getlocalename_l
    # redecl is fixed by gnulibFix. 1.9 is hipster-current.
    datamash = pkg {
      pname = "datamash"; version = "1.9";
      src = { url = "https://ftp.gnu.org/gnu/datamash/datamash-1.9.tar.gz";
              sha256 = "f382ebda03650dd679161f758f9c0a6cc9293213438d4a77a8eda325aacb87d2"; };
      preConfigure = gnulibFix;
    };

    # recode: charset converter; bundles OLD gnulib whose `manywarnings` module
    # defaults gl_gcc_warnings=yes -> -Werror wall on illumos. --disable-gcc-
    # warnings turns the wall off; gnulibFix covers the localename decl too.
    recode = pkg {
      pname = "recode"; version = "3.7.14";
      src = { url = "https://github.com/rrthomas/recode/releases/download/v3.7.14/recode-3.7.14.tar.gz";
              sha256 = "786aafd544851a2b13b0a377eac1500f820ce62615ccc2e630b501e7743b9f33"; };
      deps = [ self.libiconv.gcc ];
      preConfigure = gnulibFix;
      configureFlags = [ "--disable-gcc-warnings" "--disable-nls" ];
    };

    # dwdiff: word-level diff; autotools + gnulib. Needs the gnulib fix + the
    # feature-test macros for its POSIX symbols.
    dwdiff = pkg {
      pname = "dwdiff"; version = "2.1.4";
      src = { url = "https://os.ghalkes.nl/dist/dwdiff-2.1.4.tar.bz2";
              sha256 = "df16fec44dcb467d65a4246a43628f93741996c1773e930b90c6dde22dd58e0a"; };
      # dwdiff's hand-rolled configure probes icu-uc via pkg-config for unicode
      # support. icu4c is cached (wave18); point pkg-config at it. gnulib fix +
      # feature-test macros for its POSIX symbols.
      deps = [ self.libiconv.gcc "/nix/store/q778azk1sv04wkbaljyxp8wg5dnvv2jn-icu4c-74.2" ];
      preConfigure = gnulibFix + illumosExt + ''
        export PKG_CONFIG_PATH="/nix/store/q778azk1sv04wkbaljyxp8wg5dnvv2jn-icu4c-74.2/lib/pkgconfig:''${PKG_CONFIG_PATH:-}"
      '';
      # dwdiff compiles clean with unicode(icu); its po/ lingua-install rule
      # calls a ./install.sh that isn't shipped -> --without-gettext drops the
      # locale install (the binary itself needs no .mo files).
      configureFlags = [ "--without-gettext" ];
    };

    # --- Family 2: tputs prototype mismatch (terminfo) -----------------------
    # wdiff: front-end to diff, word-by-word; uses terminfo (tputs) + gnulib.
    # tputsFix downgrades the illumos int(*)(char) mismatch; gnulibFix covers
    # its bundled gnulib.
    wdiff = pkg {
      pname = "wdiff"; version = "1.2.2";
      src = { url = "https://ftp.gnu.org/gnu/wdiff/wdiff-1.2.2.tar.gz";
              sha256 = "34ff698c870c87e6e47a838eeaaae729fa73349139fc8db12211d2a22b78af6b"; };
      deps = [ self.ncurses.gcc ];
      preConfigure = gnulibFix;
      env = { CFLAGS = tputsFix;
              # no texinfo/makeinfo in the toolchain -> stub it so the doc/
              # wdiff.info rule is a no-op (the binary builds fine without it).
              MAKEINFO = "true"; };
      configureFlags = [ "--disable-nls" ];
    };

    # hwloc: portable hardware locality; lstopo links terminfo (tputs). The LIB
    # builds clean; lstopo hit the tputs error (wave17). tputsFix fixes it.
    hwloc = pkg {
      pname = "hwloc"; version = "2.11.2";
      src = { url = "https://download.open-mpi.org/release/hwloc/v2.11/hwloc-2.11.2.tar.gz";
              sha256 = "866ac8ef07b350a6a2ba0c6826c37d78e8994dcbcd443bdd2b436350de19d540"; };
      deps = [ self.ncurses.gcc ];
      preConfigure = illumosExt;
      env = { CFLAGS = tputsFix; };
      configureFlags = [ "--enable-shared" "--disable-cairo" "--disable-libxml2"
                         "--with-hwloc-symbol-prefix=hwloc_" ];
    };

    # --- Family 3: Linux <endian.h> htobe64/htole64 --------------------------
    # paho-mqtt-c: Eclipse MQTT C client. SHA1.c/WebSocket.c use htobe*/be*toh
    # with no illumos #else branch. endianShimStage force-includes a compat
    # header mapping them onto illumos <sys/byteorder.h> BE_*/LE_*. Built via
    # its plain Makefile (CMake unavailable) with OSTYPE forced off-Linux and
    # illumos socket libs.
    pahomqttc = pkg {
      pname = "paho-mqtt-c"; version = "1.3.13";
      src = { url = "https://github.com/eclipse/paho.mqtt.c/archive/refs/tags/v1.3.13.tar.gz";
              sha256 = "47c77e95609812da82feee30db435c3b7c720d4fd3147d466ead126e657b6d9c"; };
      buildSystem = "custom";
      customBuild = ''
        ${endianShimStage}
        export CFLAGS="$CFLAGS -D_XOPEN_SOURCE=600 -D__EXTENSIONS__"
        mkdir -p "$out/lib" "$out/include"
        # generate VersionInfo.h (normally the Makefile does this from *.in).
        cv="$(cat version.major).$(cat version.minor).$(cat version.patch)"
        sed -e "s/@BUILD_TIMESTAMP@/solnix/" -e "s/@CLIENT_VERSION@/$cv/" \
            src/VersionInfo.h.in > src/VersionInfo.h
        # paho's Makefile only knows Linux/Darwin and uses GNU-ld-only flags;
        # build the two core client shared libs directly with our cc, deriving
        # the source sets exactly as the Makefile does (filter-out per client).
        ALL=$(ls src/*.c)
        # sync client (libpaho-mqtt3c): all minus async/version/ssl.
        SYNC=$(printf '%s\n' $ALL | grep -vE 'src/(MQTTAsync|MQTTAsyncUtils|MQTTVersion|SSLSocket)\.c$' | tr '\n' ' ')
        # async client (libpaho-mqtt3a): all minus sync-client/version/ssl.
        ASYNC=$(printf '%s\n' $ALL | grep -vE 'src/(MQTTClient|MQTTVersion|SSLSocket)\.c$' | tr '\n' ' ')
        $CC -shared -fPIC -Isrc $CFLAGS -o "$out/lib/libpaho-mqtt3c.so.1" \
          $SYNC -lpthread -lsocket -lnsl 2>&1 | tail -30
        $CC -shared -fPIC -Isrc $CFLAGS -o "$out/lib/libpaho-mqtt3a.so.1" \
          $ASYNC -lpthread -lsocket -lnsl 2>&1 | tail -30
        ( cd "$out/lib" && ln -sf libpaho-mqtt3c.so.1 libpaho-mqtt3c.so && ln -sf libpaho-mqtt3a.so.1 libpaho-mqtt3a.so )
        cp src/MQTTClient.h src/MQTTAsync.h src/MQTTProperties.h src/MQTTReasonCodes.h \
           src/MQTTSubscribeOpts.h src/MQTTExportDeclarations.h "$out/include/" 2>/dev/null || true
        [ -e "$out/lib/libpaho-mqtt3c.so.1" ] || { echo FATAL: paho lib not built >&2; exit 1; }
      '';
    };

    # --- Family 1 (widen): more gnulib-heavy GNU tools the getlocalename_l +
    # gnulibFix path unblocks. All bundle gnulib; the const-qualify + feature-
    # test macros are the shared fix. ---------------------------------------
    coreutils = pkg {
      pname = "coreutils"; version = "9.7";
      src = { url = "https://ftp.gnu.org/gnu/coreutils/coreutils-9.7.tar.xz";
              sha256 = "e8bb26ad0293f9b5a1fc43fb42ba970e312c66ce92c1b0b16713d7500db251bf"; };
      preConfigure = gnulibFix + illumosExt;
      # coreutils' gnulib is large; --disable-gcc-warnings avoids any -Werror
      # wall on illumos, --without-selinux/--disable-nls trim Linux-only bits.
      # FORCE_UNSAFE_CONFIGURE=1: gnulib's mknod probe refuses to run as root
      # (our builder runs as root); the flag bypasses that guard.
      env = { FORCE_UNSAFE_CONFIGURE = "1"; };
      configureFlags = [ "--disable-gcc-warnings" "--disable-nls" "--without-selinux" ];
    };

    gnuindent = pkg {
      pname = "indent"; version = "2.2.13";
      src = { url = "https://ftp.gnu.org/gnu/indent/indent-2.2.13.tar.xz";
              sha256 = "1b81ba4e9a006ca8e6eb5cbbe4cf4f75dfc1fc9301b459aa0d40393e85590a0b"; };
      buildSystem = "custom";
      # indent compiles clean with gnulibFix; only its doc/ dir needs makeinfo
      # (absent). Build everything, then install only src/ (the binary) + man/
      # + intl/, skipping doc/ entirely so no makeinfo/html rule fires.
      customBuild = ''
        ${gnulibFix}
        ${illumosExt}
        export MAKEINFO=true
        ./configure --prefix="$out" --mandir="$out/share/man" --disable-nls
        gmake -j"$(nproc)" -C src
        gmake -C src install
        gmake -C man install 2>/dev/null || true
        [ -x "$out/bin/indent" ] || { echo FATAL: indent not installed >&2; exit 1; }
      '';
    };

    gnuunits = pkg {
      pname = "units"; version = "2.24";
      src = { url = "https://ftp.gnu.org/gnu/units/units-2.24.tar.gz";
              sha256 = "1e502c4edfacf20b29284716c72e5ddb51a495a2365d7b03e7960494c4a0c902"; };
      deps = [ self.readline.gcc self.ncurses.gcc ];
      preConfigure = gnulibFix + illumosExt;
      configureFlags = [ "--disable-nls" ];
    };

    sharutils = pkg {
      pname = "sharutils"; version = "4.15.2";
      src = { url = "https://ftp.gnu.org/gnu/sharutils/sharutils-4.15.2.tar.xz";
              sha256 = "2b05cff7de5d7b646dc1669bc36c35fdac02ac6ae4b6c19cb3340d87ec553a9a"; };
      # sharutils bundles old gnulib whose manywarnings -Werror + a printf
      # redefinition break on illumos; disable warnings + feature-test macros.
      # -fcommon: gcc-10+ -fno-common default makes gnulib's tentative
      # `program_name` def multiply-defined at link (uuencode/uudecode).
      preConfigure = gnulibFix + illumosExt;
      env = { CFLAGS = "-fcommon"; };
      configureFlags = [ "--disable-gcc-warnings" "--disable-nls" ];
    };

    # ---- Wave 21: GNU/gnulib tool tail (family fixes clear these) ---------
    # All bundle gnulib -> gnulibFix. Companion knobs per §8: --disable-nls
    # (no gettext runtime needed / avoids po install snags), MAKEINFO=true
    # (no texinfo in toolchain -> .info rules 127-fail), -fcommon
    # (program_name tentative-def multiple-def), FORCE_UNSAFE_CONFIGURE=1
    # (gnulib mknod/fifo probe refuses root; our builder is root).

    findutils = pkg {
      pname = "findutils"; version = "4.10.0";
      src = { url = "https://mirrors.kernel.org/gnu/findutils/findutils-4.10.0.tar.xz";
              sha256 = "1387e0b67ff247d2abde998f90dfbf70c1491391a59ddfecb8ae698789f0a4f5"; };
      preConfigure = gnulibFix + illumosExt;
      env = { CFLAGS = "-fcommon"; FORCE_UNSAFE_CONFIGURE = "1"; MAKEINFO = "true"; };
      configureFlags = [ "--disable-nls" ];
    };

    gnupatch = pkg {
      pname = "patch"; version = "2.7.6";
      src = { url = "https://mirrors.kernel.org/gnu/patch/patch-2.7.6.tar.xz";
              sha256 = "ac610bda97abe0d9f6b7c963255a11dcb196c25e337c61f94e4778d632f1d8fd"; };
      preConfigure = gnulibFix + illumosExt;
      env = { CFLAGS = "-fcommon"; MAKEINFO = "true"; };
      configureFlags = [ "--disable-nls" ];
    };

    cpio = pkg {
      pname = "cpio"; version = "2.15";
      src = { url = "https://mirrors.kernel.org/gnu/cpio/cpio-2.15.tar.bz2";
              sha256 = "937610b97c329a1ec9268553fb780037bcfff0dcffe9725ebc4fd9c1aa9075db"; };
      preConfigure = gnulibFix + illumosExt;
      env = { CFLAGS = "-fcommon"; FORCE_UNSAFE_CONFIGURE = "1"; MAKEINFO = "true"; };
      configureFlags = [ "--disable-nls" ];
    };

    # gengetopt: compiles clean (lib+binary); only its doc/ HTML rule needs
    # texi2html/makeinfo (absent) -> fails on gengetopt.html. Build the whole
    # tree EXCEPT doc/, then install skipping doc so no html rule fires.
    gengetopt = pkg {
      pname = "gengetopt"; version = "2.23";
      src = { url = "https://mirrors.kernel.org/gnu/gengetopt/gengetopt-2.23.tar.xz";
              sha256 = "b941aec9011864978dd7fdeb052b1943535824169d2aa2b0e7eae9ab807584ac"; };
      buildSystem = "custom";
      customBuild = ''
        ${gnulibFix}
        ${illumosExt}
        export CFLAGS="''${CFLAGS:-} -fcommon"
        export MAKEINFO=true
        ./configure --prefix="$out" --disable-nls
        # SUBDIRS in the top Makefile is 'gl doc src tests'; build/install gl+src
        # only (doc needs texi2html; tests optional). gl is a convenience lib src
        # links against.
        gmake -j"$(nproc)" -C gl
        gmake -j"$(nproc)" -C src
        gmake -C src install
        [ -x "$out/bin/gengetopt" ] || { echo FATAL: gengetopt not installed >&2; exit 1; }
      '';
    };

    # which 2.21: tiny GNU tool, bundles no gnulib but uses readline-free tilde;
    # illumosExt for POSIX getopt. Distinct from the already-cached shell/which.
    gnuwhich = pkg {
      pname = "gnu-which"; version = "2.21";
      src = { url = "https://ftp.gnu.org/gnu/which/which-2.21.tar.gz";
              sha256 = "f4a245b94124b377d8b49646bf421f9155d36aa7614b6ebf83705d3ffc76eaad"; };
      preConfigure = illumosExt;
      env = { CFLAGS = "-fcommon"; MAKEINFO = "true"; };
    };

    # ddrescue: C++ data recovery, bundles no gnulib but needs __EXTENSIONS__ +
    # -fcommon; MAKEINFO stubs its texinfo doc. .lz tarball -> lzip; the builder
    # untar path handles xz/gz/bz2 but not lzip, so fetch a .tar.gz mirror? GNU
    # only ships .lz. Use custom to lzip-decompress.
    ddrescue = pkg {
      pname = "ddrescue"; version = "1.28";
      src = { url = "https://mirrors.kernel.org/gnu/ddrescue/ddrescue-1.28.tar.lz";
              sha256 = "6626c07a7ca1cc1d03cad0958522c5279b156222d32c342e81117cfefaeb10c1"; };
      buildSystem = "custom";
      customBuild = ''
        ${illumosExt}
        export CXXFLAGS="''${CXXFLAGS:-} -D__EXTENSIONS__ -fcommon"
        export MAKEINFO=true
        ./configure --prefix="$out" --mandir="$out/share/man" CXX="$CXX" \
          CXXFLAGS="$CXXFLAGS -O2 -m64"
        gmake -j"$(nproc)"
        gmake install-bin install-man 2>/dev/null || gmake install
        [ -x "$out/bin/ddrescue" ] || { echo FATAL: ddrescue not installed >&2; exit 1; }
      '';
    };

    # enscript: text->PostScript. gnulib + makeinfo-blocked; --disable-nls,
    # MAKEINFO=true, -fcommon for its states/ scanner globals. Its bundled
    # getopt.c calls str*() without <string.h> -> gcc-14 implicit-decl ERROR;
    # force-include string.h + downgrade the diagnostic. The bundled K&R
    # compat/memcpy.c|memmove.c conflict with <string.h> once force-included;
    # libcFallbackFix (Family 7) pre-seeds ac_cv_func_*=yes so configure skips
    # them (illumos libc has them). UNBLOCKED wave 22.
    enscript = pkg {
      pname = "enscript"; version = "1.6.6";
      src = { url = "https://mirrors.kernel.org/gnu/enscript/enscript-1.6.6.tar.gz";
              sha256 = "6d56bada6934d055b34b6c90399aa85975e66457ac5bf513427ae7fc77f5c0bb"; };
      preConfigure = gnulibFix + illumosExt + libcFallbackFix;
      env = { CFLAGS = "-fcommon -include string.h -Wno-error=implicit-function-declaration"; MAKEINFO = "true"; };
      configureFlags = [ "--disable-nls" ];
    };

    # a2ps: 'anything to PostScript'. Heavy gnulib bundle; --disable-gcc-warnings
    # (old manywarnings -Werror wall) + gnulibFix + MAKEINFO. Needs a working
    # gperf/psutils at runtime but builds standalone.
    a2ps = pkg {
      pname = "a2ps"; version = "4.15.6";
      src = { url = "https://mirrors.kernel.org/gnu/a2ps/a2ps-4.15.6.tar.gz";
              sha256 = "87ff9d801cb11969181d5b8cf8b65e65e5b24bb0c76a1b825e8098f2906fbdf4"; };
      preConfigure = gnulibFix + illumosExt;
      env = { CFLAGS = "-fcommon"; MAKEINFO = "true"; };
      configureFlags = [ "--disable-gcc-warnings" "--disable-nls" ];
    };

    # parted: GNU partition editor. illumos lacks libblkid/device-mapper; build
    # libparted core only (no fs-resize, no dmraid) and expect it may still hit
    # a Linux ioctl. gnulibFix + illumosExt; pkgsrc-candidate if it walls on
    # <linux/*.h>.
    parted = pkg {
      pname = "parted"; version = "3.6";
      src = { url = "https://ftp.gnu.org/gnu/parted/parted-3.6.tar.xz";
              sha256 = "3b43dbe33cca0f9a18601ebab56b7852b128ec1a3df3a9b30ccde5e73359e612"; };
      deps = [ self.readline.gcc self.ncurses.gcc ];
      preConfigure = gnulibFix + illumosExt;
      env = { CFLAGS = "-fcommon"; MAKEINFO = "true"; };
      configureFlags = [ "--disable-nls" "--disable-device-mapper" ];
    };

    # A Python module built by pip against cached python-3.9 (add python313
    # variant by swapping the interpreter). Freeze order (compile before the
    # store path is fixed) is handled by mk-userland-pkg's install step; here we
    # just install into $out and precompile so the store path stays stable.
    pyModule = { pname, version, src, extraDeps ? [ ], py ? self.python39.gcc, pymm ? "python3.9" }:
      pkg {
        inherit pname version src;
        deps = [ py ] ++ extraDeps;
        buildSystem = "custom";
        customBuild = ''
          PY=${py}/bin/${pymm}
          # force the real gcc-14 (sysconfig CC is a dead /tmp build wrapper)
          export CC="$CC" LDSHARED="$CC -shared -m64" CFLAGS="-m64 -fPIC -O2" LDFLAGS="-m64"
          "$PY" -m pip install --no-cache-dir --no-warn-script-location --prefix="$out" . 2>&1 | tail -20
          "$PY" -m compileall -q -f "$out/lib/${pymm}/site-packages" 2>/dev/null || true
        '';
      };

    # A Perl module (MakeMaker or Build.PL) against cached perl-5.42. Pass CC
    # explicitly ($Config{cc} in the cached perl is the unexpanded template).
    perlModule = { pname, version, src, extraDeps ? [ ], perl ? self.perl.gcc }:
      pkg {
        inherit pname version src;
        deps = [ perl ] ++ extraDeps;
        buildSystem = "custom";
        customBuild = ''
          PERL=${perl}/bin/perl
          if [ -f Makefile.PL ]; then
            "$PERL" Makefile.PL INSTALL_BASE="$out" CC="$CC" LD="$CC" OPTIMIZE="-m64 -fPIC -O2"
            gmake -j"$(nproc)" CC="$CC"; gmake install
          else
            "$PERL" Build.PL --install_base "$out" --config cc="$CC" --config ld="$CC"
            "$PERL" ./Build; "$PERL" ./Build install
          fi
        '';
      };
  };
in
self
