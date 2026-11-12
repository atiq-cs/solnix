# cli/c-qnew5.nix -- leaves of the x86 queue that idle1's RANKING.md ranked first (qnew5 lane, 2026-11-12): each attr's drv pname and
# version are the queue job's (pname, target), so the builders' eval match (solnix-builder.sh eplan) turns the job into a build. A new
# file, so no served drv moves; x86 only (null gtkMeson on aarch64 drops it), as c-qnew.nix. Store-only builds (nativeTools), each with
# an in-build check that runs it on real input. Sources, patches and flags are nixpkgs f4a03c0's, pinned by sha256 (equal to nixpkgs'
# flat or NAR hash); where a recipe departs from it, the comment says why.
{ base, mkSrcPkg, world, chk, hostTools, autoreconfTools, autoreconf, cmake, python3, perl, texinfo, lzip, gtkMeson, ... }:
let
  inherit (base) zlib pkgconf gettext diffutils;
  curl = base.nixChain.curl;
  cmakeB = extra: ''
    cmake -S . -B _b -DCMAKE_INSTALL_PREFIX="$out" -DCMAKE_INSTALL_LIBDIR=lib/amd64 -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_SKIP_RPATH=ON -DCMAKE_IGNORE_PREFIX_PATH="/usr;/usr/local;/opt" \
      -DCMAKE_IGNORE_PATH="/usr/lib/64;/usr/lib/amd64;/lib/64" ${extra} >&2
    cmake --build _b -j''${NIX_BUILD_CORES} >&2; cmake --install _b >&2
  '';
  # meson projects: desktop/gtk's served store meson 1.10.2 and samurai (c-recipes4.nix's mesonBuild)
  mesonTools = [ gtkMeson.meson gtkMeson.samurai python3 pkgconf gtkMeson.gtkTools ] ++ hostTools;
  mesonBuild = flags: ''
    export PYTHONDONTWRITEBYTECODE=1
    meson setup _b --prefix="$out" --libdir=lib/amd64 --buildtype=release --wrap-mode=nodownload -Db_ndebug=true ${flags}
    samu -C _b -j''${NIX_BUILD_CORES}
    mrc=0; meson test -C _b --print-errorlogs > "$W/mt.log" 2>&1 || mrc=$?   # set -e: keep the rc
    [ $mrc = 0 ] || { echo "FATAL: meson test rc=$mrc" >&2; tail -60 "$W/mt.log" >&2; exit 1; }
    samu -C _b install
  '';
  # a C (or C++: <compiler> <ext>) test program against the just-installed library: <src> <link flags>
  tprogX = cc: ext: src: libs: ''
    cat > "$W/t.${ext}" <<'TPROG'
${src}
TPROG
    ${cc} -I"$out/include" "$W/t.${ext}" -L"$out/lib/amd64" ${libs} -Wl,-R,"$out/lib/amd64" -o "$W/t"
  '';
  tprog = tprogX ''"$CC"'' "c";
  schemesSrc = { url = "https://github.com/tinted-theming/schemes/archive/43dd14f6466a782bd57419fdfb5f398c74d6ac53.tar.gz";
                 sha256 = "909aa9702bfa67deabe35b5fd1ad235d15122e195c02373b9b59dc277b787914"; };
  # header-only .zip sources (no tarball, so not mk-src-pkg: GNU tar cannot unpack them): the store python's zipfile and coreutils, as
  # cli/c-recipes2.nix's hunspell-dict-en-us; the check compiles and runs a program against the headers with the store gcc wrapper.
  zipHeaders = { pname, version, url, sha256, dir, incs ? [ ], test, want }: derivation {
    name = "${pname}-${version}"; inherit pname version; system = "x86_64-solaris"; builder = "/usr/bin/bash";
    src = import <nix/fetchurl.nix> { inherit url sha256; };
    inherit python3; coreutils = base.coreutils; gccw = base.gccWrapper; pathGate = ../path-gate.sh;
    args = [ "-c" ''
      set -eu; export PATH="$coreutils/bin:$python3/bin"; /usr/bin/bash "$pathGate"; mkdir w; cd w
      python3 -m zipfile -e "$src" .
      mkdir -p "$out/include"; cp ${dir}/*.h "$out/include/"
      cat > t.cc <<'TPROG'
${test}
TPROG
      "$gccw/bin/g++" -I"$out/include" ${toString (map (i: "-I${i}/include") incs)} t.cc -o t
      r=$(./t); [ "$r" = "${want}" ] || { echo "FATAL: ${pname}: the check printed '$r', want '${want}'" >&2; exit 1; }
      echo "CHECK-OK: $r" >&2
    '' ];
  };
in rec {
  # dos2unix (BSD-2-Clause): DOS/Mac <-> Unix line-break conversion (dos2unix, unix2dos, mac2unix, unix2mac), its own Makefile, NLS on
  # (msgfmt from the served gettext; illumos libc has gettext, so no -lintl), its prove test suite (perl). Source: nixpkgs' tarball by
  # hash from SourceForge (the waterlan.home.xs4all.nl URL nixpkgs names now answers 404 with an HTML page, measured).
  dos2unix = mkSrcPkg {
    pname = "dos2unix"; version = "7.5.5";
    src = { url = "https://downloads.sourceforge.net/project/dos2unix/dos2unix/7.5.5/dos2unix-7.5.5.tar.gz";
            sha256 = "75f692b8484c8c24579a2ffd87df16b9c9428ed95497e3393a21d1ba0697ac33"; };
    deps = [ world ]; nativeTools = [ perl gettext ] ++ hostTools;
    build = ''
      # utf16_gb.t (UTF-16 -> GB18030) assumes wchar_t is Unicode in the GB18030 locale; upstream leaves it out on FreeBSD and Darwin,
      # whose wchar_t is not, and illumos' is not either (measured: mbtowc of d6 d0 in zh_CN.GB18030 gives 0xd6d0, not U+4E2D, and
      # no __STDC_ISO_10646__): dos2unix -gb is wrong there, as on those systems. UTF-8 locales are Unicode (e4 b8 ad -> 0x4e2d).
      [ "$(grep -c '^TESTS += utf16_gb\.t$' test/Makefile)" -eq 2 ] || { echo "FATAL: dos2unix utf16_gb anchor" >&2; exit 1; }
      sed -i 's/^TESTS += utf16_gb\.t$/# &/' test/Makefile
      gmake -j''${NIX_BUILD_CORES} prefix="$out"; gmake check prefix="$out"; gmake install prefix="$out"
      printf 'a\r\nb\r\n' > "$W/d.txt"; "$out/bin/dos2unix" -q "$W/d.txt"
      ${chk ''od -An -c "$W/d.txt" | tr -s ' ' && "$out/bin/dos2unix" --version | head -1'' "a \\\\n b \\\\n"}
      ${chk ''"$out/bin/unix2dos" --version'' "unix2dos 7\\.5\\.5"}
      ls "$out/share/locale/de/LC_MESSAGES/dos2unix.mo" "$out/share/man/man1/dos2unix.1" > /dev/null
    '';
  };

  # argp-standalone (LGPL-2.1-or-later): glibc's argp argument parser as a static library (libargp.a + argp.h), meson, as nixpkgs (its
  # test, ex1). illumos libc has no mempcpy or program_invocation_name: meson's probes compile the bundled mempcpy.c and do without.
  # Under gcc the sources expect <stdlib.h> to declare alloca (glibc's and Darwin's do); illumos keeps it in <alloca.h> only.
  argp-standalone = mkSrcPkg {
    pname = "argp-standalone"; version = "1.5.0";
    src = { url = "https://github.com/argp-standalone/argp-standalone/archive/refs/tags/1.5.0.tar.gz";
            sha256 = "c29eae929dfebd575c38174f2c8c315766092cec99a8f987569d0cad3c6d64f6"; };
    deps = [ world ]; nativeTools = mesonTools;
    build = ''
      export CFLAGS="-include alloca.h"
      ${mesonBuild ""}
      ${tprog ''#include <argp.h>
#include <stdio.h>
static int n; static error_t p(int k, char *a, struct argp_state *s) { if (k == 'v') n++; else if (k == ARGP_KEY_ARG) printf("arg %s ", a); return 0; }
int main(void){ struct argp_option o[] = { { "verbose", 'v', 0, 0, "more", 0 }, { 0 } }; struct argp a = { o, p, "FILE", "doc", 0, 0, 0 };
char *v[] = { "t", "-vv", "x", "--verbose", 0 }; int r = argp_parse(&a, 4, v, 0, 0, 0); printf("ok %d %d\n", r, n); return 0; }'' "$out/lib/amd64/libargp.a"}
      ${chk ''"$W/t"'' "^arg x ok 0 3$"}
    '';
  };

  # lzlib (BSD-2-Clause): the lzip format as a library (liblz), its own configure, shared (--enable-shared), as nixpkgs (its make check
  # on minilzip, the info page). nixpkgs' .tar.lz (the release email's hash): GNU tar unpacks it with the served lzip on PATH.
  lzlib = mkSrcPkg {
    pname = "lzlib"; version = "1.16";
    src = { url = "https://download.savannah.gnu.org/releases/lzip/lzlib/lzlib-1.16.tar.lz";
            sha256 = "cd2a96fbc685f7e3dc32b9f0e5e34046a77e3c10fcfebe62f9951e317d0a8cf4"; };
    deps = [ world ]; nativeTools = [ lzip texinfo ] ++ hostTools;
    build = ''
      # GNU --soname: illumos ld's is -h (upstream's fallback links no soname at all, so consumers would NEED liblz.so)
      grep -q -- '-Wl,--soname=$@' Makefile.in || { echo "FATAL: lzlib soname anchor" >&2; exit 1; }
      sed -i 's/-Wl,--soname=\$@/-Wl,-h,$@/' Makefile.in
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --enable-shared CC=gcc
      gmake -j''${NIX_BUILD_CORES}; gmake check; gmake install
      rm -f "$out/share/info/dir"   # per-profile (mk-src-pkg's info output does the same)
      /usr/bin/elfdump -d "$out/lib/amd64/liblz.so.1.16" | grep -Eq 'SONAME +0x[0-9a-f]+ +liblz\.so\.1$' || { echo "FATAL: liblz soname" >&2; exit 1; }
      ${tprog ''#include <stdint.h>
#include <stdio.h>
#include <lzlib.h>
int main(void){ uint8_t in[4096], c[8192], d[4096]; for (int i = 0; i < 4096; i++) in[i] = (uint8_t)(i % 7);
struct LZ_Encoder *e = LZ_compress_open(65535, 16, INT64_MAX); LZ_compress_write(e, in, 4096); LZ_compress_finish(e);
int n = 0, k; while (!LZ_compress_finished(e)) { if ((k = LZ_compress_read(e, c + n, 8192 - n)) < 0) return 2; n += k; } LZ_compress_close(e);
struct LZ_Decoder *x = LZ_decompress_open(); LZ_decompress_write(x, c, n); LZ_decompress_finish(x);
int m = 0; while (!LZ_decompress_finished(x)) { if ((k = LZ_decompress_read(x, d + m, 4096 - m)) < 0) return 3; m += k; } LZ_decompress_close(x);
int same = m == 4096; for (int i = 0; same && i < 4096; i++) same = d[i] == in[i]; printf("ok %s %d %d\n", LZ_version(), n < 200, same); return 0; }'' "-llz"}
      ${chk ''"$W/t"'' "^ok 1\\.16 1 1$"}
    '';
  };

  # gengetopt (GPL-3.0-or-later): getopt_long parser generator (C++), autotools from the release tarball, its test suite run serially
  # (not thread safe), without test_conf_parser_save.sh, and configure's `set -o posix` flipped, all as nixpkgs. The man page is the
  # tarball's (help2man only regenerates it from a newer cmdline.ggo). The check generates a parser and runs it.
  gengetopt = mkSrcPkg {
    pname = "gengetopt"; version = "2.23";
    src = { url = "https://mirrors.kernel.org/gnu/gengetopt/gengetopt-2.23.tar.xz";
            sha256 = "b941aec9011864978dd7fdeb052b1943535824169d2aa2b0e7eae9ab807584ac"; };
    deps = [ world ]; nativeTools = [ texinfo ] ++ hostTools;
    build = ''
      grep -q 'set -o posix' configure || { echo "FATAL: gengetopt posix anchor" >&2; exit 1; }
      sed -i 's/set -o posix/set +o posix/' configure
      # -L gcc.lib: libtool's C++ link would otherwise bake libstdc++.la's dir (the compiler out) in as -R (closure gate, measured; as zimg)
      ./configure --prefix="$out" LDFLAGS="-L$gccLib/amd64"
      gmake; rm tests/test_conf_parser_save.sh; gmake check; gmake install
      rm -f "$out/share/info/dir"
      printf 'package "t"\nversion "1"\noption "count" c "how many" int required\n' > "$W/t.ggo"
      cd "$W"; "$out/bin/gengetopt" -i t.ggo -F tcmd
      printf '#include <stdio.h>\n#include "tcmd.h"\nint main(int c, char **v){ struct gengetopt_args_info a; if (cmdline_parser(c, v, &a)) return 1; printf("ok %%d\\n", a.count_arg); return 0; }\n' > tm.c
      "$CC" tm.c tcmd.c -o tm; cd "$SRC"
      ${chk ''"$W/tm" --count 42'' "^ok 42$"}
      ${chk ''"$out/bin/gengetopt" --version'' "GNU gengetopt 2\\.23"}
    '';
  };

  # halibut (MIT): Simon Tatham's documentation formatter (text, HTML, man, info, PS, PDF, Windows Help, CHM), cmake, with perl for its
  # charset tables, as nixpkgs; it builds its own manual (installed). nixpkgs' one patch is upstream 570407a's charset/CMakeLists.txt
  # line (cmake_minimum_required 3.0 -> 3.7...3.28; cmake 4 rejects < 3.5): git.tartarus.org's gitweb now answers 403 to fetchers, so
  # the same one-line edit by sed (diffed from a clone of git.tartarus.org/simon/halibut.git, ce14e37..570407a).
  halibut = mkSrcPkg {
    pname = "halibut"; version = "1.3";
    src = { url = "https://www.chiark.greenend.org.uk/~sgtatham/halibut/halibut-1.3/halibut-1.3.tar.gz";
            sha256 = "aaa0f7696f17f74f42d97d0880aa088f5d68ed3079f3ed15d13b6e74909d3132"; };
    deps = [ world ]; nativeTools = [ cmake perl ] ++ hostTools;
    build = ''
      grep -qx 'cmake_minimum_required(VERSION 3.0)' charset/CMakeLists.txt || { echo "FATAL: halibut cmake anchor" >&2; exit 1; }
      sed -i 's/^cmake_minimum_required(VERSION 3\.0)$/cmake_minimum_required(VERSION 3.7...3.28)/' charset/CMakeLists.txt
      ${cmakeB ""}
      rm -f "$out/share/info/dir"
      printf '\\title solnix\n\n\\C{one} First\n\nHello \\e{world}, see \\k{one}.\n' > "$W/t.but"
      ${chk ''"$out/bin/halibut" --text="$W/t.txt" "$W/t.but" && cat "$W/t.txt"'' "Hello _world_, see chapter 1"}
      ${chk ''"$out/bin/halibut" --version'' "^Halibut, version 1\\.3$"}
      ls "$out/share/man/man1/halibut.1" "$out/share/info/halibut.info" > /dev/null
    '';
  };

  # libestr (LGPL-2.1-only): rsyslog's string handling library, autotools from the release tarball, as nixpkgs.
  libestr = mkSrcPkg {
    pname = "libestr"; version = "0.1.11";
    src = { url = "https://libestr.adiscon.com/files/download/libestr-0.1.11.tar.gz";
            sha256 = "46632b2785ff4a231dcf241eeb0dcb5fc0c7d4da8ee49cf5687722cdbe8b2024"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static
      gmake -j''${NIX_BUILD_CORES}; gmake check; gmake install
      ${tprog ''#include <libestr.h>
#include <stdio.h>
int main(void){ es_str_t *s = es_newStrFromCStr("sol", 3); if (!s || es_addBuf(&s, "nix", 3)) return 1; char *c = es_str2cstr(s, NULL);
printf("ok %s %s %u\n", es_version(), c, es_strlen(s)); return 0; }'' "-lestr"}
      ${chk ''"$W/t"'' "^ok 0\\.1\\.11 solnix 6$"}
    '';
  };

  # libnxml (LGPL-2.0-only): a small XML parser/writer on libcurl (libmrss), autotools from the tag (autoreconf), as nixpkgs. The queue's
  # job is 0.18.5, nixpkgs f4a03c0 is at 0.18.6, whose only code change fixes a stack buffer overflow in XML name parsing (the bound
  # `i < sizeof(buf) - 1` lets a multi-byte UTF-8 character overrun the buffer): carried here as a backport, so 0.18.5 is that version
  # plus the fix (all 5 sites: 0.18.5..0.18.6 diffed). Its check programs new and test_base run; easy fetches a URL (no network here).
  libnxml = mkSrcPkg {
    pname = "libnxml"; version = "0.18.5";
    src = { url = "https://github.com/bakulf/libnxml/archive/refs/tags/0.18.5.tar.gz";
            sha256 = "263d6424db3cd5f17a9f6300594548e82449ed22af59e9e5534646fa0dabd6a7"; };
    deps = [ world curl ]; nativeTools = autoreconfTools ++ [ pkgconf ] ++ hostTools;
    build = ''
      [ "$(grep -cE 'i < sizeof\((attr|name|str)\) - 1\) \{$' src/nxml_parser.c)" -eq 5 ] || { echo "FATAL: libnxml 0.18.6 fix anchors" >&2; exit 1; }
      sed -Ei 's/i < sizeof\((attr|name|str)\) - 1\) \{$/i + byte < sizeof(\1)) {/' src/nxml_parser.c
      [ "$(grep -cE 'i \+ byte < sizeof\((attr|name|str)\)\) \{$' src/nxml_parser.c)" -eq 5 ] || { echo "FATAL: libnxml 0.18.6 fix" >&2; exit 1; }
      mkdir -p m4   # AC_CONFIG_MACRO_DIRS([m4]); the tag has no m4/ (libtoolize fills it)
      ${autoreconf}
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static
      gmake -j''${NIX_BUILD_CORES}; gmake check TESTS="new test_base"; gmake install
      ${tprog ''#include <nxml.h>
#include <stdio.h>
int main(void){ nxml_t *n; nxml_data_t *r; char b[] = "<r a=\"1\"><c>solnix</c></r>"; if (nxml_new(&n) || nxml_parse_buffer(n, b, 0) || nxml_root_element(n, &r)) return 1;
printf("ok %s %s %s\n", r->value, r->children->value, r->children->children->value); nxml_free(n); return 0; }'' "-lnxml"}
      ${chk ''"$W/t"'' "^ok r c solnix$"}
    '';
  };

  # tnt (public domain): NIST's Template Numerical Toolkit, C++ headers, from nixpkgs' zip.
  tnt = zipHeaders {
    pname = "tnt"; version = "3.0.12"; url = "https://math.nist.gov/tnt/tnt_3_0_12.zip";
    sha256 = "479609bbc249e91c00392597fc48387fed8431471615c02826a8a0545673f3af"; dir = "tnt";
    test = ''#include <tnt.h>
#include <cstdio>
int main(){ TNT::Array2D<double> a(2, 2, 0.0); a[0][0] = 1; a[0][1] = 2; a[1][0] = 3; a[1][1] = 4; TNT::Array2D<double> b = TNT::matmult(a, a);
std::printf("%s %g %g %g %g\n", TNT_VERSION_STRING, b[0][0], b[0][1], b[1][0], b[1][1]); return 0; }'';
    want = "3.0.12 7 10 15 22";
  };

  # jama (public domain): NIST's JAMA/C++ linear algebra (LU, QR, SVD, Cholesky, eigen), headers on tnt, from nixpkgs' zip. nixpkgs
  # propagates tnt; here a consumer names both (no propagated inputs in this tree).
  jama = zipHeaders {
    pname = "jama"; version = "1.2.5"; url = "https://math.nist.gov/tnt/jama125.zip";
    sha256 = "7432bf51d7101f63d5880421f940f64cea124f1460ff2fcfb6226e6744d1360c"; dir = "."; incs = [ tnt ];
    test = ''#include <jama_lu.h>
#include <cstdio>
int main(){ TNT::Array2D<double> a(2, 2, 0.0); a[0][0] = 4; a[0][1] = 3; a[1][0] = 6; a[1][1] = 3; JAMA::LU<double> lu(a);
std::printf("%g %d\n", lu.det(), lu.isNonsingular()); return 0; }'';
    want = "-6 1";
  };

  # liblockfile (GPL-2.0-or-later; the library LGPL-2.0-or-later): NFS-safe lock files (liblockfile, dotlockfile), autoconf, shared, as
  # nixpkgs, its run-tests.sh. illumos: ld's soname flag is -h; no ldconfig (configure would search the host's /sbin, /usr/sbin); and
  # `install -g root` needs root, which the builder is not (nixpkgs' sandbox lets it pass): the group stays the builder's.
  liblockfile = mkSrcPkg {
    pname = "liblockfile"; version = "1.17";
    src = { url = "https://deb.debian.org/debian/pool/main/libl/liblockfile/liblockfile_1.17.orig.tar.gz";
            sha256 = "6e937f3650afab4aac198f348b89b1ca42edceb17fb6bb0918f642143ccfd15e"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      sed -i -e 's/ -g [^ ]* / /' Makefile.in   # nixpkgs' preConfigure
      sed -i -e 's/-Wl,-soname,/-Wl,-h,/' -e 's/ -g root / /' Makefile.in
      ! grep -nE -- '-soname|-g root' Makefile.in || { echo "FATAL: liblockfile Makefile.in edits" >&2; exit 1; }
      ac_cv_path_LDCONFIG=true ./configure --prefix="$out" --libdir="$out/lib/amd64" --enable-shared
      gmake; gmake test; gmake install
      /usr/bin/elfdump -d "$out/lib/amd64/liblockfile.so.1.0" | grep -Eq 'SONAME +0x[0-9a-f]+ +liblockfile\.so\.1$' || { echo "FATAL: liblockfile soname" >&2; exit 1; }
      ${tprog ''#include <lockfile.h>
#include <stdio.h>
#include <unistd.h>
int main(int c, char **v){ int a = lockfile_create(v[1], 0, 0), b = lockfile_create(v[1], 0, 0), e = access(v[1], 0); int r = lockfile_remove(v[1]);
printf("ok %d %d %d %d %d\n", a == L_SUCCESS, b != L_SUCCESS, e, r, access(v[1], 0) != 0); return 0; }'' "-llockfile"}
      ${chk ''"$W/t" "$W/x.lock"'' "^ok 1 1 0 0 1$"}
    '';
  };

  # base16-schemes (MIT): tinted-theming's base16 colour schemes (YAML) in share/themes, as nixpkgs, mode 0644 (nixpkgs' bare `install`
  # makes the YAML files executable; nothing runs them).
  base16-schemes = mkSrcPkg {
    pname = "base16-schemes"; version = "0-unstable-2026-01-15"; src = schemesSrc;
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      mkdir -p "$out/share/themes"; install -m644 base16/*.yaml "$out/share/themes/"
      ${chk ''ls "$out/share/themes" | wc -l | tr -d " " && grep -h "^name:" "$out/share/themes/default-dark.yaml"'' "^name: \"Default Dark\""}
    '';
  };

  # base24-schemes (MIT): the same tree's base24 schemes, as nixpkgs (its src is base16-schemes').
  base24-schemes = mkSrcPkg {
    pname = "base24-schemes"; version = "0-unstable-2026-01-15"; src = schemesSrc;
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      mkdir -p "$out/share/themes"; install -m644 base24/*.yaml "$out/share/themes/"
      ${chk ''grep -l "^system: \"base24\"" "$out/share/themes/"*.yaml | wc -l'' "^ *[1-9][0-9]+$"}
    '';
  };

  # m4ri (GPL-2.0-or-later): dense linear algebra over GF(2), autotools from the tag (autoreconf), as nixpkgs (make check). Pinned so
  # the build host does not choose: cache sizes 0:0:0 (m4ri's own defaults; configure reads /sys, else CPUID on non-Intel CPUs, so an
  # AMD builder would bake its caches in) and no PNG I/O (nixpkgs has no libpng input; configure would take one it finds).
  m4ri = mkSrcPkg {
    pname = "m4ri"; version = "20260122";
    src = { url = "https://github.com/malb/m4ri/archive/20260122.tar.gz";
            sha256 = "68196ed43bc2f20f8cf84433ff5d7161bf71011f2f429ce3c70b372740f4d4cf"; };
    deps = [ world ]; nativeTools = autoreconfTools ++ [ pkgconf ] ++ hostTools;
    build = ''
      ${autoreconf}
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --with-cachesize=0:0:0 --disable-png
      grep -Eq '^#define __M4RI_CPU_L1_CACHE[[:space:]]+0$' m4ri/m4ri_config.h || { echo "FATAL: m4ri cache size not pinned" >&2; grep CACHE m4ri/m4ri_config.h >&2; exit 1; }
      gmake -j''${NIX_BUILD_CORES}; gmake check; gmake install
      ${tprog ''#include <m4ri/m4ri.h>
#include <stdio.h>
int main(void){ mzd_t *a = mzd_init(200, 200), *i = mzd_init(200, 200); mzd_randomize(a); mzd_set_ui(i, 1); mzd_t *c = mzd_mul(NULL, a, i, 0);
mzd_t *s = mzd_add(NULL, a, a); printf("ok %d %d\n", mzd_equal(a, c), mzd_is_zero(s)); return 0; }'' "-lm4ri"}
      ${chk ''"$W/t"'' "^ok 1 1$"}
    '';
  };

  # tie (abstyles): TeX's change-file merger (CWEB), one C file built with cc -std=c89, as nixpkgs; the check is its Makefile.cweb ttest.
  tie = mkSrcPkg {
    pname = "tie"; version = "2.4";
    src = { url = "https://mirrors.ctan.org/web/tie/tie-2.4.tar.gz";
            sha256 = "5277b2bf28634d7a76e2fd562478ade208d8cee680cb70c7f8d139d7a628a9d4"; };
    deps = [ world ]; nativeTools = [ diffutils ] ++ hostTools;
    build = ''
      "$CC" -std=c89 tie.c -o tie
      mkdir -p "$out/bin"; cp tie "$out/bin"
      "$out/bin/tie" -c tie.outc tie.tie tie.cf? > /dev/null; diff tie.outc tie.chf.gen
      "$out/bin/tie" -m tie.outm tie.tie tie.cf? > /dev/null; diff tie.outm tie.master.gen
      ${chk ''"$out/bin/tie" -m "$W/o" tie.tie tie.cf1'' "CWEB Version 2\\.4"}
    '';
  };

  # libndtypes (BSD-3-Clause-like, bsdOriginal in nixpkgs): xnd's dynamic type library, its own configure, LD = the compiler (nixpkgs:
  # LD=cc), its test suite (static and shared), docs installed. illumos ld's soname flag is -h. ndtypes.h insists on __STDC_IEC_559__,
  # which glibc's stdc-predef.h defines from gcc's __GCC_IEC_559 (illumos has no stdc-predef.h): the header accepts gcc's macro too.
  libndtypes = mkSrcPkg {
    pname = "libndtypes"; version = "0.2.0dev3-unstable-2019-07-30";
    src = { url = "https://github.com/xnd-project/libndtypes/archive/3ce6607c96d8fe67b72cc0c97bf595620cdd274e.tar.gz";
            sha256 = "e51a9e370bcea4458934a2e6af463e274ab396317c61ec23ed8a8585e1c27cb0"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      grep -q 'CONFIGURE_LDFLAGS="-shared -Wl,-soname,$LIBSONAME"' configure || { echo "FATAL: libndtypes soname anchor" >&2; exit 1; }
      sed -i 's/CONFIGURE_LDFLAGS="-shared -Wl,-soname,\$LIBSONAME"/CONFIGURE_LDFLAGS="-shared -Wl,-h,$LIBSONAME"/' configure
      grep -q '^  #if !defined(__APPLE__) && !defined(__STDC_IEC_559__)$' libndtypes/ndtypes.h.in || { echo "FATAL: libndtypes IEC 559 anchor" >&2; exit 1; }
      sed -i 's/^  #if !defined(__APPLE__) \&\& !defined(__STDC_IEC_559__)$/  #if !defined(__APPLE__) \&\& !defined(__STDC_IEC_559__) \&\& !(defined(__GCC_IEC_559) \&\& __GCC_IEC_559 > 0)/' libndtypes/ndtypes.h.in
      grep -q '__GCC_IEC_559 > 0)$' libndtypes/ndtypes.h.in || { echo "FATAL: libndtypes IEC 559 edit" >&2; exit 1; }
      ./configure --prefix="$out" --libdir="$out/lib/amd64" LD=gcc
      gmake -j''${NIX_BUILD_CORES}; gmake check; gmake install
      /usr/bin/elfdump -d "$out/lib/amd64/libndtypes.so.0.2.0dev3" | grep -Eq 'SONAME +0x[0-9a-f]+ +libndtypes\.so\.0$' || { echo "FATAL: libndtypes soname" >&2; exit 1; }
      ${tprog ''#include <ndtypes.h>
#include <stdio.h>
int main(void){ ndt_context_t *c = ndt_context_new(); if (!c || ndt_init(c) < 0) return 1; const ndt_t *t = ndt_from_string("3 * int64", c);
if (!t) { printf("err %s\n", ndt_context_msg(c)); return 1; } printf("ok %s %lld\n", ndt_as_string(t, c), (long long)t->datasize); ndt_decref(t); ndt_finalize(); return 0; }'' "-lndtypes"}
      ${chk ''"$W/t"'' "^ok 3 \\* int64 24$"}
    '';
  };

  # wdiff (GPL-3.0-or-later): word-by-word diff, autotools from the release tarball, texinfo for its manual, its test suite, as nixpkgs.
  # It runs `diff` from PATH at run time (as nixpkgs' wdiff, which does not wrap it); the served diffutils is on PATH for the check. No
  # termcap, as nixpkgs (no curses input; glibc has no tputs): configure would otherwise take the world's libtermcap.
  wdiff = mkSrcPkg {
    pname = "wdiff"; version = "1.2.3";
    src = { url = "https://mirrors.kernel.org/gnu/wdiff/wdiff-1.2.3.tar.gz";
            sha256 = "29a4457eb0ed35c902e6732d71f25e1d6c7fe7fa0eda0fb6c371ed6779b49fd6"; };
    deps = [ world ]; nativeTools = [ texinfo diffutils ] ++ hostTools;
    build = ''
      ./configure --prefix="$out" --without-termcap
      gmake -j''${NIX_BUILD_CORES}; gmake check; gmake install
      rm -f "$out/share/info/dir"
      printf 'the quick brown fox\n' > "$W/a"; printf 'the slow brown fox\n' > "$W/b"
      ${chk ''"$out/bin/wdiff" "$W/a" "$W/b"'' "^the \\[-quick-\\] \\{\\+slow\\+\\} brown fox$"}
    '';
  };

  # c-stdaux (Apache-2.0 OR LGPL-2.1-or-later): c-util's auxiliary C macros, header only, meson, its tests, as nixpkgs. The unix
  # helpers (c-stdaux-unix.h) are only included on Linux and macOS (C_OS_LINUX/C_OS_MACOS): illumos gets the generic and GNU C parts.
  c-stdaux = mkSrcPkg {
    pname = "c-stdaux"; version = "1.6.0";
    src = { url = "https://github.com/c-util/c-stdaux/archive/refs/tags/v1.6.0.tar.gz";
            sha256 = "2ee2b7604a18b919f97f4357e61219520ec0b6e73f4d64ed9902cf1b5af047df"; };
    deps = [ world ]; nativeTools = mesonTools;
    build = ''
      ${mesonBuild ""}
      ${tprog ''#include <c-stdaux.h>
#include <stdio.h>
int main(void){ _c_cleanup_(c_freep) char *p = malloc(4); printf("ok %d %d %d %d\n", c_max(3, 7), c_min(3, 7), (int)c_align_to(13, 8), p != NULL); return 0; }'' ""}
      ${chk ''"$W/t"'' "^ok 7 3 16 1$"}
      grep -q '^Version: 1\.6\.0$' "$out/lib/amd64/pkgconfig/libcstdaux-1.pc" || { echo "FATAL: c-stdaux .pc" >&2; exit 1; }
    '';
  };

  # updfparser (LGPL-3.0-or-later): a small PDF parser/writer (libgourou), its own Makefile, static and shared, as nixpkgs (which also
  # installs the .so without a soname: consumers NEED libupdfparser.so). Libraries in lib/amd64, as every 64-bit library here.
  updfparser = mkSrcPkg {
    pname = "updfparser"; version = "0-unstable-2024-03-24";
    src = { url = "https://forge.soutade.fr/soutade/updfparser/archive/6060d123441a06df699eb275ae5ffdd50409b8f3.tar.gz";
            sha256 = "520f4938b78386ae5e42a7876294cd4f61c5ef7425c906ca3449140ea447226e"; };
    deps = [ world ]; nativeTools = [ python3 ] ++ hostTools;
    build = ''
      gmake -j''${NIX_BUILD_CORES} BUILD_STATIC=1 BUILD_SHARED=1
      install -Dt "$out/include" include/*.h; install -Dt "$out/lib/amd64" libupdfparser.so; install -Dt "$out/lib/amd64" -m644 libupdfparser.a
      # a minimal one-object PDF (python computes the xref offsets): parse it, count the objects, write it back
      python3 - "$W/a.pdf" <<'MKPDF'
import sys
b = b"%PDF-1.4\n"; o1 = len(b); b += b"1 0 obj\n<< /Type /Catalog /Solnix 42 >>\nendobj\n"; x = len(b)
b += b"xref\n0 2\n0000000000 65535 f \n%010d 00000 n \ntrailer\n<< /Size 2 /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (o1, x)
open(sys.argv[1], "wb").write(b)
MKPDF
      ${tprogX ''"$CXX"'' "cc" ''#include <uPDFParser.h>
#include <uPDFParser_common.h>
#include <cstdio>
int main(int c, char **v){ uPDFParser::Parser p; try { p.parse(v[1]); } catch (uPDFParser::Exception &e) { std::printf("%s\n", e.what()); return 1; }
std::printf("ok %d\n", (int)p.objects().size()); return 0; }'' "-lupdfparser"}
      ${chk ''"$W/t" "$W/a.pdf"'' "^ok 1$"}
    '';
  };
}
