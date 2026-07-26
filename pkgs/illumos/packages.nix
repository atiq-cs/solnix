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

  # gnulib-on-illumos fix: newer illumos libc declares getlocalename_l as
  # `const char *`, but gnulib bundled in GNU tarballs (m4/grep/sed/diffutils/
  # gettext/coreutils/...) redeclares it `char *` -> conflicting-types error.
  # const-qualify gnulib's prototype to match libc. Idempotent, safe if absent.
  gnulibFix = ''
    for f in $(find . -name 'localename.c' -o -name 'localename-unsafe.c' -o -name 'localename-table.c' 2>/dev/null); do
      sed -i 's/extern char \* *getlocalename_l/extern const char *getlocalename_l/;s/^char \* *getlocalename_l/const char *getlocalename_l/' "$f" || true
    done
  '';

  # illumos feature-test macro fix: many portable C tools use strcasecmp/
  # strncasecmp (<strings.h>) or POSIX symbols that Solaris libc hides behind
  # __EXTENSIONS__ / _XOPEN_SOURCE. Append (not clobber) the search-path CFLAGS
  # set by mk-userland. Use in preConfigure.
  illumosExt = ''
    export CFLAGS="''${CFLAGS:-} -D__EXTENSIONS__ -D_XOPEN_SOURCE=600 -D_XOPEN_SOURCE_EXTENDED=1"
    export CPPFLAGS="''${CPPFLAGS:-} -D__EXTENSIONS__ -D_XOPEN_SOURCE=600"
  '';

  # convenience: refer to a dep's gcc-built store path for RUNPATH/search.
  # We link deps built with gcc (ABI-compatible: OI clang uses gcc's libstdc++).
  self = rec {

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
      # bundled oniguruma; no external regex lib needed.
      preConfigure = illumosExt;
      configureFlags = [ "--with-oniguruma=builtin" "--disable-maintainer-mode" ];
    };

    tree = pkg {
      pname = "tree"; version = "2.1.3";
      src = { url = "https://gitlab.com/OldManProgrammer/unix-tree/-/archive/2.1.3/unix-tree-2.1.3.tar.gz";
              sha256 = "f554a1b62233b96fa8eaa2d85e91bc62cad80ee441fd591380f16cdfbe3e8868"; };
      buildSystem = "custom";
      # only __EXTENSIONS__ (for strcasecmp); NOT _XOPEN_SOURCE which pulls a
      # conflicting system `struct comment` into tree.h.
      customBuild = ''
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
      # bundled popt; skip external xxhash.
      preConfigure = illumosExt;
      configureFlags = [ "--disable-md2man" "--disable-xxhash" "--with-included-popt" ];
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
