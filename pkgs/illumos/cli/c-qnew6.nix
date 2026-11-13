# cli/c-qnew6.nix -- leaves of the x86 queue that idle1's RANKING.md ranked #21-#40 (qnew6 lane, 2026-11-12): each attr's drv pname
# and version are the queue job's (pname, target), so the builders' eval match (solnix-builder.sh eplan) turns the job into a build. A
# new file, so no served drv moves; x86 only (null gtkMeson on aarch64 drops it), as c-qnew.nix. Store-only builds (nativeTools), each
# with an in-build check that runs it on real input. Sources, patches and flags are nixpkgs f4a03c0's, pinned by sha256 (equal to
# nixpkgs' flat or NAR hash); where a recipe departs from nixpkgs, the comment says why.
{ base, mkSrcPkg, world, chk, hostTools, autoreconfTools, autoreconf, cmake, python3, perl, libtool, flex, bison, gnupatch, libogg, check,
  gtest, uthash, netsurf-buildsystem, libparserutils, libzen, autoconf-archive, gtkMeson, ... }:
let
  inherit (base) zlib pkgconf openssl;
  inherit (base.nixChain) libsodium bzip2 curl;
  inherit (gtkMeson) gperf libpng meson samurai;
  fetch = url: sha256: import <nix/fetchurl.nix> { inherit url sha256; };
  # a file of nixpkgs f4a03c0's pkgs/by-name (a package's own patch), by its sha256
  npPatch = p: sha256: fetch "https://raw.githubusercontent.com/NixOS/nixpkgs/f4a03c008967841f2a0b3cb7c436fc6fc31671f6/pkgs/by-name/${p}" sha256;
  # cmake projects: the store cmake, store prefixes only, -j from --cores (c-qnew.nix's cmakeB)
  cmakeB = extra: ''
    cmake -S . -B _b -DCMAKE_INSTALL_PREFIX="$out" -DCMAKE_INSTALL_LIBDIR=lib/amd64 -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_SKIP_RPATH=ON -DCMAKE_IGNORE_PREFIX_PATH="/usr;/usr/local;/opt" \
      -DCMAKE_IGNORE_PATH="/usr/lib/64;/usr/lib/amd64;/lib/64" ${extra} >&2
    cmake --build _b -j''${NIX_BUILD_CORES:-4} >&2; cmake --install _b >&2
  '';
  # meson recipes: desktop/gtk's served meson 1.10.2 and samurai (c-recipes4.nix's mesonBuild)
  mesonTools = [ meson samurai python3 pkgconf gtkMeson.gtkTools ] ++ hostTools;
  mesonBuild = flags: ''
    export PYTHONDONTWRITEBYTECODE=1
    meson setup _b --prefix="$out" --libdir=lib/amd64 --buildtype=release --wrap-mode=nodownload -Db_ndebug=true ${flags}
    samu -C _b -j''${NIX_BUILD_CORES:-4}
    samu -C _b install
  '';
  # a C (or C++, with <cc> = "$CXX") test program against the just-installed library: <src> <link flags>
  tprog = src: libs: ''
    cat > "$W/t.c" <<'TPROG'
${src}
TPROG
    "$CC" -I"$out/include" "$W/t.c" -L"$out/lib/amd64" ${libs} -Wl,-R,"$out/lib/amd64" -o "$W/t"
  '';
  tprogxx = src: flags: ''
    cat > "$W/t.cc" <<'TPROG'
${src}
TPROG
    "$CXX" -I"$out/include" "$W/t.cc" ${flags} -o "$W/t"
  '';
  # fail unless <file> holds exactly <n> lines matching <fixed string> (an anchor for a sed edit)
  anchor = file: n: s: ''[ "$(grep -cF -- '${s}' ${file})" = ${toString n} ] || { echo 'FATAL: anchor ${file}: ${s}' >&2; exit 1; }'';
in rec {   # rec: batch B (the dependents) builds on the leaves above
  # dns-root-data (GPL-3.0-or-later per nixpkgs; the data is IANA's): the DNS root hints and the DNSSEC root trust anchor (key + DS), as
  # nixpkgs' buildCommand: root.hints from the knot-resolver tree it pins (codeload's tarball of that commit: its etc/root.hints is
  # nixpkgs' fetchurl hash, measured), root.key and root.ds nixpkgs' own files. No ELF; the check matches the KSK-2017 DS digest.
  dns-root-data = mkSrcPkg {
    pname = "dns-root-data"; version = "2025-04-14";
    src = { url = "https://codeload.github.com/CZ-NIC/knot-resolver/tar.gz/d9c96ae96f066a85d7";
            sha256 = "e5af2f85a5348a8ae74331af7de08486a06d02e6999f027b6a6eb1a8f2af0789"; };
    nativeTools = hostTools;
    build = ''
      mkdir -p "$out"
      cp etc/root.hints "$out/root.hints"
      cp ${npPatch "dn/dns-root-data/root.key" "79104a5c45335b7c768e391ba8c75ff3003416debebac8eae9983bc95ab824af"} "$out/root.key"
      cp ${npPatch "dn/dns-root-data/root.ds" "2c212250f1ec271109464e0db2f674f2b6b497da6a177d4d1b264fccb0f6d111"} "$out/root.ds"
      chmod 0444 "$out"/root.*
      [ "$(/usr/bin/digest -a sha256 "$out/root.hints")" = e251bfb8f9cd1c134867f5c8783335c378ae92ba5e5b42488d39c64b0909f14e ] \
        || { echo "FATAL: dns-root-data: root.hints is not nixpkgs' file" >&2; exit 1; }
      ${chk ''grep -c "IN DS 20326 8 2 E06D44B80B8F1D39A95C0B0D7C65D08458E880409BBC683457104237C7F8EC8D" "$out/root.ds"; grep -E "^A\\.ROOT-SERVERS\\.NET\\. +[0-9]+ +A +198\\.41\\.0\\.4$" "$out/root.hints"'' "^1$"}
    '';
  };

  # lrzsz (GPL-2.0-or-later): XMODEM/YMODEM/ZMODEM (rz, sz, rx, sx, rb, sb), autotools from the 1998 release, as nixpkgs: its
  # CVE-2018-10195 patch, the l prefix dropped (--program-transform-name), gnu17 and its warning downgrades. Its own fastcheck (sz piping
  # its own sources to rz through a fifo, cmp each) is the check, run with TMPDIR in the build dir. NLS on, as nixpkgs (its bundled intl/).
  lrzsz = mkSrcPkg {
    pname = "lrzsz"; version = "0.12.20";
    src = { url = "https://ohse.de/uwe/releases/lrzsz-0.12.20.tar.gz";
            sha256 = "c28b36b14bddb014d9e9c97c52459852f97bd405f89113f30bee45ed92728ff1"; };
    deps = [ world ]; nativeTools = [ gnupatch ] ++ hostTools;
    build = ''
      patch -p1 < ${fetch "https://bugzilla.redhat.com/attachment.cgi?id=79507" "4147d16b8820e36084bea9d593bfe7e0bcc7b34658f373e2719f8d4a6f453ed2"}
      # the patch leaves src/zm.c newer than po/lrzsz.pot, and po/ then remakes the template with xgettext (nixpkgs has gettext's; none
      # here). The patch changes no translatable string, so the shipped template stands: keep it newer than its sources.
      touch po/lrzsz.pot; touch po/stamp-cat-id po/cat-id-tbl.c
      # autoconf 2.12 takes a CFLAGS= argument for the host type ("invalid host type"): the flags go in the environment
      CFLAGS="-g -O2 -std=gnu17 -Wno-error=implicit-function-declaration -Wno-error=implicit-int -Wno-error=incompatible-pointer-types" \
        ./configure --prefix="$out" --mandir="$out/share/man" --program-transform-name=s/^l//   # mandir: nixpkgs' fixup moves $out/man there
      gmake -j8; gmake install
      mkdir "$W/tmp"; TMPDIR="$W/tmp" gmake fastcheck
      [ -e fastcheck.ok ] || { echo "FATAL: lrzsz: fastcheck did not pass" >&2; exit 1; }
      ${chk ''"$out/bin/sz" --version; "$out/bin/rz" --version'' "^rz \\(lrzsz\\) 0\\.12\\.20$"}
      ls "$out/share/man/man1/rz.1" "$out/share/man/man1/sz.1" > /dev/null
    '';
  };

  # libdicom (MIT): reads DICOM files (openslide's DICOM-WSI), meson, as nixpkgs (release, tests on: its check suite runs against the
  # served check as a link dep, found at run time through LD_LIBRARY_PATH), uthash from the store. dcm-dump prints a bundled test file.
  libdicom = mkSrcPkg {
    pname = "libdicom"; version = "1.3.0";
    src = { url = "https://codeload.github.com/ImagingDataCommons/libdicom/tar.gz/refs/tags/v1.3.0";
            sha256 = "c753179bc41f4efede3a56f4fab33bc1997bdc9c11036f8b75c4700f20b06524"; };
    deps = [ world ]; linkDeps = [ uthash check ]; nativeTools = mesonTools;
    build = ''
      # src/dicom.c calls the POSIX two-argument ctime_r: illumos declares it under _POSIX_PTHREAD_SEMANTICS (else the 3-argument draft one)
      ${mesonBuild "-Dtests=true -Dc_args=-D_POSIX_PTHREAD_SEMANTICS"}
      mrc=0; LD_LIBRARY_PATH=${check}/lib/amd64 meson test -C _b --print-errorlogs > "$W/mt.log" 2>&1 || mrc=$?   # set -e: keep the rc
      grep -E '^ *[0-9]+/[0-9]+ ' "$W/mt.log" >&2 || true
      [ $mrc = 0 ] || { echo "FATAL: libdicom meson test rc=$mrc" >&2; tail -60 "$W/mt.log" >&2; exit 1; }
      ${chk ''"$out/bin/dcm-dump" -V; "$out/bin/dcm-dump" data/test_files/sm_image.dcm | grep -c "Modality"'' "^1\\.3\\.0$"}
      "$out/bin/dcm-dump" data/test_files/sm_image.dcm | grep -q "SM" || { echo "FATAL: libdicom: dcm-dump read no SM modality" >&2; exit 1; }
    '';
  };

  # cyclonedds (EPL-2.0): Eclipse Cyclone DDS, the OMG DDS implementation (libddsc, idlc, ddsperf), cmake, as nixpkgs: its only input is
  # cmake, so its AUTO probes find no OpenSSL and no iceoryx (security API on, its OpenSSL plugins off); here those answers are set.
  # The check generates C from an IDL with the installed idlc.
  cyclonedds = mkSrcPkg {
    pname = "cyclonedds"; version = "11.0.1";
    src = { url = "https://codeload.github.com/eclipse-cyclonedds/cyclonedds/tar.gz/refs/tags/11.0.1";
            sha256 = "c25d46075ad6b5cee564bda9e5f49509e9a6dbb1a8b858e708eb360d335cf973"; };
    deps = [ world ]; nativeTools = [ cmake bison ] ++ hostTools;
    build = ''
      # ddsrt/sockets/posix.h already knows illumos' default (non-XPG4.2) struct msghdr has no msg_control/msg_controllen/msg_flags
      # (DDSRT_MSGHDR_FLAGS 0, which ddsi_udp.c honours); 11.0's multicast probe in ifaddrs.c sets them unguarded. Leave them out (the
      # initializer zeroes the rest) and, without msg_flags, skip the truncation test: the probe matches a 16-byte random payload anyway.
      f=src/ddsrt/src/ifaddrs/posix/ifaddrs.c
      ${anchor "$f" 1 "    .msg_control = NULL,"}
      ${anchor "$f" 1 "    .msg_controllen = 0,"}
      ${anchor "$f" 1 "    .msg_flags = 0"}
      ${anchor "$f" 1 "        !(msg.msg_flags & (MSG_TRUNC | MSG_CTRUNC)))"}
      sed -i -e '/^    \.msg_control = NULL,$/d' -e '/^    \.msg_controllen = 0,$/d' -e '/^    \.msg_flags = 0$/d' \
        -e 's@^        !(msg\.msg_flags & (MSG_TRUNC | MSG_CTRUNC)))$@#if DDSRT_MSGHDR_FLAGS\n&\n#else\n        1)\n#endif@' "$f"
      [ "$(grep -c 'msg_control\|msg_flags' "$f")" = 1 ] || { echo "FATAL: cyclonedds ifaddrs edit" >&2; exit 1; }
      # ddsrt links libsocket/libnsl on Solaris only for the SunPro compiler: gcc on SunOS needs them as much (sendmsg, getifaddrs)
      f=src/ddsrt/CMakeLists.txt
      ${anchor "$f" 1 ''if(CMAKE_C_COMPILER_ID STREQUAL "SunPro")''}
      sed -i 's/^    if(CMAKE_C_COMPILER_ID STREQUAL "SunPro")$/    if(CMAKE_C_COMPILER_ID STREQUAL "SunPro" OR CMAKE_SYSTEM_NAME STREQUAL "SunOS")/' "$f"
      ${anchor "$f" 1 ''if(CMAKE_C_COMPILER_ID STREQUAL "SunPro" OR CMAKE_SYSTEM_NAME STREQUAL "SunOS")''}
      # the built idlc runs during the build (ddsperf's types): cmakeB's CMAKE_SKIP_RPATH leaves it no RUNPATH to its own libraries yet
      # (mk-src-pkg adds the store RUNPATH at install), so the build tree's lib/ for that run
      export LD_LIBRARY_PATH="$PWD/_b/lib"
      ${cmakeB "-DENABLE_SSL=OFF -DENABLE_ICEORYX=OFF -DENABLE_ICEORYX2=OFF"}
      unset LD_LIBRARY_PATH
      printf 'module M { @topic struct T { long id; string s; }; };\n' > "$W/t.idl"
      ( cd "$W" && "$out/bin/idlc" t.idl )
      ${chk ''grep -c "M_T_desc" "$W/t.h" "$W/t.c"'' "t\\.c:[1-9]"}
      # a publish/subscribe round in one process: the HelloWorld example's IDL through the installed idlc, a reliable writer and reader on
      # one participant (local delivery, no network needed), one sample written and taken back
      cp examples/helloworld/HelloWorldData.idl "$W/"; ( cd "$W" && "$out/bin/idlc" HelloWorldData.idl )
      cat > "$W/t.c" <<'TPROG'
#include <dds/dds.h>
#include <stdio.h>
#include <string.h>
#include "HelloWorldData.h"
int main(void){ dds_entity_t p = dds_create_participant(DDS_DOMAIN_DEFAULT, NULL, NULL); if (p < 0) { printf("participant %s\n", dds_strretcode(-p)); return 1; }
dds_entity_t t = dds_create_topic(p, &HelloWorldData_Msg_desc, "solnix_t", NULL, NULL); dds_qos_t *q = dds_create_qos();
dds_qset_reliability(q, DDS_RELIABILITY_RELIABLE, DDS_SECS(10)); dds_qset_history(q, DDS_HISTORY_KEEP_ALL, 0);
dds_entity_t r = dds_create_reader(p, t, q, NULL), w = dds_create_writer(p, t, q, NULL); dds_delete_qos(q); if (t < 0 || r < 0 || w < 0) return 2;
HelloWorldData_Msg m = { 7, "solnix" }; if (dds_write(w, &m) != DDS_RETCODE_OK) return 3;
void *s[1] = { NULL }; dds_sample_info_t i[1]; int n = 0;
for (int k = 0; k < 100 && n <= 0; k++) { n = dds_take(r, s, i, 1, 1); if (n <= 0) dds_sleepfor(DDS_MSECS(20)); }
HelloWorldData_Msg *g = s[0]; printf("ok %d %d %s %s\n", n, n > 0 ? g->userID : -1, n > 0 ? g->message : "-", dds_strretcode(DDS_RETCODE_OK));
dds_return_loan(r, s, n); dds_delete(p); return 0; }
TPROG
      "$CC" -I"$out/include" -I"$W" "$W/t.c" "$W/HelloWorldData.c" -L"$out/lib/amd64" -lddsc -Wl,-R,"$out/lib/amd64" -o "$W/t"
      ${chk ''"$W/t"'' "^ok 1 7 solnix Success$"}
    '';
  };

  # easel (BSD-2-Clause): Sean Eddy's sequence analysis library and its esl-* miniapps (hmmer's), autotools from the tag, as nixpkgs:
  # autoreconf, `make check` (its unit tests and the sqc testsuite: perl and python3 on PATH, devkit/sqc's #! the store perl). The SIMD
  # paths it picks are SSE/SSE4/AVX by compile probe (x86-64 baseline flags each file asks for), not by the build CPU.
  easel = mkSrcPkg {
    pname = "easel"; version = "0.49";
    src = { url = "https://codeload.github.com/EddyRivasLab/easel/tar.gz/refs/tags/easel-0.49";
            sha256 = "90f75bc4727e6dfb5f402d9f70cf4a606d9639f72d21e07461279d3f3f06b918"; };
    deps = [ world ]; nativeTools = autoreconfTools ++ [ python3 ] ++ hostTools;
    build = ''
      ${autoreconf}
      ./configure --prefix="$out"
      gmake -j8
      sed -i "1s|^#! */usr/bin/perl|#!${perl}/bin/perl|" devkit/sqc
      gmake -j8 check
      gmake install
      printf '>a\nACGTACGTAC\n>b\nACGTA\n' > "$W/t.fa"
      ${chk ''"$out/bin/esl-seqstat" --dna "$W/t.fa"'' "^Total # residues: +15$"}
      "$out/bin/easel" --version | grep -qx 0.49 || { echo "FATAL: easel --version" >&2; exit 1; }
    '';
  };

  # libtommath (Unlicense / public domain, nixpkgs: publicDomain wtfpl): the LibTom multiple-precision integer library, its libtool
  # makefile.shared, as nixpkgs: the store libtool, nixpkgs' force_mp_set_double.patch. Its own demo test suite runs. The check: 2^127-1
  # is prime and prints in base 10.
  libtommath = mkSrcPkg {
    pname = "libtommath"; version = "1.3.0";
    src = { url = "https://github.com/libtom/libtommath/releases/download/v1.3.0/ltm-1.3.0.tar.xz";
            sha256 = "296272d93435991308eb73607600c034b558807a07e829e751142e65ccfa9d08"; };
    deps = [ world ]; nativeTools = [ gnupatch libtool ] ++ hostTools;
    build = ''
      patch -p1 < ${npPatch "li/libtommath/force_mp_set_double.patch" "60e6d11d9eef0e6e6e1bcd4054082c184b8791ce9c18e3b3ca2ea9937114a709"}
      M="-f makefile.shared PREFIX=$out LIBPATH=$out/lib/amd64 CC=$CC LIBTOOL=libtool INSTALL_GROUP=$(id -g) INSTALL_USER=$(id -u)"
      gmake -j8 $M; gmake $M install
      # its demo test suite against the installed library (makefile.shared's `test` target wants non-PIC demo/*.o, which the store
      # libtool, built without static libraries, does not write)
      "$CC" -I. -O2 demo/shared.c demo/test.c -L"$out/lib/amd64" -ltommath -Wl,-R,"$out/lib/amd64" -o "$W/ltmtest"
      "$W/ltmtest" > "$W/test.log" 2>&1 || { tail -20 "$W/test.log" >&2; exit 1; }
      grep -E "^Tests OK/NOP/FAIL: [0-9]+/[0-9]+/0$" "$W/test.log" >&2 || { echo "FATAL: libtommath tests" >&2; tail -5 "$W/test.log" >&2; exit 1; }
      ${tprog ''#include <tommath.h>
#include <stdio.h>
int main(void){ mp_int a; char s[64]; size_t n; mp_bool p; if (mp_init(&a) || mp_2expt(&a, 127) || mp_sub_d(&a, 1, &a)) return 1;
if (mp_prime_is_prime(&a, 8, &p) || mp_to_radix(&a, s, sizeof s, &n, 10)) return 2; printf("ok %s %d\n", s, p == MP_YES); mp_clear(&a); return 0; }'' "-ltommath"}
      ${chk ''"$W/t"'' "^ok 170141183460469231731687303715884105727 1$"}
    '';
  };

  # libkate (BSD-3-Clause): the Kate karaoke/text codec for Ogg (libkate, liboggkate, kateenc/katedec/katalyzer), autotools from the tag,
  # as nixpkgs (bison, flex: kateenc's parser; libogg, libpng from the store; docs off: no doxygen, as nixpkgs' closure). make check runs.
  # The check encodes a bundled .kate example to Ogg and decodes it back.
  libkate = mkSrcPkg {
    pname = "libkate"; version = "0.4.3";
    src = { url = "https://gitlab.xiph.org/xiph/kate/-/archive/kate-0.4.3/kate-kate-0.4.3.tar.gz";
            sha256 = "451fceba0caf53f01c5a47c93585a4442996747002647be6378e21b61e7241bf"; };
    deps = [ world libogg libpng zlib ]; nativeTools = autoreconfTools ++ [ bison flex pkgconf ] ++ hostTools;
    build = ''
      # two tests call alloca, which illumos declares in <alloca.h> only (glibc's <stdlib.h> has it too)
      for f in tests/bitwise.c tests/text.c; do ${anchor "$f" 1 "#include <stdlib.h>"}; sed -i 's|^#include <stdlib.h>$|&\n#include <alloca.h>|' "$f"; done
      ${autoreconf}
      # NM=gnm: tests' check-local greps nm output for exported non-kate_ symbols; illumos nm prints undefined symbols with a zero address
      # (GNU nm leaves it blank), so every U line looked like a definition. GNU nm is what that check and libtool expect.
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --disable-doc NM=gnm
      gmake -j8; gmake check; gmake install
      "$out/bin/kateenc" -t kate -c SUB -l en -o "$W/m.ogg" examples/kate/minimal.kate
      ${chk ''"$out/bin/katedec" "$W/m.ogg"'' "plain old text"}
    '';
  };

  # libhubbub (MIT): NetSurf's HTML5 parser, a static library on the served netsurf-buildsystem and libparserutils, as nixpkgs (gperf
  # and perl generate its tables). The check tokenises a document and counts its start tags.
  libhubbub = mkSrcPkg {
    pname = "libhubbub"; version = "0.3.8";
    src = { url = "https://download.netsurf-browser.org/libs/releases/libhubbub-0.3.8-src.tar.gz";
            sha256 = "8ac1e6f5f3d48c05141d59391719534290c59cd029efc249eb4fdbac102cd5a5"; };
    deps = [ world libparserutils ]; nativeTools = [ perl gperf pkgconf ] ++ hostTools;
    build = ''
      # its -std=c99 hides strncasecmp in illumos <strings.h> (its -D_BSD_SOURCE/-D_DEFAULT_SOURCE are glibc's): __EXTENSIONS__
      # build/make-entities.pl inserts the entities into its search trie in `keys %entities` order, which perl randomises per run: the
      # entity table (src/tokeniser/entities.o) differed between two builds (--check, measured). A fixed hash seed gives one order;
      # any order is a valid trie (the lookups are the same)
      PERL_HASH_SEED=0 PERL_PERTURB_KEYS=0 CFLAGS=-D__EXTENSIONS__ gmake install PREFIX="$out" NSSHARED="${netsurf-buildsystem}/share/netsurf-buildsystem" CC="$CC" BUILD_CC="$CC" Q=
      ${tprog ''#include <hubbub/hubbub.h>
#include <hubbub/parser.h>
#include <stdio.h>
#include <string.h>
static int n;
static hubbub_error tok(const hubbub_token *t, void *pw){ (void)pw; if (t->type == HUBBUB_TOKEN_START_TAG) n++; return HUBBUB_OK; }
int main(void){ hubbub_parser *p; hubbub_parser_optparams o; const char *d = "<!DOCTYPE html><p>a<b>b</b><i>c";
if (hubbub_parser_create("UTF-8", false, &p) != HUBBUB_OK) return 1; o.token_handler.handler = tok; o.token_handler.pw = NULL;
hubbub_parser_setopt(p, HUBBUB_PARSER_TOKEN_HANDLER, &o); hubbub_parser_parse_chunk(p, (const uint8_t *)d, strlen(d));
hubbub_parser_completed(p); hubbub_parser_destroy(p); printf("ok %d\n", n); return 0; }'' "-I${libparserutils}/include $out/lib/libhubbub.a ${libparserutils}/lib/libparserutils.a"}
      ${chk ''"$W/t"'' "^ok 3$"}
    '';
  };

  # ncompress (public domain): the classic compress/uncompress (LZW .Z), its GNUmakefile, as nixpkgs: the three gcc 15 commits it fetches
  # (their Changes hunks excluded, as nixpkgs), install_core, uncompress renamed uncompress-ncompress (gzip ships an uncompress). Its
  # tests/runtests.sh runs. The check round-trips a file through compress -c / uncompress-ncompress -c.
  ncompress = mkSrcPkg {
    pname = "ncompress"; version = "5.0";
    src = { url = "https://codeload.github.com/vapier/ncompress/tar.gz/v5.0";
            sha256 = "96ec931d06ab827fccad377839bfb91955274568392ddecf809e443443aead46"; };
    deps = [ world ]; nativeTools = [ gnupatch ] ++ hostTools;
    build = ''
      for p in ${fetch "https://github.com/vapier/ncompress/commit/af7d29d87ddf8b2002dad41152efa94e9c825b35.patch" "087a77380674c7ebd068c00db35e67ae3ce834af7f9d5af25b09b72f46c02c0f"} \
               ${fetch "https://github.com/vapier/ncompress/commit/aa359df10ec29a56c12f6e5c2bcec8d8ecfa2740.patch" "16992ccd0237e825b6773e275f14d0c91509b1735333cff19c9d12ac4b119395"} \
               ${fetch "https://github.com/vapier/ncompress/pull/40/commits/90810a7f11bf157b479c23c0fe6cee0bebec15c6.patch" "3c80128b45176e437868765de26dcf9bf0e12d5141bcb29da8835e1c635a0927"}; do
        # nixpkgs' fetchpatch excludes = [ "Changes" ]: only the compress.c hunks
        filterdiff() { awk '/^diff --git /{ keep = ($3 != "a/Changes") } keep' "$1"; }
        filterdiff "$p" | patch -p1
      done
      gmake -j8 PREFIX="$out" CC="$CC"
      # tests/runtests.sh is #!/bin/sh with `local` (ksh93, illumos' sh, has none): run it with bash, as on a Linux /bin/sh
      bash tests/runtests.sh
      gmake install_core PREFIX="$out" CC="$CC"
      mv "$out/bin/uncompress" "$out/bin/uncompress-ncompress"
      head -c 20000 "$out/bin/compress" > "$W/x"; "$out/bin/compress" -c "$W/x" > "$W/x.Z"
      # compress.c decompresses when argv[0] is exactly "uncompress": nixpkgs' renamed uncompress-ncompress compresses (as here); -d is the
      # decompressor by flag
      ${chk ''od -An -tx1 -N2 "$W/x.Z"'' "1f 9d"}
      "$out/bin/compress" -d -c "$W/x.Z" | cmp -s - "$W/x" || { echo "FATAL: ncompress round trip" >&2; exit 1; }
    '';
  };

  # pbzip2 (BSD-style, nixpkgs bsd2): parallel bzip2, its Makefile on the store bzip2 library, as nixpkgs: the two FreeBSD ports patches
  # (libc++ 19), the PRIuMAX fix. The check compresses with 4 threads and decompresses with the served-bzip2-compatible stream format.
  pbzip2 = mkSrcPkg {
    pname = "pbzip2"; version = "1.1.13";
    src = { url = "https://launchpad.net/pbzip2/1.1/1.1.13/+download/pbzip2-1.1.13.tar.gz";
            sha256 = "8fd13eaaa266f7ee91f85c1ea97c86d9c9cc985969db9059cdebcb1e1b7bdbe6"; };
    deps = [ world bzip2 ]; nativeTools = [ gnupatch ] ++ hostTools;
    build = ''
      patch -p0 < ${fetch "https://github.com/freebsd/freebsd-ports/raw/974d3ff054965d2bd2ab884a0579ed06c5a08b07/archivers/pbzip2/files/patch-BZ2StreamScanner.cpp" "1509f4d6bd7063bd25aa58d5d1150d7435ce044d93463575779c8afeb6cd1185"}
      patch -p0 < ${fetch "https://github.com/freebsd/freebsd-ports/raw/974d3ff054965d2bd2ab884a0579ed06c5a08b07/archivers/pbzip2/files/patch-BZ2StreamScanner.h" "9e2b7bd46bf068cdaf891ec57f16808286907291ee1054a83b971314ea63d4f0"}
      ${anchor "pbzip2.cpp" 27 ''"PRIuMAX"''}
      sed -i 's/"PRIuMAX"/" PRIuMAX "/g' pbzip2.cpp
      gmake -j8 CXX="$CXX"; gmake install PREFIX="$out" CXX="$CXX"
      head -c 300000 "$out/bin/pbzip2" > "$W/x"; "$out/bin/pbzip2" -p4 -k -c "$W/x" > "$W/x.bz2"
      ${chk ''od -An -c -N3 "$W/x.bz2"; "$out/bin/pbzip2" -d -c "$W/x.bz2" | cmp - "$W/x" && echo same'' "same"}
    '';
  };

  # memtailor (BSD-3-Clause): Macaulay2's C++ arena and memory-pool allocators, autotools from the tag, as nixpkgs (static library: its
  # LT_INIT disable-shared; gtest for `make check`, the store gtest). The check allocates from an Arena and frees the top.
  memtailor = mkSrcPkg {
    pname = "memtailor"; version = "1.4";
    src = { url = "https://codeload.github.com/Macaulay2/memtailor/tar.gz/refs/tags/v1.4";
            sha256 = "d16726040d73751d220f2a2d6404a74b2a3f7d2d7a62d11d69f845bafce55136"; };
    deps = [ world gtest ]; nativeTools = autoreconfTools ++ hostTools;
    build = ''
      ${autoreconf}
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --with-gtest
      gmake -j8; gmake check; gmake install
      ${tprogxx ''#include <memtailor.h>
#include <cstdio>
int main(){ memt::Arena a; int *p = a.allocArrayNoCon<int>(100).first; for (int i = 0; i < 100; i++) p[i] = i; long s = 0; for (int i = 0; i < 100; i++) s += p[i];
a.freeTop(p); std::printf("ok %ld %d\n", s, (int)a.isEmpty()); return 0; }'' "$out/lib/amd64/libmemtailor.a"}
      ${chk ''"$W/t"'' "^ok 4950 1$"}
    '';
  };

  # curlpp (MIT): C++ wrapper for libcurl, cmake, as nixpkgs (its curl 8.10 patch: CURLOPT_CLOSEPOLICY is gone), on the store curl. The
  # check builds a request and URL-escapes a string through libcurl.
  curlpp = mkSrcPkg {
    pname = "curlpp"; version = "0.8.1";
    src = { url = "https://codeload.github.com/jpbarrette/curlpp/tar.gz/v0.8.1";
            sha256 = "97e3819bdcffc3e4047b6ac57ca14e04af85380bd93afe314bee9dd5c7f46a0a"; };
    deps = [ world curl ]; nativeTools = [ cmake gnupatch ] ++ hostTools;
    build = ''
      patch -p1 < ${npPatch "cu/curlpp/curl_8_10_build_failure.patch" "c08497c5524ea6b1ebffafb37833b17333950ab4f967bca8cea23b7cc0807bff"}
      # curlpp-config --cc prints CMAKE_C_COMPILER, which is the build dir's wrapper (gate B8): the compiler by name, as every other
      # *-config here records it
      ${anchor "extras/CMakeLists.txt" 1 ''set(CC "''${CMAKE_C_COMPILER}")''}
      sed -i 's/^set(CC "''${CMAKE_C_COMPILER}")$/set(CC "gcc")/' extras/CMakeLists.txt
      ${cmakeB "-DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCURL_INCLUDE_DIR=${curl}/include -DCURL_LIBRARY=${curl}/lib/amd64/libcurl.so"}
      grep -q "^CURL_LIBRARY.*=${curl}/lib/amd64/libcurl.so$" _b/CMakeCache.txt || { echo "FATAL: curlpp: not the store curl" >&2; exit 1; }
      grep -qx '	echo gcc' "$out/bin/curlpp-config" || { echo "FATAL: curlpp-config --cc" >&2; grep -n echo "$out/bin/curlpp-config" | head -3 >&2; exit 1; }
      ${tprogxx ''#include <curlpp/cURLpp.hpp>
#include <curlpp/Easy.hpp>
#include <curlpp/Options.hpp>
#include <iostream>
int main(){ curlpp::Cleanup c; curlpp::Easy r; r.setOpt(new curlpp::options::Url("http://127.0.0.1:1/")); std::cout << "ok " << curlpp::escape("a b&c") << "\n"; return 0; }'' "-I${curl}/include -L$out/lib/amd64 -lcurlpp -L${curl}/lib/amd64 -lcurl -Wl,-R,$out/lib/amd64:${curl}/lib/amd64"}
      ${chk ''"$W/t"'' "^ok a%20b%26c$"}
    '';
  };

  # gnulib (GPL-3.0-or-later, its modules under their own licences): the GNU portability library SOURCE tree and gnulib-tool, as nixpkgs:
  # the tree copied to $out, lib -> include, bin/gnulib-tool; the five build-aux perl scripts exec the store perl. No fixup (nixpkgs'
  # dontFixup: a vendored tree), so no shebang rewriting beyond nixpkgs' patchShebangs of gnulib-tool and gnulib-tool.py (#! /bin/sh, and
  # python3 through /usr/bin/env: B9 allows both). The three files nixpkgs leaves with a host #! (check-module: perl, vcs-to-changelog.py:
  # python3, gen-uninames.lisp: clisp) are maintainer tools; their exec bit is dropped so no out file runs a host interpreter (gate B9).
  # The check: gnulib-tool --list names the memcpy module, and --extract-description prints its description.
  gnulib = mkSrcPkg {
    pname = "gnulib"; version = "20241001";
    src = { url = "https://codeload.github.com/coreutils/gnulib/tar.gz/0a01f6737dc5666c730bdfe6a038da53a4156cc2";
            sha256 = "75aaadacd0a78f91c1342af1a64d7333da310bac8adac9591c269c9f4055ee9e"; };
    deps = [ perl ]; nativeTools = [ perl python3 ] ++ hostTools;
    build = ''
      for f in build-aux/prefix-gnulib-mk build-aux/useless-if-before-free build-aux/update-copyright build-aux/gitlog-to-changelog build-aux/announce-gen; do
        ${anchor "$f" 1 "exec perl"}
        sed -i "s|exec perl|exec ${perl}/bin/perl|" "$f"
      done
      chmod a-x check-module build-aux/vcs-to-changelog.py lib/uniname/gen-uninames.lisp
      # cp * as nixpkgs, plus .gnulib-tool.py: gnulib-tool.py execs it, and gnulib-tool takes that path when a python3 >= 3.7 is on PATH
      # (nixpkgs' out lacks it, so its gnulib-tool works only without python3)
      mkdir -p "$out/bin"; cp -R * .gnulib-tool.py "$out/"
      ln -s "$out/lib" "$out/include"; ln -s "$out/gnulib-tool" "$out/bin/"
      for i in sh py; do
        ${chk ''GNULIB_TOOL_IMPL=$i "$out/bin/gnulib-tool" --list | grep -x memcpy; GNULIB_TOOL_IMPL=$i "$out/bin/gnulib-tool" --extract-description memcpy'' "^memcpy\\(\\) function: copy memory area\\.$"}
      done
    '';
  };

  # libdatrie (LGPL-2.1-or-later): double-array tries (libthai's), autotools from nixpkgs' git rev, as nixpkgs: autoreconf with
  # autoconf-archive (AX_COMPARE_VERSION), AC_INIT's version from nixpkgs (no .git for git-version-gen), libiconv for trietool, its man
  # page. The library's version script goes through the mapfile shim (its DATRIE_0.2 node; configure's probe would say no). One output
  # (nixpkgs splits bin/out/lib/dev). `make check` runs; the check adds words with trietool and queries one back.
  libdatrie = mkSrcPkg {
    pname = "libdatrie"; version = "2019-12-20";
    src = { url = "https://codeload.github.com/tlwg/libdatrie/tar.gz/d1db08ac1c76f54ba23d63665437473788c999f3";
            sha256 = "b72c56d3059c665cdd3259a51eedef409546c5c192b78f71409db49c4c97d554"; };
    deps = [ world base.libiconv ]; nativeTools = autoreconfTools ++ [ autoconf-archive pkgconf ] ++ hostTools;
    build = ''
      "$BASH" ${../version-script-mapfile.sh} wrap
      ${anchor "configure.ac" 1 "AC_INIT(libdatrie,"}
      sed -i -e "/AC_INIT/,+3d" configure.ac
      sed -i "5iAC_INIT(libdatrie,2019-12-20,[https://github.com/tlwg/libdatrie/issues])" configure.ac
      ${autoreconf}
      # GNU libiconv (the world's 64-bit iconv has no converters: base-src.nix libiconv): configure finds libc's iconv_open first, so
      # it is told no, and links -liconv. Its iconv.h takes const char ** (ICONV_CONST on illumos), trietool passes char **: a warning.
      CFLAGS="-g -O2 -Wno-error=incompatible-pointer-types" ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static \
        --disable-doxygen-doc datrie_cv_have_version_script=yes ac_cv_func_iconv_open=no
      gmake -j8; gmake check; gmake install
      /usr/bin/elfdump -d "$out/bin/trietool" | grep -q 'NEEDED.*libiconv\.so' || { echo "FATAL: trietool not on GNU libiconv" >&2; exit 1; }
      /usr/bin/pvs -dos "$out/lib/amd64/libdatrie.so" | grep -q "DATRIE_0.2: trie_new;$" || { echo "FATAL: libdatrie: no DATRIE_0.2 node" >&2; /usr/bin/pvs -do "$out/lib/amd64/libdatrie.so" >&2; exit 1; }
      printf '[0x0061,0x007a]\n' > "$W/t.abm"; printf 'apple\t1\nbanana\t2\n' > "$W/w.txt"
      "$out/bin/trietool" -p "$W" t add-list -e UTF-8 "$W/w.txt"
      ${chk ''LC_ALL=C "$out/bin/trietool" -p "$W" t query banana'' "^2$"}
      ls "$out/share/man/man1/trietool.1" > /dev/null
    '';
  };

  # libmediainfo (BSD-2-Clause): MediaArea's media metadata library, autotools in Project/GNU/Library, as nixpkgs: shared, libcurl (the
  # store curl), zlib, on the served libzen (propagated in nixpkgs: here a dep, so its RUNPATH names it), its .pc to lib/pkgconfig too.
  # The check reads a WAV header it writes.
  libmediainfo = mkSrcPkg {
    pname = "libmediainfo"; version = "26.05";
    src = { url = "https://mediaarea.net/download/source/libmediainfo/26.05/libmediainfo_26.05.tar.xz";
            sha256 = "c08b2d87b2fb5edb4526c2a8a317eb1f2cff44807e4631a037ca9f9a1d455054"; };
    deps = [ world zlib curl libzen ]; linkDeps = [ openssl ]; nativeTools = autoreconfTools ++ [ pkgconf ] ++ hostTools;   # openssl: libcurl.pc's Requires.private
    build = ''
      # illumos <sys/time.h> defines SEC (1, with MILLISEC/MICROSEC/NANOSEC), and File_Jpeg names a JPEG 2000 marker and its parser SEC:
      # drop the macro there (nothing in the file uses it as a time unit). The file has CRLF line ends.
      f=Source/MediaInfo/Image/File_Jpeg.h
      ${anchor "$f" 1 "    void SEC () { Data_Common(); };"}
      sed -i 's/^namespace MediaInfoLib\r$/#ifdef SEC\r\n#undef SEC\r\n#endif\r\n&/' "$f"
      [ "$(grep -c '^#undef SEC' "$f")" = 1 ] || { echo "FATAL: libmediainfo SEC edit" >&2; exit 1; }
      cd Project/GNU/Library
      ${autoreconf}
      # -L gcc.lib: libtool finds libstdc++.la in the compiler out and bakes that libdir into the library as -R (closure gate, measured;
      # c-recipes4.nix zimg, libdb, gmp6). A plain .so found first adds no rpath.
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --enable-shared --with-libcurl LDFLAGS="-L$gccLib/amd64"
      gmake -j8; gmake install
      /usr/bin/elfdump -d "$out/lib/amd64/libmediainfo.so" | grep -q 'NEEDED.*libcurl\.so' || { echo "FATAL: libmediainfo not linked to libcurl" >&2; exit 1; }
      mkdir -p "$out/lib/pkgconfig"; install -m 644 libmediainfo.pc "$out/lib/pkgconfig/libmediainfo.pc"
      # a 1-second 8 kHz mono 8-bit PCM WAV
      { printf 'RIFF\x4c\x1f\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00\x40\x1f\x00\x00\x40\x1f\x00\x00\x01\x00\x08\x00data\x40\x1f\x00\x00'; head -c 8000 /dev/zero; } > "$W/t.wav"
      ${tprogxx ''#include <MediaInfo/MediaInfo.h>
#include <ZenLib/Ztring.h>
#include <iostream>
using namespace MediaInfoLib;
int main(int c, char **v){ (void)c; MediaInfo m; if (!m.Open(ZenLib::Ztring().From_Local(v[1]))) return 1;
std::cout << "ok " << ZenLib::Ztring(m.Get(Stream_General, 0, __T("Format"))).To_Local() << " " << ZenLib::Ztring(m.Get(Stream_Audio, 0, __T("SamplingRate"))).To_Local() << "\n"; return 0; }''
        ''$(PKG_CONFIG_PATH="$out/lib/amd64/pkgconfig:$PKG_CONFIG_LIBDIR" pkg-config --cflags libmediainfo) -L$out/lib/amd64 -lmediainfo -L${libzen}/lib/amd64 -lzen -Wl,-R,$out/lib/amd64:${libzen}/lib/amd64''}
      ${chk ''"$W/t" "$W/t.wav"'' "^ok Wave 8000$"}
    '';
  };

  # expected-lite (BSL-1.0): std::expected for C++11 and later, header-only, cmake, as nixpkgs (its tests on: doCheck, ctest runs them).
  expected-lite = mkSrcPkg {
    pname = "expected-lite"; version = "0.10.0";
    src = { url = "https://codeload.github.com/nonstd-lite/expected-lite/tar.gz/v0.10.0";
            sha256 = "cfe082e4ffedeeedac47763504102646a39c080599c7c1fe99299d6a1f99af92"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DEXPECTED_LITE_OPT_BUILD_TESTS=ON"}
      ( cd _b && ctest -j''${NIX_BUILD_CORES:-4} --output-on-failure ) >&2
      ${tprogxx ''#include <nonstd/expected.hpp>
#include <cstdio>
nonstd::expected<int, const char *> half(int x){ if (x % 2) return nonstd::make_unexpected("odd"); return x / 2; }
int main(){ auto a = half(42), b = half(7); std::printf("ok %d %s\n", *a, b.error()); return 0; }'' "-std=c++11"}
      ${chk ''"$W/t"'' "^ok 21 odd$"}
      ls "$out/lib/amd64/cmake/expected-lite/expected-lite-config.cmake" > /dev/null
    '';
  };

  # libuecc (BSD-2-Clause): a very small elliptic-curve (Ed25519) library (fastd, ecdsautils), cmake, as nixpkgs: its CMake 4 backport
  # (cmake_minimum_required 3.18). The check: the base point times the group order is the identity, times 1 is not.
  libuecc = mkSrcPkg {
    pname = "libuecc"; version = "7";
    src = { url = "https://codeload.github.com/neocturne/libuecc/tar.gz/refs/tags/v7";
            sha256 = "465a6584c991c13fddf36700328c44fee9a3baff9025fb5f232b34d003d715e0"; };
    deps = [ world ]; nativeTools = [ cmake gnupatch ] ++ hostTools;
    build = ''
      patch -p1 < ${fetch "https://github.com/neocturne/libuecc/commit/b3812bf5ab1777193c4b85863311c33997d141f9.patch" "bc99cf26bceeecbde64f5a5cf9d413907b047808dbf8bcad92e27711d068e692"}
      ${cmakeB "-DLIB_SUFFIX=/amd64"}
      ${tprog ''#include <libuecc/ecc.h>
#include <stdio.h>
int main(void){ ecc_25519_work_t p, q; ecc_int256_t one = {{ 1 }}; ecc_25519_scalarmult_base(&p, &ecc_25519_gf_order); ecc_25519_scalarmult_base(&q, &one);
printf("ok %d %d\n", ecc_25519_is_identity(&p), ecc_25519_is_identity(&q)); return 0; }'' "-I$out/include/libuecc-7 -luecc"}
      ${chk ''"$W/t"'' "^ok 1 0$"}
      grep -qx "libdir=\''${exec_prefix}/lib/amd64" "$out/lib/amd64/pkgconfig/libuecc.pc" || { echo "FATAL: libuecc.pc libdir" >&2; cat "$out/lib/amd64/pkgconfig/libuecc.pc" >&2; exit 1; }
    '';
  };

  # ---- qnew6 batch B: the leaves' queue dependents (RANKING.md's last column), each on a leaf above ----------------------------------
  # libtomcrypt (Unlicense / public domain, nixpkgs: publicDomain wtfpl): the LibTom cryptographic toolkit on libtommath, its libtool
  # makefile.shared, as nixpkgs: the CVE-2019-17362 fix (upstream PR 508, pinned by its own sha256: nixpkgs' fetchpatch hashes the
  # normalised diff), -DUSE_LTM -DLTM_DESC -DLTC_PTHREAD and -ltommath. Its self-test suite runs against the installed library.
  libtomcrypt = mkSrcPkg {
    pname = "libtomcrypt"; version = "1.18.2";
    src = { url = "https://github.com/libtom/libtomcrypt/releases/download/v1.18.2/crypt-1.18.2.tar.xz";
            sha256 = "96ad4c3b8336050993c5bc2cf6c057484f2b0f9f763448151567fbab5e767b84"; };
    deps = [ world libtommath ]; nativeTools = [ gnupatch libtool pkgconf ] ++ hostTools;
    build = ''
      patch -p1 < ${fetch "https://github.com/libtom/libtomcrypt/pull/508/commits/25c26a3b7a9ad8192ccc923e15cf62bf0108ef94.patch" "50a20210e18a766a2d278787353fbbef255a71119f9529ce78d43f8c815dd84f"}
      M="-f makefile.shared PREFIX=$out LIBPATH=$out/lib/amd64 CC=$CC LIBTOOL=libtool EXTRALIBS=-ltommath INSTALL_GROUP=$(id -g) INSTALL_USER=$(id -u)"
      gmake -j8 $M CFLAGS="-DUSE_LTM -DLTM_DESC -DLTC_PTHREAD"; gmake $M CFLAGS="-DUSE_LTM -DLTM_DESC -DLTC_PTHREAD" install
      # the self-test suite (tests/, as makefile.shared's `test` target links it) against the installed library: its tests open the
      # bundled tests/*.key/.der by relative path, so it runs from the source tree
      # with its makefile's -DLTC_SOURCE (the tests use the library's internal mp_* macros and tables)
      "$CC" -DUSE_LTM -DLTM_DESC -DLTC_PTHREAD -DLTC_SOURCE -Isrc/headers -Itests tests/*.c -L"$out/lib/amd64" -ltomcrypt -ltommath \
        -Wl,-R,"$out/lib/amd64:${libtommath}/lib/amd64" -o "$W/ltctest"
      "$W/ltctest" > "$W/test.log" 2>&1 || { tail -30 "$W/test.log" >&2; exit 1; }
      grep -E "^SUCCESS: passed=[0-9]+ failed=0 " "$W/test.log" >&2 || { echo "FATAL: libtomcrypt tests" >&2; tail -30 "$W/test.log" >&2; exit 1; }
      ${tprog ''#include <tomcrypt.h>
#include <stdio.h>
int main(void){ unsigned char h[32]; unsigned long n = 32; register_hash(&sha256_desc); int i = find_hash("sha256");
if (hash_memory(i, (const unsigned char *)"abc", 3, h, &n) != CRYPT_OK) return 1; printf("ok "); for (unsigned k = 0; k < n; k++) printf("%02x", h[k]); printf("\n"); return 0; }'' "-ltomcrypt -ltommath -Wl,-R,${libtommath}/lib/amd64"}
      ${chk ''"$W/t"'' "^ok ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad$"}
    '';
  };

  # pigz (Zlib licence): parallel gzip, its Makefile on the store zlib, as nixpkgs (pigz, unpigz, its man page; the PDF too, nixpkgs'
  # doc output, here in share/doc). Its `make tests` runs (nixpkgs runs it on Linux only; here it passes), with ncompress for the .Z
  # tests (nixpkgs' check input).
  pigz = mkSrcPkg {
    pname = "pigz"; version = "2.8";
    src = { url = "https://codeload.github.com/madler/pigz/tar.gz/refs/tags/v2.8";
            sha256 = "2f7f6a6986996d21cb8658535fff95f1c7107ddce22b5324f4b41890e2904706"; };
    deps = [ world zlib ]; nativeTools = [ ncompress ] ++ hostTools;
    build = ''
      gmake -j8 CC="$CC"
      install -Dm755 pigz "$out/bin/pigz"; ln -s pigz "$out/bin/unpigz"
      install -Dm644 pigz.1 "$out/share/man/man1/pigz.1"; ln -s pigz.1 "$out/share/man/man1/unpigz.1"
      install -Dm644 pigz.pdf "$out/share/doc/pigz/pigz.pdf"
      head -c 400000 "$out/bin/pigz" > "$W/x"; "$out/bin/pigz" -p4 -c "$W/x" > "$W/x.gz"
      ${chk ''od -An -tx1 -N2 "$W/x.gz"; "$out/bin/unpigz" -c "$W/x.gz" | cmp - "$W/x" && echo same'' "same"}
    '';
  };

  # mathic (LGPL-2.0-or-later): Macaulay2's data structures for Groebner basis computation, autotools from the tag, as nixpkgs: on the
  # memtailor above, gtest for `make check`. The check compiles a mathic program against the installed library.
  mathic = mkSrcPkg {
    pname = "mathic"; version = "1.5";
    src = { url = "https://codeload.github.com/Macaulay2/mathic/tar.gz/refs/tags/v1.5";
            sha256 = "6bd2fd41d95efb0bf599aa5c6bc406f0d6fff803fccfe854db4835041c6267ee"; };
    deps = [ world memtailor gtest ]; nativeTools = autoreconfTools ++ [ pkgconf ] ++ hostTools;
    build = ''
      ${autoreconf}
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --with-gtest LDFLAGS="-L$gccLib/amd64"
      gmake -j8; gmake check; gmake install
      ${tprogxx ''#include <mathic.h>
#include <cstdio>
int main(){ mathic::ColumnPrinter p; p.addColumn(); p[0] << "solnix"; std::printf("ok %d\n", (int)p.getColumnCount()); return 0; }''
        "-I${memtailor}/include -L$out/lib/amd64 -lmathic -L${memtailor}/lib/amd64 -lmemtailor -Wl,-R,$out/lib/amd64:${memtailor}/lib/amd64"}
      ${chk ''"$W/t"'' "^ok 1$"}
    '';
  };

  # libthai (LGPL-2.1-or-later): Thai language support (word breaking, character classes), autotools from the release, as nixpkgs: on
  # the libdatrie above (its trietool builds the dictionary trie), its man pages. `make check` runs. The check breaks a Thai phrase.
  libthai = mkSrcPkg {
    pname = "libthai"; version = "0.1.30";
    src = { url = "https://github.com/tlwg/libthai/releases/download/v0.1.30/libthai-0.1.30.tar.xz";
            sha256 = "ddba8b53dfe584c3253766030218a88825488a51a7deef041d096e715af64bdd"; };
    deps = [ world libdatrie ]; nativeTools = [ libdatrie pkgconf ] ++ hostTools;
    build = ''
      "$BASH" ${../version-script-mapfile.sh} wrap
      # tests/test_thbrk.c passes char ** to iconv, whose GNU libiconv prototype (the one libdatrie links) takes const char ** here
      CFLAGS="-g -O2 -Wno-error=incompatible-pointer-types" ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --disable-doxygen-doc
      gmake -j8; gmake check; gmake install
      ls "$out/share/libthai/thbrk.tri" > /dev/null
      ${tprog ''#include <thai/thbrk.h>
#include <stdio.h>
int main(void){ const unsigned char s[] = { 0xca, 0xc7, 0xd1, 0xca, 0xb4, 0xd5, 0xa4, 0xc3, 0xd1, 0xba, 0 };  /* TIS-620 "sawasdee khrap" */
int pos[8]; ThBrk *b = th_brk_new(NULL); if (!b) return 1; int n = th_brk_find_breaks(b, s, pos, 8); printf("ok %d %d\n", n, n > 0 ? pos[0] : -1);
th_brk_delete(b); return 0; }'' "-lthai -L${libdatrie}/lib/amd64 -ldatrie -Wl,-R,${libdatrie}/lib/amd64"}
      ${chk ''"$W/t"'' "^ok 1 6$"}
    '';
  };

  # mediainfo (BSD-2-Clause): MediaArea's command-line media metadata tool, autotools in Project/GNU/CLI, as nixpkgs: on the
  # libmediainfo above and the served libzen. The check reads a WAV it writes.
  mediainfo = mkSrcPkg {
    pname = "mediainfo"; version = "26.05";
    src = { url = "https://mediaarea.net/download/source/mediainfo/26.05/mediainfo_26.05.tar.xz";
            sha256 = "f852093f9050022d699606eeabb38b24da5523d0212fab64dc4e4d3e46b56de1"; };
    deps = [ world zlib libmediainfo libzen ]; linkDeps = [ curl openssl ]; nativeTools = autoreconfTools ++ [ pkgconf ] ++ hostTools;
    build = ''
      cd Project/GNU/CLI
      ${autoreconf}
      ./configure --prefix="$out" --with-libmediainfo=${libmediainfo} LDFLAGS="-L$gccLib/amd64"
      gmake -j8; gmake install
      { printf 'RIFF\x4c\x1f\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00\x40\x1f\x00\x00\x40\x1f\x00\x00\x01\x00\x08\x00data\x40\x1f\x00\x00'; head -c 8000 /dev/zero; } > "$W/t.wav"
      ${chk ''"$out/bin/mediainfo" --Inform="Audio;%Format% %SamplingRate%" "$W/t.wav"'' "^PCM 8000$"}
    '';
  };

  # ecdsautils (MIT, BSD-2-Clause): ECDSA keys, signatures and verification on the libuecc above (ecdsautil and libecdsautil), cmake,
  # as nixpkgs: its CMake 4 backport; no doxygen docs (nixpkgs' doxygen input builds none it installs). The check signs a file and
  # verifies it with the derived public key.
  ecdsautils = mkSrcPkg {
    pname = "ecdsautils"; version = "0.4.2";
    src = { url = "https://codeload.github.com/freifunk-gluon/ecdsautils/tar.gz/v0.4.2";
            sha256 = "8880e5a506555a06d7a866de8a76c28bb4c7472abbf0d3fb396100d16c447174"; };
    deps = [ world libuecc ]; nativeTools = [ cmake gnupatch pkgconf ] ++ hostTools;
    build = ''
      patch -p1 < ${fetch "https://github.com/freifunk-gluon/ecdsautils/commit/19f096f9c10264f4efe4b926fe83126e85642cba.patch" "439e08d3f311cc1692644937c0b05a33ef38e575af92e41894b1823af1ea966f"}
      # its -std=c99 hides getopt in illumos <unistd.h> (glibc's <getopt.h>, which it includes, declares it anyway): __EXTENSIONS__
      ${cmakeB "-DLIB_SUFFIX=/amd64 -DCMAKE_C_FLAGS=-D__EXTENSIONS__"}
      E="$out/bin/ecdsautil"
      ${chk ''"$E" help'' "^ecdsautils 0\\.4\\.2$"}
      "$E" generate-key > "$W/sec"; "$E" show-key < "$W/sec" > "$W/pub"; printf 'solnix\n' > "$W/f"
      "$E" sign "$W/f" < "$W/sec" > "$W/sig"
      ${chk ''"$E" verify -s "$(cat "$W/sig")" -p "$(cat "$W/pub")" "$W/f" && echo verified'' "^verified$"}
      printf 'other\n' > "$W/g"; ! "$E" verify -s "$(cat "$W/sig")" -p "$(cat "$W/pub")" "$W/g" || { echo "FATAL: ecdsautil verified a wrong file" >&2; exit 1; }
    '';
  };
}
