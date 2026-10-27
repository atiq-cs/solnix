# src.nix (aarch64) -- the from-source packages nix needs, built natively on aarch64 illumos with
# the aarch64 gcc (./gcc-src.nix). Same recipes as ../base-src.nix + ../nix-src.nix; the shared
# builder ../mk-src-pkg.nix runs with aarch64 = true (LP64: libs in lib/, arm64-gate target flags).
{ gate, libcSlice, gcc, system ? "aarch64-solaris" }:
# gateLibs: the few gate libraries (outside the libc slice) htop/wget link; on x86 they come
# from the whole world (mk-proto-world.nix), which aarch64 does not have yet.

let
  mkSrcPkg = args: import ../mk-src-pkg.nix {
    inherit gate gcc;
    aarch64 = true;
    runtimeLibDirs = [ "${libcSlice}/lib" ];
  } (args // { inherit system; });
in
rec {
  inherit mkSrcPkg;

  # as ../base-src.nix zlib (OI symbol-version mapfile), LP64 only. --libdir first: zlib's
  # configure is not autoconf and rejects the --build that mk-src-pkg adds after "./configure --prefix=".
  zlib = mkSrcPkg {
    pname = "zlib"; version = "1.3.2";
    src = { url = "https://zlib.net/fossils/zlib-1.3.2.tar.gz";
            sha256 = "bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16"; };
    build = ''
      CFLAGS="-O2 -fPIC" LDSHARED="$CC -shared -Wl,-h,libz.so.1 -Wl,-M,${../patches/zlib-illumos.mapfile}" \
        ./configure --libdir="$out/$LIBSUB" --prefix="$out" --sharedlibdir="$out/$LIBSUB" --includedir="$out/include"
      gmake -j8 libz.so.1.3.2
      gmake install
    '';
  };

  # openssl 3.4.0 has no solaris aarch64 target: add one (solaris-common-gcc + the linux-aarch64
  # asm profile), as solnix-pkgs' entry-aarch64-wave4.nix does for the cross build.
  openssl = mkSrcPkg {
    pname = "openssl"; version = "3.4.0";
    src = { url = "https://github.com/openssl/openssl/releases/download/openssl-3.4.0/openssl-3.4.0.tar.gz";
            sha256 = "e15dda82fe2fe8139dc2ac21a36d4ca01d5313c75f99f46c4e8a27709b7294bf"; };
    build = ''
      cp ${./openssl-solaris-aarch64.conf} Configurations/55-solaris-aarch64.conf
      ./Configure solaris64-aarch64-gcc --prefix="$out" --libdir=lib --openssldir=/etc/openssl \
        shared no-tests no-docs
      gmake -j24 build_sw
      gmake install_sw
    '';
  };

  # git: nix 2.24 runs the git CLI for git+https flake inputs (the registry). As ../base-src.nix's
  # git, but SHELL_PATH /bin/sh (no store bash on aarch64 yet; illumos sh is ksh93, POSIX).
  git = mkSrcPkg {
    pname = "git"; version = "2.54.0";
    src = { url = "https://www.kernel.org/pub/software/scm/git/git-2.54.0.tar.xz";
            sha256 = "f689162364c10de79ef89aa8dbf48731eb057e34edbbd20aca510ce0154681a3"; };
    deps = [ zlib openssl nixChain.curl ];
    build = ''
      cat > config.mak <<EOF
      CC = $CC
      prefix = $out
      SHELL_PATH = /bin/sh
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
      lib = lib
      CC_LD_DYNPATH = -Wl,-R,
      EOF
      gmake -j24 all
      gmake install
      "$out/bin/git" --version | grep -q '^git version 2.54.0' || { echo "FATAL: git --version" >&2; exit 1; }
    '';
  };

  # tree (as ../base-src.nix's, without the x86 -m64).
  tree = mkSrcPkg {
    pname = "tree"; version = "2.1.3";
    src = { url = "https://gitlab.com/OldManProgrammer/unix-tree/-/archive/2.1.3/unix-tree-2.1.3.tar.gz";
            sha256 = "f554a1b62233b96fa8eaa2d85e91bc62cad80ee441fd591380f16cdfbe3e8868"; };
    build = ''
      for f in *.c *.h; do [ -f "$f" ] && sed -i 's/struct comment/struct tree_comment/g' "$f"; done
      gmake -j8 CC="$CC" CFLAGS="-D__EXTENSIONS__ -O2" MANDIR="$out/share/man" PREFIX="$out"
      gmake install PREFIX="$out" MANDIR="$out/share/man"
      "$out/bin/tree" --version | grep -q '^tree v2.1.3' || { echo "FATAL: tree --version" >&2; exit 1; }
    '';
  };

  # ncurses, less, libiconv: verbatim from ../base-src.nix (the lp64Fix rewrite handles lib/amd64).
  ncurses = mkSrcPkg {
    pname = "ncurses"; version = "6.5";
    src = { url = "https://mirrors.kernel.org/gnu/ncurses/ncurses-6.5.tar.gz";
            sha256 = "136d91bc269a9a5785e5f9e980bc76ab57428f604ce3e5a5a90cebc767971cc6"; };
    build = ''
      L="$out/lib/amd64"
      ./configure --prefix="$out" --libdir="$L" --with-shared --without-normal --without-debug \
        --enable-widec --enable-overwrite --enable-pc-files --with-pkg-config-libdir="$L/pkgconfig" \
        --without-ada --without-tests --without-cxx-binding --disable-stripping \
        --with-default-terminfo-dir="$out/share/terminfo" --with-terminfo-dirs="$out/share/terminfo"
      gmake -j24
      gmake install
      ln -s . "$out/include/ncursesw"; ln -s . "$out/include/ncurses"
      for l in ncurses curses tinfo; do ln -s libncursesw.so "$L/lib$l.so"; done
      ln -s ncursesw.pc "$L/pkgconfig/ncurses.pc"
      for t in xterm-256color sun-color vt100 screen-256color tmux-256color; do
        [ -n "$(find "$out/share/terminfo" -name "$t")" ] || { echo "FATAL: terminfo $t missing" >&2; exit 1; }
      done
      [ "$(TERM=xterm-256color "$out/bin/tput" colors)" = 256 ] || { echo "FATAL: tput colors" >&2; exit 1; }
    '';
  };  less = mkSrcPkg {
    pname = "less"; version = "679";
    src = { url = "https://www.greenwoodsoftware.com/less/less-679.tar.gz";
            sha256 = "9b68820c34fa8a0af6b0e01b74f0298bcdd40a0489c61649b47058908a153d78"; };
    deps = [ ncurses ];
    build = ''
      ./configure --prefix="$out" --with-regex=posix
      gmake -j24
      gmake install
      # configure takes -ltinfo first, which is ncurses' libtinfo.so alias; the
      # gate's SVR4 libcurses/libtermcap must not be what it linked.
      /usr/bin/elfdump -d "$out/bin/less" | grep -q 'NEEDED.*libncursesw\.so' \
        || { echo "FATAL: less does not NEED libncursesw" >&2; /usr/bin/elfdump -d "$out/bin/less" | grep NEEDED >&2; exit 1; }
    '';
  };  libiconv = mkSrcPkg {
    pname = "libiconv"; version = "1.17";
    src = { url = "https://mirrors.kernel.org/gnu/libiconv/libiconv-1.17.tar.gz";
            sha256 = "8f74213b56238c85a50a5329f77e06198771e70dd9a739779f4c02f65d971313"; };
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --disable-nls
      gmake -j24
      gmake install
      find "$out/share/doc" -delete 2>/dev/null || true
      [ "$(printf '\303\251' | "$out/bin/iconv" -f UTF-8 -t UTF-16LE | od -An -tx1 | tr -d ' ')" = e900 ] \
        || { echo "FATAL: libiconv UTF-8 -> UTF-16LE self-check" >&2; exit 1; }
    '';
  };
  # readline 8.2 on the store ncurses (bash's line editor; the maintainer found neither bash nor
  # readline on the aarch64 image). -ltinfo is ncurses' alias, never the gate's SVR4 termcap.
  readline = mkSrcPkg {
    pname = "readline"; version = "8.2";
    src = { url = "https://mirrors.kernel.org/gnu/readline/readline-8.2.tar.gz";
            sha256 = "3feb7171f16a84ee82ca18a36d7b9be109a52c04f492a053331d7d1095007c35"; };
    deps = [ ncurses ];
    build = ''
      # support/shobj-conf picks gcc flags only when $CC's name says gcc ("solaris2*-*gcc*"), and
      # then runs `gcc -print-prog-name=ld`; mk-src-pkg's wrapper is cc64 -> SunPro's -K pic (measured).
      mkdir -p "$SRC/.bin"; ln -s "$CC" "$SRC/.bin/gcc"; export PATH="$SRC/.bin:$PATH" CC="$SRC/.bin/gcc"
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --with-curses --enable-shared --disable-static
      gmake -j24 SHLIB_LIBS=-lncursesw
      gmake install SHLIB_LIBS=-lncursesw
      find "$out/share/doc" "$out/share/info" -delete 2>/dev/null || true
      /usr/bin/elfdump -d "$out/lib/amd64/libreadline.so.8" | grep -q 'NEEDED.*libncursesw' \
        || { echo "FATAL: libreadline does not NEED libncursesw" >&2; exit 1; }
    '';
  };

  # bash 5.2.37, as ../base-src.nix's bash, on the store readline + ncurses (x86 links the
  # world's curses and bash's bundled readline; aarch64 has no world yet).
  bash = mkSrcPkg {
    pname = "bash"; version = "5.2.37";
    src = { url = "https://mirrors.kernel.org/gnu/bash/bash-5.2.37.tar.gz";
            sha256 = "9599b22ecd1d5787ad7d3b7bf0c59f312b3396d1e281175dd1f8a4014da621ff"; };
    deps = [ readline ncurses ];
    build = ''
      CFLAGS="-O2 -Wno-error=incompatible-pointer-types" \
      ./configure --prefix="$out" --without-bash-malloc --disable-nls \
        --with-installed-readline="${readline}" --with-curses bash_cv_termcap_lib=libncursesw
      gmake -j24
      gmake install
      find "$out/share/doc" "$out/share/info" -delete 2>/dev/null || true
      [ "$("$out/bin/bash" -c 'echo $BASH_VERSION')" = 5.2.37\(1\)-release ] || { echo "FATAL: bash version" >&2; exit 1; }
      /usr/bin/elfdump -d "$out/bin/bash" | grep -q 'NEEDED.*libreadline' \
        || { echo "FATAL: bash not linked to the store readline" >&2; exit 1; }
    '';
  };
  # nano: ../base-src.nix's gnuTool recipe, deps = ncurses only (no world on aarch64 yet).
  nano = mkSrcPkg {
    pname = "nano"; version = "8.4";
    src = { url = "https://www.nano-editor.org/dist/v8/nano-8.4.tar.xz";
            sha256 = "5ad29222bbd55624d87ea677928b3106a743114d6c6f9b41f36c97be2a8e628d"; };
    deps = [ ncurses ];
    build = ''
      FORCE_UNSAFE_CONFIGURE=1 MAKEINFO=true ./configure --prefix="$out" --disable-nls --disable-libmagic --disable-speller
      gmake -j24 MAKEINFO=true
      gmake install MAKEINFO=true
      find "$out/share/doc" "$out/share/info" -delete 2>/dev/null || true
    '';
  };

  # nvi (nvi2) on the BSD DB 1.85: solnix's vi (bin/vi, ex, view), as ../base-src.nix.
  db1 = import ../db1.nix { inherit mkSrcPkg; };
  nvi = import ../nvi2.nix { inherit mkSrcPkg ncurses db1 libiconv; };

  # gate libs htop (libkstat, libproc) and wget (libuuid) NEED, copied from the proto with their
  # NEEDED closure (measured on the aarch64 proto), RUNPATH -> itself + the libc slice.
  gateLibs = derivation {
    name = "illumos-gate-libs"; inherit system gate zlib;
    libc = libcSlice;
    roots = "libkstat.so.1 libproc.so.1";  # htop. (libuuid -> libdlpi -> libdladm -> ... -> libxml2 = the world; wget goes --without-libuuid)
    builder = "/usr/bin/bash";
    args = [ "-c" ''
      set -eu; export PATH=/usr/gnu/bin:/usr/bin
      mkdir -p $out/lib
      # the roots' NEEDED closure inside the gate, minus what the libc slice and zlib provide
      todo="$roots"; libs=""
      while [ -n "$todo" ]; do
        set -- $todo; l=$1; shift; todo="$*"
        case " $libs " in *" $l "*) continue;; esac
        [ -e $libc/lib/$l ] || [ -e $zlib/lib/$l ] && continue
        f=$gate/lib/$l; [ -e $f ] || f=$gate/usr/lib/$l; [ -e $f ] || { echo "FATAL: $l not in the gate" >&2; exit 1; }
        libs="$libs $l"
        todo="$todo $(/usr/bin/elfdump -d $f | awk '$2=="NEEDED"{print $4}' | tr '\n' ' ')"
      done
      echo "gate libs:$libs" >&2
      for l in $libs; do
        f=$gate/lib/$l; [ -e $f ] || f=$gate/usr/lib/$l; cp $f $out/lib/$l; chmod u+w $out/lib/$l
        case $l in *.so.1) ln -s $l $out/lib/''${l%.1};; esac
        /usr/bin/elfedit -e "dyn:runpath $out/lib:$libc/lib:$zlib/lib" $out/lib/$l  # libctf/libdwarf NEED libz
      done
      unset LD_LIBRARY_PATH || true
      bad=$(for f in $out/lib/*.so.[0-9]*; do /usr/bin/ldd $f 2>&1 | awk -v f=$f '/not found/ || (/=>/ && $NF !~ /^\/nix\/store\//) {print f": "$0}'; done)
      [ -z "$bad" ] || { echo "FATAL: gate libs leave the store: $bad" >&2; exit 1; }
    '' ];
  };

  htop = mkSrcPkg {
    pname = "htop"; version = "3.4.1";
    src = { url = "https://github.com/htop-dev/htop/releases/download/3.4.1/htop-3.4.1.tar.xz";
            sha256 = "904f7d4580fc11cffc7e0f06895a4789e0c1c054435752c151e812fead9f6220"; };
    deps = [ gateLibs ncurses ];
    build = ''
      # illumos <math.h> exposes NAN/isgreater only under __C99FEATURES__.
      CFLAGS="-O2 -D__EXTENSIONS__ -D__C99FEATURES__" ./configure --prefix="$out" --enable-unicode
      grep -q '^my_htop_platform=solaris\|^HTOP_PLATFORM.*solaris\|solaris/Platform' Makefile config.log \
        || { echo "FATAL: htop did not select its solaris backend" >&2; exit 1; }
      gmake -j24
      gmake install
    '';
  };  wget = mkSrcPkg {
    pname = "wget"; version = "1.24.5";
    src = { url = "https://mirrors.kernel.org/gnu/wget/wget-1.24.5.tar.gz";
            sha256 = "fa2dc35bab5184ecbc46a9ef83def2aaaa3f4c9f3c97d4bd19dcb07d4da637de"; };
    deps = [ gateLibs zlib openssl ];
    build = ''
      for f in $(find . \( -name 'localename*.[ch]' -o -name 'getlocalename_l*.[ch]' -o -name 'setlocale_null*.c' \)); do
        sed -i 's/extern char \* *getlocalename_l/extern const char *getlocalename_l/;s/^char \* *getlocalename_l/const char *getlocalename_l/' "$f"
      done
      CFLAGS="''${CFLAGS:-} -D__EXTENSIONS__ -D_XOPEN_SOURCE=600 -D_XOPEN_SOURCE_EXTENDED=1" \
      CPPFLAGS="''${CPPFLAGS:-} -D__EXTENSIONS__ -D_XOPEN_SOURCE=600 -I${openssl}/include" \
      LDFLAGS="''${LDFLAGS:-} -L${openssl}/lib/amd64 -R${openssl}/lib/amd64 -L${zlib}/lib/amd64 -R${zlib}/lib/amd64" \
        ./configure --prefix="$out" --with-ssl=openssl --with-libssl-prefix=${openssl} \
          --with-zlib --disable-nls --without-libpsl --disable-pcre --disable-pcre2 --without-libuuid
      gmake -j24
      gmake install
      find "$out/share/doc" "$out/share/info" -delete 2>/dev/null || true
      "$out/bin/wget" --version | grep -q '^GNU Wget 1.24.5' || { echo "FATAL: wget --version" >&2; exit 1; }
      [ -f "$out/share/man/man1/wget.1" ] || { echo "FATAL: wget ships no man page" >&2; exit 1; }
      /usr/bin/elfdump -d "$out/bin/wget" | grep -q 'NEEDED.*libssl' || { echo "FATAL: wget not linked to openssl" >&2; /usr/bin/elfdump -d "$out/bin/wget" | grep NEEDED >&2; exit 1; }
    '';
  };
  top = derivation {
    name = "top-htop-3.4.1"; inherit system htop;
    builder = "/usr/bin/bash";
    args = [ "-c" "/usr/bin/mkdir -p $out/bin && /usr/bin/ln -s $htop/bin/htop $out/bin/top" ];
  };

  # gcc wrapper (as ../base-src.nix gccWrapper): bin/gcc = the derivation gcc + RUNPATH to its lib.
  # No -B binutils: aarch64 uses the stage0 box's /usr/bin/gas + illumos ld (gcc-src --with-as/--with-ld).
  gccWrapper = derivation {
    name = "gcc-wrapper-14.3.0"; inherit system gcc; gccLib = gcc.lib;
    builder = "/usr/bin/bash";
    args = [ "-c" ''
      set -eu; export PATH=/usr/bin; mkdir -p $out/bin
      for t in gcc:gcc cc:gcc g++:g++ c++:g++; do
        printf '#!/usr/bin/bash\nexec %s -Wl,-R,%s/lib "$@"\n' "$gcc/bin/''${t#*:}" "$gccLib" > $out/bin/''${t%%:*}
        /usr/bin/chmod +x $out/bin/''${t%%:*}
      done
    '' ];
  };

  # fetch(1), FreeBSD's (../bsdfetch.nix), with the aarch64 text rewrite.
  bsdfetch = import ../bsdfetch.nix { inherit gate gccWrapper openssl libcSlice system; aarch64 = true; };

  nixChain = import ../nix-src.nix {
    inherit mkSrcPkg zlib openssl libcSlice system;
    gccLib = gcc.lib;
    libSub = "lib";
  };
}
