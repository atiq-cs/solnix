# cli/c-recipes2.nix -- C/C++ tools and libraries solnix lacked (recipes2, 2026-11-02): the maintainer's pinentry-curses, hunspell
# (+ the en_US dictionary) and whisper-cpp; then gmp, mpfr, libmpc, tcl, giflib, cpio, groff, fmt, catch2_3 (common libraries in the
# build queue's head). Versions are the queue's targets. Store-only builds (nativeTools = NixOS nativeBuildInputs + config.site),
# each with an in-build check that runs it for real. A new file, so no served recipe's drv moves.
# Sources: GNU and gnupg tarballs are gpg-verified (recipes2 progress step18); GitHub/SourceForge ones have no upstream signature
# and are pinned by sha256 (equal to nixpkgs' hash where nixpkgs has the same version: tcl, hunspellDicts.en_US).
{ base, mkSrcPkg, world, zlib, ncurses, libiconv, readline, chk, dropDocs, hostTools, gnum4, perl, cmake, libgpg-error, libassuan, bzip2-bin, python3, ... }:
let
  gnu = p: v: ext: sha256: { url = "https://mirrors.kernel.org/gnu/${p}/${p}-${v}.tar.${ext}"; inherit sha256; };
  gh = repo: tag: sha256: { url = "https://codeload.github.com/${repo}/tar.gz/refs/tags/${tag}"; inherit sha256; };
  # cmake projects: the store cmake, store prefixes only (cmake's find_* searches the host /usr/lib by default: ccache, measured)
  cmakeB = extra: ''
    cmake -S . -B _b -DCMAKE_INSTALL_PREFIX="$out" -DCMAKE_INSTALL_LIBDIR=lib/amd64 -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_SKIP_RPATH=ON -DCMAKE_IGNORE_PREFIX_PATH="/usr;/usr/local;/opt" \
      -DCMAKE_IGNORE_PATH="/usr/lib/64;/usr/lib/amd64;/lib/64" ${extra} >&2
    cmake --build _b -j16 >&2; cmake --install _b >&2
  '';
  ncw = "-I${ncurses}/include/ncursesw";
in rec {
  # ---- the maintainer's tools ----------------------------------------------------------------------------------------------
  # pinentry-curses (GPL-2.0+): nixpkgs' flavours [curses tty]; gpg-agent runs it to ask for a passphrase on a terminal.
  pinentry-curses = mkSrcPkg {
    pname = "pinentry-curses"; version = "1.3.2";
    src = { url = "https://gnupg.org/ftp/gcrypt/pinentry/pinentry-1.3.2.tar.bz2";
            sha256 = "8e986ed88561b4da6e9efe0c54fa4ca8923035c99264df0b0464497c5fb94e9e"; };
    deps = [ world ncurses libgpg-error libassuan ]; nativeTools = [ bzip2-bin ] ++ hostTools;   # bzip2: GNU tar unpacks .tar.bz2 through it
    build = ''
      # configure finds libgpg-error/libassuan through their *-config scripts on PATH (c-gnupg.nix does the same)
      export PATH="${libgpg-error}/bin:${libassuan}/bin:$PATH" GPGRT_CONFIG=${libgpg-error}/bin/gpgrt-config
      ./configure --prefix="$out" --disable-nls --disable-doc --enable-pinentry-curses --enable-pinentry-tty \
        --disable-pinentry-qt --disable-pinentry-qt5 --disable-pinentry-gtk2 --disable-pinentry-gnome3 --disable-pinentry-emacs \
        --disable-pinentry-efl --disable-pinentry-fltk --disable-pinentry-tqt --disable-libsecret --disable-fallback-curses \
        --with-libgpg-error-prefix=${libgpg-error} --with-libassuan-prefix=${libassuan} \
        NCURSES_CFLAGS="${ncw} -D__EXTENSIONS__ -DNCURSES_WIDECHAR" NCURSES_LIBS="-lncursesw"   # = ncursesw.pc Cflags: addnwstr is declared only with NCURSES_WIDECHAR (measured)
      gmake -j8; gmake install   # install links bin/pinentry -> pinentry-curses itself
      [ "$(readlink "$out/bin/pinentry")" = pinentry-curses ] || { echo "FATAL: bin/pinentry is not pinentry-curses" >&2; exit 1; }
      ${dropDocs}
      ${chk ''"$out/bin/pinentry-curses" --version'' "^pinentry-curses \\(pinentry\\) 1\\.3\\.2"}
      # the Assuan protocol gpg-agent speaks, over stdin/stdout (no terminal needed for these commands)
      ${chk ''printf 'SETDESC hi\nGETINFO version\nBYE\n' | "$out/bin/pinentry-curses"'' "^D 1\\.3\\.2$"}
      /usr/bin/elfdump -d "$out/bin/pinentry-curses" | grep -q 'NEEDED.*libncursesw' || { echo "FATAL: pinentry-curses does not NEED libncursesw" >&2; exit 1; }
    '';
  };

  # hunspell (MPL-1.1/GPL/LGPL): library + CLI, nixpkgs' --with-ui --with-readline. Dictionaries: hunspell-dict-en-us.
  hunspell = mkSrcPkg {
    pname = "hunspell"; version = "1.7.3";
    src = { url = "https://github.com/hunspell/hunspell/releases/download/v1.7.3/hunspell-1.7.3.tar.gz";
            sha256 = "433274dac0619cb00c2e18b43a3dd3a9d50da5b5613fa9b5c21781e35dd76bc1"; };
    # GNU libiconv, as gdb (c-dev.nix): g++ predefines _XPG6, which makes the gate's <iconv.h> declare iconv(..., char **, ...), and
    # hunspell.cxx passes const char ** ("invalid conversion", measured); GNU iconv.h has one prototype for C and C++.
    deps = [ world ncurses readline libiconv perl ]; nativeTools = hostTools;
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --disable-nls --with-ui --with-readline \
        --with-libiconv-prefix=${libiconv} CPPFLAGS="-I${libiconv}/include ${ncw}" LDFLAGS="-L$gccLib/amd64"   # -L gcc.lib: as gmp6
      gmake -j8; gmake install
      ${dropDocs}
      # bin/ispellaff2myspell is #!/usr/bin/perl (no such file on solnix): the store perl, as NixOS' patchShebangs does
      f="$out/bin/ispellaff2myspell"; head -1 "$f" | grep -qx '#!/usr/bin/perl -w' || { echo "FATAL: ispellaff2myspell shebang anchor" >&2; exit 1; }
      sed -i "1s|^#!/usr/bin/perl -w$|#!${perl}/bin/perl -w|" "$f"
      ${chk ''"$out/bin/ispellaff2myspell" --help'' "[Uu]sage|ispellaff2myspell"}
      ${chk ''"$out/bin/hunspell" -v'' "Hunspell 1\\.7\\.3"}
      # a real spell check against a two-word dictionary: the misspelling is reported, the known word is not
      printf '2\nhello\nworld\n' > "$W/t.dic"; printf 'SET UTF-8\nTRY esianrtolcdugmphbyfvkwz\n' > "$W/t.aff"
      ${chk ''echo "hello wrold" | "$out/bin/hunspell" -d "$W/t" -l'' "^wrold$"}
    '';
  };

  # The en_US dictionary (SCOWL, wordlist.sourceforge.net; nixpkgs hunspellDicts.en_US: same zip and hash), in share/hunspell as nixpkgs.
  # A zip, so not mk-src-pkg (GNU tar unpacks): the store python's zipfile, store coreutils install (desktop/cosmic-data.nix does the same).
  hunspell-dict-en-us = derivation {
    name = "hunspell-dict-en-us-2026.02.25"; pname = "hunspell-dict-en-us"; system = "x86_64-solaris"; builder = "/usr/bin/bash";
    src = import <nix/fetchurl.nix> { url = "https://downloads.sourceforge.net/project/wordlist/speller/2026.02.25/hunspell-en_US-2026.02.25.zip";
      sha256 = "ac8e73310e951d88c52c2cf2ba54ceaca34f8486a81630ac8a75dc5f931179f9"; };
    inherit python3 hunspell; coreutils = base.coreutils; pathGate = ../path-gate.sh;
    args = [ "-c" ''
      set -eu; export PATH="$coreutils/bin:$python3/bin"; /usr/bin/bash "$pathGate"; mkdir w; cd w
      python3 -m zipfile -e "$src" .
      mkdir -p "$out/share/hunspell" "$out/share/doc/hunspell-dict-en-us"
      install -m0444 en_US.dic en_US.aff "$out/share/hunspell/"; install -m0444 README_en_US.txt "$out/share/doc/hunspell-dict-en-us/"
      # a real spell check with this dictionary: the misspelling is reported, the correct words are not
      r=$(echo "the quick brown fox jumpd over" | "$hunspell/bin/hunspell" -d "$out/share/hunspell/en_US" -l)
      [ "$r" = jumpd ] || { echo "FATAL: hunspell with en_US reported '$r', want 'jumpd'" >&2; exit 1; }
      echo "CHECK-OK: en_US flags 'jumpd' only" >&2
    '' ];
  };

  # whisper-cpp (MIT): speech-to-text. nixpkgs' CPU build: examples on, GGML_NATIVE off (the build host's CPU must not decide).
  # No SDL2/ffmpeg/CUDA/Vulkan (not in solnix).
  whisper-cpp = mkSrcPkg {
    pname = "whisper-cpp"; version = "1.9.5";
    # CMakeCache records this recipe's own -DCMAKE_SYSTEM_IGNORE_PATH (the host dirs cmake must NOT search), not a host tool
    hostPathAllow = "^[0-9]+:CMAKE_SYSTEM_IGNORE_PATH:UNINITIALIZED=/bin;/usr/bin;/sbin;/usr/sbin;/usr/gnu/bin$";
    src = gh "ggml-org/whisper.cpp" "v1.9.5" "ff1a9053feb509ff9d7729703355541ae9690073a6b1c40eb692c962e0dc1720";
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      # g++ on Solaris predefines __STDC_VERSION__ (201112L) in C++ too (measured: g++ -std=c++17 -E of an empty file), so the
      # bundled miniaudio.h takes its C11 branch (<stdalign.h>, _Alignas) in C++ and fails; only C sees that branch now.
      f=examples/miniaudio.h
      grep -q '^#if !defined(_MSC_VER) && defined (__STDC_VERSION__) && (__STDC_VERSION__ >= 201112L)$' $f || { echo "FATAL: miniaudio anchor" >&2; exit 1; }
      sed -i 's/^#if !defined(_MSC_VER) \&\& defined (__STDC_VERSION__) \&\& (__STDC_VERSION__ >= 201112L)$/#if !defined(_MSC_VER) \&\& !defined(__cplusplus) \&\& defined (__STDC_VERSION__) \&\& (__STDC_VERSION__ >= 201112L)/' $f
      grep -q '!defined(__cplusplus) && defined (__STDC_VERSION__)' $f || { echo "FATAL: miniaudio edit" >&2; exit 1; }
      for t in examples/{bench,command,cli,quantize,server,stream,talk-llama}/CMakeLists.txt; do
        [ -f "$t" ] && ! grep -q 'install(' "$t" && echo 'install(TARGETS ''${TARGET} RUNTIME)' >> "$t"
      done
      # ggml has no GGML_CPU_ALL_VARIANTS for SunOS ("not yet supported with x86 on SunOS", measured), so one CPU backend at a fixed
      # baseline instead of the build host's -march=native: x86-64-v2 + AVX + AVX2 + FMA + F16C (Haswell, 2013+; every EC2 x86 and
      # the maintainer's X1s). shortcut: no AVX512 path and no pre-Haswell support; upgrade when ggml supports variants on SunOS.
      # cmake on illumos reports CMAKE_SYSTEM_PROCESSOR=i386 (uname -p) even for a 64-bit build, so ggml took GGML_SYSTEM_ARCH UNKNOWN
      # and built the generic CPU backend: no SIMD, the AVX2 flags below were dead (measured in the cmake log). A 64-bit SunOS i386 is x86.
      f=ggml/cmake/common.cmake
      grep -q '^            CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|i686|AMD64|amd64)\$"))$' $f || { echo "FATAL: ggml arch anchor" >&2; exit 1; }
      sed -i 's/^\(            \)CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|i686|AMD64|amd64)\$"))$/\1(CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|i686|AMD64|amd64)$" OR (CMAKE_SYSTEM_NAME STREQUAL "SunOS" AND CMAKE_SIZEOF_VOID_P EQUAL 8 AND CMAKE_SYSTEM_PROCESSOR STREQUAL "i386"))))/' $f
      # cmake's find_program also searches past PATH, in /bin and /usr/bin: ggml found the HOST's /bin/git on both hosts and asked it
      # for a commit (gate2 L5, measured). NixOS has no git in the sandbox: keep cmake's system search out of the host dirs.
      ${cmakeB ''"-DCMAKE_SYSTEM_IGNORE_PATH=/bin;/usr/bin;/sbin;/usr/sbin;/usr/gnu/bin" -DCMAKE_DISABLE_FIND_PACKAGE_Git=TRUE \
        -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_BUILD_TESTS=OFF -DWHISPER_SDL2=OFF -DGGML_NATIVE=OFF -DGGML_LTO=OFF \
        -DBUILD_SHARED_LIBS=ON -DGGML_OPENMP=OFF -DGGML_CCACHE=OFF -DGGML_SSE42=ON -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON \
        -DGGML_F16C=ON -DGGML_BMI2=ON "-DCMAKE_EXE_LINKER_FLAGS=-L$gccLib/amd64 -lsocket -lnsl" -DCMAKE_SHARED_LINKER_FLAGS=-L$gccLib/amd64 \
        "-DCMAKE_CXX_FLAGS=-include alloca.h"''}
      # alloca: examples/cli/cli.cpp calls it, declared only in <alloca.h> on illumos. -lsocket -lnsl: whisper-server's httplib uses
      # sockets, which live there on illumos (its CMakeLists adds a socket library for Windows only). Both measured.
      # checks that can fail: the cache names no git, and ggml configured its x86 CPU backend
      ! grep -E '^GIT_(EXECUTABLE|EXE):[A-Z]+=/' _b/CMakeCache.txt || { echo "FATAL: whisper cmake found a host git" >&2; exit 1; }
      n=$(find _b/ggml -name 'quants.c.o' -path '*arch/x86*' | wc -l); g=$(find _b/ggml -name '*.o' -path '*arch/*' ! -path '*arch/x86*' | wc -l)
      [ "$n" -ge 1 ] && [ "$g" = 0 ] || { echo "FATAL: ggml CPU backend is not x86 (x86 objs $n, other-arch objs $g)" >&2; exit 1; }
      install -m755 models/download-ggml-model.sh "$out/bin/whisper-cpp-download-ggml-model"
      ${chk ''"$out/bin/whisper-cli" --help'' "usage: .*whisper-cli"}
      # a real run of the pipeline: load the source tree's test model, decode the JFK sample (miniaudio) and run the CPU backend to the
      # end (the test model has no weights, so it transcribes nothing; the real models are downloaded by the user, as on NixOS)
      "$out/bin/whisper-cli" -m models/for-tests-ggml-tiny.bin -f samples/jfk.wav -t 4 > "$W/wh.out" 2>&1 || { echo "FATAL: whisper-cli run failed" >&2; tail -5 "$W/wh.out" >&2; exit 1; }
      for re in "whisper_model_load: type += 1 .tiny." "read_audio_data: reading audio data from .samples/jfk.wav." "^system_info: n_threads = 4"; do
        grep -Eq "$re" "$W/wh.out" || { echo "FATAL: whisper-cli run: no /$re/" >&2; tail -5 "$W/wh.out" >&2; exit 1; }
      done; echo "CHECK-OK: whisper-cli loaded the model, decoded jfk.wav, ran the CPU backend" >&2
    '';
  };

  # ---- common libraries -----------------------------------------------------------------------------------------------------
  # gmp (LGPL-3.0+/GPL-2.0+): nixpkgs --with-pic --enable-cxx, CFLAGS=-std=gnu99 (gcc 15's C23 default breaks a configure test), no
  # --enable-fat on SunOS (nixpkgs: some tests crash there), --build pinned so config.guess cannot probe the host CPU.
  gmp6 = mkSrcPkg {
    pname = "gmp6"; version = "6.3.0";
    src = gnu "gmp" "6.3.0" "xz" "a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898";
    deps = [ world ]; nativeTools = [ gnum4 ] ++ hostTools;
    build = ''
      # LDFLAGS -L gcc.lib: libtool found libstdc++.la in the compiler out and baked that libdir into libgmpxx as -R (closure gate,
      # measured; gdb in c-dev.nix has the same fix). A plain .so found first adds no rpath.
      ( unset ABI; ./configure --prefix="$out" --libdir="$out/lib/amd64" --build=x86_64-pc-solaris2.11 --disable-static --with-pic \
          --enable-cxx ABI=64 CFLAGS="-std=gnu99 -O2" LDFLAGS="-L$gccLib/amd64" )   # gnu99, not nixpkgs' c99: strict ISO C hides isascii() on illumos (doprnt.c, measured)
      gmake -j16; gmake install
      ${dropDocs}
      printf '#include <gmp.h>\n#include <stdio.h>\nint main(void){mpz_t a;mpz_init(a);mpz_ui_pow_ui(a,2,100);gmp_printf("%%Zd\\n",a);return 0;}\n' > "$W/t.c"
      "$CC" -I"$out/include" -L"$out/lib/amd64" -Wl,-R,"$out/lib/amd64" "$W/t.c" -lgmp -o "$W/t"
      ${chk ''"$W/t"'' "^1267650600228229401496703205376$"}
    '';
  };
  mpfr = mkSrcPkg {
    pname = "mpfr"; version = "4.2.2";
    src = gnu "mpfr" "4.2.2" "xz" "b67ba0383ef7e8a8563734e2e889ef5ec3c3b898a01d00fa0a6869ad81c6ce01";
    deps = [ world gmp6 ]; nativeTools = hostTools;
    build = ''
      # --with-gmp-include/-lib, not --with-gmp=: that one assumes lib/, and the two may not be combined (configure says so)
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --with-gmp-include=${gmp6}/include --with-gmp-lib=${gmp6}/lib/amd64
      gmake -j16; gmake install
      ${dropDocs}
      printf '#include <mpfr.h>\nint main(void){mpfr_t x;mpfr_init2(x,200);mpfr_const_pi(x,MPFR_RNDN);mpfr_printf("%%.30Rf\\n",x);return 0;}\n' > "$W/t.c"
      "$CC" -I"$out/include" -I${gmp6}/include "$W/t.c" -L"$out/lib/amd64" -lmpfr -lgmp -o "$W/t"
      ${chk ''"$W/t"'' "^3\\.141592653589793238462643383280$"}
    '';
  };
  libmpc = mkSrcPkg {
    pname = "libmpc"; version = "1.4.1";
    src = gnu "mpc" "1.4.1" "xz" "91204cd32f164bd3b7c992d4a6a8ce6519511aadab30f78b6982d0bf8d73e931";
    deps = [ world gmp6 mpfr ]; nativeTools = hostTools;
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --with-gmp-include=${gmp6}/include --with-gmp-lib=${gmp6}/lib/amd64 \
        --with-mpfr-include=${mpfr}/include --with-mpfr-lib=${mpfr}/lib/amd64
      gmake -j16; gmake install
      ${dropDocs}
      printf '#include <mpc.h>\n#include <stdio.h>\nint main(void){mpc_t z;mpc_init2(z,64);mpc_set_si_si(z,0,1,MPC_RNDNN);mpc_sqr(z,z,MPC_RNDNN);printf("%%s\\n",mpc_get_str(10,0,z,MPC_RNDNN));return 0;}\n' > "$W/t.c"
      "$CC" -I"$out/include" -I${mpfr}/include -I${gmp6}/include "$W/t.c" -L"$out/lib/amd64" -lmpc -lmpfr -lgmp -o "$W/t"
      ${chk ''"$W/t"'' "^.-1\\.0+ \\+0.$"}   # i^2 = (-1 +0)
    '';
  };

  # tcl 8.6 (TCL licence, BSD-like): nixpkgs --enable-threads --enable-man-symlinks --enable-64bit, tclsh + tclsh8.6, libtcl8.6.so.
  # The bundled extension packages (pkgs/: sqlite, itcl, thread, tdbc) build too, as in nixpkgs.
  tcl = mkSrcPkg {
    pname = "tcl"; version = "8.6.16";
    src = { url = "https://downloads.sourceforge.net/project/tcl/Tcl/8.6.16/tcl8.6.16-src.tar.gz";
            sha256 = "91cb8fa61771c63c262efb553059b7c7ad6757afa5857af6265e4b0bdc2a14a5"; };
    deps = [ world zlib ]; nativeTools = hostTools;
    build = ''
      # the bundled sqlite3 extension builds with -DSQLITE_USE_ALLOCA, and on illumos alloca() is declared only in <alloca.h>,
      # which sqlite does not include ("implicit declaration of function 'alloca'", measured): gcc's builtin, by name.
      export CFLAGS="-O2 -Dalloca=__builtin_alloca"
      cd unix
      # Byte order pinned from the TARGET (this drv's $system), not probed: tcl's autoconf-2.59 AC_C_BIGENDIAN looks for BYTE_ORDER in
      # <sys/param.h>, but the gate defines it only in <endian.h>; the fallback run test calls exit() without <stdlib.h>, gcc 14 rejects
      # the implicit declaration, and the failed link reads as "yes". That shipped WORDS_BIGENDIAN=1 on x86_64 and aarch64, and every
      # double format panicked ("wrong digit!", tclStrToD.c; libdb1, measured).
      case "$system" in x86_64-*|aarch64-*) be=no ord=q;; sparcv9-*) be=yes ord=Q;; *) echo "FATAL: tcl: byte order of $system?" >&2; exit 1;; esac
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --enable-threads --enable-man-symlinks --enable-64bit --enable-shared \
        --without-tzdata ac_cv_c_bigendian=$be
      got=no; grep -q WORDS_BIGENDIAN tclConfig.sh && got=yes
      [ "$got" = "$be" ] || { echo "FATAL: tcl configured bigendian=$got, $system is $be" >&2; exit 1; }
      gmake -j16; gmake install
      ln -s tclsh8.6 "$out/bin/tclsh"
      ${dropDocs}
      ${chk ''echo 'puts [info patchlevel]' | "$out/bin/tclsh"'' "^8\\.6\\.16$"}
      ${chk ''echo 'package require Thread; puts [expr {6*7}]' | "$out/bin/tclsh"'' "^42$"}
      # doubles: the big-endian misconfiguration aborted on 0.1 and printed 2.5 as 5.56e-309. A native double must be laid out as the
      # target's own byte order ($ord: q little, Q big), and survive binary format/scan.
      printf '%s\n' 'binary scan [binary format d 1.0] d x' \
        "puts \"[expr {0.1}] [expr {2.5*2}] \$x [expr {[binary format d 1.0] eq [binary format $ord 1.0]}]\"" > "$W/dbl.tcl"
      ${chk ''"$out/bin/tclsh" "$W/dbl.tcl"'' "^0\\.1 5\\.0 1\\.0 1$"}
    '';
  };

  # giflib (MIT): its own Makefile (no configure), nixpkgs' PREFIX/LIBDIR install. The prebuilt man pages ship in doc/.
  giflib = mkSrcPkg {
    pname = "giflib"; version = "6.1.3";
    src = { url = "https://downloads.sourceforge.net/project/giflib/giflib-6.x/giflib-6.1.3.tar.gz";
            sha256 = "b65b66b99f0424b93525f987386f22fc5efb9da2bfc92ad4a532249aaffbab0e"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      M="CC=$CC PREFIX=$out LIBDIR=$out/lib/amd64"   # its Makefile's SHELL=/bin/sh (the world's)
      gmake -j8 $M shared-lib static-lib gif2rgb gifbuild gifclrmp gifecho giffix gifinto giftext giftool gifsponge
      gmake $M install-bin install-include install-shared-lib
      mkdir -p "$out/share/man/man1"; cp doc/*.1 "$out/share/man/man1/"
      ${chk ''"$out/bin/giftext" < pic/porsche.gif | head -4'' "Screen Size - Width = 320, Height = 200"}   # = tests/porsche.dmp
    '';
  };

  # GNU cpio: no rmt (nixpkgs: the paxutils remote tape helper is not installed), no NLS.
  cpio = mkSrcPkg {
    pname = "cpio"; version = "2.15";
    src = gnu "cpio" "2.15" "bz2" "937610b97c329a1ec9268553fb780037bcfff0dcffe9725ebc4fd9c1aa9075db";
    deps = [ world ]; nativeTools = [ bzip2-bin ] ++ hostTools;
    build = ''
      MAKEINFO=true ./configure --prefix="$out" --disable-nls --disable-rmt
      gmake -j8 MAKEINFO=true; gmake install MAKEINFO=true
      ${dropDocs}
      ${chk ''"$out/bin/cpio" --version'' "^cpio \\(GNU cpio\\) 2\\.15"}
      mkdir -p "$W/c/d"; echo cpio-ok > "$W/c/d/f"; ( cd "$W/c" && echo d/f | "$out/bin/cpio" -o -H newc > "$W/a.cpio" )
      ${chk ''mkdir -p "$W/x" && cd "$W/x" && "$out/bin/cpio" -id < "$W/a.cpio" 2>/dev/null && cat d/f'' "^cpio-ok$"}
    '';
  };

  # GNU groff: the man page formatter (man(1) needs it to render pages). nixpkgs keeps the perl scripts in a separate output; here
  # one output with perl as a runtime dep. No X11 (gxditview), no ghostscript/netpbm (no -Thtml image conversion), no uchardet.
  groff = mkSrcPkg {
    pname = "groff"; version = "1.25.0";
    # groff's Makefile sed REPLACES /usr/bin/perl with the store $(PERL) in its scripts: a rewrite away from the host, not a host tool
    hostPathAllow = "^[0-9]+:[[:space:]]+-e \"s[|]/usr/bin/perl[|][$][(]PERL[)][|]\" [\\\\]$";
    src = gnu "groff" "1.25.0" "gz" "24d103a07eb79e418963bce206c8771b649871f83bda2fd4c2e65529c1c56921";
    deps = [ world perl ]; nativeTools = [ perl ] ++ hostTools;
    build = ''
      # configure's troff probe runs the troff on PATH, the world's illumos troff: under 1.24 it answered yes on dixi (fonts in
      # /usr/lib/font) and no on chef2, so dixi's binaries came out g-prefixed (geqn, gchem; NarHash differed, measured). 1.25's
      # GROFF_G prefixes whenever a troff on PATH does not answer .g = 1 (a shim that fails now makes the prefix, measured). Shadow
      # troff with one that answers 1, GNU-compatible: no prefix, as with no troff at all (NixOS: none in the sandbox).
      mkdir -p "$W/notroff"; printf '#!/bin/sh\necho 1\n' > "$W/notroff/troff"; chmod +x "$W/notroff/troff"
      # Same class: configure looks for the HOST's macro sets in /usr/share/lib/tmac (dixi has the world's an/s/m there, chef2 none)
      # and, when found, installs g-prefixed groff macros plus site-tmac wrappers that .so the host files (NarHash differed again,
      # measured). --with-compatibility-wrappers=no: groff's own macros, plain names (NixOS, which has no system tmac either).
      PATH="$W/notroff:$PATH" MAKEINFO=true ./configure --prefix="$out" --without-x --without-gs --without-uchardet --without-libiconv-prefix \
        --with-compatibility-wrappers=no ac_cv_path_PERL=${perl}/bin/perl
      grep -q '^g = *$' Makefile || { echo "FATAL: groff configured a g prefix" >&2; grep '^g =' Makefile >&2; exit 1; }
      gmake -j16 MAKEINFO=true; gmake install MAKEINFO=true
      ${dropDocs}
      # 1.25 makes groff.7 with soelim -I $(abs_top_srcdir) (1.24 shipped it prebuilt): its .lf lines name the build dir. /build, as
      # mk-src-pkg's -ffile-prefix-map maps $W for the compiler (NixOS's sandbox path)
      m="$out/share/man/man7/groff.7"; grep -q "^\.lf 1 \"$W/" "$m" || { echo "FATAL: groff.7 .lf anchor" >&2; exit 1; }
      sed -i "s|^\(\.lf [0-9]* \"\)$W/|\1/build/|" "$m"; ! grep -q "$W" "$m" || { echo "FATAL: groff.7 still names $W" >&2; exit 1; }
      ${chk ''"$out/bin/groff" --version'' "^GNU groff version 1\\.25\\.0"}
      [ -x "$out/bin/eqn" ] && [ ! -e "$out/bin/geqn" ] || { echo "FATAL: groff binaries are prefixed" >&2; exit 1; }
      [ -f "$out/share/groff/1.25.0/tmac/an.tmac" ] && [ ! -e "$out/share/groff/1.25.0/tmac/gan.tmac" ] && [ -z "$(ls "$out/lib/groff/site-tmac")" ] \
        || { echo "FATAL: groff macros are prefixed or wrap host macro files" >&2; exit 1; }
      # a real man page render
      ${chk ''printf '.TH T 1\n.SH NAME\nt \\- a test page\n' | "$out/bin/groff" -man -Tutf8'' "a test page"}
    '';
  };

  # fmt (MIT): the C++ formatting library, shared, as nixpkgs (tests off: they need gtest's network fetch).
  fmt = mkSrcPkg {
    pname = "fmt"; version = "12.2.1";   # the queue's upstream-newer target (recipes3)
    src = gh "fmtlib/fmt" "12.2.1" "449374d74f31b67796dece454d59b93e6f1538efcce0e9ac78000c98142c139e";
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DBUILD_SHARED_LIBS=ON -DFMT_TEST=OFF -DFMT_DOC=OFF"}
      printf '#include <fmt/format.h>\n#include <cstdio>\nint main(){std::puts(fmt::format("{:>6}|{:.3f}", 42, 3.14159).c_str());}\n' > "$W/t.cc"
      "$CXX" -std=c++17 -I"$out/include" "$W/t.cc" -L"$out/lib/amd64" -lfmt -o "$W/t"
      ${chk ''"$W/t"'' "^    42\\|3\\.142$"}
    '';
  };

  # Catch2 v3 (BSL-1.0): static libs + headers + cmake config, as nixpkgs catch2_3.
  catch2_3 = mkSrcPkg {
    pname = "catch2_3"; version = "3.16.1";   # the queue's upstream-newer target (recipes3)
    src = gh "catchorg/Catch2" "v3.16.1" "d16bd1b8b2364918bd472cb216394acb93bde6784890df0d91bccfb3f28d777d";
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      # libstdc++'s bits/std_abs.h pulls the gate's <math.h>, whose iso/math_c99.h #defines isnan() even for C++; until <cmath>
      # #undefs it, Catch's own `bool isnan(double)` declaration is macro-expanded ("'isnan' is not a member of 'Catch'",
      # reproduced with a 4-line test on dixi). <cmath> first in the polyfill header fixes it (and is harmless elsewhere).
      f=src/catch2/internal/catch_polyfills.hpp
      grep -q '^namespace Catch {' $f || { echo "FATAL: catch2 polyfills anchor" >&2; exit 1; }
      sed -i '0,/^namespace Catch {/s//#include <cmath>\nnamespace Catch {/' $f
      ${cmakeB "-DCATCH_DEVELOPMENT_BUILD=OFF -DCATCH_BUILD_TESTING=OFF -DCATCH_INSTALL_DOCS=OFF"}
      printf '#include <catch2/catch_test_macros.hpp>\nTEST_CASE("t"){ REQUIRE(1+1==2); }\n' > "$W/t.cc"
      "$CXX" -std=c++17 -I"$out/include" "$W/t.cc" -L"$out/lib/amd64" -lCatch2Main -lCatch2 -o "$W/t"
      ${chk ''"$W/t" --colour-mode none'' "All tests passed .1 assertion in 1 test case"}
    '';
  };
}
