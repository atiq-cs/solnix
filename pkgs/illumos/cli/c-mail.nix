# cli/c-mail.nix -- text-mode web and mail: lynx, w3m (+ bdwgc), isync (mbsync), neomutt,
# fortune-mod. TLS everywhere is the from-source openssl; CA bundle is the system's /etc/openssl.
{ mkSrcPkg, pkgconf, world, zlib, openssl, ncurses, readline, chk, scrub, dropDocs, gnulibFix, cmake, perl, gdbm, hostTools, ... }:
rec {
  lynx = mkSrcPkg {
    pname = "lynx"; version = "2.9.2";
    src = { url = "https://invisible-mirror.net/archives/lynx/tarballs/lynx2.9.2.tar.gz";
            sha256 = "99f8f28f860094c533100d1cedf058c27fb242ce25e991e2d5f30ece4457a3bf"; };
    deps = [ world ncurses openssl zlib ];
    nativeTools = hostTools;   # store-only PATH + config.site (wave4)
    build = ''
      # configure bakes the absolute path of each helper it finds on PATH into the binary; the
      # builder PATH leads with the seed build tools, which then became a RUNTIME reference of
      # lynx (gzip/tar/zcat, measured). Bare names: lynx runs them from the user's PATH.
      export ac_cv_path_GZIP=gzip ac_cv_path_TAR=tar ac_cv_path_ZCAT=zcat ac_cv_path_UNCOMPRESS=gunzip \
        ac_cv_path_INSTALL=install ac_cv_path_MV=mv ac_cv_path_RM=rm ac_cv_path_BZIP2=bzip2 \
        ac_cv_path_UNZIP=unzip ac_cv_path_ZIP=zip ac_cv_path_COMPRESS=compress ac_cv_path_UUDECODE=uudecode \
        ac_cv_path_TELNET=telnet ac_cv_path_RLOGIN=rlogin ac_cv_path_TN3270=tn3270 ac_cv_path_BROTLI=brotli
      CFLAGS="-O2 -D__EXTENSIONS__" ./configure --prefix="$out" --sysconfdir=/etc --with-ssl=${openssl} \
        --with-zlib --with-screen=ncursesw --enable-widec --enable-ipv6 --disable-nls --with-curses-dir=${ncurses} \
        --disable-idna --without-bzlib --without-brotli   # none is linked either way (no libidn/libbz2/libbrotlidec dep); enabled, configure
        # searches the HOST /usr/include and /usr/lib for them and bakes what it found into cfg_defs.h (LYNXCOMPILEOPTS), so chef and a solnix
        # host differed (wave4: /usr/include/idn*, find_linkage_bz2 maybe vs no). NixOS builds lynx without them too.
      # sysconfdir stays /etc (lynx reads /etc/lynx.cfg at run time); the INSTALL goes to $out/etc, never the host's /etc
      # (nixpkgs lynx: configureFlags --sysconfdir=/etc, installFlags sysconfdir=$out/etc). chef wrote its /etc/lynx.cfg as root.
      gmake -j8; gmake install sysconfdir="$out/etc"
      [ -f "$out/etc/lynx.cfg" ] || { echo "FATAL: lynx.cfg not installed under \$out/etc" >&2; exit 1; }
      ${chk ''"$out/bin/lynx" -version'' "^Lynx Version 2\\.9\\.2"}
      ! strings "$out/bin/lynx" | grep -qE "/nix/store/[a-z0-9]{32}-solnix-seed-build-tools" \
        || { echo "FATAL: lynx names the seed build tools" >&2; exit 1; }
      printf '<html><body><p>hlcli-lynx</p></body></html>\n' > t.html
      export HOME=$W/home; mkdir -p "$HOME"
      ${chk ''"$out/bin/lynx" -dump -nolist -cfg=/dev/null t.html'' "hlcli-lynx"}
    '';
  };

  bdwgc = mkSrcPkg {
    pname = "bdwgc"; version = "8.2.8";
    src = { url = "https://github.com/ivmai/bdwgc/releases/download/v8.2.8/gc-8.2.8.tar.gz";
            sha256 = "7649020621cb26325e1fb5c8742590d92fb48ce5c259b502faf7d9fb5dabb160"; };
    deps = [ world ];
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --enable-cplusplus=no --disable-docs
      gmake -j8; gmake install
      [ -f "$out/lib/amd64/libgc.so.1" ] || { echo "FATAL: no libgc.so.1" >&2; exit 1; }
    '';
  };

  w3m = mkSrcPkg {
    pname = "w3m"; version = "0.5.4";
    src = { url = "https://git.sr.ht/~rkta/w3m/archive/v0.5.4.tar.gz";
            sha256 = "fa20fa320373f383cdb5676a22314c193738c9c41a1b02d8634e331a190672ee"; };
    deps = [ world ncurses openssl zlib bdwgc ];
    nativeTools = [ perl ] ++ hostTools;   # store-only PATH + config.site; perl: w3mman and the cgi scripts get a #! to the store perl (OI: /usr/bin/perl, solnix: none)
    build = ''
      # NKF: configure.ac AC_PATH_PROGS(NKF, nkf, /usr/local/bin/nkf): the Japanese-text filter the multipart cgi runs, defaulting to a
      # host path when no nkf is found. No nkf here (nor in nixpkgs' w3m inputs): the bare name, found on the user's PATH if installed.
      # Through the cache variable: AC_PATH_PROGS keeps a preset NKF only when it is absolute, so NKF=nkf searched PATH, found none and
      # fell back to /usr/local/bin/nkf (configure:4893-4932; host-path-scan caught it, wave6u). The comment sits above the command:
      # between 'CFLAGS=.. \' and configure, it ended the command, so configure ran without CFLAGS.
      CFLAGS="-O2 -D__EXTENSIONS__ -std=gnu17 -Wno-error=incompatible-pointer-types -Wno-error=implicit-function-declaration" \
      ac_cv_path_NKF=nkf ./configure --prefix="$out" --with-ssl=${openssl} --with-gc=${bdwgc} --with-termlib=ncursesw \
        --enable-image=no --without-x --disable-w3mmailer --disable-nls
      gmake -j8; gmake install
      ${chk ''"$out/bin/w3m" -version'' "^w3m version"}
      printf '<html><body><p>hlcli-w3m</p></body></html>\n' > t.html
      export HOME=$W/home; mkdir -p "$HOME"   # w3m -dump writes ~/.w3m (no sandbox: /homeless-shelter)
      ${chk ''"$out/bin/w3m" -dump t.html'' "hlcli-w3m"}
      grep -qx 'NKF		= nkf' scripts/multipart/Makefile || { echo "FATAL: w3m NKF is not the bare name" >&2; exit 1; }
    '';
  };

  isync = mkSrcPkg {
    pname = "isync"; version = "1.5.1";
    hostPathAllow = "/opt/cov-analysis-[*]/bin/cov-build";   # Makefile.am's Coverity target (maintainer only, never run)
    src = { url = "https://downloads.sourceforge.net/project/isync/isync/1.5.1/isync-1.5.1.tar.gz";
            sha256 = "28cc90288036aa5b6f5307bfc7178a397799003b96f7fd6e4bd2478265bb22fa"; };
    deps = [ world openssl zlib ];
    nativeTools = [ perl ] ++ hostTools;   # store-only PATH; configure requires perl ('perl not found' on a solnix host)
    build = ''
      CFLAGS="-O2 -D__EXTENSIONS__" ./configure --prefix="$out" --with-ssl=${openssl} --without-sasl --without-db
      gmake -j8; gmake install
      ${chk ''"$out/bin/mbsync" --version'' "^isync 1\\.5\\.1"}
      [ -f "$out/share/man/man1/mbsync.1" ] || { echo "FATAL: no mbsync.1" >&2; exit 1; }
    '';
  };

  neomutt = mkSrcPkg {
    pname = "neomutt"; version = "20250510";
    src = { url = "https://github.com/neomutt/neomutt/archive/refs/tags/20250510.tar.gz";
            sha256 = "12d225e270d8e16cda41d855880b9d938750a4f1d647f55c6353337d32ffd653"; };
    deps = [ world ncurses openssl zlib gdbm ];
    nativeTools = [ pkgconf ] ++ hostTools;   # store-only PATH (SysV /usr/sbin/install on solnix: install-data failed); configure needs pkg-config
    build = ''
      # cli/parse.c resets getopt with optind = 0 (glibc's "reinitialise") except on BSD/Apple;
      # illumos getopt then parses argv[0] and every option is lost, so `neomutt -v` tried to
      # send mail (measured). Use the BSD arm's optind = 1 on __sun too.
      grep -q '^#if defined(BSD) || defined(__APPLE__)$' cli/parse.c || { echo "FATAL: neomutt getopt anchor" >&2; exit 1; }
      sed -i 's/^#if defined(BSD) || defined(__APPLE__)$/#if defined(BSD) || defined(__APPLE__) || defined(__sun)/' cli/parse.c
      sed -i 's/^  optreset = 1;$/#ifndef __sun\n  optreset = 1;\n#endif/' cli/parse.c
      CFLAGS="-O2 -D__EXTENSIONS__" ./configure --prefix="$out" --sysconfdir=/etc --ssl --with-ssl=${openssl} \
        --with-ncurses=${ncurses} --gdbm --with-gdbm=${gdbm} --zlib --with-zlib=${zlib} \
        --disable-nls --disable-doc --disable-idn2
      # sysconfdir stays /etc (neomutt reads /etc/neomuttrc), the install goes to $out/etc: install-docs wrote the host's /etc/neomuttrc
      # (chef: root-owned, 2026-10-31 01:28 = the wave3 build; as nixbld: 'cannot remove /etc/neomuttrc'). nixpkgs: the same split.
      gmake -j8; gmake install sysconfdir="$out/etc"
      [ -f "$out/etc/neomuttrc" ] || { echo "FATAL: neomuttrc not installed under \$out/etc" >&2; exit 1; }
      # smime_keys is "#! /usr/bin/perl -w" (host perl; out-host-refs). The user's perl via env, -w as "use warnings".
      sed -i '1s|^#! */usr/bin/perl -w$|#!/usr/bin/env perl\nuse warnings;|' "$out/libexec/neomutt/smime_keys"
      head -2 "$out/libexec/neomutt/smime_keys" | grep -q '^use warnings;$' || { echo "FATAL: smime_keys #! not rewritten" >&2; exit 1; }
      ${chk ''"$out/bin/neomutt" -v </dev/null'' "^NeoMutt 20250510"}
      /usr/bin/elfdump -d "$out/bin/neomutt" | grep -q 'NEEDED.*libssl' || { echo "FATAL: neomutt without openssl" >&2; exit 1; }
    '';
  };

  fortune-mod = mkSrcPkg {
    pname = "fortune-mod"; version = "3.24.0";
    src = { url = "https://github.com/shlomif/fortune-mod/releases/download/fortune-mod-3.24.0/fortune-mod-3.24.0.tar.xz";
            sha256 = "1f387877254e95eab61f937257b42609f29b994ef0571531655bbfc3a2ac74ac"; };
    deps = [ world ];
    build = ''
      export PATH=${cmake}/bin:${perl}/bin:$PATH
      mkdir b; cd b
      cmake .. -DCMAKE_INSTALL_PREFIX="$out" -DCMAKE_C_COMPILER="$CC" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SKIP_RPATH=ON -DNO_OFFENSIVE=ON -DLOCALDIR="$out/share/games/fortunes" \
        -DCOOKIEDIR="$out/share/games/fortunes" -DSKIP_RINUTILS_INSTALL=ON >&2
      gmake -j8; gmake install
      f=$(ls "$out"/games/fortune "$out"/bin/fortune 2>/dev/null | head -1)
      [ -n "$f" ] || { echo "FATAL: no fortune binary" >&2; exit 1; }
      [ -x "$out/bin/fortune" ] || { mkdir -p "$out/bin"; ln -s ../games/fortune "$out/bin/fortune"; }
      ${chk ''"$out/bin/fortune" -f'' "fortunes"}
    '';
  };
}
