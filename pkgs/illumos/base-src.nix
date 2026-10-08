# base-src.nix -- the non-gate packages the base system needs, built FROM SOURCE
# with mk-src-pkg.nix. Each one replaces something that used to be copied from
# the build host: zlib + libxml2 replace externalLibs (host /usr/lib copies),
# openssl + openssh replace make-be's host sshd copy, bash replaces nothing (the
# gate has no bash) but is a login shell users expect.
{ gate, libcSlice, world ? null, gcc ? "/usr/gcc/14" }:
# gcc: the from-source gcc derivation (gcc-src.nix). Everything here is compiled
# by it, both ABIs; the IPS seed only compiled gcc itself.

let
  mkSrcPkg = import ./mk-src-pkg.nix {
    inherit gate gcc;
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
