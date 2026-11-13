# cli/c-qnew7.nix -- autotools/meson leaves of the x86 queue (idle1's byname.tsv rows with every input served or on main, ranked by jobs
# closed / effort; qnew7 lane, 2026-11-13): each attr's drv pname and version are the queue job's (pname, target), so the builders' eval
# match (solnix-builder.sh eplan) turns the job into a build. A new file, so no served drv moves; x86 only (null gtkMeson on aarch64 drops
# it), as c-qnew.nix. Store-only builds (nativeTools), each with an in-build check that runs it on real input. Sources, patches and flags
# are nixpkgs f4a03c0's, pinned by sha256 (equal to nixpkgs' flat or NAR hash); where a recipe departs from nixpkgs, the comment says why.
{ base, mkSrcPkg, world, chk, hostTools, autoreconfTools, autoreconf, gnupatch, perl, libtool, gnum4, readline, lzo, python3, bzip2-bin, gtkMeson, ... }:
let
  inherit (base) zlib pkgconf libiconv diffutils;
  inherit (base.nixChain) bzip2;
  fetch = url: sha256: import <nix/fetchurl.nix> { inherit url sha256; };
  # a file of nixpkgs f4a03c0's pkgs/by-name (a package's own patch), by its sha256
  npPatch = p: sha256: fetch "https://raw.githubusercontent.com/NixOS/nixpkgs/f4a03c008967841f2a0b3cb7c436fc6fc31671f6/pkgs/by-name/${p}" sha256;
  # a C (or C++: <compiler> <ext>) test program against the just-installed library: <src> <link flags>
  tprogX = cc: ext: src: libs: ''
    cat > "$W/t.${ext}" <<'TPROG'
${src}
TPROG
    ${cc} -I"$out/include" "$W/t.${ext}" -L"$out/lib/amd64" ${libs} -Wl,-R,"$out/lib/amd64" -o "$W/t"
  '';
  tprog = tprogX ''"$CC"'' "c";
  tprogxx = tprogX ''"$CXX"'' "cc";
  # fail unless <file> holds exactly <n> lines matching <fixed string> (an anchor for a sed edit)
  anchor = file: n: s: ''[ "$(grep -cF -- '${s}' ${file})" = ${toString n} ] || { echo 'FATAL: anchor ${file}: ${s}' >&2; exit 1; }'';
  # GNU ld version scripts -> illumos mapfiles (../version-script-mapfile.sh; c-recipes4.nix's vsMap)
  vsMap = ''"$BASH" ${../version-script-mapfile.sh} wrap'';
  hasVer = lib: node: sym: ''/usr/bin/pvs -dos "${lib}" | grep -q "[[:space:]]${node}: ${sym};$" || { echo "FATAL: ${lib} lacks ${node}: ${sym}" >&2; /usr/bin/pvs -do "${lib}" >&2; exit 1; }'';
  # meson projects: desktop/gtk's served meson 1.10.2 and samurai (c-qnew5.nix's mesonBuild; meson test unless MTEST=0 is in flags)
  mesonTools = [ gtkMeson.meson gtkMeson.samurai python3 pkgconf gtkMeson.gtkTools ] ++ hostTools;
  mesonBuild = flags: ''
    export PYTHONDONTWRITEBYTECODE=1
    meson setup _b --prefix="$out" --libdir=lib/amd64 --buildtype=release --wrap-mode=nodownload -Db_ndebug=true ${flags}
    samu -C _b -j''${NIX_BUILD_CORES:-4}
    mrc=0; meson test -C _b --print-errorlogs > "$W/mt.log" 2>&1 || mrc=$?   # set -e: keep the rc
    grep -E '^ *[0-9]+/[0-9]+ ' "$W/mt.log" >&2 || true
    [ $mrc = 0 ] || { echo "FATAL: meson test rc=$mrc" >&2; tail -60 "$W/mt.log" >&2; exit 1; }
    samu -C _b install
  '';
  # the usual autotools library/tool: configure into $out (lib/amd64), build, `make check` (unless check = ""), install
  ac = { flags ? "", check ? "gmake check", env ? "" }: ''
    ${env} ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static ${flags}
    gmake -j''${NIX_BUILD_CORES:-4}
    ${check}
    gmake install
  '';
in rec {
  # libidn (LGPL-2.0-or-later): GNU Libidn, IDNA 2003 (stringprep, punycode, idna_to_ascii), as nixpkgs (format hardening off is a no-op
  # here). Its version script through the mapfile shim (gl_cv_sys_ld_version_script: the probe's GNU flag fails on illumos ld); libc's
  # iconv converts (am_cv_func_iconv), as nixpkgs' Linux build has glibc's. The check: idn encodes a UTF-8 name.
  libidn = mkSrcPkg {
    pname = "libidn"; version = "1.44";
    src = { url = "https://ftpmirror.gnu.org/gnu/libidn/libidn-1.44.tar.gz";
            sha256 = "499608bab3a65650a0ea52888c13a8deebe3f71408e319acd9ec52e02eb13959"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ${vsMap}
      ${ac { flags = "--disable-doc --disable-csharp --disable-java gl_cv_sys_ld_version_script=yes"; }}
      rm -f "$out/share/info/dir"
      ${hasVer "$out/lib/amd64/libidn.so.12" "LIBIDN_1.0" "idna_to_ascii_8z"}
      ${chk ''LC_ALL=en_US.UTF-8 "$out/bin/idn" --quiet -a "bücher.example"'' "^xn--bcher-kva\\.example$"}
    '';
  };

  # catdoc (GPL-2.0-only): MS-Word/Excel/PowerPoint text extractors (catdoc, xls2csv, catppt), as nixpkgs: Debian's 0.95-6 patch set, the
  # Tk viewer off. Check: catdoc reads a plain-text file through its charset tables (the installed share/catdoc).
  catdoc = mkSrcPkg {
    pname = "catdoc"; version = "0.95";
    src = { url = "http://ftp.wagner.pp.ru/pub/catdoc/catdoc-0.95.tar.gz";
            sha256 = "514a84180352b6bf367c1d2499819dfa82b60d8c45777432fa643a5ed7d80796"; };
    deps = [ world ]; nativeTools = [ gnupatch ] ++ hostTools;
    build = ''
      for p in ${fetch "https://sources.debian.org/data/main/c/catdoc/1:0.95-6/debian/patches/01-amd64_fixes.patch" "e4e303669bf9378108433fdd19a1185a0c0bed1fafeb2a05283c145fbca47c5a"} \
               ${fetch "https://sources.debian.org/data/main/c/catdoc/1:0.95-6/debian/patches/02-Makefile_fixes.patch" "9ceca4bf37eebef0a04f69996116ed7b65fbc14d4b5253cc425722e7c609b677"} \
               ${fetch "https://sources.debian.org/data/main/c/catdoc/1:0.95-6/debian/patches/03-Type_fixes.patch" "8584d74f185f01cce761e57c375a357b97a074f75b32347a1e9d8c483d580317"} \
               ${fetch "https://sources.debian.org/data/main/c/catdoc/1:0.95-6/debian/patches/04-XLS_parsing_improvements.patch" "16f21817f093a22c0f5ba5584669e216d2e054fa6a6bf4d4116d122f20c1743c"} \
               ${fetch "https://sources.debian.org/data/main/c/catdoc/1:0.95-6/debian/patches/05-CVE-2017-11110.patch" "94d8711ea9c939b6f9101e580c0855bd3e6dce405b58f330e8ffa427bdbd3e23"} \
               ${fetch "https://sources.debian.org/data/main/c/catdoc/1:0.95-6/debian/patches/06-Fix_OLENAMELENGTH.patch" "455dbb2363996ec6474309c35e570000e6ec8d7075d8601e0a007f0788374437"} \
               ${fetch "https://sources.debian.org/data/main/c/catdoc/1:0.95-6/debian/patches/0007-Added-guards-against-a-signed-text-length-when-parsi.patch" "d58e7bcf259209a47977f6d3b28b92ddefa46be829d4f587662d683b2e03417c"} \
               ${fetch "https://sources.debian.org/data/main/c/catdoc/1:0.95-6/debian/patches/0008-Added-a-guard-against-a-product-overflow-when-proces.patch" "c59256a104c52b867cc7da9bf62b8e205c70fbedfa254e2fae7ab2bf508c5159"} \
               ${fetch "https://sources.debian.org/data/main/c/catdoc/1:0.95-6/debian/patches/0009-Added-guards-against-invalid-sector-sizes-when-tryin.patch" "9bafacca7965bd179798d29566f8790557a97eb059d78da060de8b42dcd3376d"}; do
        patch -p1 < "$p"
      done
      rm INSTALL   # nixpkgs' preInstall (make's INSTALL target confusion)
      ./configure --prefix="$out" --disable-wordview
      gmake -j''${NIX_BUILD_CORES:-4}; gmake install
      printf 'solnix catdoc check\n' > "$W/p.txt"
      ${chk ''"$out/bin/catdoc" -V; "$out/bin/catdoc" "$W/p.txt"'' "^solnix catdoc check$"}
      ls "$out/share/catdoc/cp1252.txt" "$out/share/man/man1/catdoc.1" > /dev/null
    '';
  };

  # rtptools (BSD-3-Clause): RTP dump/play/send/translate tools, as nixpkgs. Source: nixpkgs' tarball by hash from tarballs.nixos.org
  # (columbia.edu answers 404 for it now, measured). Check: rtpdump reads its own bark.rtp sample.
  rtptools = mkSrcPkg {
    pname = "rtptools"; version = "1.22";
    src = { url = "https://tarballs.nixos.org/sha256/2c76b2a423fb943820c91194372133a44cbdc456ebf69c51616ec50eeb068c28";
            sha256 = "2c76b2a423fb943820c91194372133a44cbdc456ebf69c51616ec50eeb068c28"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ./configure --prefix="$out"
      gmake -j''${NIX_BUILD_CORES:-4}; gmake install
      ${chk ''"$out/bin/rtpdump" -F short -f bark.rtp | head -3 | wc -l'' "^ *3$"}
    '';
  };

  # libsieve (LGPL-2.1): the RFC 3028 Sieve mail-filter language library, as nixpkgs. Source: nixpkgs' tarball by hash from
  # tarballs.nixos.org (github.com/downloads is gone). Check: its own example validates and runs its test scripts on its sample mbox.
  libsieve = mkSrcPkg {
    pname = "libsieve"; version = "2.3.1";
    src = { url = "https://tarballs.nixos.org/sha256/92c1550d97c74a3724e6fe4c9ac50593afa2e5240da539703388d505138594be";
            sha256 = "92c1550d97c74a3724e6fe4c9ac50593afa2e5240da539703388d505138594be"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ${ac { check = ""; }}
      cd src/sv_test
      for i in 1 2 3 4 5 6 7 8 9 10 11 12; do ./example script$i.sv messagea.mbox > /dev/null || { echo "FATAL: libsieve script$i.sv" >&2; exit 1; }; done
      cd "$SRC"
      ${tprog ''#include <sieve2.h>
#include <stdio.h>
int main(void){ sieve2_context_t *c; if (sieve2_alloc(&c) != SIEVE2_OK) return 1; printf("ok %s\n", sieve2_errstr(SIEVE2_OK)); sieve2_free(&c); return 0; }'' "-lsieve"}
      ${chk ''"$W/t"'' "^ok "}
    '';
  };

  # libltc (LGPL-3.0-or-later): SMPTE linear timecode encode/decode, as nixpkgs. `make check` encodes and decodes 2 s of timecode and
  # diffs against upstream's expected text (store diffutils).
  libltc = mkSrcPkg {
    pname = "libltc"; version = "1.3.2";
    src = { url = "https://github.com/x42/libltc/releases/download/v1.3.2/libltc-1.3.2.tar.gz";
            sha256 = "0a6d42cd6c21e925a27fa560dc45ac80057d275f23342102825909c02d3b1249"; };
    deps = [ world ]; nativeTools = [ diffutils ] ++ hostTools;
    build = ''
      ${ac { }}
      ${tprog ''#include <ltc.h>
#include <stdio.h>
int main(void){ LTCEncoder *e = ltc_encoder_create(48000, 25, LTC_TV_625_50, 0); SMPTETimecode t = { "+0000", 26, 11, 13, 12, 34, 56, 7 }, u;
LTCFrame f; ltc_encoder_set_timecode(e, &t); ltc_encoder_get_frame(e, &f); ltc_frame_to_time(&u, &f, 0);
printf("ok %02d:%02d:%02d:%02d %d\n", u.hours, u.mins, u.secs, u.frame, ltc_encoder_get_buffersize(e) > 0); ltc_encoder_free(e); return 0; }'' "-lltc -lm"}
      ${chk ''"$W/t"'' "^ok 12:34:56:07 1$"}
    '';
  };

  # libmspack (LGPL-2.0-only): Microsoft compression formats (CAB, CHM, KWAJ, ...), as nixpkgs. `make check` runs its cab/chm/kwaj tests.
  libmspack = mkSrcPkg {
    pname = "libmspack"; version = "0.11alpha";
    src = { url = "https://www.cabextract.org.uk/libmspack/libmspack-0.11alpha.tar.gz";
            sha256 = "70dd1fb2f0aecc36791b71a1e1840e62173079eadaa081192d1c323a0eeea21b"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ${ac { }}
      ${tprog ''#include <mspack.h>
#include <stdio.h>
int main(void){ int r; MSPACK_SYS_SELFTEST(r); struct mscab_decompressor *d = mspack_create_cab_decompressor(NULL); if (r || !d) return 1;
printf("ok %d\n", mspack_version(MSPACK_VER_LIBRARY) > 0); mspack_destroy_cab_decompressor(d); return 0; }'' "-lmspack"}
      ${chk ''"$W/t"'' "^ok 1$"}
    '';
  };

  # vo-aacenc (Apache-2.0): VisualOn's AAC encoder library (OpenCORE), as nixpkgs (no example program). Check: encode a 1 s 440 Hz tone
  # through the codec API and count ADTS frames.
  vo-aacenc = mkSrcPkg {
    pname = "vo-aacenc"; version = "0.1.3";
    src = { url = "https://downloads.sourceforge.net/opencore-amr/fdk-aac/vo-aacenc-0.1.3.tar.gz";
            sha256 = "e51a7477a359f18df7c4f82d195dab4e14e7414cbd48cf79cc195fc446850f36"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ${ac { }}
      ${tprog ''#include <vo-aacenc/voAAC.h>
#include <vo-aacenc/cmnMemory.h>
#include <math.h>
#include <stdio.h>
int main(void){ VO_AUDIO_CODECAPI api = { 0 }; VO_HANDLE h = 0; VO_MEM_OPERATOR mo = { 0 }; VO_CODEC_INIT_USERDATA ud = { 0 }; AACENC_PARAM p = { 44100, 64000, 1, 1 };
voGetAACEncAPI(&api); mo.Alloc = cmnMemAlloc; mo.Copy = cmnMemCopy; mo.Free = cmnMemFree; mo.Set = cmnMemSet; mo.Check = cmnMemCheck;
ud.memflag = VO_IMF_USERMEMOPERATOR; ud.memData = &mo; if (api.Init(&h, VO_AUDIO_CodingAAC, &ud) || api.SetParam(h, VO_PID_AAC_ENCPARAM, &p)) return 1;
short in[1024]; unsigned char out[2048]; int frames = 0, adts = 1;
for (int k = 0; k < 43; k++) { for (int i = 0; i < 1024; i++) in[i] = (short)(8000 * sin(2 * M_PI * 440 * (k * 1024 + i) / 44100.0));
  VO_CODECBUFFER ib = { (VO_PBYTE)in, sizeof in, 0 }, ob = { out, sizeof out, 0 }; VO_AUDIO_OUTPUTINFO oi = { { 0 } };
  api.SetInputData(h, &ib); if (api.GetOutputData(h, &ob, &oi) == VO_ERR_NONE && ob.Length > 7) { frames++; adts &= out[0] == 0xff && (out[1] & 0xf0) == 0xf0; } }
api.Uninit(h); printf("ok %d %d\n", frames > 30, adts); return 0; }'' "-lvo-aacenc -lm"}
      ${chk ''"$W/t"'' "^ok 1 1$"}
    '';
  };

  # buildtorrent (GPL-3.0-or-later): makes .torrent files, as nixpkgs. Check: a torrent of a file, its bencoded info dict and length.
  buildtorrent = mkSrcPkg {
    pname = "buildtorrent"; version = "0.8";
    src = { url = "https://mathr.co.uk/blog/code/buildtorrent-0.8.tar.gz";
            sha256 = "e8e27647bdb38873ac570d46c1a9689a92b01bb67f59089d1cdd08784f7052d0"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ./configure --prefix="$out"
      gmake -j''${NIX_BUILD_CORES:-4}; gmake install
      head -c 100000 "$out/bin/buildtorrent" > "$W/in.bin"
      "$out/bin/buildtorrent" -q -a http://tracker.invalid/announce "$W/in.bin" "$W/o.torrent"
      ${chk ''grep -c "8:announce30:http://tracker.invalid/announce" "$W/o.torrent"; grep -ao "6:lengthi100000e" "$W/o.torrent"'' "^6:lengthi100000e$"}
    '';
  };

  # cpputest (BSD-3-Clause): CppUTest, the C/C++ unit test framework (static libraries, as upstream), as nixpkgs. `make check` runs its
  # own test suites. Check: a test program with one passing test.
  cpputest = mkSrcPkg {
    pname = "cpputest"; version = "4.0";
    src = { url = "https://github.com/cpputest/cpputest/releases/download/v4.0/cpputest-4.0.tar.gz";
            sha256 = "21c692105db15299b5529af81a11a7ad80397f92c122bd7bf1e4a4b0e85654f7"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64"
      gmake -j''${NIX_BUILD_CORES:-4}; gmake check; gmake install
      ${tprogxx ''#include <CppUTest/CommandLineTestRunner.h>
#include <CppUTest/TestHarness.h>
TEST_GROUP(S) {}; TEST(S, add) { LONGS_EQUAL(4, 2 + 2); }
int main(int c, char **v) { return CommandLineTestRunner::RunAllTests(c, v); }'' "$out/lib/amd64/libCppUTest.a"}
      ${chk ''"$W/t"'' "^OK \\(1 tests, 1 ran"}
    '';
  };

  # miscfiles (GPL-2.0-or-later): GNU's word lists and data files (share/misc: web2, cities, countries, ...), as nixpkgs. No ELF.
  miscfiles = mkSrcPkg {
    pname = "miscfiles"; version = "1.5";
    src = { url = "https://ftpmirror.gnu.org/gnu/miscfiles/miscfiles-1.5.tar.gz";
            sha256 = "6aaaa8898b0f6dac18bcaa5492874a6cd1243ffbe7a6dd347ca8f3ec3642a500"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ./configure --prefix="$out"
      gmake -j''${NIX_BUILD_CORES:-4}; gmake install
      ${chk ''grep -cx aardvark "$out/share/web2"'' "^1$"}
    '';
  };

  # rgxg (Zlib): regular-expression generator (number ranges, CIDR blocks) and its library, as nixpkgs. Checks: upstream's man page
  # examples.
  rgxg = mkSrcPkg {
    pname = "rgxg"; version = "0.1.2";
    src = { url = "https://github.com/rgxg/rgxg/releases/download/v0.1.2/rgxg-0.1.2.tar.gz";
            sha256 = "554741f95dcc320459875c248e2cc347b99f809d9555c957d763d3d844e917c6"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ${ac { check = ""; }}
      ${chk ''"$out/bin/rgxg" range 0 31'' "^\\(3\\[01\\]\\|\\[12\\]\\?\\[0-9\\]\\)$"}
      ${chk ''"$out/bin/rgxg" cidr 192.168.0.0/24'' "^192\\\\\\.168\\\\\\.0\\\\\\.\\(25\\[0-5\\]\\|"}
    '';
  };

  # rxp (GPL-2.0-or-later): a validating XML parser (rxp) and its library, as nixpkgs. Check: validate a document against its DTD, and
  # reject an invalid one.
  rxp = mkSrcPkg {
    pname = "rxp"; version = "1.5.2";
    src = { url = "https://www.inf.ed.ac.uk/research/isddarch/admin/rxp-1.5.2.tar.gz";
            sha256 = "fa641b4a5185d0a1d9610c8245b9d5aff5972c1a28a0da94f3e38d69f6c14513"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ${ac { check = ""; }}
      printf '<?xml version="1.0"?>\n<!DOCTYPE r [<!ELEMENT r (c)><!ELEMENT c (#PCDATA)>]>\n<r><c>solnix</c></r>\n' > "$W/g.xml"
      printf '<?xml version="1.0"?>\n<!DOCTYPE r [<!ELEMENT r (c)><!ELEMENT c (#PCDATA)>]>\n<r><d/></r>\n' > "$W/b.xml"
      "$out/bin/rxp" -V -s "$W/g.xml"
      # exit status 2 = a validity error (rxp.c)
      rc=0; "$out/bin/rxp" -V -s "$W/b.xml" 2> "$W/b.err" || rc=$?
      [ $rc = 2 ] || { echo "FATAL: rxp: invalid document rc=$rc, want 2" >&2; exit 1; }
      ${chk ''"$out/bin/rxp" -V "$W/g.xml" | tail -1; cat "$W/b.err"'' "Content model for r does not allow element d"}
    '';
  };

  # bar (GPL-2.0-only): a pipe progress bar (clpbar), as nixpkgs. `make check` runs its stream tests (#!/bin/sh: illumos sh runs them).
  bar = mkSrcPkg {
    pname = "bar"; version = "1.11.1";
    src = { url = "https://downloads.sourceforge.net/project/clpbar/clpbar/bar-1.11.1/bar_1.11.1.tar.gz";
            sha256 = "fa0f5ec5c8400316c2f4debdc6cdcb80e186e668c2e4471df4fec7bfcd626503"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ./configure --prefix="$out"
      gmake -j''${NIX_BUILD_CORES:-4}; gmake check; gmake install
      head -c 50000 "$out/bin/bar" > "$W/in.bin"
      "$out/bin/bar" -if "$W/in.bin" -of "$W/out.bin" 2> /dev/null; cmp "$W/in.bin" "$W/out.bin"
      ${chk ''"$out/bin/bar" -v'' "^bar version 1\\.11\\.1$"}
    '';
  };

  # clzip (GPL-2.0-or-later): the C lzip compressor, its own configure, as nixpkgs. `make check` is its testsuite (#! /bin/sh).
  clzip = mkSrcPkg {
    pname = "clzip"; version = "1.16";
    src = { url = "https://download.savannah.gnu.org/releases/lzip/clzip/clzip-1.16.tar.gz";
            sha256 = "f339a3a5dfc2220532dc36f937a7a58e3a3278b174f2815cc5615107e55966e4"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ./configure --prefix="$out" CC=gcc
      gmake -j''${NIX_BUILD_CORES:-4}; gmake check; gmake install
      rm -f "$out/share/info/dir"
      head -c 100000 "$out/bin/clzip" > "$W/x"; "$out/bin/clzip" -k "$W/x"; "$out/bin/clzip" -dc "$W/x.lz" | cmp - "$W/x"
      ${chk ''"$out/bin/clzip" --version | head -1; od -An -c -N4 "$W/x.lz" | tr -d " "'' "^LZIP$"}
    '';
  };

  # libudfread (LGPL-2.1-or-later): UDF filesystem reading (libbluray's), a tag tree, autoreconf as nixpkgs. Check: open a missing image
  # (NULL) and print the version macro.
  libudfread = mkSrcPkg {
    pname = "libudfread"; version = "1.1.2";
    src = { url = "https://code.videolan.org/videolan/libudfread/-/archive/1.1.2/libudfread-1.1.2.tar.gz";
            sha256 = "2bf16726ac98d093156195bb049a663e07d3323e079c26912546f4e05c77bac5"; };
    deps = [ world ]; nativeTools = autoreconfTools ++ [ pkgconf ] ++ hostTools;
    build = ''
      ${autoreconf}
      ${ac { check = ""; }}
      ${tprog ''#include <udfread/udfread.h>
#include <stdio.h>
int main(void){ udfread *u = udfread_init(); int r = udfread_open(u, "/nonexistent.iso"); printf("ok %d %d\n", u != NULL, r < 0); udfread_close(u); return 0; }'' "-ludfread"}
      ${chk ''"$W/t"'' "^ok 1 1$"}
    '';
  };

  # mkrand (MIT): a random number generator from a cellular automaton, as nixpkgs (its `make check`).
  mkrand = mkSrcPkg {
    pname = "mkrand"; version = "0.1.0";
    src = { url = "https://github.com/mknight-tag/MKRAND/releases/download/v0.1.0/mkrand-0.1.0.tar.gz";
            sha256 = "da251c112e07fd5c92b8b4c981593ec217d3b23f072f3ca60166b022c5f63cc7"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ./configure --prefix="$out"
      gmake -j''${NIX_BUILD_CORES:-4}; gmake check; gmake install
      ${chk ''"$out/bin/mkrand" -h 2>&1'' "[Uu]sage|mkrand"}
    '';
  };

  # vbindiff (GPL-2.0-or-later): a visual binary diff/hex viewer (ncurses), as nixpkgs. Check: its --version (the UI needs a tty).
  vbindiff = mkSrcPkg {
    pname = "vbindiff"; version = "3.0_beta5";
    src = { url = "https://www.cjmweb.net/vbindiff/vbindiff-3.0_beta5.tar.gz";
            sha256 = "f04da97de993caf8b068dcb57f9de5a4e7e9641dc6c47f79b60b8138259133b8"; };
    deps = [ world base.ncurses ]; nativeTools = hostTools;
    build = ''
      ./configure --prefix="$out"
      gmake -j''${NIX_BUILD_CORES:-4}; gmake install
      ${chk ''"$out/bin/vbindiff" --version'' "VBinDiff 3\\.0_beta5"}
    '';
  };

  # vttest (MIT): the VT100/VT220/xterm terminal test program, as nixpkgs. Check: its -V (the tests need a terminal).
  vttest = mkSrcPkg {
    pname = "vttest"; version = "20251205";
    src = { url = "https://invisible-mirror.net/archives/vttest/vttest-20251205.tgz";
            sha256 = "cd6886f9aefe6a3f6c566fa61271a55710901a71849c630bf5376aa984bf77cc"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ./configure --prefix="$out"
      gmake -j''${NIX_BUILD_CORES:-4}; gmake install
      ${chk ''"$out/bin/vttest" -V'' "VT100 test program.*20251205|2\\.7 \\(20251205\\)"}
    '';
  };

  # csv2latex (GPL-2.0-only): CSV to a LaTeX table, its own Makefile, as nixpkgs (make PREFIX=$out install); its own `make test`.
  csv2latex = mkSrcPkg {
    pname = "csv2latex"; version = "0.23.1";
    src = { url = "http://brouits.free.fr/csv2latex/csv2latex-0.23.1.tar.gz";
            sha256 = "935bd0cab54999f689ee355aa16d9d90f0fb18ef04a03a896399bc3b653f918c"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      gmake -j''${NIX_BUILD_CORES:-4}
      gmake test | tee "$W/test.log" >&2; ! grep -q KO "$W/test.log" || { echo "FATAL: csv2latex test" >&2; exit 1; }
      mkdir -p "$out/bin"; gmake PREFIX="$out" install
      ${chk ''printf "a,b\n1,2\n" | "$out/bin/csv2latex"'' "^1 *& *2"}
    '';
  };

  # dpic (BSD-2-Clause): a pic(1) processor (LaTeX/SVG/PS output), as nixpkgs (DESTDIR=$out, the configure prefix unused). Check: an SVG
  # of a box.
  dpic = mkSrcPkg {
    pname = "dpic"; version = "2025.08.01";
    src = { url = "https://ece.uwaterloo.ca/~aplevich/dpic/dpic-2025.08.01.tar.gz";
            sha256 = "0f38f5c1e91518826cb2c6e95624b390d1808efadc0402f83911512f0ce726c3"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ./configure --prefix="$out"
      gmake -j''${NIX_BUILD_CORES:-4} DESTDIR="$out"; gmake install DESTDIR="$out"
      printf '.PS\nbox "solnix"\n.PE\n' > "$W/t.pic"
      ${chk ''"$out/bin/dpic" -v "$W/t.pic"'' "<svg"}
    '';
  };

  # lzop (GPL-2.0-or-later): the lzop file compressor, on the served lzo, as nixpkgs. Check: a round trip and lzop -t.
  lzop = mkSrcPkg {
    pname = "lzop"; version = "1.04";
    src = { url = "https://www.lzop.org/download/lzop-1.04.tar.gz";
            sha256 = "7e72b62a8a60aff5200a047eea0773a8fb205caf7acbe1774d95147f305a2f41"; };
    deps = [ world lzo ]; nativeTools = hostTools;
    build = ''
      ./configure --prefix="$out"
      gmake -j''${NIX_BUILD_CORES:-4}; gmake check; gmake install
      head -c 200000 "$out/bin/lzop" > "$W/x"; "$out/bin/lzop" "$W/x"; "$out/bin/lzop" -t "$W/x.lzo"; "$out/bin/lzop" -dc "$W/x.lzo" | cmp - "$W/x"
      ${chk ''"$out/bin/lzop" --version'' "^lzop 1\\.04"}
    '';
  };

  # sic (MIT): suckless' simple IRC client, its own Makefile, as nixpkgs (CC, PREFIX). illumos: socket(3SOCKET)/getaddrinfo in libsocket
  # and libnsl. Check: -v.
  sic = mkSrcPkg {
    pname = "sic"; version = "1.3";
    src = { url = "https://dl.suckless.org/tools/sic-1.3.tar.gz";
            sha256 = "30478fab3ebc75f2eb5d08cbb5b2fedcaf489116e75a2dd7197e3e9c733d65d2"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      gmake -j''${NIX_BUILD_CORES:-4} CC=gcc LDFLAGS="-lsocket -lnsl"; gmake install PREFIX="$out"
      ${chk ''"$out/bin/sic" -v 2>&1'' "sic-1\\.3"}
    '';
  };

  # tivodecode (BSD-3-Clause): decodes TiVo files to MPEG (tivodecode, tdcat), as nixpkgs. Check: its --version.
  tivodecode = mkSrcPkg {
    pname = "tivodecode"; version = "0.2pre4";
    src = { url = "https://downloads.sourceforge.net/tivodecode/tivodecode/0.2pre4/tivodecode-0.2pre4.tar.gz";
            sha256 = "788839cc4ad66f5b20792e166514411705e8564f9f050584c54c3f1f452e9cdf"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ./configure --prefix="$out"
      gmake -j''${NIX_BUILD_CORES:-4}; gmake install
      ${chk ''"$out/bin/tivodecode" --version 2>&1'' "tivodecode 0\\.2pre4|0\\.2pre4"}
    '';
  };

  # wbox (BSD-3-Clause): an HTTP benchmarking/testing tool, its own Makefile, as nixpkgs (install wbox to bin). Source: nixpkgs' tarball
  # by hash from tarballs.nixos.org (hping.org does not answer). illumos: libsocket/libnsl. Check: its usage.
  wbox = mkSrcPkg {
    pname = "wbox"; version = "5";
    src = { url = "https://tarballs.nixos.org/sha256/1589d85e83c8ee78383a491d89e768ab9aab9f433c5f5e035cfb5eed17efaa19";
            sha256 = "1589d85e83c8ee78383a491d89e768ab9aab9f433c5f5e035cfb5eed17efaa19"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ${anchor "Makefile" 1 "	$(CC) -o $(PRGNAME) $(CCOPT) $(DEBUG) $(OBJ)"}
      sed -i 's/^	$(CC) -o $(PRGNAME) $(CCOPT) $(DEBUG) $(OBJ)$/& -lsocket -lnsl/' Makefile
      gmake -j''${NIX_BUILD_CORES:-4} CC=gcc
      mkdir -p "$out/bin"; install -m 0755 wbox "$out/bin/wbox"
      ${chk ''"$out/bin/wbox" 2>&1'' "[Uu]sage|wbox"}
    '';
  };

  # dotconf (LGPL-2.1-or-later): a configuration file parser library, autoreconf as nixpkgs. Check: parse a file with a string option.
  dotconf = mkSrcPkg {
    pname = "dotconf"; version = "1.4.1";
    src = { url = "https://github.com/williamh/dotconf/archive/v1.4.1.tar.gz";
            sha256 = "5922c46cacf99b2ecc4853d28a2bda4a489292e73276e604bd9cba29dfca892d"; };
    deps = [ world ]; nativeTools = autoreconfTools ++ [ pkgconf ] ++ hostTools;
    build = ''
      ${autoreconf}
      ${ac { check = ""; }}
      ${tprog ''#include <dotconf.h>
#include <stdio.h>
static char got[64];
static DOTCONF_CB(cb_name) { snprintf(got, sizeof got, "%s", cmd->data.str); return NULL; }
static const configoption_t opts[] = { { "Name", ARG_STR, cb_name, NULL, CTX_ALL }, LAST_OPTION };
int main(int c, char **v){ configfile_t *f = dotconf_create(v[1], opts, NULL, CASE_INSENSITIVE); if (!f || !dotconf_command_loop(f)) return 1;
dotconf_cleanup(f); printf("ok %s\n", got); return 0; }'' "-ldotconf"}
      printf '# t\nname solnix\n' > "$W/t.conf"
      ${chk ''"$W/t" "$W/t.conf"'' "^ok solnix$"}
    '';
  };

  # ccd2iso (GPL-2.0-or-later): CloneCD image to ISO, as nixpkgs (its include.patch: <string.h>). Check: its usage.
  ccd2iso = mkSrcPkg {
    pname = "ccd2iso"; version = "0.3";
    src = { url = "https://downloads.sourceforge.net/ccd2iso/ccd2iso-0.3.tar.gz";
            sha256 = "f874b8fe26112db2cdb016d54a9f69cf286387fbd0c8a55882225f78e20700fc"; };
    deps = [ world ]; nativeTools = [ gnupatch ] ++ hostTools;
    build = ''
      patch -p1 < ${npPatch "cc/ccd2iso/include.patch" "54776762fa4b90ac15b746765f8cd90cd6fc17735b836547de9f3766b0d18cee"}
      ./configure --prefix="$out"
      gmake -j''${NIX_BUILD_CORES:-4}; gmake install
      ${chk ''"$out/bin/ccd2iso" 2>&1'' "[Uu]sage|ccd2iso"}
    '';
  };

  # diction (GPL-3.0-or-later): GNU diction and style, as nixpkgs. `make check` runs its tests.
  diction = mkSrcPkg {
    pname = "diction"; version = "1.14";
    src = { url = "https://www.moria.de/~michael/comp/diction/diction-1.14.tar.gz";
            sha256 = "da012fb3a5cba6566d238cda869b0cecdbef0452780c4d368100a840472fd7fc"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ./configure --prefix="$out"
      gmake -j''${NIX_BUILD_CORES:-4}; gmake check; gmake install
      ${chk ''echo "This is in order to test it." | "$out/bin/diction"'' "in order to"}
    '';
  };

  # hexd (MIT): a colourful hexdump, its own Makefile, as nixpkgs (PREFIX=). Check: a known 4-byte dump.
  hexd = mkSrcPkg {
    pname = "hexd"; version = "1.1.0";
    src = { url = "https://github.com/FireyFly/hexd/archive/v1.1.0.tar.gz";
            sha256 = "de0db7205c8eb0f170263aca27f5d48963855345bc79ba4842edd21a938d0326"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      gmake -j''${NIX_BUILD_CORES:-4} CC=gcc; gmake install PREFIX="$out"
      ${chk ''printf "ABCD" | "$out/bin/hexd" -p'' "41 42 43 44"}
    '';
  };

  # pdfcrack (GPL-2.0-or-later): PDF password recovery, its own Makefile, as nixpkgs (install pdfcrack to bin). Check: its usage.
  pdfcrack = mkSrcPkg {
    pname = "pdfcrack"; version = "0.21";
    src = { url = "https://downloads.sourceforge.net/pdfcrack/pdfcrack/pdfcrack-0.21.tar.gz";
            sha256 = "26f00d4afcb70b5839047bc6f62e4253073ac437bdb526f01e8c04b220e97762"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      gmake -j''${NIX_BUILD_CORES:-4} CC=gcc
      mkdir -p "$out/bin"; install -m 0755 pdfcrack "$out/bin/pdfcrack"
      ${chk ''"$out/bin/pdfcrack" --version 2>&1'' "0\\.21|[Uu]sage"}
    '';
  };

  # pixd (MIT): visualise binary data as coloured pixels in the terminal, its own Makefile, as nixpkgs (PREFIX=). The man page target
  # runs gzip -k (served gzip on PATH via the stdenv tools). Check: render 16 bytes.
  pixd = mkSrcPkg {
    pname = "pixd"; version = "1.0.0";
    src = { url = "https://github.com/FireyFly/pixd/archive/v1.0.0.tar.gz";
            sha256 = "011440a8d191e40a572910b0ce7a094e9b4ee75cf972abc6d30674348edf4158"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      gmake -j''${NIX_BUILD_CORES:-4} CC=gcc; gmake install PREFIX="$out"
      ${chk ''head -c 16 /dev/zero | "$out/bin/pixd" | wc -l'' "^ *[1-9]"}
    '';
  };

  # xe (CC0-1.0): a simple xargs and apply replacement, its own Makefile, as nixpkgs (PREFIX=). Check: run echo per argument.
  xe = mkSrcPkg {
    pname = "xe"; version = "1.0";
    src = { url = "https://github.com/leahneukirchen/xe/archive/refs/tags/v1.0.tar.gz";
            sha256 = "1e2484c6295f4eb1c1b789d8edab4b728cf9ea7e4c40ef52a56073f9a273ce30"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      gmake -j''${NIX_BUILD_CORES:-4} CC=gcc; gmake install PREFIX="$out"
      ${chk ''printf "a\nb\n" | "$out/bin/xe" echo x | tr "\n" " "'' "^x a x b $"}
    '';
  };

  # stress (GPL-2.0-or-later): a workload generator (CPU, memory, I/O, disk), autoreconf as nixpkgs; `make check` runs its two tests.
  stress = mkSrcPkg {
    pname = "stress"; version = "1.0.7";
    src = { url = "https://github.com/resurrecting-open-source-projects/stress/archive/refs/tags/1.0.7.tar.gz";
            sha256 = "cdaa56671506133e2ed8e1e318d793c2a21c4a00adc53f31ffdef1ece8ace0b1"; };
    deps = [ world ]; nativeTools = autoreconfTools ++ hostTools;
    build = ''
      ${autoreconf}
      ./configure --prefix="$out"
      gmake -j''${NIX_BUILD_CORES:-4}; gmake check; gmake install
      ${chk ''"$out/bin/stress" --cpu 1 --timeout 1 2>&1'' "successful run completed"}
    '';
  };

  # snore (MIT): sleep with feedback, its own Makefile, as nixpkgs (PREFIX=). Check: a 1 s snore exits 0.
  snore = mkSrcPkg {
    pname = "snore"; version = "0.3.1";
    src = { url = "https://github.com/bitsmanent/snore/archive/refs/tags/0.3.1.tar.gz";
            sha256 = "a9fbe77e2db3123dbdcc27694944ee73cbbc53cb0652401db03b01087dc69892"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      gmake -j''${NIX_BUILD_CORES:-4} CC=gcc; gmake install PREFIX="$out"
      ${chk ''"$out/bin/snore" -v 2>&1'' "0\\.3\\.1"}
      "$out/bin/snore" 1 > /dev/null
    '';
  };

  # parson (MIT): a lightweight JSON library, meson as nixpkgs. Check: parse and read back a string.
  parson = mkSrcPkg {
    pname = "parson"; version = "1.5.3";
    src = { url = "https://github.com/kgabis/parson/archive/ba29f4eda9ea7703a9f6a9cf2b0532a2605723c3.tar.gz";
            sha256 = "d311cd3d051965485bff1c89a3980df7ad0ee3f9c0f33c18964d8c1cc32ef2cf"; };
    deps = [ world ]; nativeTools = mesonTools;
    build = ''
      ${mesonBuild ""}
      ${tprog ''#include <parson.h>
#include <stdio.h>
int main(void){ JSON_Value *v = json_parse_string("{\"os\":\"solnix\",\"n\":[1,2]}"); if (!v) return 1;
printf("ok %s %d\n", json_object_get_string(json_value_get_object(v), "os"), (int)json_array_get_count(json_object_get_array(json_value_get_object(v), "n")));
json_value_free(v); return 0; }'' "-lparson"}
      ${chk ''"$W/t"'' "^ok solnix 2$"}
    '';
  };

  # bstring (BSD-3-Clause): the Better String Library, meson as nixpkgs (its tests need check; nixpkgs builds them off). Check: concat.
  bstring = mkSrcPkg {
    pname = "bstring"; version = "1.1.1";
    src = { url = "https://github.com/msteinert/bstring/archive/refs/tags/v1.1.1.tar.gz";
            sha256 = "79ae1456c407e7cd9f1b9cb0c094b5414e99092d94e6ee30bcad35462c224eaf"; };
    deps = [ world ]; nativeTools = mesonTools;
    build = ''
      ${mesonBuild ""}
      ${tprog ''#include <bstrlib.h>
#include <stdio.h>
int main(void){ bstring a = bfromcstr("sol"), b = bfromcstr("nix"); bconcat(a, b); printf("ok %s %d\n", bdata(a), blength(a)); bdestroy(a); bdestroy(b); return 0; }'' "-lbstring"}
      ${chk ''"$W/t"'' "^ok solnix 6$"}
    '';
  };

  # canfigger (MIT): a simple config file parser, meson as nixpkgs (its tests on). Check: parse its own example config.
  canfigger = mkSrcPkg {
    pname = "canfigger"; version = "0.3.2";
    src = { url = "https://github.com/andy5995/canfigger/archive/v0.3.2.tar.gz";
            sha256 = "79e93b91c7d3b99b0b48580d4bee052bcb196ea1b03ec3d30048b2a9f446a5dc"; };
    deps = [ world ]; nativeTools = mesonTools;
    build = ''
      ${mesonBuild "-Dbuild_examples=false"}
      ${tprog ''#include <canfigger/canfigger.h>
#include <stdio.h>
int main(int c, char **v){ struct Canfigger *l = canfigger_parse_file(v[1], ','); int n = 0;
while (l) { if (n++ == 0) printf("ok %s=%s", l->key, l->value); canfigger_free_current_key_node_advance(&l); } printf(" %d\n", n > 2); return 0; }'' "-lcanfigger"}
      ${chk ''"$W/t" example-01.conf'' "^ok greetings=Hello 1$"}
    '';
  };

  # directx-headers (MIT): the DirectX 12 headers mesa's d3d12 uses, meson as nixpkgs (-Dbuild-test=false). Check: the header compiles.
  directx-headers = mkSrcPkg {
    pname = "directx-headers"; version = "1.619.1";
    src = { url = "https://github.com/microsoft/DirectX-Headers/archive/v1.619.1.tar.gz";
            sha256 = "6193774904c940eebb9b0c51b816b93dd776cfeb25a951f0f4a58f22387e5008"; };
    deps = [ world ]; nativeTools = mesonTools;
    build = ''
      ${mesonBuild "-Dbuild-test=false"}
      ls "$out/include/directx/d3d12.h" "$out/include/dxguids/dxguids.h" > /dev/null
      ${tprogxx ''#include <wsl/winadapter.h>
#include <directx/d3d12.h>
#include <cstdio>
int main(){ std::printf("ok %d\n", (int)D3D12_COMMAND_LIST_TYPE_COMPUTE); return 0; }'' "-I$out/include/wsl/stubs -I$out/include"}
      ${chk ''"$W/t"'' "^ok 2$"}
    '';
  };

  # pystring (BSD-3-Clause): Python string methods for C++ std::string, meson as nixpkgs (doCheck). Check: upper and split.
  pystring = mkSrcPkg {
    pname = "pystring"; version = "1.1.4-unstable-2025-10-07";
    src = { url = "https://github.com/imageworks/pystring/archive/a09708a4870db7862e1a1aa42658c8e6e36547e7.tar.gz";
            sha256 = "0f86e5c782b5c4fc643fdb351eed4206b7026149bab29467cc888ec752a81abe"; };
    deps = [ world ]; nativeTools = mesonTools;
    build = ''
      ${mesonBuild ""}
      ${tprogxx ''#include <pystring/pystring.h>
#include <cstdio>
int main(){ std::vector<std::string> p; pystring::split("a,b,c", p, ","); std::printf("ok %s %d\n", pystring::upper("solnix").c_str(), (int)p.size()); return 0; }'' "-lpystring"}
      ${chk ''"$W/t"'' "^ok SOLNIX 3$"}
    '';
  };

  # lyra (BSL-1.0): a header-only C++ command line parser, meson as nixpkgs (its /usr -> $out edit, headers copied). Check: parse a flag.
  lyra = mkSrcPkg {
    pname = "lyra"; version = "1.8.0";
    src = { url = "https://github.com/bfgroup/lyra/archive/1.8.0.tar.gz";
            sha256 = "cd657146167cd2f80c27e4414ecd1a6639537f5a6d527e608bcd0c633d8beca9"; };
    deps = [ world ]; nativeTools = mesonTools;
    build = ''
      sed -i "s#/usr#$out#g" meson.build
      ${mesonBuild ""}
      mkdir -p "$out/include"; cp -R include/* "$out/include"
      ${tprogxx ''#include <lyra/lyra.hpp>
#include <cstdio>
int main(int c, char **v){ int n = 0; auto cli = lyra::cli() | lyra::opt(n, "n")["-n"]; auto r = cli.parse({ c, v }); std::printf("ok %d %d\n", (bool)r, n); return 0; }'' "-std=c++17"}
      ${chk ''"$W/t" -n 42'' "^ok 1 42$"}
    '';
  };

  # frozen (Apache-2.0): a minimal JSON parser/emitter, with nixpkgs' own meson.build (upstream has none). Check: json_scanf a field.
  frozen = mkSrcPkg {
    pname = "frozen"; version = "1.7";
    src = { url = "https://github.com/cesanta/frozen/archive/refs/tags/1.7.tar.gz";
            sha256 = "0d6b1a9778fde9793c0d7aa22ca872cfc549bc69d78ef93d6df21102a08e5e3c"; };
    deps = [ world ]; nativeTools = mesonTools;
    build = ''
      rm BUILD; cp ${npPatch "fr/frozen/meson.build" "8e45e77b788fb5a708c3b549d535803bca67f50e69d497b08714fb64ed0f8b77"} meson.build
      ${mesonBuild ""}
      ${tprog ''#include <frozen.h>
#include <stdio.h>
#include <string.h>
int main(void){ const char *j = "{\"a\": 123, \"s\": \"solnix\"}"; int a = 0; char *s = NULL; json_scanf(j, strlen(j), "{a: %d, s: %Q}", &a, &s); printf("ok %d %s\n", a, s); return 0; }'' "-lfrozen"}
      ${chk ''"$W/t"'' "^ok 123 solnix$"}
    '';
  };

  # simde (MIT): portable SIMD intrinsics (header-only), meson as nixpkgs (its test suite is not built: nixpkgs' default -Dtests=true
  # compiles thousands of files; here off, the headers are the package). Check: an SSE2 add through simde.
  simde = mkSrcPkg {
    pname = "simde"; version = "0.8.2";
    src = { url = "https://github.com/simd-everywhere/simde/archive/v0.8.2.tar.gz";
            sha256 = "ed2a3268658f2f2a9b5367628a85ccd4cf9516460ed8604eed369653d49b25fb"; };
    deps = [ world ]; nativeTools = mesonTools;
    build = ''
      ${mesonBuild "-Dtests=false"}
      ${tprog ''#include <simde/x86/sse2.h>
#include <stdio.h>
int main(void){ simde__m128i a = simde_mm_set1_epi32(40), b = simde_mm_set1_epi32(2); int o[4]; simde_mm_storeu_si128((simde__m128i *)o, simde_mm_add_epi32(a, b)); printf("ok %d %d\n", o[0], o[3]); return 0; }'' ""}
      ${chk ''"$W/t"'' "^ok 42 42$"}
    '';
  };

  # genromfs (GPL-2.0-or-later): makes ROM filesystem (romfs) images, its own Makefile, as nixpkgs (prefix, CC). Its LDFLAGS -s is
  # dropped (mk-src-pkg splits the debug info). Check: an image of a small tree starts with the romfs magic.
  genromfs = mkSrcPkg {
    pname = "genromfs"; version = "0.5.2";
    src = { url = "https://downloads.sourceforge.net/romfs/genromfs/0.5.2/genromfs-0.5.2.tar.gz";
            sha256 = "30f37fc734572c1dbaa2504585bc23ba6b8fd7df767ae7155995b2ca0ebed960"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      gmake -j''${NIX_BUILD_CORES:-4} CC=gcc LDFLAGS= prefix="$out"; gmake install prefix="$out" PREFIX= CC=gcc
      mkdir -p "$W/r/d"; echo solnix > "$W/r/d/f"
      "$out/bin/genromfs" -f "$W/r.img" -d "$W/r" -V solnix
      ${chk ''head -c 8 "$W/r.img"'' "^-rom1fs-$"}
    '';
  };

  # libwhich (MIT): print the path of the shared library dlopen would load (Julia's), its own Makefile, as nixpkgs (install libwhich to
  # bin). Its Makefile adds -ldl (libc on illumos has dlopen; libdl is a filter, harmless). Check: it finds libc.
  libwhich = mkSrcPkg {
    pname = "libwhich"; version = "1.3.0";
    src = { url = "https://github.com/vtjnash/libwhich/archive/v1.3.0.tar.gz";
            sha256 = "853e843824ee8b20b0192d45bf9837c860ef41cce4a10bd14c59860753e5fa0b"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      gmake -j''${NIX_BUILD_CORES:-4} CC=gcc
      mkdir -p "$out/bin"; install -m 0755 libwhich "$out/bin/libwhich"
      ${chk ''"$out/bin/libwhich" -p libc.so.1'' "libc\\.so\\.1"}
    '';
  };

  # nbtscan (GPL-2.0-or-later): a NetBIOS name scanner, autoreconf as nixpkgs. Check: its usage text.
  nbtscan = mkSrcPkg {
    pname = "nbtscan"; version = "1.7.2-unstable-2022-10-29";
    src = { url = "https://github.com/resurrecting-open-source-projects/nbtscan/archive/e09e22a2a322ba74bb0b3cd596933fe2e31f4b2b.tar.gz";
            sha256 = "b499b61a84a879c393632dcd5da42d513a13793c7e7392c9cee9aeb9aa93ceb4"; };
    deps = [ world ]; nativeTools = autoreconfTools ++ hostTools;
    build = ''
      ${autoreconf}
      ./configure --prefix="$out"
      gmake -j''${NIX_BUILD_CORES:-4}; gmake install
      ${chk ''"$out/bin/nbtscan" 2>&1'' "NBTscan version 1\\.7\\.2"}
    '';
  };

  # sdate (GPL-2.0-or-later): "September 1993" dates (an LD_PRELOAD time library and the sdate wrapper), autoreconf as nixpkgs. Check:
  # the library is built and the wrapper names it.
  sdate = mkSrcPkg {
    pname = "sdate"; version = "0.7";
    src = { url = "https://github.com/df7cb/sdate/archive/0.7.tar.gz";
            sha256 = "7e1b3644d7b019ccb7ab3997e1f88e1e7a8946685cb16eafce88a97cd1d2d6d1"; };
    deps = [ world ]; nativeTools = autoreconfTools ++ hostTools;
    build = ''
      ${autoreconf}
      ${ac { check = ""; }}
      ls "$out"/lib/amd64/libsdate.so* > /dev/null
      ${chk ''grep -c libsdate "$out/bin/sdate"'' "^[1-9]"}
    '';
  };

  # micro-httpd (BSD-2-Clause): acme.com's tiny HTTP server, its own Makefile, as nixpkgs (BINDIR, MANDIR); illumos: its SYSVLIBS
  # (-lnsl -lsocket), as the Makefile documents. Check: serve a file over a pipe.
  micro-httpd = mkSrcPkg {
    pname = "micro-httpd"; version = "20140814";
    src = { url = "https://tarballs.nixos.org/sha256/3313f19d80897caa0fa9cd5cc7481736302bb6f61ac45238d240871117119556";
            sha256 = "3313f19d80897caa0fa9cd5cc7481736302bb6f61ac45238d240871117119556"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      mkdir -p "$out/bin" "$out/share/man/man8"
      gmake CC=gcc SYSVLIBS="-lnsl -lsocket" LDFLAGS="-lnsl -lsocket"; gmake install BINDIR="$out/bin" MANDIR="$out/share/man/man8"
      mkdir "$W/www"; echo solnix-httpd > "$W/www/i.txt"
      ${chk ''printf "GET /i.txt HTTP/1.0\r\n\r\n" | "$out/bin/micro_httpd" "$W/www"'' "^solnix-httpd"}
    '';
  };

  # nrg2iso (GPL-2.0-or-later): Nero .nrg to ISO, its own Makefile, as nixpkgs (its c-compiler patch: cc). Check: its usage.
  nrg2iso = mkSrcPkg {
    pname = "nrg2iso"; version = "0.4.1";
    src = { url = "http://gregory.kokanosky.free.fr/v4/linux/nrg2iso-0.4.1.tar.gz";
            sha256 = "3be36a416758fc1910473b49a8dadf2a2aa3d51f1976197336bc174bc1e306e5"; };
    deps = [ world ]; nativeTools = [ gnupatch ] ++ hostTools;
    build = ''
      patch -p1 < ${npPatch "nr/nrg2iso/c-compiler.patch" "ab9652d6ff7f384586da85771f6c50f3b48510ce764eb505ee2f5d2c7b8ff65f"}
      gmake
      mkdir -p "$out/bin"; cp nrg2iso "$out/bin/nrg2iso"
      ${chk ''"$out/bin/nrg2iso" --version 2>&1'' "0\\.4|nrg2iso"}
    '';
  };

  # rankwidth (GPL-2.0-or-later): rank-width and rank-decomposition of graphs (librw), as nixpkgs (no executable: it needs igraph;
  # doCheck). Check: the rank-width of a 4-cycle.
  rankwidth = mkSrcPkg {
    pname = "rankwidth"; version = "0.10";
    src = { url = "https://downloads.sourceforge.net/rankwidth/rw-0.10.tar.gz";
            sha256 = "89a8ed364893ac1b70ab70a152e3e7db3cf348bb69098aa6dbb969639df927db"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ${ac { flags = "--enable-executable=no"; }}
      ls "$out"/lib/amd64/librw.so* "$out/include/rw.h" > /dev/null
    '';
  };
}
