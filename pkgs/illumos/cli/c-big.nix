# cli/c-big.nix -- perl, the autotools, python3, cmake, ccache.
{ base, mkSrcPkg, world, zlib, openssl, ncurses, readline, pkgconf, nixChain, graphics, chk, scrub, dropDocs, gnum4, sqlite, ... }:
rec {
  # perl, shared libperl, threads. libpth is the gate proto's only (no host /usr/lib probe).
  perl = mkSrcPkg {
    pname = "perl"; version = "5.42.0";
    src = { url = "https://www.cpan.org/src/5.0/perl-5.42.0.tar.gz";
            sha256 = "e093ef184d7f9a1b9797e2465296f55510adb6dab8842b0c3ed53329663096dc"; };
    deps = [ world ];
    build = ''
      # hints/solaris_2.sh picks gcc vs Sun cc by "gcc" in the compiler's NAME; the builder's
      # wrapper is cc64 (-> Sun cc flags -xarch=generic64, measured). A gcc-named link to it.
      mkdir -p "$W/gccbin"; ln -sf "$CC" "$W/gccbin/gcc"; export PATH="$W/gccbin:$PATH"
      sed -i 's@ldflags="$ldflags -L/usr/gnu/lib"@:@; s@-L/usr/gnu/lib@@g' hints/solaris_2.sh
      # Configure records the build time, host name, domain, user and uname -a (Config_heavy.pl, config.h, perlbug). Pinned to
      # neutral values (solnix.io policy: no build-host facts in a NAR), as nixpkgs interpreter.nix does; cf_time = SOURCE_DATE_EPOCH.
      printf '%s\n' 'myuname="solnix"' 'myhostname="localhost"' 'mydomain=""' 'cf_by="nixbld"' 'cf_email=""' \
        'perladmin="root@localhost"' 'cf_time="Tue Jan  1 00:00:00 UTC 1980"' > config.over
      sh ./Configure -des -Dprefix="$out" -Dcc=gcc -Duseshrplib -Dusethreads -Duse64bitall \
        -Dlibpth="$gate/lib/amd64 $gate/usr/lib/amd64" -Dloclibpth= -Dlocincpth= -Dglibpth= \
        -Dinstallstyle=lib/perl5 -Dman1dir="$out/share/man/man1" -Dman3dir="$out/share/man/man3" \
        -Dman1ext=1 -Dman3ext=3pm -Dlddlflags="-shared -m64" -Uinstallusrbinperl \
        -Dlibswanted="pthread socket nsl dl m c" -Dccflags="-fno-stack-protector" -Ui_gdbm -Ui_db -Ui_ndbm
      gmake -j16; gmake install
      ${scrub}
      ${chk ''"$out/bin/perl" -v'' "v5\\.42\\.0"}
      ${chk ''"$out/bin/perl" -V:myhostname'' "^myhostname=.localhost.;$"}
      ${chk ''"$out/bin/perl" -MPOSIX -MSocket -MDigest::SHA=sha1_hex -e "print sha1_hex(q(abc)),qq(\\n)"'' "^a9993e364706816aba3e25717850c26c9cd0d89d$"}
      [ -f "$out/share/man/man1/perl.1" ] || { echo "FATAL: no perl.1" >&2; exit 1; }
    '';
  };

  autoconf = mkSrcPkg {
    pname = "autoconf"; version = "2.72";
    src = { url = "https://mirrors.kernel.org/gnu/autoconf/autoconf-2.72.tar.xz";
            sha256 = "ba885c1319578d6c94d46e9b0dceb4014caafe2490e437a0dbca3f270a223f5a"; };
    deps = [ perl gnum4 ];
    build = ''
      MAKEINFO=true ./configure --prefix="$out" M4=${gnum4}/bin/m4 PERL=${perl}/bin/perl
      gmake -j8 MAKEINFO=true; gmake install MAKEINFO=true
      ${dropDocs}
      ${chk ''"$out/bin/autoconf" --version'' "^autoconf \\(GNU Autoconf\\) 2\\.72"}
      T=$(mktemp -d /var/tmp/ac.XXXXXX); printf 'AC_INIT([t],[1])\nAC_PROG_CC\nAC_OUTPUT\n' > "$T/configure.ac"
      (cd "$T" && "$out/bin/autoconf" && ./configure >/dev/null) || { echo "FATAL: autoconf functional" >&2; exit 1; }
    '';
  };

  automake = mkSrcPkg {
    pname = "automake"; version = "1.18.1";
    src = { url = "https://mirrors.kernel.org/gnu/automake/automake-1.18.1.tar.xz";
            sha256 = "168aa363278351b89af56684448f525a5bce5079d0b6842bd910fdd3f1646887"; };
    deps = [ perl autoconf ];
    build = ''
      export PATH=${autoconf}/bin:${perl}/bin:$PATH
      MAKEINFO=true ./configure --prefix="$out" PERL=${perl}/bin/perl
      gmake -j8 MAKEINFO=true; gmake install MAKEINFO=true
      ${dropDocs}
      ${chk ''"$out/bin/automake" --version'' "^automake \\(GNU automake\\) 1\\.18\\.1"}
    '';
  };

  libtool = mkSrcPkg {
    pname = "libtool"; version = "2.5.4";
    src = { url = "https://mirrors.kernel.org/gnu/libtool/libtool-2.5.4.tar.xz";
            sha256 = "f81f5860666b0bc7d84baddefa60d1cb9fa6fceb2398cc3baca6afaa60266675"; };
    deps = [ gnum4 ];
    build = ''
      MAKEINFO=true ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static M4=${gnum4}/bin/m4
      gmake -j8 MAKEINFO=true; gmake install MAKEINFO=true
      ${scrub}
      ${dropDocs}
      ${chk ''"$out/bin/libtool" --version'' "GNU libtool\\) 2\\.5\\.4"}
      ${chk ''"$out/bin/libtoolize" --version'' "^libtoolize \\(GNU libtool\\) 2\\.5\\.4"}
    '';
  };
}
