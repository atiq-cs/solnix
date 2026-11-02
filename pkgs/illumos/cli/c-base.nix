# cli/c-base.nix -- small GNU/C tools: file (libmagic), bc, GNU m4, readline.
{ mkSrcPkg, world, zlib, ncurses, chk, gnulibFix, dropDocs, hostTools, ... }:
rec {
  file = mkSrcPkg {
    pname = "file"; version = "5.46";
    src = { url = "https://astron.com/pub/file/file-5.46.tar.gz";
            sha256 = "c9cc77c7c560c543135edc555af609d5619dbef011997e988ce40a3d75d86088"; };
    deps = [ zlib ];
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --enable-zlib \
        --disable-bzlib --disable-xzlib --disable-zstdlib --disable-lzlib --disable-libseccomp
      gmake -j8; gmake install
      ${chk ''"$out/bin/file" --version'' "^file-5.46"}
      ${chk ''"$out/bin/file" "$out/bin/file"'' "ELF 64-bit LSB"}
      [ -f "$out/share/man/man1/file.1" ] || { echo "FATAL: no file.1" >&2; exit 1; }
    '';
  };

  readline = mkSrcPkg {
    pname = "readline"; version = "8.2";
    src = { url = "https://mirrors.kernel.org/gnu/readline/readline-8.2.tar.gz";
            sha256 = "3feb7171f16a84ee82ca18a36d7b9be109a52c04f492a053331d7d1095007c35"; };
    deps = [ ncurses ];
    build = ''
      # shobj-conf keys on "gcc" in $CC; the builder's wrapper is cc64, which selects the Sun cc
      # arm (-K pic, /usr/ccs/bin/ld). Make the Sun-cc arm unreachable so the gcc arm is taken.
      sed -i 's/^sunos5\*|solaris2\*)$/sunos5-suncc-only)/; s/^sunos5\*-\*gcc\*|solaris2\*-\*gcc\*)/sunos5*|solaris2*)/' support/shobj-conf
      grep -q '^sunos5-suncc-only)' support/shobj-conf || { echo "FATAL: shobj-conf anchor" >&2; exit 1; }
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --with-curses --disable-static --disable-install-examples
      gmake -j8 SHLIB_LIBS=-lncursesw; gmake install SHLIB_LIBS=-lncursesw
      ${dropDocs}
      /usr/bin/elfdump -d "$out/lib/amd64/libreadline.so.8" | grep -q 'NEEDED.*libncursesw' \
        || { echo "FATAL: libreadline does not NEED libncursesw" >&2; exit 1; }
    '';
  };

  # flex 2.6.4 (nixpkgs' version and tarball): bc's configure wants flex for --with-readline ("readline works only with flex"); the
  # OpenIndiana build host had /usr/bin/flex, a solnix host has none. The tarball ships generated scan.c/parse.c: no flex/bison to build it.
  flex = mkSrcPkg {
    pname = "flex"; version = "2.6.4";
    src = { url = "https://github.com/westes/flex/releases/download/v2.6.4/flex-2.6.4.tar.gz";
            sha256 = "e87aae032bf07c26f85ac0ed3250998c37621d95f8bd748b31f15b33c45ee995"; };
    deps = [ world ]; nativeTools = [ gnum4 ] ++ hostTools;   # GNU m4 (-P): the world's m4 is SVR4 ('bad option: -P'); OI had /usr/bin/gm4
    build = ''
      MAKEINFO=true HELP2MAN=true ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --disable-nls
      gmake -j8 MAKEINFO=true HELP2MAN=true; gmake install MAKEINFO=true HELP2MAN=true
      ${dropDocs}
      ${chk ''"$out/bin/flex" --version'' "^flex 2\\.6\\.4"}
    '';
  };
  bc = mkSrcPkg {
    pname = "bc"; version = "1.08.2";
    src = { url = "https://mirrors.kernel.org/gnu/bc/bc-1.08.2.tar.gz";
            sha256 = "ae470fec429775653e042015edc928d07c8c3b2fc59765172a330d3d87785f86"; };
    deps = [ readline ncurses ]; nativeTools = [ flex gnum4 ] ++ hostTools;   # flex runs `m4` from PATH (main.c: M4 basename searched first; nixpkgs flex propagates m4)   # store-only PATH + config.site; flex from the store (wave4)
    build = ''
      MAKEINFO=true ./configure --prefix="$out" --with-readline
      gmake -j8 MAKEINFO=true; gmake install MAKEINFO=true
      ${dropDocs}
      ${chk ''"$out/bin/bc" --version'' "^bc 1.08.2"}
      ${chk ''echo "2^64" | "$out/bin/bc"'' "^18446744073709551616$"}
      ${chk ''echo "2 3 + p" | "$out/bin/dc"'' "^5$"}
    '';
  };

  gnum4 = mkSrcPkg {
    pname = "gnum4"; version = "1.4.20";
    src = { url = "https://mirrors.kernel.org/gnu/m4/m4-1.4.20.tar.xz";
            sha256 = "e236ea3a1ccf5f6c270b1c4bb60726f371fa49459a8eaaebc90b216b328daf2b"; };
    deps = [ world ]; nativeTools = hostTools;   # store-only PATH + config.site: locales/iconv/O_NOATIME/install differed by host (wave4 cfg/gnum4-1.4.20.diff)
    build = ''
      ${gnulibFix}
      MAKEINFO=true ./configure --prefix="$out" --disable-nls --disable-gcc-warnings
      gmake -j8 MAKEINFO=true; gmake install MAKEINFO=true
      ${dropDocs}
      ${chk ''"$out/bin/m4" --version'' "^m4 \\(GNU M4\\) 1.4.20"}
      ${chk ''echo "define(x,42)x" | "$out/bin/m4"'' "^42$"}
    '';
  };
}
