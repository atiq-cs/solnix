# cli/c-net.nix -- terminal/network tools: screen, socat, sqlite, ncdu, tig, lsof.
{ mkSrcPkg, world, zlib, openssl, ncurses, readline, pkgconf, chk, gnulibFix, dropDocs, hostTools, ... }:
rec {
  # screen 4.9.1: screen 5 requires openpty(), which illumos libc does not have (configure:
  # "unable to find openpty() function", measured); 4.9 carries its own SVR4 /dev/ptmx path.
  screen = mkSrcPkg {
    pname = "screen"; version = "4.9.1";
    src = { url = "https://mirrors.kernel.org/gnu/screen/screen-4.9.1.tar.gz";
            sha256 = "26cef3e3c42571c0d484ad6faf110c5c15091fbf872b06fa7aa4766c7405ac69"; };
    deps = [ world ncurses ];
    nativeTools = hostTools;   # store-only PATH + config.site (wave4)
    build = ''
      # _XOPEN_SOURCE=600: msg_control/CMSG_* in illumos <sys/socket.h> are XPG4.2+ only.
      CFLAGS="-O2 -D__EXTENSIONS__ -D_XOPEN_SOURCE=600" ./configure --prefix="$out" --disable-pam --disable-socket-dir \
        --enable-telnet --enable-colors256 --with-sys-screenrc=/etc/screenrc
      # configure's getutent probe calls pututline() on utmpx with no prototype, which gcc 14
      # rejects, so GETUTENT goes undetected and os.h re-declares getutxent static (measured).
      # (and utmp.c calls kill() without <signal.h> under _XOPEN_SOURCE).
      grep -q '^#define UTMPOK' config.h && printf '#define GETUTENT 1\n#include <signal.h>\n' >> config.h
      gmake -j8; gmake install
      ${chk ''"$out/bin/screen" --version'' "^Screen version 4\\.09\\.01"}
      # functional: a detached session runs a command and exits
      export SCREENDIR=$(mktemp -d /var/tmp/scr.XXXXXX); chmod 700 "$SCREENDIR"
      "$out/bin/screen" -D -m sh -c 'echo screen-ok > "$SCREENDIR/o"'
      ${chk ''cat "$SCREENDIR/o"'' "^screen-ok$"}
      [ -f "$out/share/man/man1/screen.1" ] || { echo "FATAL: no screen.1" >&2; exit 1; }
    '';
  };

  socat = mkSrcPkg {
    pname = "socat"; version = "1.8.1.2";
    # upstream publishes no signature or checksum; sha256 == Alpine's distfiles copy (edge, v3.23)
    src = { url = "http://www.dest-unreach.org/socat/download/socat-1.8.1.2.tar.gz";
            sha256 = "daeb9eed37a99424cd14877208706e93745c91cb86fb917a355635f4df5c8499"; };
    deps = [ world openssl readline ncurses ];
    nativeTools = hostTools;   # store-only PATH + config.site (wave4)
    build = ''
      CFLAGS="-O2 -D__EXTENSIONS__" ./configure --prefix="$out" --disable-libwrap
      gmake -j8; gmake install
      ${chk ''"$out/bin/socat" -V'' "socat version 1.8.1.2"}
      ${chk ''echo hlcli | "$out/bin/socat" - -'' "^hlcli$"}
      /usr/bin/elfdump -d "$out/bin/socat" | grep -q 'NEEDED.*libssl' || { echo "FATAL: socat without openssl" >&2; exit 1; }
    '';
  };

  # sqlite CLI (nix-src.nix's sqlite is the library nix links, 3.46.1, no shell readline).
  sqlite = mkSrcPkg {
    pname = "sqlite"; version = "3.50.4";
    src = { url = "https://sqlite.org/2025/sqlite-autoconf-3500400.tar.gz";
            sha256 = "a3db587a1b92ee5ddac2f66b3edb41b26f9c867275782d46c3a088977d6a5b18"; };
    deps = [ readline ncurses zlib ];
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --enable-readline \
        --with-readline-ldflags="-lreadline -lncursesw" --disable-editline
      # autosetup's --soname "does not support SONAME" on illumos (measured): set it ourselves.
      gmake -j8 LDFLAGS.libsqlite3.soname=-Wl,-h,libsqlite3.so.0; gmake install LDFLAGS.libsqlite3.soname=-Wl,-h,libsqlite3.so.0
      ${chk ''"$out/bin/sqlite3" --version'' "^3\\.50\\.4"}
      ${chk ''echo "select 6*7;" | "$out/bin/sqlite3" :memory:'' "^42$"}
      # autosetup sets NO soname by default: consumers then NEED the bare libsqlite3.so dev link
      # (python3's _sqlite3 did, and resolved a host copy; measured). legacy = libsqlite3.so.0.
      /usr/bin/elfdump -d "$out/lib/amd64/libsqlite3.so" | grep -q 'SONAME.*libsqlite3\.so\.0' \
        || { echo "FATAL: libsqlite3 has no libsqlite3.so.0 SONAME" >&2; exit 1; }
    '';
  };

  # ncdu 1.x (C; ncdu 2 is Zig, which has no illumos toolchain here).
  ncdu = mkSrcPkg {
    pname = "ncdu"; version = "1.22";
    src = { url = "https://dev.yorhel.nl/download/ncdu-1.22.tar.gz";
            sha256 = "0ad6c096dc04d5120581104760c01b8f4e97d4191d6c9ef79654fa3c691a176b"; };
    deps = [ ncurses ];
    build = ''
      CFLAGS="-O2 -D__EXTENSIONS__" ./configure --prefix="$out" --with-ncursesw
      gmake -j8; gmake install
      ${chk ''"$out/bin/ncdu" -v'' "^ncdu 1.22"}
      ${chk ''"$out/bin/ncdu" -o- -x "$out"'' ''"progname":"ncdu"''}
    '';
  };

  tig = mkSrcPkg {
    pname = "tig"; version = "2.6.0";
    src = { url = "https://github.com/jonas/tig/releases/download/tig-2.6.0/tig-2.6.0.tar.gz";
            sha256 = "99d4a0fdd3d93547ebacfe511195cb92e4f75b91644c06293c067f401addeb3e"; };
    deps = [ ncurses readline libiconvDep ];
    nativeTools = [ pkgconf ] ++ hostTools;   # store-only PATH + config.site; configure needs pkg-config (OI had /usr/bin/pkg-config)
    build = ''
      CFLAGS="-O2 -D__EXTENSIONS__" LIBS="-lncursesw" ./configure --prefix="$out" --with-ncursesw --with-readline
      gmake -j8 prefix="$out"; gmake install install-doc-man prefix="$out"
      ${chk ''"$out/bin/tig" --version'' "^tig version 2.6.0"}
      [ -f "$out/share/man/man1/tig.1" ] || { echo "FATAL: no tig.1" >&2; exit 1; }
    '';
  };
  libiconvDep = world;

  # lsof: illumos-gate ships no lsof (pfiles is the native tool); lsof 4.99 has a sun dialect
  # that reads the kernel through libkvm, as OpenIndiana's lsof does.
  lsof = mkSrcPkg {
    pname = "lsof"; version = "4.99.5";
    src = { url = "https://github.com/lsof-org/lsof/releases/download/4.99.5/lsof-4.99.5.tar.gz";
            sha256 = "4682c2491ec8b3d62f84e135afc1d9ead1bad5f034b50716f0c3826a4ee7d229"; };
    deps = [ world ];
    build = ''
      # the Makefile assembles the man page with soelim (groff), which this host lacks: a shim.
      mkdir -p "$W/so"; printf '%s\n' '#!/usr/bin/bash' \
        'awk '"'"'/^\.so /{f=$2; while ((getline l < f) > 0) print l; close(f); next} {print}'"'"' "$@"' > "$W/so/soelim"
      chmod +x "$W/so/soelim"; export PATH="$W/so:$PATH"
      ./configure --prefix="$out" --disable-static
      gmake -j8; gmake install
      ${chk ''"$out/bin/lsof" -v'' "revision: 4.99.5"}
      ${chk ''"$out/bin/lsof" -p $$'' "^bash +[0-9]+ "}
      ${chk ''"$out/bin/lsof" -a -p $$ -d cwd'' "cwd +V?DIR"}
      [ -f "$out/share/man/man8/lsof.8" ] || [ -f "$out/share/man/man1/lsof.1" ] || { echo "FATAL: no lsof man" >&2; exit 1; }
    '';
  };
}
