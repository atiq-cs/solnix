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
  gccStore   = "/nix/store/1sif429w2gpwzxcjqljb481anq0y7wh2-illumos-gcc14";
  clangStore = "/nix/store/b824mvhkdd4hh0vdi828x1nppkpqwm1y-illumos-clang";
  libcStore  = "/nix/store/acpbjdc4l4n20nmlasqgrizkvycsanmc-illumos-libc";
  ldStore    = "/nix/store/9cldpn929s3vrbajqvvla8szhy51bnd8-illumos-ld";
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
    for f in $(find . -name 'localename.c' 2>/dev/null); do
      sed -i 's/extern char \* *getlocalename_l/extern const char *getlocalename_l/' "$f" || true
    done
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
  };
in
self
