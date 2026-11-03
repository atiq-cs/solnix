# base-src.nix -- the non-gate packages the base system needs, built FROM SOURCE
# with mk-src-pkg.nix. Each one replaces something that used to be copied from
# the build host: zlib + libxml2 replace externalLibs (host /usr/lib copies),
# openssl + openssh replace make-be's host sshd copy, bash replaces nothing (the
# gate has no bash) but is a login shell users expect.
{ gate, libcSlice, world ? null, gcc ? "/usr/gcc/14", buildTools ? [ ], seedTools ? [ ], aarch64 ? false, system ? "x86_64-solaris"
, nixChainTools ? { }, perl ? null
, mkSrcPkgA ? null, plain ? (d: d)   # aarch64 store-only set (main af5ac0e, aarch64/tools.nix): its mkSrcPkg, and the plain drvs' text -> store tools
, shared ? { } }:   # one ncurses/less/libiconv from the caller (aarch64 final: srcPkgs'); x86: {} (one copy each already, wave6t step11)   # { cmake; bzip2Bin; } from the cli set (default.nix), for nixChain's store-only builds
# perl: the store perl (cli), for curl's man pages; its build closure has no nixChain, so no cycle. null: curl keeps the old text.
# aarch64/system: the same recipes natively on aarch64 illumos (aarch64/home.nix), through
# mk-src-pkg's aarch64 text rewrite. The defaults leave every x86 derivation unchanged.
# gcc: the from-source gcc derivation (gcc-src.nix). Everything here is compiled
# by it, both ABIs; the IPS seed only compiled gcc itself.
# buildTools: store paths whose bin/ go first on every mk-src-pkg builder PATH
# (store gmake/gnutar/gzip/xz/bzip2/gnugrep/gnused/gstrip). Default [] keeps the
# OI buildhost path (/usr/gnu + host decompressors). A solnix system passes the
# store set so it can build with no /usr/gnu. Threaded to mkSrcPkg below.

let
  mkSrcPkg = if mkSrcPkgA != null then mkSrcPkgA else if aarch64
    then args: import ./mk-src-pkg.nix { inherit gate gcc buildTools aarch64; runtimeLibDirs = [ "${libcSlice}/lib" ]; } (args // { inherit system; })
    else args: import ./mk-src-pkg.nix {
    inherit gate gcc buildTools;
    runtimeLibDirs = [ "${libcSlice}/lib/amd64" "${libcSlice}/lib" ];
    # wave6: store-only by default (NixOS stdenv). Exempt: the seed instance (buildTools = [ ]), until bootstrap-tools.
    storeOnly = buildTools != [ ];
    seedOuts = buildTools == [ ];   # the seed's outs pass the content gate too (wave6t; mk-src-pkg seedOuts)
    # the world's own closure (zlib libxml2 nspr nss) and the two tools in hostTools cannot use hostTools (a cycle): they get
    # the seed instance's world-free set (lib/host-pkgs.nix seedTools: perl coreutils findutils + the seed world).
    defaultNativeTools = if builtins.elem (args.pname or "") [ "zlib" "libxml2" "nspr" "nss" "coreutils" "findutils" "pkgconf" ] then seedTools   # pkgconf: libxml2 (in the world) needs it
      else if (args.pname or "") == "bash" then hostToolsNoBash else hostTools;
  } (args // { # the seed instance is build-only (nothing it builds ships): no man/info/doc outputs there, so its drvs (and gcc15) do not move
    docOutputs = if buildTools == [ ] then [ ] else args.docOutputs or [ ]; });
  needWorld = if world == null then throw "base-src: this package needs the userland world" else world;
  # [] for the seed (buildTools = [], the OI bootstrap that builds seedBuildTools): its recipes keep the OI PATH, so no cycle and no seed move.
  # store bash first (recipes1 LOOPHOLES class 3: automake's configure wanted a POSIX shell the store-only PATH lacked and the OI host
  # had; NixOS's stdenv always has bash on PATH). bash itself builds with the rest (no cycle: its only dep is the world).
  hostToolsNoBash = if buildTools == [ ] then [ ] else [ self.coreutils self.findutils needWorld ];
  hostTools = if buildTools == [ ] then [ ] else [ self.bash ] ++ hostToolsNoBash;
  # hermetic recipes (mk-src-pkg nativeTools): the store tools a configure/make run needs, NixOS stdenv's set (coreutils: GNU install,
  # findutils, gnused/gnugrep/gnutar/gzip/xz/make via the seed in buildTools), then the world for the illumos tools (elfdump, ld, nm).
  # Only recipes that are NOT one of these may use it (no cycle): coreutils/findutils are base outs that do not take nativeTools.
  self = rec {
  inherit mkSrcPkg hostTools;

  # Nix 2.24.15 + its dependency chain (./nix-src.nix).
  nixChain = import ./nix-src.nix ({ inherit mkSrcPkg zlib openssl libcSlice hostTools perl; system = "x86_64-solaris"; gccLib = gcc.lib; } // nixChainTools);

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
    pname = "libxml2"; version = "2.15.4";   # 8 High in 2.14.6 (fixed 2.15.3/2.15.4); 2.14 has no later release; soname stays .16
    src = { url = "https://download.gnome.org/sources/libxml2/2.15/libxml2-2.15.4.tar.xz";
            sha256 = "98087fd181d9070724f3fbc65c7377db03038eb92bd882374daff44940138821"; };
    abis = [ "64" "32" ];
    deps = [ zlib ];
    # + pkg-config: 2.15's configure requires it (PKG_PROG_PKG_CONFIG, PKG_CHECK_MODULES zlib); the OI host gave /usr/bin/pkg-config.
    # The store pkgconf is world-free (its own deps: libc), so the world's closure stays acyclic.
    nativeTools = if buildTools == [ ] then null else [ self.pkgconf ] ++ seedTools;
    build = ''
      # 2.15 removed LZMA support (and --without-lzma) and the HTTP client (its symbols are stubs: the soname stays .16)
      ./configure --prefix="$out" --libdir="$out/$LIBSUB" --without-python --without-icu \
        --with-zlib --disable-static --without-debug
      gmake -j4
      gmake install
    '';
  };

  openssl = mkSrcPkg {
    pname = "openssl"; version = "3.4.8";   # 30 High/Critical in 3.4.0, all fixed by 3.4.8. 3.4 went EOL 2026-10-22: next is 3.5 LTS
    src = { url = "https://github.com/openssl/openssl/releases/download/openssl-3.4.8/openssl-3.4.8.tar.gz";
            sha256 = "9de9ce2f29e584044ae07ab93fc601637be01fdc91d109c5a655ec7419e6022b"; };
    # libc only (runtimeLibDirs): no world dep, so nix's closure does not pull
    # the whole userland in through libcrypto.
    # Configure is perl (OI had /usr/bin/perl). The store perl depends on openssl's dependents' world, so openssl takes the
    # seed tools (perl coreutils findutils + the seed world: world-free of this instance), as nss does. Build-time only.
    nativeTools = if buildTools == [ ] then null else seedTools;
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
    pname = "openssh"; version = "10.6p1";
    src = { url = "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-10.6p1.tar.gz";
            sha256 = "a9dc9565dffe8640f64d863cd29a32bc4a3dbdec0566a7fc44c5d6ee767d5f39"; };   # .asc: Damien Miller RELEASE_KEY 7168B983
    deps = [ needWorld zlib openssl ];
    nativeTools = hostTools;   # store-only PATH + config.site (wave4: host /usr/gnu, /usr/bin perl/python3/xauth/openssl leaked into configure)
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
      # build stamp from SOURCE_DATE_EPOCH, as nixpkgs' nspr patch (the Makefiles call date(1) and ./now).
      gmake -j4 SH_DATE="1980-01-01 00:00:00" SH_NOW="''${SOURCE_DATE_EPOCH}000000"
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
    # store-only PATH from the seed (world-free: the world links nss): perl for certdata.perl, coreutils, the seed world's ar/uname/nawk.
    nativeTools = seedTools;
    build = ''
      # ./patches/nss/0001-hacl-bignum-base-include-alloca.patch, applied with sed: GNU patch depends on the world, which depends on nss.
      H=nss/lib/freebl/verified/internal/Hacl_Bignum_Base.h
      sed -i 's@^#include <string.h>$@#include <alloca.h>\n#include <string.h>@' "$H"
      grep -q '^#include <alloca.h>$' "$H" || { echo "FATAL: nss alloca include not applied" >&2; exit 1; }
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
      # no *.chk: shlibsign's DSA signature is random per build (so no two builds match, measured, repro2), and
      # it is only read in FIPS mode. nixpkgs makes them only with enableFIPS (default false).
      cp -P "$O"/lib/*.so "$out/$LIBSUB/"
      # headers once (ABI 64, the first pass): they are ABI-independent, and the 32-bit pass's cp onto the 64-bit pass's read-only copies
      # fails as nixbld ('Permission denied'); every earlier nss was built as root, which overwrote them (wave5 W1).
      [ "$ABI" = 64 ] && cp dist/public/nss/*.h dist/public/dbm/*.h "$out/include/nss/"
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
    nativeTools = hostTools;   # store-only PATH (wave4: INSTALL=/usr/gnu/bin/install did not exist on a solnix host): GNU install + tar from the store
    build = ''
      cat > config.mak <<EOF
      CC = $CC
      prefix = $out
      SHELL_PATH = ${bash}/bin/bash
      NO_PERL = YesPlease
      NO_PYTHON = YesPlease
      NO_TCLTK = YesPlease
      NO_GETTEXT = YesPlease
      NO_EXPAT = YesPlease
      NO_INSTALL_HARDLINKS = YesPlease
      INSTALL_SYMLINKS = YesPlease
      SKIP_DASHED_BUILT_INS = YesPlease
      INSTALL = install
      TAR = tar
      ZLIB_PATH = ${zlib}
      OPENSSLDIR = ${openssl}
      CURLDIR = ${nixChain.curl}
      CURL_LDFLAGS = -lcurl
      lib = lib/amd64
      CC_LD_DYNPATH = -Wl,-R,
      EOF
      gmake -j4 all
      gmake install
      # NO_PERL leaves the fsmonitor-watchman sample hook on #!/usr/bin/perl (host; out-host-refs). /usr/bin/env perl: the user's.
      sed -i '1s|^#!/usr/bin/perl$|#!/usr/bin/env perl|' "$out/share/git-core/templates/hooks/fsmonitor-watchman.sample"
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
    # 2.47 is the signed release (Nick Clifton's key, sha256 = the announcement's), but its bfd/development.sh still says
    # development=true experimental=true, so it calls itself 2.47.20260726, turns on extra checking and -Werror (Debian
    # reported it on binutils@, 2026-07-26). Set both to false, as every other release tarball has them.
    pname = "binutils"; version = "2.47";
    src = { url = "https://mirrors.kernel.org/gnu/binutils/binutils-2.47.tar.xz";
            sha256 = "154ab23b60070e8f27013c22977f1129425d67d1e8acd6e13010e617811e4cff"; };
    build = ''
      T=x86_64-pc-solaris2.11
      sed -i 's/^development=true$/development=false/; s/^experimental=true$/experimental=false/' bfd/development.sh
      grep -qx development=false bfd/development.sh || { echo "FATAL: bfd/development.sh not pinned" >&2; exit 1; }
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
      "$out/bin/as" --version | head -1 | grep -q ' 2\.47$' || { echo "FATAL: gas does not say 2.47: $("$out/bin/as" --version | head -1)" >&2; exit 1; }
    '';
  };

  # GNU make. The gate's make is illumos make (`make -v` = "illumos make"); GNU
  # build systems want GNU make, which OpenIndiana ships as gmake. Both names here.
  gnumake = mkSrcPkg {
    pname = "gnumake"; version = "4.4.1";
    src = { url = "https://mirrors.kernel.org/gnu/make/make-4.4.1.tar.gz";
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
    name = "gcc-wrapper-${gcc.version}"; system = "x86_64-solaris";
    inherit gcc binutils; gccLib = gcc.lib;
    builder = "/usr/bin/bash";
    # store coreutils (+ the world for its runtime) on PATH, not /usr/bin (OpenIndiana's on an OI host). The seed instance
    # (buildTools = [ ], exempt until the bootstrap-tools wave) has no store coreutils of its own yet: it keeps /usr/bin.
    # wave6t: the seed instance too (its own coreutils + world: store paths, gate2 A1). The wrappers' #! is /bin/sh (POSIX: they
    # only exec with "$@"; gate B9 rejected #!/usr/bin/bash), so the wrapper pulls no bash into a closure.
    wrapPath = "${coreutils}/bin:${needWorld}/usr/bin";
    pathGate = "${./path-gate.sh}";
    shell = "/bin/sh";
    # the store libc's lib dirs in every link's RUNPATH, as NixOS's cc-wrapper adds glibc's: without them a program (iwm-driver's
    # wpa-pmk, P0 run n) took libc.so.1 from the host's /lib/64 and failed the publish gate. The seed's text is untouched (it, and
    # the gcc15 it builds, must not move): the edit is a text rewrite applied off the seed only.
    args = map (t: if buildTools == [ ] then t else builtins.replaceStrings [ "-Wl,-R,%s/lib/amd64:%s/lib \"$@\"\\n' \\\n      \"$shell\" \"$real\" \"$binutils\" \"$gccLib\" \"$gccLib\" > \"$f\"" "echo \"=== gcc-wrapper: C (64/32) and C++ hello run ===\" >&2" ] [ "-Wl,-R,%s/lib/amd64:%s/lib:%s/lib/amd64:%s/lib \"$@\"\\n' \\\n      \"$shell\" \"$real\" \"$binutils\" \"$gccLib\" \"$gccLib\" \"${libcSlice}\" \"${libcSlice}\" > \"$f\"" "for x in hc64 hc32 hcc; do ldd ./$x | grep 'libc\\.so\\.1' | grep -q '=>[[:space:]]*/nix/store/' || { echo \"FATAL: gcc-wrapper: $x takes libc from the host\" >&2; exit 1; }; done\n      echo \"=== gcc-wrapper: C (64/32) and C++ hello run, libc from the store ===\" >&2" ] t) [ "-c" ''
      set -eu; export PATH=$wrapPath
      [ -z "$pathGate" ] || /usr/bin/bash "$pathGate"
      mkdir -p $out/bin
      for t in gcc:gcc cc:gcc g++:g++ c++:g++ cpp:cpp; do
        f="$out/bin/''${t%%:*}"; real="$gcc/bin/''${t#*:}"
        if [ "''${t#*:}" = cpp ]; then
          printf '#!%s\nexec %s -B%s/bin/ "$@"\n' "$shell" "$real" "$binutils" > "$f"
        else
          printf '#!%s\nexec %s -B%s/bin/ -Wl,-R,%s/lib/amd64:%s/lib "$@"\n' \
            "$shell" "$real" "$binutils" "$gccLib" "$gccLib" > "$f"
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
    PATH = "${coreutils}/bin";   # store-only (wave6, gate2 A1); the seed instance has no vi
    args = [ "-c" ''
      set -eu
      /usr/bin/bash ${./path-gate.sh}
      mkdir -p $out/bin
      for n in vi ex view; do
        [ -x $world/usr/xpg4/bin/$n ] || { echo "FATAL: no $n in the world" >&2; exit 1; }
        ln -s $world/usr/xpg4/bin/$n $out/bin/$n
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
  ncurses = shared.ncurses or (mkSrcPkg {
    pname = "ncurses"; version = "6.5";
    docOutputs = [ "man" ];   # nixpkgs ncurses: man output
    src = { url = "https://mirrors.kernel.org/gnu/ncurses/ncurses-6.5.tar.gz";
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
  });

  less = shared.less or (mkSrcPkg {
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
  });

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
    name = "top-htop-3.4.1"; inherit system; inherit htop;
    builder = "/usr/bin/bash";
    PATH = "${coreutils}/bin";   # store-only (wave6, gate2 A1)
    args = [ "-c" "/usr/bin/bash ${./path-gate.sh} && mkdir -p $out/bin && ln -s $htop/bin/htop $out/bin/top && true" ];   # true: see cacert
  };

  libevent = mkSrcPkg {
    pname = "libevent"; version = "2.1.13";
    src = { url = "https://github.com/libevent/libevent/releases/download/release-2.1.13-stable/libevent-2.1.13-stable.tar.gz";
            sha256 = "f7e9383b8c0baa81b687e5b5eecc01beefaf1b19b64151d95ed61647fe7a315c"; };   # upstream .asc: Nick Mathewson 7A02B352
    deps = [ needWorld ];  # libsendfile.so.1 (the gate's), not in the libc slice
    nativeTools = hostTools;   # store-only PATH + config.site (recipes1)
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
    nativeTools = hostTools;   # store-only PATH + config.site (recipes1); yacc is the world's
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
  gnuTool = { pname, version, url, sha256, flags ? "", deps ? [ needWorld ], nativeTools ? null, docOutputs ? [ ] }: mkSrcPkg {
    inherit pname version deps nativeTools docOutputs; src = { inherit url sha256; };
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
    pname = "coreutils"; version = "9.12";
    docOutputs = [ "man" ];   # nixpkgs coreutils: info output too, but dropDocs deletes share/info here (MAKEINFO=true)
    url = "https://mirrors.kernel.org/gnu/coreutils/coreutils-9.12.tar.xz";
    sha256 = "a480198559733e9b3da999e90543ac6f888a2caa544d8d664c5a1f17e528e210";
    # one multicall binary with a symlink per tool, nixpkgs' default (singleBinary =
    # "symlinks"): the separate binaries repeat the same gnulib code ~100 times.
    # kill,uptime: 9.12 stopped installing them by default (9.7 did; nixpkgs passes arch,kill,uptime). No arch: the
    # world's arch(1) prints the illumos kernel arch (i86pc), and a GNU arch on PATH would shadow it.
    flags = "--without-selinux --disable-gcc-warnings --without-openssl --without-libgmp --enable-single-binary=symlinks --enable-install-program=kill,uptime";
  };
  gnugrep = gnuTool {
    pname = "gnugrep"; version = "3.11";
    url = "https://mirrors.kernel.org/gnu/grep/grep-3.11.tar.xz";
    sha256 = "1db2aedde89d0dea42b16d9528f894c8d15dae4e190b59aecc78f5a951276eab";
    flags = "--disable-perl-regexp --disable-gcc-warnings";
  };
  gnused = gnuTool {
    pname = "gnused"; version = "4.9";
    url = "https://mirrors.kernel.org/gnu/sed/sed-4.9.tar.xz";
    sha256 = "6e226b732e1cd739464ad6862bd1a1aba42d7982922da7a53519631d24975181";
    flags = "--disable-gcc-warnings";
  };
  gnutar = gnuTool {
    pname = "gnutar"; version = "1.35";
    url = "https://mirrors.kernel.org/gnu/tar/tar-1.35.tar.xz";
    sha256 = "4d62ff37342ec7aed748535323930c7cf94acf71c3591882b26a7ea50f3edc16";
    flags = "--disable-gcc-warnings";
    nativeTools = hostTools;   # store-only PATH + config.site: chef and dixi probed different locales/iconv/tools (wave4)
  };
  findutils = gnuTool {
    pname = "findutils"; version = "4.10.0";
    url = "https://mirrors.kernel.org/gnu/findutils/findutils-4.10.0.tar.xz";
    sha256 = "1387e0b67ff247d2abde998f90dfbf70c1491391a59ddfecb8ae698789f0a4f5";
    flags = "--disable-gcc-warnings";
  };
  diffutils = gnuTool {
    pname = "diffutils"; version = "3.10";
    url = "https://mirrors.kernel.org/gnu/diffutils/diffutils-3.10.tar.xz";
    sha256 = "90e5e93cc724e4ebe12ede80df1634063c7a855692685919bfe60b556c9bd09e";
    flags = "--disable-gcc-warnings";
    nativeTools = hostTools;   # store-only PATH + config.site: chef and dixi probed different locales/iconv/O_NOATIME/install (wave4 cfg/diffutils-3.10.diff)
  };

  # Install-media tools NixOS's minimal ISO ships (profiles/base.nix,
  # installation-cd-base.nix defaultPackages) that the illumos world lacks
  # (docs/nixos-iso-tool-parity.md). gzip: no gzip(1) anywhere in the world, and
  # solnix-install's boot_archive check calls gzip -t.
  gzip = gnuTool {
    pname = "gzip"; version = "1.13";
    url = "https://mirrors.kernel.org/gnu/gzip/gzip-1.13.tar.xz";
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
  # nvi (nvi2) and the BSD DB 1.85 it edits through: the maintainer-required nvi,
  # and solnix's vi (bin/vi, ex, view link to nvi). See ./nvi2.nix and ./db1.nix.
  db1 = import ./db1.nix { inherit mkSrcPkg; };
  nvi = import ./nvi2.nix { inherit mkSrcPkg ncurses db1 libiconv; };
  # rsync (NixOS installation-cd-base.nix defaultPackages). The bundled popt,
  # zlib-free (no -z), no optional hash/compression libraries: the media links
  # nothing it does not already carry.
  rsync = mkSrcPkg {
    pname = "rsync"; version = "3.5.0";
    src = { url = "https://download.samba.org/pub/rsync/src/rsync-3.5.0.tar.gz";
            sha256 = "c7ffd1ef653e99540f661e47cb00b7f9cad1ee6b972399b16f93d672656e0d33"; };   # upstream .asc: Andrew Tridgell 9FEF112D
    deps = [ needWorld ];
    nativeTools = hostTools;   # store-only PATH + config.site (wave4: host /usr/gnu, /usr/bin perl/python3/xauth/openssl leaked into configure)
    build = ''
      ./configure --prefix="$out" --with-included-popt --with-included-zlib --disable-openssl \
        --disable-xxhash --disable-zstd --disable-lz4 --disable-md2man --disable-debug
      gmake -j4
      gmake install
      "$out/bin/rsync" --version | grep -q '^rsync  *version 3.5.0' || { echo "FATAL: rsync --version" >&2; exit 1; }
    '';
  };
  # smartctl: its os_solaris backend speaks ATA/SCSI through USCSI (SATA/SAS
  # disks); it has no NVMe path on illumos, where nvmeadm get-logpage is the tool.
  # configure adds -fstack-protector-strong when it links, which NEEDs libssp.so.0;
  # gcc.lib does not ship libssp, so smartctl failed to load (measured). An -f
  # option in CXXFLAGS makes configure skip that probe (configure.ac:802).
  smartmontools = mkSrcPkg {
    pname = "smartmontools"; version = "7.4";
    # the Makefile's own seds that REWRITE upstream's /usr/local paths to the configured dirs (15 lines: -e 's|/usr/local/..|$(dir)|',
    # sed 's|/usr/local/..|..|'; 93f0cfc's narrower pattern left 769-808 as hits, W2 t7 931ik18z)
    hostPathAllow = "(sed|-e) 's[|]/usr/local/";
    src = { url = "https://downloads.sourceforge.net/project/smartmontools/smartmontools/7.4/smartmontools-7.4.tar.gz";
            sha256 = "e9a61f641ff96ca95319edfb17948cd297d0cd3342736b2c49c99d4716fb993d"; };
    deps = [ needWorld ];
    build = ''
      # --with-scriptpath: the PATH smartd's warning scripts run with (etc/smartd_warning.sh); configure's default is
      # /usr/local/bin:/usr/bin:/bin. The system profile, as on NixOS (the store-only build must not name /usr/local; gate B13 WARNed it).
      CXXFLAGS="-g -O2 -fno-stack-protector" ./configure --prefix="$out" --with-scriptpath=/run/current-system/sw/bin:/usr/bin:/bin \
        --without-update-smart-drivedb --without-initscriptdir \
        --without-systemdsystemunitdir --without-smartdplugindir --without-libcap-ng --without-selinux
      gmake -j4
      gmake install
      ${dropDocs}
      "$out/sbin/smartctl" --version | grep -q '^smartctl 7.4' || { echo "FATAL: smartctl --version" >&2; exit 1; }
    '';
  };

  # tree: the directory lister the maintainer's required set names. Plain
  # make (no autotools). illumos declares `struct comment` in a system header
  # pulled in via tree's includes; tree.h defines its own `struct comment` ->
  # redefinition error, so rename tree's struct throughout (packages.nix' fix).
  # Installs its own man page at share/man/man1/tree.1 (MANDIR), so `man tree`
  # works through the system MANPATH. 64-bit build; __EXTENSIONS__ for strcasecmp.
  tree = mkSrcPkg {
    pname = "tree"; version = "2.1.3";
    src = { url = "https://gitlab.com/OldManProgrammer/unix-tree/-/archive/2.1.3/unix-tree-2.1.3.tar.gz";
            sha256 = "f554a1b62233b96fa8eaa2d85e91bc62cad80ee441fd591380f16cdfbe3e8868"; };
    deps = [ needWorld ];
    nativeTools = hostTools;   # store-only PATH + config.site (wave4: host /usr/gnu, /usr/bin perl/python3/xauth/openssl leaked into configure)
    build = ''
      for f in *.c *.h; do
        [ -f "$f" ] || continue
        sed -i 's/struct comment/struct tree_comment/g' "$f"
      done
      gmake -j4 CC="$CC" CFLAGS="-D__EXTENSIONS__ -O2 -m64" MANDIR="$out/share/man" PREFIX="$out"
      gmake install PREFIX="$out" MANDIR="$out/share/man"
      "$out/bin/tree" --version | grep -q '^tree v2.1.3' || { echo "FATAL: tree --version" >&2; exit 1; }
      [ -f "$out/share/man/man1/tree.1" ] || { echo "FATAL: tree ships no man page" >&2; exit 1; }
    '';
  };

  # wget: the maintainer's required file-transfer tool (alongside curl). GNU
  # autotools; TLS via the from-source openssl, gzip via zlib. No libpsl / pcre2
  # here (not in base-src), so --without-libpsl and no PCRE URL filtering; neither
  # is needed for `wget <url>`. gnulibFix for the getlocalename_l clash,
  # illumosExt for strcasecmp/_XOPEN_SOURCE. Installs share/man/man1/wget.1, so
  # `man wget` works through the system MANPATH.
  # wget's man page is pod2man output, and pod2man is perl's: perl is a cli package (after this set), so the recipe takes it as an
  # argument (wgetWith); default.nix exports wgetWith cli.perl. The plain `wget` here (no perl) is what other base packages could use.
  wget = wgetWith null;
  wgetWith = perl: mkSrcPkg ({
    pname = "wget"; version = "1.25.0";
    src = { url = "https://mirrors.kernel.org/gnu/wget/wget-1.25.0.tar.gz";
            sha256 = "766e48423e79359ea31e41db9e5c289675947a7fcf2efdcedb726ac9d0da3784"; };   # .sig: Darshit Shah (gnu-keyring.gpg)
    deps = [ needWorld zlib openssl ];
    build = ''
      for f in $(find . \( -name 'localename*.[ch]' -o -name 'getlocalename_l*.[ch]' -o -name 'setlocale_null*.c' \)); do
        sed -i 's/extern char \* *getlocalename_l/extern const char *getlocalename_l/;s/^char \* *getlocalename_l/const char *getlocalename_l/' "$f"
      done
      CFLAGS="''${CFLAGS:-} -D__EXTENSIONS__ -D_XOPEN_SOURCE=600 -D_XOPEN_SOURCE_EXTENDED=1" \
      CPPFLAGS="''${CPPFLAGS:-} -D__EXTENSIONS__ -D_XOPEN_SOURCE=600 -I${openssl}/include" \
      LDFLAGS="''${LDFLAGS:-} -L${openssl}/lib/amd64 -R${openssl}/lib/amd64 -L${zlib}/lib/amd64 -R${zlib}/lib/amd64" \
        ./configure --prefix="$out" --with-ssl=openssl --with-libssl-prefix=${openssl} \
          --with-zlib --disable-nls --without-libpsl --disable-pcre --disable-pcre2
      gmake -j4
      gmake install
      ${dropDocs}
      "$out/bin/wget" --version | grep -q '^GNU Wget 1.25.0' || { echo "FATAL: wget --version" >&2; exit 1; }
      [ -f "$out/share/man/man1/wget.1" ] || { echo "FATAL: wget ships no man page" >&2; exit 1; }
      /usr/bin/elfdump -d "$out/bin/wget" | grep -q 'NEEDED.*libssl' || { echo "FATAL: wget not linked to openssl" >&2; /usr/bin/elfdump -d "$out/bin/wget" | grep NEEDED >&2; exit 1; }
    '';
  } // (if perl == null then { } else { nativeTools = [ perl ] ++ hostTools; }));   # store-only PATH + config.site; perl: pod2man (wave4)

  # GNU libiconv, for gettext. The world's iconv(3) modules are the gate proto's
  # usr/lib/iconv, which has no amd64/ directory and no UTF-8%UTF-16 or
  # UTF-8%8859-1 converters, so a 64-bit msgfmt cannot read a UTF-8 .po file
  # ("invalid multibyte sequence", measured). nixpkgs links gettext to libiconv
  # on every non-glibc platform; same here.
  libiconv = shared.libiconv or (mkSrcPkg {
    pname = "libiconv"; version = "1.17";
    src = { url = "https://mirrors.kernel.org/gnu/libiconv/libiconv-1.17.tar.gz";
            sha256 = "8f74213b56238c85a50a5329f77e06198771e70dd9a739779f4c02f65d971313"; };
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --disable-nls
      gmake -j4
      gmake install
      find "$out/share/doc" -delete 2>/dev/null || true
      [ "$(printf '\303\251' | "$out/bin/iconv" -f UTF-8 -t UTF-16LE | od -An -tx1 | tr -d ' ')" = e900 ] \
        || { echo "FATAL: libiconv UTF-8 -> UTF-16LE self-check" >&2; exit 1; }
    '';
  });

  # gettext: home-manager prints its messages through gettext/ngettext (the
  # illumos world has gettext and msgfmt but no ngettext, measured) and its
  # build runs msgfmt. Only the runtime tools are built (gettext-runtime, plus
  # msgfmt from gettext-tools); NLS stays on, it is the point of the package.
  gettext = mkSrcPkg {
    pname = "gettext"; version = "0.22.5";
    src = { url = "https://mirrors.kernel.org/gnu/gettext/gettext-0.22.5.tar.xz";
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
    pname = "jq"; version = "1.8.2";
    docOutputs = [ "man" ];   # nixpkgs jq: man output (jq.1 is prebuilt in the tarball)
    # upstream publishes no signature; sha256 == the release's sha256sum.txt == nixpkgs
    src = { url = "https://github.com/jqlang/jq/releases/download/jq-1.8.2/jq-1.8.2.tar.gz";
            sha256 = "71b8d6e8f5fe81f6c6d0d110e3892251f6ce76ed095abd315e26e6e1193af3af"; };
    nativeTools = hostTools;   # store-only PATH + config.site (recipes1); libc only at run time, as before
    build = ''
      # configure.ac sets MAKE=/usr/gnu/bin/make on SunOS when MAKE is unset (an OI host path; a solnix host has none): the store gmake.
      MAKE=gmake ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-docs --disable-static --without-oniguruma
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
    nativeTools = [ self.pkgconf ] ++ hostTools;   # store-only: configure needs pkg-config for xorg-macros (the OI host's before)
    build = ''
      # xorg-macros reads the HOST's /usr/share/man/man7/attributes.7 to pick SysV vs BSD man sections (host state; yes on chef and on
      # a solnix host whose /usr/share/man is the profile's): pinned to the answer both give, the BSD sections (NixOS: no such file
      # in the sandbox -> the same answer as here only by luck, so pin). shortcut: per recipe; move to config.site in the next full rebuild.
      ac_cv_file__usr_share_man_man7_attributes_7=yes ./configure --prefix="$out"
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
  hostname = derivation (plain {
    name = "hostname-f"; inherit system;
    builder = "/usr/bin/bash";
    # store-only build (wave6, gate2 A1). The wrapper it writes still execs /usr/bin/hostname AT RUN TIME: the running system's.
    PATH = "${coreutils}/bin:${needWorld}/usr/bin";
    args = [ "-c" ''
      /usr/bin/bash ${./path-gate.sh} || exit 1
      mkdir -p $out/bin
      cat > $out/bin/hostname <<'EOF'
    #!/usr/bin/bash
    if [ "$#" = 1 ] && { [ "$1" = -f ] || [ "$1" = --fqdn ]; }; then
      h=$(/usr/bin/hostname); d=$(/usr/bin/domainname 2>/dev/null)
      [ -n "$d" ] && case "$h" in *.*) ;; *) h="$h.$d";; esac
      echo "$h"; exit 0
    fi
    exec /usr/bin/hostname "$@"
    EOF
      chmod 555 $out/bin/hostname
      [ "$($out/bin/hostname -f)" = "$(hostname)" ] || [ -n "$(domainname)" ]
    '' ];
  });

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
  home-manager = derivation (plain {
    name = "home-manager-26.05-db7d5e2"; inherit system;
    # tests/ (1.9 MB, ~2,700 files) is dropped: only the module tree, lib and the
    # script are read at run time. nixpkgs' package keeps the whole source as
    # HOME_MANAGER_PATH; this departs from it to fit the installer media.
    # narHash is of the tree WITHOUT tests/ (the store path the old eval-time filter gave).
    hmSrc = import ./fetch-tarball.nix {
      url = "https://github.com/nix-community/home-manager/archive/db7d5e2332710f5abb088f6b5de927d7f9511b35.tar.gz";
      sha256 = "63657a72baa6fda8bfdb5a2d5e530bbcce0b087dfb23be5d7598626d61870941";
      narHash = "08l22vv66hzgg3am7hs2vjxgdhgpr0wpizxf71fyfp9z4sycwv1s";
      name = "home-manager-source"; exclude = [ "tests" ]; inherit system;
    };
    inherit bash;
    depPath = builtins.concatStringsSep ":" (map (p: "${p}/bin") [ coreutils findutils gettext gnused gnugrep jq less ncurses hostname ]);
    msgfmt = "${gettext}/bin/msgfmt";
    builder = "/usr/bin/bash";
    PATH = "${coreutils}/bin:${gnused}/bin:${gnugrep}/bin";   # store-only (wave6, gate2 A1)
    args = [ "-c" ''
      set -eu; export PATH=${coreutils}/bin:${gnused}/bin:${gnugrep}/bin   # store tools only (recipes1)
      /usr/bin/bash ${./path-gate.sh}
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
  });

  bash = mkSrcPkg {
    pname = "bash"; version = "5.2.37";
    docOutputs = [ "man" "info" "doc" ];   # nixpkgs bash: man doc info outputs
    src = { url = "https://mirrors.kernel.org/gnu/bash/bash-5.2.37.tar.gz";
            sha256 = "9599b22ecd1d5787ad7d3b7bf0c59f312b3396d1e281175dd1f8a4014da621ff"; };
    deps = [ needWorld ];
    build = ''
      # illumos curses declares tputs(..., int (*)(char)); GCC 14 errors on the
      # mismatch with bash's int (*)(int) putc callback (display.c:2839, measured).
      # nixpkgs bash 5.nix's -DSYS_BASHRC=/etc/bashrc -DSYS_BASH_LOGOUT -DNON_INTERACTIVE_LOGIN_SHELLS -DSSH_SOURCE_BASHRC, set in
      # config-top.h (its commented-out defines): /etc/bashrc then runs for every shell, `ssh host cmd` included, so
      # PATH/MANPATH/INFOPATH reach it (wave6 plan section 4; /etc/bashrc sources solnix-env.sh).
      sed -i -e 's@^/\* #define SYS_BASHRC .*@#define SYS_BASHRC "/etc/bashrc"@' \
        -e 's@^/\* #define SYS_BASH_LOGOUT .*@#define SYS_BASH_LOGOUT "/etc/bash_logout"@' \
        -e 's@^/\* #define NON_INTERACTIVE_LOGIN_SHELLS \*/@#define NON_INTERACTIVE_LOGIN_SHELLS@' \
        -e 's@^/\* #define SSH_SOURCE_BASHRC \*/@#define SSH_SOURCE_BASHRC@' config-top.h
      [ "$(grep -cE '^#define (SYS_BASHRC "/etc/bashrc"|SYS_BASH_LOGOUT "/etc/bash_logout"|NON_INTERACTIVE_LOGIN_SHELLS|SSH_SOURCE_BASHRC)$' config-top.h)" = 4 ] \
        || { echo "FATAL: bash config-top.h defines not set" >&2; exit 1; }
      CFLAGS="-O2 -Wno-error=incompatible-pointer-types" \
      ./configure --prefix="$out" --without-bash-malloc --disable-nls
      # builtins/psize.sh MEASURES the build host's pipe (psize.aux | sleep 3, until EPIPE) for `ulimit -p`; under load it falls back
      # to 512, so two builds compiled 0x4000 vs 0x200 (wave5 W2 --check). Pin illumos PIPE_BUF (limits.h): the target's value, not a race.
      # The rule is `pipesize.h: psize.aux` -> `$(SHELL) psize.sh > $@`: replace the script, so whenever make runs it, it prints the pin.
      printf '#!/bin/sh\necho "#define PIPESIZE 5120"\n' > builtins/psize.sh
      gmake -j6
      grep -qx '#define PIPESIZE 5120' builtins/pipesize.h || { echo "FATAL: bash PIPESIZE not pinned" >&2; exit 1; }
      gmake install
      strings -a "$out/bin/bash" | grep -qx /etc/bashrc || { echo "FATAL: bash built without SYS_BASHRC" >&2; exit 1; }
    '';
  };
}; in self
