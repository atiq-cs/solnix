# base-src.nix -- the non-gate packages the base system needs, built FROM SOURCE
# with mk-src-pkg.nix. Each one replaces something that used to be copied from
# the build host: zlib + libxml2 replace externalLibs (host /usr/lib copies),
# openssl + openssh replace make-be's host sshd copy, bash replaces nothing (the
# gate has no bash) but is a login shell users expect.
{ gate, libcSlice, world ? null, gcc ? "/usr/gcc/14", buildTools ? [ ] }:
# gcc: the from-source gcc derivation (gcc-src.nix). Everything here is compiled
# by it, both ABIs; the IPS seed only compiled gcc itself.
# buildTools: store paths whose bin/ go first on every mk-src-pkg builder PATH
# (store gmake/gnutar/gzip/xz/bzip2/gnugrep/gnused/gstrip). Default [] keeps the
# OI buildhost path (/usr/gnu + host decompressors). A solnix system passes the
# store set so it can build with no /usr/gnu. Threaded to mkSrcPkg below.

let
  mkSrcPkg = import ./mk-src-pkg.nix {
    inherit gate gcc buildTools;
    runtimeLibDirs = [ "${libcSlice}/lib/amd64" "${libcSlice}/lib" ];
  };
  needWorld = if world == null then throw "base-src: this package needs the userland world" else world;
in
rec {
  inherit mkSrcPkg;

  # Nix 2.24.15 + its dependency chain (./nix-src.nix).
  nixChain = import ./nix-src.nix { inherit mkSrcPkg zlib openssl libcSlice; system = "x86_64-solaris"; gccLib = gcc.lib; };

  # libz.so.1 with the illumos symbol versions (SUNW_1.1 .. ILLUMOS_0.2). The
  # gate's libzfs/libzpool record `libz.so.1 SUNW_1.1` as a needed version, so an
  # unversioned upstream libz would fail to load there. The mapfile is
  # OpenIndiana's (oi-userland components/library/zlib/mapfile).
  zlib = mkSrcPkg {
    pname = "zlib"; version = "1.3.2";
    src = { url = "https://zlib.net/fossils/zlib-1.3.2.tar.gz";
            sha256 = "bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16"; };
    abis = [ "64" "32" ];
    build = ''
      CFLAGS="-O2 -fPIC" LDSHARED="$CC -shared -Wl,-h,libz.so.1 -Wl,-M,${./patches/zlib-illumos.mapfile}" \
        ./configure --prefix="$out" --libdir="$out/$LIBSUB" --sharedlibdir="$out/$LIBSUB" --includedir="$out/include"
      gmake -j4 libz.so.1.3.2
      gmake install
    '';
  };

  # libxml2.so.16 (soname 16 first appears in 2.14). The gate's libpool,
  # libzonecfg, libbrand and svccfg NEED it; both ABIs, because SMF is 32-bit.
  libxml2 = mkSrcPkg {
    pname = "libxml2"; version = "2.14.6";
    src = { url = "https://download.gnome.org/sources/libxml2/2.14/libxml2-2.14.6.tar.xz";
            sha256 = "7ce458a0affeb83f0b55f1f4f9e0e55735dbfc1a9de124ee86fb4a66b597203a"; };
    abis = [ "64" "32" ];
    deps = [ zlib ];
    build = ''
      ./configure --prefix="$out" --libdir="$out/$LIBSUB" --without-python --without-icu \
        --without-lzma --with-zlib --disable-static --without-debug
      gmake -j4
      gmake install
    '';
  };

  openssl = mkSrcPkg {
    pname = "openssl"; version = "3.4.0";
    src = { url = "https://github.com/openssl/openssl/releases/download/openssl-3.4.0/openssl-3.4.0.tar.gz";
            sha256 = "e15dda82fe2fe8139dc2ac21a36d4ca01d5313c75f99f46c4e8a27709b7294bf"; };
    # libc only (runtimeLibDirs): no world dep, so nix's closure does not pull
    # the whole userland in through libcrypto.
    build = ''
      ./Configure solaris64-x86_64-gcc --prefix="$out" --libdir=lib/amd64 --openssldir=/etc/openssl \
        shared no-tests no-docs
      gmake -j6 build_sw
      gmake install_sw
    '';
  };

  # OpenSSH with PAM. docs/sshd-pam-fail-open.md: without UsePAM, OpenSSH 10 on
  # illumos accepts any password; the config make-be stages sets UsePAM yes.
  # sysconfdir is /etc/ssh (host keys + config are per-machine state, as on NixOS);
  # the binaries and libexec helpers live in the store.
  openssh = mkSrcPkg {
    pname = "openssh"; version = "10.2p1";
    src = { url = "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-10.2p1.tar.gz";
            sha256 = "ccc42c0419937959263fa1dbd16dafc18c56b984c03562d2937ce56a60f798b2"; };
    deps = [ needWorld zlib openssl ];
    build = ''
      DP=/run/current-system/sw/bin:/usr/bin:/usr/sbin:/sbin
      # GCC 14 makes -Wincompatible-pointer-types an error; illumos PAM declares
      # pam_get_item(..., void **) and a non-const conversation callback, where
      # OpenSSH assumes Linux-PAM's const forms (measured: auth-pam.c:480 etc).
      CFLAGS="-O2 -Wno-error=incompatible-pointer-types" \
      ./configure --prefix="$out" --sysconfdir=/etc/ssh --with-pam \
        --with-solaris-contracts --with-solaris-projects --with-solaris-privs \
        --with-privsep-path=/var/empty --with-privsep-user=sshd \
        --with-default-path="$DP" --with-superuser-path="$DP" \
        --with-pid-dir=/var/run --with-mantype=man --without-rpath
      gmake -j6
      D=$(mktemp -d /var/tmp/sshdest.XXXXXX)
      gmake install-nokeys DESTDIR="$D"
      cp -R "$D$out/." "$out/"
      mkdir -p "$out/share/ssh-defaults"; cp -R "$D/etc/ssh/." "$out/share/ssh-defaults/"
    '';
  };

  # NSPR + NSS: the gate's libldap.so.5 (Sun's Mozilla LDAP C SDK) NEEDs libnspr4,
  # libplc4, libnss3 and libssl3 (versions NSPR_4.0 / NSS_3.2), and libsldap,
  # passwdutil, the pam_unix_* modules, nss_ldap, kmf_nss and the ldap* tools reach
  # it. Those NEEDED entries are LAZY, so a non-LDAP `passwd` runs without them,
  # but the first LDAP call (or LD_BIND_NOW) dies with "libplc4.so: open failed"
  # (measured on the world). illumos-gate does not ship them; OpenIndiana builds
  # them as library/mozilla-nspr and library/mozilla-nss into /usr/lib/mps.
  # Both ABIs: passwd, the PAM stack and SMF are 32-bit.
  nspr = mkSrcPkg {
    pname = "nspr"; version = "4.40";
    src = { url = "https://ftp.mozilla.org/pub/nspr/releases/v4.40/src/nspr-4.40.tar.gz";
            sha256 = "c0c1884c627f3db7a783f7c7314c695226b2043696791d15519e7e0578c19bdc"; };
    abis = [ "64" "32" ];
    build = ''
      # configure appends -m64 itself for --enable-64bit; the wrapper already passes it.
      E=""; [ "$ABI" = 64 ] && E=--enable-64bit
      cd nspr
      ./configure --prefix="$out" --libdir="$out/$LIBSUB" --includedir="$out/include/nspr" \
        --enable-optimize --disable-debug $E
      gmake -j4
      gmake install
      rm -f "$out/$LIBSUB"/*.a "$out/bin/compile-et.pl" "$out/bin/prerr.properties"
    '';
  };

  nss = mkSrcPkg {
    pname = "nss"; version = "3.98";
    # 3.98 is OpenIndiana's current mozilla-nss, built with the coreconf makefiles.
    # Newer NSS releases build with gyp + ninja, which the build host does not have.
    src = { url = "https://ftp.mozilla.org/pub/security/nss/releases/NSS_3_98_RTM/src/nss-3.98.tar.gz";
            sha256 = "f549cc33d35c0601674bfacf7c6ad683c187595eb4125b423238d3e9aa4209ce"; };
    abis = [ "64" "32" ];
    deps = [ nspr zlib libcExtra ];
    build = ''
      patch -p1 < ${./patches/nss/0001-hacl-bignum-base-include-alloca.patch}
      # coreconf's SunOS5.mk: RPATH '$ORIGIN' is replaced by the store RUNPATH
      # the compiler wrapper bakes in; -lthread/-lposix4/-lkstat come from the gate.
      sed -i "s,^RPATH = -R '\$\$ORIGIN'$,RPATH =," nss/coreconf/SunOS5.mk
      B=""; [ "$ABI" = 64 ] && B="USE_64=1"
      gmake -C nss -j1 BUILD_OPT=1 NS_USE_GCC=1 NSS_ENABLE_WERROR=0 NSDISTMODE=copy \
        NSS_DISABLE_GTESTS=1 \
        CC="$CC" CCC="$CXX" AS="$CC" LD="$CC" $B \
        NSPR_INCLUDE_DIR=${nspr}/include/nspr NSPR_LIB_DIR=${nspr}/$LIBSUB \
        USE_SYSTEM_ZLIB=1 ZLIB_LIBS="-L${zlib}/$LIBSUB -lz"
      O=$(ls -d dist/SunOS5*_OPT.OBJ | head -1)
      mkdir -p "$out/$LIBSUB" "$out/include/nss"
      cp -P "$O"/lib/*.so "$O"/lib/*.chk "$out/$LIBSUB/" 2>/dev/null || cp -P "$O"/lib/*.so "$out/$LIBSUB/"
      cp dist/public/nss/*.h dist/public/dbm/*.h "$out/include/nss/"
      if [ "$ABI" = 64 ]; then
        mkdir -p "$out/bin"
        for t in certutil modutil pk12util; do cp "$O/bin/$t" "$out/bin/"; done
      fi
      for l in libnss3 libssl3 libsmime3 libnssutil3 libsoftokn3; do
        [ -e "$out/$LIBSUB/$l.so" ] || { echo "FATAL: $l.so not built for ABI $ABI" >&2; exit 1; }
      done
    '';
  };

  # libc-adjacent gate libraries NSS links (-lthread -lkstat) that the libc slice
  # does not carry, copied from the gate. The world links its own copies of these
  # to the files here, so a process maps each library once.
  libcExtra = derivation {
    name = "illumos-libc-extra"; system = "x86_64-solaris"; inherit gate;
    libc = libcSlice;
    builder = "/usr/bin/bash";
    args = [ "-c" ''
      set -eu; export PATH=/usr/gnu/bin:/usr/bin
      for sub in lib lib/amd64; do
        mkdir -p $out/$sub
        for l in libthread.so.1 libkstat.so.1; do cp $gate/$sub/$l $out/$sub/; done
        ln -s libthread.so.1 $out/$sub/libthread.so; ln -s libkstat.so.1 $out/$sub/libkstat.so
        # -lposix4: librt, which the libc slice already carries (one copy per process)
        ln -s $libc/$sub/librt.so.1 $out/$sub/libposix4.so
        for f in $out/$sub/*.so.1; do [ -L "$f" ] && continue; chmod u+w "$f"
          /usr/bin/elfedit -e "dyn:runpath $libc/$sub" "$f"; done
      done
    '' ];
  };

  # git, for flake inputs fetched over git and for users. NixOS ships it as a
  # normal package; nix itself fetches flakes with libgit2 and does not need it.
  git = mkSrcPkg {
    pname = "git"; version = "2.54.0";
    src = { url = "https://www.kernel.org/pub/software/scm/git/git-2.54.0.tar.xz";
            sha256 = "f689162364c10de79ef89aa8dbf48731eb057e34edbbd20aca510ce0154681a3"; };
    deps = [ zlib openssl nixChain.curl ];
    build = ''
      cat > config.mak <<EOF
      CC = $CC
      prefix = $out
      SHELL_PATH = ${bash}/bin/bash
      PERL_PATH = /usr/bin/perl
      NO_PERL = YesPlease
      NO_PYTHON = YesPlease
      NO_TCLTK = YesPlease
      NO_GETTEXT = YesPlease
      NO_EXPAT = YesPlease
      NO_INSTALL_HARDLINKS = YesPlease
      INSTALL_SYMLINKS = YesPlease
      SKIP_DASHED_BUILT_INS = YesPlease
      INSTALL = /usr/gnu/bin/install
      TAR = /usr/gnu/bin/tar
      ZLIB_PATH = ${zlib}
      OPENSSLDIR = ${openssl}
      CURLDIR = ${nixChain.curl}
      CURL_LDFLAGS = -lcurl
      lib = lib/amd64
      CC_LD_DYNPATH = -Wl,-R,
      EOF
      gmake -j4 all
      gmake install
    '';
  };

  # GNU binutils, for its assembler. The gcc above was configured
  # --with-as=/usr/bin/gas, the build host's IPS gas; an installed solnix system has
  # no assembler at all (not in the gate, the world or the store), so its gcc can
  # emit .s but not .o. gas is C, so this can only be built where an assembler
  # already exists (the build host), then copied. ld is NOT built: gcc links with
  # the gate's link-editor (--with-ld=/usr/bin/ld). The other binutils tools are
  # installed with a g prefix (gstrip, gobjdump, ...), the OpenIndiana layout, so
  # they never shadow the gate's ar/nm/strip; bin/as is gas under its plain name,
  # which is what gcc -B<dir>/ looks for.
  binutils = mkSrcPkg {
    pname = "binutils"; version = "2.46.1";
    src = { url = "https://ftp.gnu.org/gnu/binutils/binutils-2.46.1.tar.xz";
            sha256 = "e127a709cba24c76de8936cb7083dd768f28cd37eb010492e2f19b71eb1294e4"; };
    build = ''
      T=x86_64-pc-solaris2.11
      # no -g: DWARF names the gate proto and the compiler, and the stripper only
      # touches ELF files, so debug info in an installed .a would pull both into
      # the runtime closure. --disable-install-libbfd keeps libbfd.a/bfd.h out.
      CFLAGS=-O2 CXXFLAGS=-O2 MAKEINFO=true ./configure --prefix="$out" --build=$T --host=$T --target=$T \
        --program-prefix=g --disable-ld --disable-gold --disable-gprof --disable-gprofng \
        --disable-libctf --disable-shared --disable-install-libbfd --disable-nls --disable-werror --without-zstd
      # LEXLIB empty: configure finds the build host's lex library (-ll) and links
      # gar/granlib to libl.so.1 from /usr/lib (the closure gate caught it). The
      # shipped arlex.c is pre-generated with yywrap() defined as a macro, so
      # nothing from libl is used.
      gmake -j4 MAKEINFO=true LEXLIB=
      gmake install MAKEINFO=true LEXLIB=
      ln -s gas "$out/bin/as"
      # the native tooldir duplicates bin/ under unprefixed names; nothing uses it.
      find "$out/$T" -delete 2>/dev/null || true
      # self-check: the new gas assembles both ELF classes gcc asks for.
      printf '.text\n.globl f\nf: ret\n' > t.s
      for c in 64 32; do
        "$out/bin/as" --$c -o t$c.o t.s
        [ "$(od -An -tx1 -N4 t$c.o | tr -d ' \n')" = 7f454c46 ] || { echo "FATAL: gas --$c made no ELF" >&2; exit 1; }
      done
    '';
  };

  # GNU make. The gate's make is illumos make (`make -v` = "illumos make"); GNU
  # build systems want GNU make, which OpenIndiana ships as gmake. Both names here.
  gnumake = mkSrcPkg {
    pname = "gnumake"; version = "4.4.1";
    src = { url = "https://ftp.gnu.org/gnu/make/make-4.4.1.tar.gz";
            sha256 = "dd16fb1d67bfab79a72f5e8390735c49e3e8e70b4945a15ab1f81ddb78658fb3"; };
    build = ''
      ./configure --prefix="$out" --without-guile --disable-nls
      gmake -j4
      gmake install
      ln -s make "$out/bin/gmake"
      "$out/bin/make" --version | head -1 | grep -q '^GNU Make 4.4.1' || { echo "FATAL: make --version" >&2; exit 1; }
    '';
  };

  # pkgconf -- the pkg-config implementation (pkg-config is unmaintained; pkgconf
  # is the one every distro ships now). Pure C, no perl/m4; its release tarball
  # carries a pre-generated ./configure, so it builds with just the solnix cc +
  # GNU make (no autotools at build time). Installs the `pkgconf` binary and a
  # `pkg-config` compat symlink, the name autotools/meson/cargo-build scripts
  # probe. Part of solnix-dev-full so an on-image build host can resolve
  # library flags the NixOS way (pkg-config on PATH).
  pkgconf = mkSrcPkg {
    pname = "pkgconf"; version = "2.3.0";
    src = { url = "https://distfiles.ariadne.space/pkgconf/pkgconf-2.3.0.tar.xz";
            sha256 = "3a9080ac51d03615e7c1910a0a2a8df08424892b5f13b0628a204d3fcce0ea8b"; };
    build = ''
      ./configure --prefix="$out" --disable-static
      gmake -j4
      gmake install
      ln -s pkgconf "$out/bin/pkg-config"
      "$out/bin/pkgconf" --version >/dev/null || { echo "FATAL: pkgconf --version" >&2; exit 1; }
    '';
  };

  # gcc + binutils' gas, the stdenv cc-wrapper's job reduced to what illumos needs:
  #   -B<binutils>/bin/  gcc finds `as` there when its configured /usr/bin/gas is
  #                      absent (gcc -B fakeas/ -c ran fakeas/as, measured).
  #   -Wl,-R,<gcc.lib>   C++ (and libgcc_s) programs find their runtime: no
  #                      libstdc++ is on the system's default search path.
  # Linking uses the gcc's built-in /usr/bin/ld (the gate's link-editor in the
  # system profile); headers and crt objects come from its sysroot, the gate proto.
  gccWrapper = derivation {
    name = "gcc-wrapper-14.3.0"; system = "x86_64-solaris";
    inherit gcc binutils; gccLib = gcc.lib;
    builder = "/usr/bin/bash";
    args = [ "-c" ''
      set -eu; export PATH=/usr/bin
      mkdir -p $out/bin
      for t in gcc:gcc cc:gcc g++:g++ c++:g++ cpp:cpp; do
        f="$out/bin/''${t%%:*}"; real="$gcc/bin/''${t#*:}"
        if [ "''${t#*:}" = cpp ]; then
          printf '#!/usr/bin/bash\nexec %s -B%s/bin/ "$@"\n' "$real" "$binutils" > "$f"
        else
          printf '#!/usr/bin/bash\nexec %s -B%s/bin/ -Wl,-R,%s/lib/amd64:%s/lib "$@"\n' \
            "$real" "$binutils" "$gccLib" "$gccLib" > "$f"
        fi
        chmod +x "$f"
      done
      # self-check: a C and a C++ program compile, link and run, both ABIs for C.
      cd "$(mktemp -d /var/tmp/gccwrap.XXXXXX)"
      printf '#include <stdio.h>\nint main(void){puts("hello c");return 0;}\n' > h.c
      printf '#include <iostream>\nint main(){std::cout<<"hello c++"<<std::endl;}\n' > h.cc
      for m in 64 32; do $out/bin/cc -m$m -o hc$m h.c; [ "$(./hc$m)" = "hello c" ]; done
      $out/bin/c++ -m64 -o hcc h.cc; [ "$(./hcc)" = "hello c++" ]
      echo "=== gcc-wrapper: C (64/32) and C++ hello run ===" >&2
    '' ];
  };

  # vi, ex, view: the gate already builds vi (the Sun/BSD ex/vi, 32-bit, curses
  # from the world), in two variants: usr/has/bin (the historical one) and
  # usr/xpg4/bin (built for the XPG4/POSIX behaviour). The gate's manifests put
  # neither at usr/bin/vi (IPS mediates that name; measured: no usr/bin/vi in any
  # gate .p5m), so a solnix PATH had no vi. This links the POSIX one, which is
  # what a NixOS user's vi (vim in vi mode, or nvi) behaves closest to.
  vi = derivation {
    name = "illumos-vi"; system = "x86_64-solaris"; world = needWorld;
    builder = "/usr/bin/bash";
    args = [ "-c" ''
      set -eu
      /usr/bin/mkdir -p $out/bin
      for n in vi ex view; do
        [ -x $world/usr/xpg4/bin/$n ] || { echo "FATAL: no $n in the world" >&2; exit 1; }
        /usr/bin/ln -s $world/usr/xpg4/bin/$n $out/bin/$n
      done
    '' ];
  };

  # ---- command-line packages (the NixOS base userland's interactive tools) ----

  # ncurses, wide-character. Headers go straight into include/ (--enable-overwrite)
  # with ncursesw/ and ncurses/ pointing back at it, and the unsuffixed names
  # (libncurses, libcurses, ncurses.pc) link to the w library: the nixpkgs layout,
  # so a consumer finds this ncurses whichever name it asks for rather than the
  # gate's SVR4 libcurses. The terminfo database is this package's
  # share/terminfo (compiled in, as on NixOS); TERMINFO_DIRS adds others at run time.
  ncurses = mkSrcPkg {
    pname = "ncurses"; version = "6.5";
    src = { url = "https://ftp.gnu.org/gnu/ncurses/ncurses-6.5.tar.gz";
            sha256 = "136d91bc269a9a5785e5f9e980bc76ab57428f604ce3e5a5a90cebc767971cc6"; };
    build = ''
      L="$out/lib/amd64"
      ./configure --prefix="$out" --libdir="$L" --with-shared --without-normal --without-debug \
        --enable-widec --enable-overwrite --enable-pc-files --with-pkg-config-libdir="$L/pkgconfig" \
        --without-ada --without-tests --without-cxx-binding --disable-stripping \
        --with-default-terminfo-dir="$out/share/terminfo" --with-terminfo-dirs="$out/share/terminfo"
      gmake -j4
      gmake install
      ln -s . "$out/include/ncursesw"; ln -s . "$out/include/ncurses"
      for l in ncurses curses tinfo; do ln -s libncursesw.so "$L/lib$l.so"; done
      ln -s ncursesw.pc "$L/pkgconfig/ncurses.pc"
      for t in xterm-256color sun-color vt100 screen-256color tmux-256color; do
        [ -n "$(find "$out/share/terminfo" -name "$t")" ] || { echo "FATAL: terminfo $t missing" >&2; exit 1; }
      done
      [ "$(TERM=xterm-256color "$out/bin/tput" colors)" = 256 ] || { echo "FATAL: tput colors" >&2; exit 1; }
    '';
  };

  less = mkSrcPkg {
    pname = "less"; version = "679";
    src = { url = "https://www.greenwoodsoftware.com/less/less-679.tar.gz";
            sha256 = "9b68820c34fa8a0af6b0e01b74f0298bcdd40a0489c61649b47058908a153d78"; };
    deps = [ ncurses ];
    build = ''
      ./configure --prefix="$out" --with-regex=posix
      gmake -j4
      gmake install
      # configure takes -ltinfo first, which is ncurses' libtinfo.so alias; the
      # gate's SVR4 libcurses/libtermcap must not be what it linked.
      /usr/bin/elfdump -d "$out/bin/less" | grep -q 'NEEDED.*libncursesw\.so' \
        || { echo "FATAL: less does not NEED libncursesw" >&2; /usr/bin/elfdump -d "$out/bin/less" | grep NEEDED >&2; exit 1; }
    '';
  };

  # htop, with its upstream solaris backend (kstat + libproc, both from the gate,
  # so the world is a dependency: libkstat/libproc are not in the libc slice).
  htop = mkSrcPkg {
    pname = "htop"; version = "3.4.1";
    src = { url = "https://github.com/htop-dev/htop/releases/download/3.4.1/htop-3.4.1.tar.xz";
            sha256 = "904f7d4580fc11cffc7e0f06895a4789e0c1c054435752c151e812fead9f6220"; };
    deps = [ needWorld ncurses ];
    build = ''
      # illumos <math.h> exposes NAN/isgreater only under __C99FEATURES__.
      CFLAGS="-O2 -D__EXTENSIONS__ -D__C99FEATURES__" ./configure --prefix="$out" --enable-unicode
      grep -q '^my_htop_platform=solaris\|^HTOP_PLATFORM.*solaris\|solaris/Platform' Makefile config.log \
        || { echo "FATAL: htop did not select its solaris backend" >&2; exit 1; }
      gmake -j4
      gmake install
    '';
  };

  # top: htop under the name. The SunOS top (unixtop 3.8) last released in 2008;
  # htop is maintained and carries an upstream illumos/Solaris backend. prstat is
  # the native illumos equivalent and stays in the world.
  top = derivation {
    name = "top-htop-3.4.1"; system = "x86_64-solaris"; inherit htop;
    builder = "/usr/bin/bash";
    args = [ "-c" "/usr/bin/mkdir -p $out/bin && /usr/bin/ln -s $htop/bin/htop $out/bin/top" ];
  };

  libevent = mkSrcPkg {
    pname = "libevent"; version = "2.1.12";
    src = { url = "https://github.com/libevent/libevent/releases/download/release-2.1.12-stable/libevent-2.1.12-stable.tar.gz";
            sha256 = "92e6de1be9ec176428fd2367677e61ceffc2ee1cb119035037a27d346b0403bb"; };
    deps = [ needWorld ];  # libsendfile.so.1 (the gate's), not in the libc slice
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --disable-samples \
        --disable-openssl --disable-libevent-regress --disable-debug-mode
      gmake -j4
      gmake install
    '';
  };

  tmux = mkSrcPkg {
    pname = "tmux"; version = "3.5a";
    src = { url = "https://github.com/tmux/tmux/releases/download/3.5a/tmux-3.5a.tar.gz";
            sha256 = "16216bd0877170dfcc64157085ba9013610b12b082548c7c9542cc0103198951"; };
    deps = [ needWorld libevent ncurses ];  # libxnet.so.1 is the gate's
    build = ''
      # cmd-parse.c ships pre-generated; configure only checks that a yacc exists.
      ./configure --prefix="$out" --disable-utf8proc
      gmake -j4
      gmake install
    '';
  };

  # GNU tools: home-manager's script uses GNU options (mktemp --tmpdir, readlink -f,
  # realpath: none of them in the illumos tools, measured), and so do most build
  # systems. gnulib in these tarballs declares getlocalename_l non-const, which
  # clashes with illumos <locale.h>; the sed is packages.nix's gnulibFix. The
  # world is a dependency: ls/find/sed/tar link libsec (ACLs), libgen and their
  # gate dependencies, which the libc slice does not carry (the closure gate
  # caught them resolving from /lib/64).
  # NOTE: mk-src-pkg builds one output. nixpkgs moves share/doc and share/info to
  # doc/info outputs, which a system profile does not install; with one output
  # the equivalent is to not ship them. man pages stay (NixOS installs man
  # outputs by default, documentation.man.enable).
  dropDocs = ''find "$out/share/doc" "$out/share/info" -delete 2>/dev/null || true'';
  gnuTool = { pname, version, url, sha256, flags ? "", deps ? [ needWorld ] }: mkSrcPkg {
    inherit pname version deps; src = { inherit url sha256; };
    build = ''
      for f in $(find . \( -name 'localename*.[ch]' -o -name 'getlocalename_l*.[ch]' -o -name 'setlocale_null*.c' \)); do
        sed -i 's/extern char \* *getlocalename_l/extern const char *getlocalename_l/;s/^char \* *getlocalename_l/const char *getlocalename_l/' "$f"
      done
      FORCE_UNSAFE_CONFIGURE=1 MAKEINFO=true ./configure --prefix="$out" --disable-nls ${flags}
      gmake -j4 MAKEINFO=true
      gmake install MAKEINFO=true
      ${dropDocs}
    '';
  };
  coreutils = gnuTool {
    pname = "coreutils"; version = "9.7";
    url = "https://ftp.gnu.org/gnu/coreutils/coreutils-9.7.tar.xz";
    sha256 = "e8bb26ad0293f9b5a1fc43fb42ba970e312c66ce92c1b0b16713d7500db251bf";
    # one multicall binary with a symlink per tool, nixpkgs' default (singleBinary =
    # "symlinks"): the separate binaries repeat the same gnulib code ~100 times.
    flags = "--without-selinux --disable-gcc-warnings --without-openssl --without-libgmp --enable-single-binary=symlinks";
  };
  gnugrep = gnuTool {
    pname = "gnugrep"; version = "3.11";
    url = "https://ftp.gnu.org/gnu/grep/grep-3.11.tar.xz";
    sha256 = "1db2aedde89d0dea42b16d9528f894c8d15dae4e190b59aecc78f5a951276eab";
    flags = "--disable-perl-regexp --disable-gcc-warnings";
  };
  gnused = gnuTool {
    pname = "gnused"; version = "4.9";
    url = "https://ftp.gnu.org/gnu/sed/sed-4.9.tar.xz";
    sha256 = "6e226b732e1cd739464ad6862bd1a1aba42d7982922da7a53519631d24975181";
    flags = "--disable-gcc-warnings";
  };
  gnutar = gnuTool {
    pname = "gnutar"; version = "1.35";
    url = "https://ftp.gnu.org/gnu/tar/tar-1.35.tar.xz";
    sha256 = "4d62ff37342ec7aed748535323930c7cf94acf71c3591882b26a7ea50f3edc16";
    flags = "--disable-gcc-warnings";
  };
  findutils = gnuTool {
    pname = "findutils"; version = "4.10.0";
    url = "https://ftp.gnu.org/gnu/findutils/findutils-4.10.0.tar.xz";
    sha256 = "1387e0b67ff247d2abde998f90dfbf70c1491391a59ddfecb8ae698789f0a4f5";
    flags = "--disable-gcc-warnings";
  };
  diffutils = gnuTool {
    pname = "diffutils"; version = "3.10";
    url = "https://ftp.gnu.org/gnu/diffutils/diffutils-3.10.tar.xz";
    sha256 = "90e5e93cc724e4ebe12ede80df1634063c7a855692685919bfe60b556c9bd09e";
    flags = "--disable-gcc-warnings";
  };

  # Install-media tools NixOS's minimal ISO ships (profiles/base.nix,
  # installation-cd-base.nix defaultPackages) that the illumos world lacks
  # (docs/nixos-iso-tool-parity.md). gzip: no gzip(1) anywhere in the world, and
  # solnix-install's boot_archive check calls gzip -t.
  gzip = gnuTool {
    pname = "gzip"; version = "1.13";
    url = "https://ftp.gnu.org/gnu/gzip/gzip-1.13.tar.xz";
    sha256 = "7454eb6935db17c6655576c2e1b0fabefd38b4d0936e0f87f48cd062ce91a057";
    flags = "--disable-gcc-warnings";
  };
  # nano: NixOS's manual edits configuration.nix with nano; vi is the only editor
  # in the world.
  nano = gnuTool {
    pname = "nano"; version = "8.4";
    url = "https://www.nano-editor.org/dist/v8/nano-8.4.tar.xz";
    sha256 = "5ad29222bbd55624d87ea677928b3106a743114d6c6f9b41f36c97be2a8e628d";
    flags = "--disable-libmagic --disable-speller";
    deps = [ needWorld ncurses ];
  };
  # rsync (NixOS installation-cd-base.nix defaultPackages). The bundled popt,
  # zlib-free (no -z), no optional hash/compression libraries: the media links
  # nothing it does not already carry.
  rsync = mkSrcPkg {
    pname = "rsync"; version = "3.4.1";
    src = { url = "https://download.samba.org/pub/rsync/src/rsync-3.4.1.tar.gz";
            sha256 = "2924bcb3a1ed8b551fc101f740b9f0fe0a202b115027647cf69850d65fd88c52"; };
    deps = [ needWorld ];
    build = ''
      ./configure --prefix="$out" --with-included-popt --with-included-zlib --disable-openssl \
        --disable-xxhash --disable-zstd --disable-lz4 --disable-md2man --disable-debug
      gmake -j4
      gmake install
      "$out/bin/rsync" --version | grep -q '^rsync  *version 3.4.1' || { echo "FATAL: rsync --version" >&2; exit 1; }
    '';
  };
  # smartctl: its os_solaris backend speaks ATA/SCSI through USCSI (SATA/SAS
  # disks); it has no NVMe path on illumos, where nvmeadm get-logpage is the tool.
  # configure adds -fstack-protector-strong when it links, which NEEDs libssp.so.0;
  # gcc.lib does not ship libssp, so smartctl failed to load (measured). An -f
  # option in CXXFLAGS makes configure skip that probe (configure.ac:802).
  smartmontools = mkSrcPkg {
    pname = "smartmontools"; version = "7.4";
    src = { url = "https://downloads.sourceforge.net/project/smartmontools/smartmontools/7.4/smartmontools-7.4.tar.gz";
            sha256 = "e9a61f641ff96ca95319edfb17948cd297d0cd3342736b2c49c99d4716fb993d"; };
    deps = [ needWorld ];
    build = ''
      CXXFLAGS="-g -O2 -fno-stack-protector" ./configure --prefix="$out" --without-update-smart-drivedb --without-initscriptdir \
        --without-systemdsystemunitdir --without-smartdplugindir --without-libcap-ng --without-selinux
      gmake -j4
      gmake install
      ${dropDocs}
      "$out/sbin/smartctl" --version | grep -q '^smartctl 7.4' || { echo "FATAL: smartctl --version" >&2; exit 1; }
    '';
  };

  # GNU libiconv, for gettext. The world's iconv(3) modules are the gate proto's
  # usr/lib/iconv, which has no amd64/ directory and no UTF-8%UTF-16 or
  # UTF-8%8859-1 converters, so a 64-bit msgfmt cannot read a UTF-8 .po file
  # ("invalid multibyte sequence", measured). nixpkgs links gettext to libiconv
  # on every non-glibc platform; same here.
  libiconv = mkSrcPkg {
    pname = "libiconv"; version = "1.17";
    src = { url = "https://ftp.gnu.org/gnu/libiconv/libiconv-1.17.tar.gz";
            sha256 = "8f74213b56238c85a50a5329f77e06198771e70dd9a739779f4c02f65d971313"; };
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --disable-nls
      gmake -j4
      gmake install
      find "$out/share/doc" -delete 2>/dev/null || true
      [ "$(printf '\303\251' | "$out/bin/iconv" -f UTF-8 -t UTF-16LE | od -An -tx1 | tr -d ' ')" = e900 ] \
        || { echo "FATAL: libiconv UTF-8 -> UTF-16LE self-check" >&2; exit 1; }
    '';
  };

  # gettext: home-manager prints its messages through gettext/ngettext (the
  # illumos world has gettext and msgfmt but no ngettext, measured) and its
  # build runs msgfmt. Only the runtime tools are built (gettext-runtime, plus
  # msgfmt from gettext-tools); NLS stays on, it is the point of the package.
  gettext = mkSrcPkg {
    pname = "gettext"; version = "0.22.5";
    src = { url = "https://ftp.gnu.org/gnu/gettext/gettext-0.22.5.tar.xz";
            sha256 = "fe10c37353213d78a5b83d48af231e005c4da84db5ce88037d88355938259640"; };
    deps = [ needWorld libiconv ];
    build = ''
      for f in $(find . \( -name 'localename*.[ch]' -o -name 'getlocalename_l*.[ch]' -o -name 'setlocale_null*.c' \)); do
        sed -i 's/extern char \* *getlocalename_l/extern const char *getlocalename_l/;s/^char \* *getlocalename_l/const char *getlocalename_l/' "$f"
      done
      # ac_cv_func_memset_s=no: gnulib's memset_explicit.c defines __STDC_WANT_LIB_EXT1__
      # after config.h has already pulled in illumos <sys/feature_tests.h>, so
      # memset_s stays undeclared (gcc 14: implicit declaration error, measured);
      # without it gnulib uses its memset + compiler-barrier fallback.
      ac_cv_func_memset_s=no MAKEINFO=true ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --disable-java \
        --disable-csharp --disable-openmp --disable-acl --disable-curses --without-emacs --without-git \
        --without-cvs --without-xz --without-bzip2 --with-included-libxml --with-included-libunistring \
        --with-included-gettext --disable-c++ --with-libiconv-prefix=${libiconv}
      gmake -j4 MAKEINFO=true
      gmake install MAKEINFO=true
      ${dropDocs}
      # share/gettext/archive.dir.tar.gz is autopoint's/gettextize's m4 archive
      # (6.7 MB), for maintainers regenerating a package's build system; nothing at
      # run time reads it, so it and the two tools that need it are not shipped.
      find "$out/share/gettext/archive.dir.tar.gz" "$out/bin/autopoint" "$out/bin/gettextize" -delete
      for t in gettext ngettext envsubst msgfmt; do [ -x "$out/bin/$t" ] || { echo "FATAL: no $t" >&2; exit 1; }; done
      [ "$("$out/bin/ngettext" one many 2)" = many ] || { echo "FATAL: ngettext self-check" >&2; exit 1; }
      # msgfmt must read UTF-8 (home-manager's .po files): the failure mode above.
      printf 'msgid ""\nmsgstr "Content-Type: text/plain; charset=UTF-8\\n"\n\nmsgid "a"\nmsgstr "\303\251"\n' > t.po
      "$out/bin/msgfmt" -o t.mo t.po || { echo "FATAL: msgfmt cannot read UTF-8" >&2; exit 1; }
      /usr/bin/elfdump -d "$out/bin/msgfmt" | grep -q 'NEEDED.*libiconv' || { echo "FATAL: msgfmt not linked to libiconv" >&2; exit 1; }
    '';
  };

  # jq, without oniguruma (no regex builtins: test/match/sub). home-manager
  # only uses @uri and -r.
  jq = mkSrcPkg {
    pname = "jq"; version = "1.7.1";
    src = { url = "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-1.7.1.tar.gz";
            sha256 = "478c9ca129fd2e3443fe27314b455e211e0d8c60bc8ff7df703873deeee580c2"; };
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-docs --disable-static --without-oniguruma
      gmake -j4
      gmake install
      [ "$(echo '{"a":[1,2]}' | "$out/bin/jq" -c '.a|add')" = 3 ] || { echo "FATAL: jq self-check" >&2; exit 1; }
      ${dropDocs}
    '';
  };

  # lndir (X.org util), which home-manager's home-files derivation runs to merge
  # the generated tree, as on NixOS (xorg.lndir). Its build needs only
  # xorgproto's headers and xproto.pc, which install without compiling anything.
  xorgproto = mkSrcPkg {
    pname = "xorgproto"; version = "2024.1";
    src = { url = "https://www.x.org/releases/individual/proto/xorgproto-2024.1.tar.xz";
            sha256 = "372225fd40815b8423547f5d890c5debc72e88b91088fbfb13158c20495ccb59"; };
    build = ''
      ./configure --prefix="$out" --datarootdir="$out/share" --without-xmlto --without-fop --disable-legacy
      gmake install
    '';
  };
  lndir = mkSrcPkg {
    pname = "lndir"; version = "1.0.5";
    src = { url = "https://www.x.org/releases/individual/util/lndir-1.0.5.tar.xz";
            sha256 = "3b65577a5575cce095664f5492164a96941800fe6290a123731d47f3e7104ddb"; };
    linkDeps = [ xorgproto ];
    build = ''
      ./configure --prefix="$out"
      gmake -j4
      gmake install
      # self-check: a tree of links that mirrors the source tree.
      mkdir -p t/s/a t/d; echo x > t/s/a/f
      "$out/bin/lndir" -silent "$PWD/t/s" t/d
      [ -L t/d/a/f ] && [ "$(cat t/d/a/f)" = x ] || { echo "FATAL: lndir self-check" >&2; exit 1; }
    '';
  };

  # hostname with -f: home-manager's flake mode looks up "$USER@$(hostname -f)"
  # (then $(hostname), $(hostname -s)) to pick a homeConfigurations entry, and
  # illumos hostname has no -f (usage: hostname [-s], measured). -f prints the
  # name plus the DNS domain when one is configured (domainname), else the
  # bare name: the same fallback GNU inetutils' hostname -f gives an
  # unresolvable host. Every other use goes to the system's hostname.
  hostname = derivation {
    name = "hostname-f"; system = "x86_64-solaris";
    builder = "/usr/bin/bash";
    args = [ "-c" ''
      /usr/bin/mkdir -p $out/bin
      /usr/bin/cat > $out/bin/hostname <<'EOF'
    #!/usr/bin/bash
    if [ "$#" = 1 ] && { [ "$1" = -f ] || [ "$1" = --fqdn ]; }; then
      h=$(/usr/bin/hostname); d=$(/usr/bin/domainname 2>/dev/null)
      [ -n "$d" ] && case "$h" in *.*) ;; *) h="$h.$d";; esac
      echo "$h"; exit 0
    fi
    exec /usr/bin/hostname "$@"
    EOF
      /usr/bin/chmod 555 $out/bin/hostname
      [ "$($out/bin/hostname -f)" = "$(/usr/bin/hostname)" ] || [ -n "$(/usr/bin/domainname)" ]
    '' ];
  };

  # home-manager (the command), pinned to the release-26.05 commit the
  # maintainer's nix-config locks. nixpkgs builds it with runCommand +
  # substituteInPlace; this does the same five substitutions with sed, so it
  # needs no stdenv. Its runtime PATH is the solnix GNU tools above: the script
  # and its activation use readlink -e, realpath -m, mktemp --tmpdir, find -printf
  # and ngettext, none of which the illumos tools provide (measured). The
  # source is also installed as share/home-manager, the <home-manager> path the
  # script's non-flake build resolves its modules from. nixos-option is not on
  # the path, so the home-manager option subcommand is the one that is missing;
  # inetutils' role (hostname -f) is the hostname shim above.
  home-manager = derivation {
    name = "home-manager-26.05-db7d5e2"; system = "x86_64-solaris";
    # tests/ (1.9 MB, ~2,700 files) is dropped: only the module tree, lib and the
    # script are read at run time. nixpkgs' package keeps the whole source as
    # HOME_MANAGER_PATH; this departs from it to fit the installer media.
    hmSrc = let src = builtins.fetchTarball {
      url = "https://github.com/nix-community/home-manager/archive/db7d5e2332710f5abb088f6b5de927d7f9511b35.tar.gz";
      sha256 = "1vy9bsc0wgz9ccgghpv4vn0z077j486il9jhrld78llf9720xsbz";
    }; in builtins.path { path = src; name = "home-manager-source"; filter = p: _: p != "${src}/tests"; };
    inherit bash;
    depPath = builtins.concatStringsSep ":" (map (p: "${p}/bin") [ coreutils findutils gettext gnused gnugrep jq less ncurses hostname ]);
    msgfmt = "${gettext}/bin/msgfmt";
    builder = "/usr/bin/bash";
    args = [ "-c" ''
      set -eu; export PATH=/usr/bin
      mkdir -p $out/bin $out/share/bash
      ln -s $hmSrc $out/share/home-manager
      cp $hmSrc/lib/bash/home-manager.sh $out/share/bash/home-manager.sh
      sed -e "s|@bash@|$bash|g" -e "s|@DEP_PATH@|$depPath|g" \
          -e "s|@HOME_MANAGER_LIB@|$out/share/bash/home-manager.sh|g" \
          -e "s|@HOME_MANAGER_PATH@|$out/share/home-manager|g" -e "s|@OUT@|$out|g" \
          $hmSrc/home-manager/home-manager > $out/bin/home-manager
      chmod 555 $out/bin/home-manager
      if grep -n '@[A-Za-z_]*@' $out/bin/home-manager; then echo "FATAL: unsubstituted @var@" >&2; exit 1; fi
      for f in $hmSrc/home-manager/po/*.po; do
        l=''${f##*/}; l=''${l%.po}; mkdir -p $out/share/locale/$l/LC_MESSAGES
        $msgfmt -o $out/share/locale/$l/LC_MESSAGES/home-manager.mo $f
      done
      [ "$($out/bin/home-manager --version)" = 26.05-pre ] || { echo "FATAL: home-manager --version" >&2; exit 1; }
    '' ];
  };

  bash = mkSrcPkg {
    pname = "bash"; version = "5.2.37";
    src = { url = "https://ftp.gnu.org/gnu/bash/bash-5.2.37.tar.gz";
            sha256 = "9599b22ecd1d5787ad7d3b7bf0c59f312b3396d1e281175dd1f8a4014da621ff"; };
    deps = [ needWorld ];
    build = ''
      # illumos curses declares tputs(..., int (*)(char)); GCC 14 errors on the
      # mismatch with bash's int (*)(int) putc callback (display.c:2839, measured).
      CFLAGS="-O2 -Wno-error=incompatible-pointer-types" \
      ./configure --prefix="$out" --without-bash-malloc --disable-nls
      gmake -j6
      gmake install
    '';
  };
}
