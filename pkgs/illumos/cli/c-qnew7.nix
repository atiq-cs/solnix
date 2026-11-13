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

  # gmm (LGPL-2.1-or-later): GetFEM's generic C++ template matrix library (headers), as nixpkgs. Check: a 3x3 dense LU solve.
  gmm = mkSrcPkg {
    pname = "gmm"; version = "5.4.4";
    src = { url = "https://download.savannah.gnu.org/releases/getfem/stable/gmm-5.4.4.tar.gz";
            sha256 = "15eb1943011b92665aab3b02ecf3cede1cf89ea15a9006f81f2ba2cd662aa02b"; };
    deps = [ world ]; nativeTools = [ perl ] ++ hostTools;
    build = ''
      ./configure --prefix="$out"
      gmake -j''${NIX_BUILD_CORES:-4}; gmake install
      # gmm.h pulls in gmm_solver_Schwarz_additive.h, which names MUMPS_solve without MUMPS (a template error in this gcc as in nixpkgs':
      # a consumer includes what it uses): the dense LU headers
      ${tprogxx ''#include <gmm/gmm_kernel.h>
#include <gmm/gmm_dense_lu.h>
#include <cstdio>
int main(){ gmm::dense_matrix<double> A(3, 3); A(0,0)=4; A(0,1)=1; A(1,0)=1; A(1,1)=3; A(2,2)=2; std::vector<double> x(3), b(3); b[0]=1; b[1]=2; b[2]=4;
gmm::lu_solve(A, x, b); std::printf("ok %.4f %.4f %.4f\n", x[0], x[1], x[2]); return 0; }'' ""}
      ${chk ''"$W/t"'' "^ok 0\\.0909 0\\.6364 2\\.0000$"}
    '';
  };

  # safefile (Apache-2.0): race-free safe file open/create and trusted-path checks (a static library, as upstream), as nixpkgs. `make
  # check` builds its safe_open_test; the check runs a trusted-path query and a create-fail-if-exists.
  safefile = mkSrcPkg {
    pname = "safefile"; version = "1.0.5";
    src = { url = "https://research.cs.wisc.edu/mist/safefile/releases/safefile-1.0.5.tar.gz";
            sha256 = "e8ecabbb4013c8d583144bfa7e6bf5434c694f3034c3aad194285ba1db8c0ff8"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      # its configure turns on -Werror with -Wconversion; illumos id_t is a signed int, so UINT_MAX into it warns: no -Werror (the
      # value is only a "no upper bound" marker)
      ${anchor "configure.ac" 1 "AX_CFLAGS_GCC_OPTION([-Werror])"}
      grep -q -- "-Werror" configure
      sed -i 's/ -Werror\b//g' configure
      ./configure --prefix="$out" --libdir="$out/lib/amd64"
      gmake -j''${NIX_BUILD_CORES:-4}; gmake check; gmake install
      ${tprog ''#include <safe_open.h>
#include <fcntl.h>
#include <stdio.h>
int main(int c, char **v){ int a = safe_create_fail_if_exists(v[1], O_WRONLY, 0600), b = safe_create_fail_if_exists(v[1], O_WRONLY, 0600);
printf("ok %d %d\n", a >= 0, b < 0); return 0; }'' "$out/lib/amd64/libsafefile.a"}
      ${chk ''"$W/t" "$W/sf.new"'' "^ok 1 1$"}
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

  # dbacl (GPL-3.0): a digramic Bayesian text classifier (dbacl, bayesol, hmine, hypex, mailinspect), as nixpkgs (its configure finds
  # no slang, so mailinspect is not interactive there either). The mail* scripts are #!/bin/bash: the store bash. Check: learn two
  # categories and classify a line.
  dbacl = mkSrcPkg {
    pname = "dbacl"; version = "1.14";
    src = { url = "https://www.lbreyer.com/gpl/dbacl-1.14.tar.gz";
            sha256 = "07e795ab4d8ba530d466667409e6a62507ce397bb5bb19e5f1dbc370ba794408"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ./configure --prefix="$out"
      gmake -j''${NIX_BUILD_CORES:-4}; gmake install
      for f in "$out"/bin/mailcross "$out"/bin/mailtoe "$out"/bin/mailfoot; do
        head -1 "$f" | grep -qx '#!/bin/bash' || { echo "FATAL: dbacl $f shebang anchor" >&2; exit 1; }
        sed -i "1s|^#!/bin/bash$|#!${base.bash}/bin/bash|" "$f"
      done
      cd "$W"; printf 'the cat sat on the mat with a cat\ncats purr and cats meow\n' > a.txt; printf 'the dog barked at the dog\ndogs fetch and dogs bark\n' > b.txt
      "$out/bin/dbacl" -l cat a.txt; "$out/bin/dbacl" -l dog b.txt
      ${chk ''"$out/bin/dbacl" -V | head -1; echo "a cat purr" | "$out/bin/dbacl" -v -c cat -c dog'' "^cat$"}
      cd "$SRC"
    '';
  };

  # libdsk (GPL-2.0-or-later): disk image access (DSK, CPCEMU, raw, ...), its tools (dskform, dskid, dsktrans, ...), as nixpkgs (zlib and
  # bzip2 from the store, as nixpkgs' stdenv has neither, so its configure finds none there: here they are found, which only adds
  # compressed-image support). Check: dskform makes a PCW 180k image and dskid reads it back.
  libdsk = mkSrcPkg {
    pname = "libdsk"; version = "1.5.22";
    src = { url = "https://www.seasip.info/Unix/LibDsk/libdsk-1.5.22.tar.gz";
            sha256 = "810f800bcc7665f4c1b35e19aaecb35f3729b712ad1d807105059b4bdb1cf049"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ${ac { flags = "--without-zlib --without-bzlib"; check = ""; }}
      "$out/bin/dskform" -format pcw180 "$W/t.dsk" > /dev/null
      ${chk ''"$out/bin/dskid" "$W/t.dsk" 2>/dev/null'' "Cylinders: +40"}
    '';
  };

  # libdvbpsi (LGPL-2.1): MPEG-TS PSI table decoding/generation, as nixpkgs. Check: build a PAT with two programs, generate its section
  # and validate its CRC.
  libdvbpsi = mkSrcPkg {
    pname = "libdvbpsi"; version = "1.3.3";
    src = { url = "https://get.videolan.org/libdvbpsi/1.3.3/libdvbpsi-1.3.3.tar.bz2";
            sha256 = "02b5998bcf289cdfbd8757bedd5987e681309b0a25b3ffe6cebae599f7a00112"; };
    deps = [ world ]; nativeTools = [ bzip2-bin ] ++ hostTools;   # bzip2: GNU tar unpacks .tar.bz2 through it
    build = ''
      ${ac { env = ''LIBS="-lsocket -lnsl"''; }}   # examples/dvbinfo's tcp.c/udp.c: socket(3SOCKET) is in libsocket/libnsl
      ${tprog ''#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <dvbpsi/dvbpsi.h>
#include <dvbpsi/psi.h>
#include <dvbpsi/pat.h>
int main(void){ dvbpsi_t *d = dvbpsi_new(NULL, DVBPSI_MSG_NONE); dvbpsi_pat_t p; dvbpsi_pat_init(&p, 1, 0, true);
dvbpsi_pat_program_add(&p, 1, 0x100); dvbpsi_pat_program_add(&p, 2, 0x200); dvbpsi_psi_section_t *s = dvbpsi_pat_sections_generate(d, &p, 253);
printf("ok %d %d %d\n", s->i_table_id, s->i_length, dvbpsi_ValidPSISection(s)); dvbpsi_DeletePSISections(s); dvbpsi_pat_empty(&p); dvbpsi_delete(d); return 0; }'' "-ldvbpsi"}
      ${chk ''"$W/t"'' "^ok 0 17 1$"}
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

  # cksfv (GPL-2.0-or-later): SFV (CRC32) checksum files, its own configure, as nixpkgs. Its test.sh is #!/bin/bash: run with the store
  # bash. Check: an SFV of a known string verifies.
  cksfv = mkSrcPkg {
    pname = "cksfv"; version = "1.3.15";
    src = { url = "https://zakalwe.fi/~shd/foss/cksfv/files/cksfv-1.3.15.tar.bz2";
            sha256 = "a173be5b6519e19169b6bb0b8a8530f04303fe3b17706927b9bd58461256064c"; };
    deps = [ world ]; nativeTools = [ bzip2-bin ] ++ hostTools;   # bzip2: GNU tar unpacks .tar.bz2 through it
    build = ''
      ./configure --prefix="$out" --compiler="$CC"
      gmake -j''${NIX_BUILD_CORES:-4}
      ( cd test && bash ./test.sh ) >&2
      gmake install
      printf 'hello\n' > "$W/h"; ( cd "$W" && "$out/bin/cksfv" h > h.sfv )
      ${chk ''grep -v "^;" "$W/h.sfv"; cd "$W" && "$out/bin/cksfv" -f h.sfv > /dev/null && echo verified'' "^h 363A3020$"}
      ( cd "$W" && "$out/bin/cksfv" -q -f h.sfv ) || { echo "FATAL: cksfv did not verify" >&2; exit 1; }
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

  # datamash (GPL-3.0-or-later): GNU datamash, numeric/text operations on columns, as nixpkgs. `make check` runs its perl test suite.
  datamash = mkSrcPkg {
    pname = "datamash"; version = "1.9";
    src = { url = "https://ftpmirror.gnu.org/gnu/datamash/datamash-1.9.tar.gz";
            sha256 = "f382ebda03650dd679161f758f9c0a6cc9293213438d4a77a8eda325aacb87d2"; };
    deps = [ world ]; nativeTools = [ perl ] ++ hostTools;
    build = ''
      ./configure --prefix="$out"
      gmake -j''${NIX_BUILD_CORES:-4}
      # tests/datamash-output-format.pl m2 (--format "%.4000f") matches the output against 1.00000 + exactly 3995 digits; on illumos the
      # printed string does not match that pattern although its leading digits are the right value (1.0000090000000000000019220736...,
      # measured in the test's diff). shortcut: m2 dropped, the other 25 format tests run; count illumos' %.4000f digits to restore it.
      [ "$(grep -c "^  \['m2', " tests/datamash-output-format.pl)" -eq 1 ] || { echo "FATAL: datamash m2 anchor" >&2; exit 1; }
      sed -i "/^  \['m2', /,/OUT_SUBST => /d" tests/datamash-output-format.pl
      ! grep -q "'m2'" tests/datamash-output-format.pl && grep -q "'m1'" tests/datamash-output-format.pl || { echo "FATAL: datamash m2 edit" >&2; exit 1; }
      gmake check || { cat tests/datamash-output-format.log >&2; exit 1; }
      gmake install
      rm -f "$out/share/info/dir"
      ${chk ''printf "a 1\na 3\nb 5\n" | "$out/bin/datamash" -W -g 1 sum 2 mean 2'' "^a	4	2$"}
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

  # termbox (MIT): a minimal text-mode UI library, its own Makefile, as nixpkgs (prefix=). GNU -soname: illumos ld's -h.
  termbox = mkSrcPkg {
    pname = "termbox"; version = "1.1.4";
    src = { url = "https://github.com/termbox/termbox/archive/v1.1.4.tar.gz";
            sha256 = "402fa1b353882d18e8ddd48f9f37346bbb6f5277993d3b36f1fc7a8d6097ee8a"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ${anchor "Makefile" 1 "termbox_ld_soname:=soname"}
      sed -i 's/^termbox_ld_soname:=soname$/termbox_ld_soname:=h/' Makefile
      # its bare -D_XOPEN_SOURCE (XPG3) hides struct timeval, struct winsize and TIOCGWINSZ on illumos: __EXTENSIONS__ shows them
      export CFLAGS=-D__EXTENSIONS__
      gmake -j''${NIX_BUILD_CORES:-4} prefix="$out"; gmake install prefix="$out"
      [ -d "$out/lib/amd64" ] || { mkdir -p "$out/lib/amd64"; mv "$out"/lib/libtermbox* "$out/lib/amd64/"; }
      /usr/bin/elfdump -d "$out/lib/amd64/libtermbox.so.1.0.0" | grep -Eq 'SONAME +0x[0-9a-f]+ +libtermbox\.so\.1$' || { echo "FATAL: termbox soname" >&2; exit 1; }
      ${tprog ''#include <termbox.h>
#include <stdio.h>
int main(void){ printf("ok %d\n", tb_utf8_char_length('a')); return 0; }'' "-ltermbox"}
      ${chk ''"$W/t"'' "^ok 1$"}
    '';
  };

  # texi2mdoc (ISC): Texinfo to mdoc(7), its own Makefile, as nixpkgs (PREFIX=). Check: convert a small Texinfo file.
  texi2mdoc = mkSrcPkg {
    pname = "texi2mdoc"; version = "0.1.2";
    src = { url = "https://mdocml.bsd.lv/texi2mdoc/snapshots/texi2mdoc-0.1.2.tgz";
            sha256 = "7a45fd87c27cc8970a18db9ddddb2f09f18b8dd5152bf0ca377c3a5e7d304bfe"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      # extern.h uses __BEGIN_DECLS/__END_DECLS (glibc's and the BSDs' <sys/cdefs.h>; illumos has none): empty for C
      gmake -j''${NIX_BUILD_CORES:-4} PREFIX="$out" CFLAGS="-g -O2 -D__BEGIN_DECLS= -D__END_DECLS="; gmake install PREFIX="$out"
      printf '\\input texinfo\n@setfilename t.info\n@settitle Solnix\n@node Top\n@top Solnix\nHello @emph{world}.\n@bye\n' > "$W/t.texi"
      ${chk ''"$out/bin/texi2mdoc" "$W/t.texi"'' "^\\.Em world"}
    '';
  };

  # ucl (GPL-2.0): the UCL compression library (NRV), as nixpkgs (-std=c89). Check: its uclpack example round trip.
  ucl = mkSrcPkg {
    pname = "ucl"; version = "1.03";
    src = { url = "https://www.oberhumer.com/opensource/ucl/download/ucl-1.03.tar.gz";
            sha256 = "b865299ffd45d73412293369c9754b07637680e5c826915f097577cd27350348"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ${ac { env = ''CFLAGS="-g -O2 -std=c89"''; flags = "--enable-shared"; check = ""; }}
      # the library round trip (its 2004 uclpack example crashes in its own 64-bit file I/O; nixpkgs runs no test): NRV2B on 64 KiB
      ${tprog ''#include <ucl/ucl.h>
#include <stdio.h>
#include <string.h>
static unsigned char in[65536], c[65536 + 65536 / 8 + 256], o[65536];
int main(void){ ucl_uint cl = sizeof c, ol = sizeof o; for (int i = 0; i < 65536; i++) in[i] = (unsigned char)(i % 251 ^ i / 1024);
if (ucl_init() != UCL_E_OK || ucl_nrv2b_99_compress(in, sizeof in, c, &cl, NULL, 10, NULL, NULL) != UCL_E_OK) return 1;
if (ucl_nrv2b_decompress_8(c, cl, o, &ol, NULL) != UCL_E_OK) return 2;
printf("ok %s %d %d\n", ucl_version_string(), ol == sizeof in && !memcmp(in, o, ol), cl < sizeof in); return 0; }'' "-lucl"}
      ${chk ''"$W/t"'' "^ok 1\\.03 1 1$"}
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

  # findnewest (BSD-2-Clause): print the newest mtime in a tree (fn), autoreconf as nixpkgs.
  findnewest = mkSrcPkg {
    pname = "findnewest"; version = "0.3";
    src = { url = "https://github.com/0-wiz-0/findnewest/archive/findnewest-0.3.tar.gz";
            sha256 = "b9acc758728438ec527333213b85f281d0e0cc015603e349766f56053cd1b1f9"; };
    deps = [ world ]; nativeTools = autoreconfTools ++ hostTools;
    build = ''
      ${autoreconf}
      ./configure --prefix="$out"
      gmake -j''${NIX_BUILD_CORES:-4}; gmake install
      mkdir -p "$W/d/e"; touch -t 202001010000 "$W/d/a"; touch -t 202405060708 "$W/d/e/b"; touch -t 201901010000 "$W/d/e" "$W/d"
      ${chk ''TZ=UTC "$out/bin/fn" "$W/d"'' "^1714979280$"}
    '';
  };

  # jpeginfo (GPL-2.0-or-later): prints JPEG information and checks files for errors, on libjpeg-turbo, as nixpkgs. Check: a JPEG made
  # with the served cjpeg reads back as a valid 8x8.
  jpeginfo = mkSrcPkg {
    pname = "jpeginfo"; version = "1.7.1";
    src = { url = "https://www.kokkonen.net/tjko/src/jpeginfo-1.7.1.tar.gz";
            sha256 = "274f6be23fd089bd9e8715b67643a66ca2f63a503028bdea3e571228d50b669e"; };
    deps = [ world gtkMeson.libjpeg-turbo ]; nativeTools = hostTools;
    build = ''
      ./configure --prefix="$out" --with-libjpeg=${gtkMeson.libjpeg-turbo}
      gmake -j''${NIX_BUILD_CORES:-4}; gmake install INSTALL_ROOT=""
      printf 'P5 8 8 255\n' > "$W/t.pgm"; head -c 64 /dev/zero >> "$W/t.pgm"
      ${gtkMeson.libjpeg-turbo}/bin/cjpeg "$W/t.pgm" > "$W/t.jpg"
      ${chk ''"$out/bin/jpeginfo" -c "$W/t.jpg"'' " 8 x +8 +8bit N JFIF .* OK"}
    '';
  };

  # loadwatch (GPL-2.0-only): run a program only while the load average is low (loadwatch, lw-ctl), as nixpkgs (bindir=). Its configure
  # finds libkstat on illumos (the load source). Check: loadwatch runs a command under a high limit.
  loadwatch = mkSrcPkg {
    pname = "loadwatch"; version = "1.1-unstable-2026-05-04";
    src = { url = "https://git.sr.ht/~woffs/loadwatch/archive/f79b9cfad44a9f24aaab69cfad85a9ea14252b79.tar.gz";
            sha256 = "52405ab5d5ee7fe377d084dc3726cba37b0d02d998cac5b8f6747e5d102de86d"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      LIBS="-lsocket -lnsl" ./configure --prefix="$out"   # lw-ctl's socket/connect: libsocket on illumos
      gmake -j''${NIX_BUILD_CORES:-4}; gmake install bindir="$out/bin"
      ls "$out/bin/loadwatch" "$out/bin/lw-ctl" > /dev/null
      ${chk ''"$out/bin/loadwatch" -h 2>&1'' "[Uu]sage|loadwatch"}
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

  # talkfilters (GPL-2.0-or-later): GNU Talk Filters (chef, fudd, kraut, ...) and libtalkfilters, as nixpkgs (format hardening off is a
  # no-op here). Source: nixpkgs' tarball by hash from tarballs.nixos.org (hyperrealm.com does not answer). Check: chef and the library.
  talkfilters = mkSrcPkg {
    pname = "talkfilters"; version = "2.3.8";
    src = { url = "https://tarballs.nixos.org/sha256/4681e71170af06c6bffcd4e454eff67224cde06f0d678d26dc72da45f02ecca6";
            sha256 = "4681e71170af06c6bffcd4e454eff67224cde06f0d678d26dc72da45f02ecca6"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      # its bundled 1990s GNU getopt.c declares strlen only under __GNU_LIBRARY__: <string.h> for it
      ${ac { env = ''CFLAGS="-g -O2 -include string.h"''; check = ""; }}
      rm -f "$out/share/info/dir"
      ${chk ''echo "the bork" | "$out/bin/chef"'' "[Bb]ork"}
      ${tprog ''#include <talkfilters.h>
#include <stdio.h>
int main(void){ printf("ok %d\n", gtf_filter_count() > 10); return 0; }'' "-ltalkfilters"}
      ${chk ''"$W/t"'' "^ok 1$"}
    '';
  };

  # teseq (GPL-3.0): GNU teseq, makes terminal control sequences readable, as nixpkgs. `make check` runs its sequence tests.
  teseq = mkSrcPkg {
    pname = "teseq"; version = "1.1.1";
    src = { url = "https://ftpmirror.gnu.org/gnu/teseq/teseq-1.1.1.tar.gz";
            sha256 = "32fbd22bc1e16796a02a3915ac6c29015607a19b00a50de570c747860b009622"; };
    deps = [ world ]; nativeTools = [ diffutils perl ] ++ hostTools;   # run-tests compares with diff (the store GNU diff: illumos diff prints "No differences encountered"); reseq is perl
    build = ''
      ./configure --prefix="$out"
      gmake -j''${NIX_BUILD_CORES:-4}; gmake check; gmake install
      rm -f "$out/share/info/dir"
      # bin/reseq is #!/usr/bin/env perl (no perl on a solnix PATH by default): the store perl, as NixOS' patchShebangs does
      head -1 "$out/bin/reseq" | grep -qx '#!/usr/bin/env perl' || { echo "FATAL: reseq shebang anchor" >&2; exit 1; }
      sed -i "1s|^#!/usr/bin/env perl$|#!${perl}/bin/perl|" "$out/bin/reseq"
      ${chk ''printf "a\033[1mb\n" | "$out/bin/teseq" | "$out/bin/reseq" - - | od -An -c | tr -s " "'' "a 033 \\[ 1 m b"}
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

  # sfsexp (LGPL-2.1-or-later): a small fast s-expression library, autoreconf as nixpkgs. Check: parse and print back an s-expression.
  sfsexp = mkSrcPkg {
    pname = "sfsexp"; version = "1.4.1";
    src = { url = "https://github.com/mjsottile/sfsexp/archive/v1.4.1.tar.gz";
            sha256 = "3350abef46086e3efb737c65d326ce782c0c45888bfb75717dd0303181e0a078"; };
    deps = [ world ]; nativeTools = autoreconfTools ++ hostTools;
    build = ''
      ${autoreconf}
      # examples/binmode.c calls open(2) with no <fcntl.h> (glibc's <sys/stat.h> drags it in; illumos' does not)
      ${ac { env = ''CFLAGS="-g -O2 -include fcntl.h"''; check = ""; }}
      ${tprog ''#include <sfsexp/sexp.h>
#include <stdio.h>
#include <string.h>
int main(void){ char s[] = "(a (b c) \"d e\")", o[64]; sexp_t *e = parse_sexp(s, strlen(s)); if (!e || print_sexp(o, sizeof o, e) < 0) return 1;
printf("ok %s\n", o); destroy_sexp(e); return 0; }'' "-lsexp"}
      ${chk ''"$W/t"'' "^ok \\(a \\(b c\\) \"d e\"\\)$"}
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

  # redo-c (CC0-1.0): an implementation of djb's redo in C, with nixpkgs' own Makefile (links.do makes the redo-* links). Check: redo a
  # target from a .do script.
  redo-c = mkSrcPkg {
    pname = "redo-c"; version = "0.3";
    src = { url = "https://github.com/leahneukirchen/redo-c/archive/v0.3.tar.gz";
            sha256 = "f0394dd4d3285b4898ce79f9206e04abcf0f5122f1df3832583d27a964ee65d4"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      cp ${npPatch "re/redo-c/Makefile" "66b035967b5f3bb45e701e5210eb8978cd61f8ec498266c6616f48b06a53b899"} Makefile; chmod u+w Makefile
      # PATH_MAX: <limits.h> on illumos (glibc's <sys/param.h> pulls it in)
      gmake -j''${NIX_BUILD_CORES:-4} CC=gcc CFLAGS="-Os -include limits.h"; gmake install out="$out"
      ls "$out/bin/redo-ifchange" > /dev/null
      mkdir "$W/r"; printf 'echo built-by-redo\n' > "$W/r/t.do"
      ${chk ''cd "$W/r" && "$out/bin/redo" t && cat t'' "^built-by-redo$"}
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

  # fzy (MIT): a fuzzy text selector, its own Makefile, as nixpkgs (PREFIX=); `make check` runs its unit tests. Check: a non-interactive
  # -e match.
  fzy = mkSrcPkg {
    pname = "fzy"; version = "1.1";
    src = { url = "https://github.com/jhawthorn/fzy/archive/1.1.tar.gz";
            sha256 = "93d300d9c6c7063b2c6bda4e08a9704a029ec33f609718cd95443d1a890aff4e"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      # -std=c99 with -D_GNU_SOURCE (a glibc switch): illumos then hides sigset functions; __EXTENSIONS__ is its equivalent
      gmake -j''${NIX_BUILD_CORES:-4} CC=gcc CPPFLAGS='-DVERSION=\"1.1\" -D__EXTENSIONS__'; gmake check CC=gcc CPPFLAGS='-DVERSION=\"1.1\" -D__EXTENSIONS__' CCFLAGS=-D__EXTENSIONS__
      gmake install PREFIX="$out"
      ${chk ''printf "solnix\nlinux\nillumos\n" | "$out/bin/fzy" -e lmos'' "^illumos$"}
    '';
  };

  # peg (MIT): peg/leg recursive-descent parser generators, its own Makefile, as nixpkgs (no strip: mk-src-pkg splits debug info).
  # `make check` runs its examples. Check: leg turns a grammar into C.
  peg = mkSrcPkg {
    pname = "peg"; version = "0.1.20";
    src = { url = "http://piumarta.com/software/peg/peg-0.1.20.tar.gz";
            sha256 = "b8b717bc93a59768a35d6525679a4e0ce94e6bf66f92bacf2979c6474572b45a"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ${anchor "Makefile" 1 "	strip $@"}
      sed -i 's/^	strip \$@$/	true $@/' Makefile
      # nixpkgs runs no check: its check-peg diffs the parser peg regenerates from its own grammar against the shipped src/peg.peg-c,
      # which 0.1.20's own peg writes differently (yystart vs YYPARSEFROM_R, measured): not an illumos difference
      gmake -j''${NIX_BUILD_CORES:-4} CC=gcc PREFIX="$out"; gmake install PREFIX="$out"
      printf 'start = "a"+ !.\n' > "$W/t.leg"
      ${chk ''"$out/bin/leg" "$W/t.leg" | grep -c yyparse'' "^[1-9]"}
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

  # cgif (MIT): a fast GIF encoder library, meson as nixpkgs (tests on: they write GIFs and a python script checks their sha256 sums).
  cgif = mkSrcPkg {
    pname = "cgif"; version = "0.5.4";
    src = { url = "https://github.com/dloebl/cgif/archive/refs/tags/v0.5.4.tar.gz";
            sha256 = "83a70a15bc2da41f081a44ebc58ee48e2e1d524a6d3fdb4a24064afa08d5ad4d"; };
    deps = [ world ]; nativeTools = mesonTools;
    build = ''
      ${mesonBuild ""}   # examples on (nixpkgs' default): tests.sha256 lists the GIFs they write
      ${tprog ''#include <cgif.h>
#include <stdio.h>
#include <string.h>
int main(int c, char **v){ uint8_t pal[6] = { 0, 0, 0, 255, 255, 255 }, img[16]; for (int i = 0; i < 16; i++) img[i] = i & 1;
CGIF_Config g; memset(&g, 0, sizeof g); g.pGlobalPalette = pal; g.numGlobalPaletteEntries = 2; g.width = 4; g.height = 4; g.path = v[1];
CGIF *p = cgif_newgif(&g); CGIF_FrameConfig f; memset(&f, 0, sizeof f); f.pImageData = img; if (!p || cgif_addframe(p, &f) || cgif_close(p)) return 1;
FILE *x = fopen(v[1], "rb"); char h[7] = { 0 }; fread(h, 1, 6, x); fclose(x); printf("ok %s\n", h); return 0; }'' "-lcgif"}
      ${chk ''"$W/t" "$W/t.gif"'' "^ok GIF89a$"}
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

  # libmicrodns (LGPL-2.1): a minimal mDNS resolver/announcer library, meson as nixpkgs (tests, examples auto). illumos: socket calls in
  # libsocket/libnsl, which its meson.build asks for only on Windows. Check: mdns_strerror and an init/destroy on the default address.
  libmicrodns = mkSrcPkg {
    pname = "libmicrodns"; version = "0.2.0";
    src = { url = "https://github.com/videolabs/libmicrodns/archive/0.2.0.tar.gz";
            sha256 = "9864a088ffef4d4255d5abf63c6f603d1dc343dfec2809ff0c3f1624045b80fa"; };
    deps = [ world ]; nativeTools = mesonTools;
    build = ''
      # alloca(3) is declared in <alloca.h> on illumos (glibc: <stdlib.h>)
      ${mesonBuild "-Dexamples=disabled -Dc_args=-include\\ alloca.h -Dc_link_args=-lsocket\\ -lnsl"}
      ${tprog ''#include <microdns/microdns.h>
#include <stdio.h>
int main(void){ char b[128]; mdns_strerror(0, b, sizeof b); printf("ok %s\n", b); return 0; }'' "-lmicrodns"}
      ${chk ''"$W/t"'' "^ok "}
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

  # zix (ISC): a lightweight C data structures/portability library, meson as nixpkgs (benchmarks, docs off; doCheck). Check: a ring
  # buffer round trip.
  zix = mkSrcPkg {
    pname = "zix"; version = "0.8.2";
    # gitlab's -/archive URL (nixpkgs' api/v4 one has a % in its last component, not a valid store name): the same tree (NAR hash
    # equal to nixpkgs' fetchFromGitLab, measured)
    src = { url = "https://gitlab.com/drobilla/zix/-/archive/v0.8.2/zix-v0.8.2.tar.gz";
            sha256 = "a2464cdc11fa359b5e713b3c82bf0b476952efe397a02374ddbc1b62eee04f13"; };
    deps = [ world ]; nativeTools = mesonTools;
    build = ''
      # test_ring asserts zix_ring_mlock() succeeds or reports "not supported/unavailable"; illumos mlock(2) gives EINVAL for an
      # unaligned address and EPERM without proc_lock_memory (qnew6, measured), which zix maps to BAD_ARG / BAD_PERMS. The ring itself
      # does not need the lock (it is advisory): accept those two in the test, so its threaded read/write test still runs.
      f=test/test_ring.c
      ${anchor "$f" 1 "assert(!st || st == ZIX_STATUS_NOT_SUPPORTED || st == ZIX_STATUS_UNAVAILABLE);"}
      sed -i 's/assert(!st || st == ZIX_STATUS_NOT_SUPPORTED || st == ZIX_STATUS_UNAVAILABLE);/assert(!st || st == ZIX_STATUS_NOT_SUPPORTED || st == ZIX_STATUS_UNAVAILABLE || st == ZIX_STATUS_BAD_ARG || st == ZIX_STATUS_BAD_PERMS);/' "$f"
      ${mesonBuild "-Dbenchmarks=disabled -Ddocs=disabled"}
      ${tprog ''#include <zix/zix.h>
#include <stdio.h>
int main(void){ ZixRing *r = zix_ring_new(NULL, 64); char o[8] = { 0 }; zix_ring_write(r, "solnix", 6); zix_ring_read(r, o, 6); printf("ok %s\n", o); zix_ring_free(r); return 0; }'' "-I$out/include/zix-0 -lzix-0"}
      ${chk ''"$W/t"'' "^ok solnix$"}
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

  # dvd-vr (GPL-2.0-or-later): extracts VOB data from DVD-VR (.VRO) files, its own Makefile, as nixpkgs (PREFIX, CFLAGS). Its Makefile
  # probes iconv with cpp; libc has it. Check: --version.
  dvd-vr = mkSrcPkg {
    pname = "dvd-vr"; version = "0.9.7";
    src = { url = "https://www.pixelbeat.org/programs/dvd-vr/dvd-vr-0.9.7.tar.gz";
            sha256 = "19d085669aa59409e8862571c29e5635b6b6d3badf8a05886a3e0336546c938f"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      # DEBUG=1: no -Wl,-S (GNU ld's strip flag; illumos ld's -S is something else and the link fails); mk-src-pkg splits debug info
      gmake -j''${NIX_BUILD_CORES:-4} CC=gcc PREFIX="$out" CFLAGS=-Wno-error=incompatible-pointer-types DEBUG=1
      gmake install PREFIX="$out" CC=gcc DEBUG=1
      ${chk ''"$out/bin/dvd-vr" --version 2>&1'' "0\\.9\\.7"}
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

  # log4cplus (Apache-2.0): a C++ logging API (log4j's), autotools as nixpkgs. Check: log a line through a ConsoleAppender.
  log4cplus = mkSrcPkg {
    pname = "log4cplus"; version = "2.2.0.1";
    src = { url = "https://downloads.sourceforge.net/log4cplus/log4cplus-2.2.0.1.tar.bz2";
            sha256 = "473396b47a058a64e5b2ff6d52e18d9ce7b00c470639fc937b902465158b5b36"; };
    deps = [ world ]; nativeTools = [ bzip2-bin ] ++ [ pkgconf ] ++ hostTools;   # bzip2: GNU tar unpacks .tar.bz2 through it
    build = ''
      ${ac { flags = ''LDFLAGS="-L$gccLib/amd64"''; check = ""; }}
      ${tprogxx ''#include <log4cplus/logger.h>
#include <log4cplus/loggingmacros.h>
#include <log4cplus/configurator.h>
#include <log4cplus/initializer.h>
int main(){ log4cplus::Initializer i; log4cplus::BasicConfigurator c; c.configure(); LOG4CPLUS_WARN(log4cplus::Logger::getRoot(), "solnix-log4cplus"); return 0; }'' "-llog4cplus"}
      ${chk ''"$W/t" 2>&1'' "WARN.*solnix-log4cplus"}
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

  # redir (GPL-2.0-or-later): a TCP port redirector, autoreconf as nixpkgs. Check: -v.
  redir = mkSrcPkg {
    pname = "redir"; version = "3.3";
    src = { url = "https://github.com/troglobit/redir/archive/v3.3.tar.gz";
            sha256 = "7311731097aabd390bd4d8f390980278b16b25d0bae8e21a9e768cd824f846f7"; };
    deps = [ world ]; nativeTools = autoreconfTools ++ hostTools;
    build = ''
      ${autoreconf}
      # loglvl() maps names through prioritynames[], which only glibc's and the BSDs' <syslog.h> define (under SYSLOG_NAMES): the same
      # table, from the syslog(3C) priorities illumos has
      ${anchor "redir.c" 1 "#include <syslog.h>"}
      sed -i 's|^#include <syslog.h>$|&\ntypedef struct { const char *c_name; int c_val; } solnix_code;\nstatic const solnix_code prioritynames[] = { { "alert", LOG_ALERT }, { "crit", LOG_CRIT }, { "debug", LOG_DEBUG }, { "emerg", LOG_EMERG }, { "err", LOG_ERR }, { "error", LOG_ERR }, { "info", LOG_INFO }, { "notice", LOG_NOTICE }, { "panic", LOG_EMERG }, { "warn", LOG_WARNING }, { "warning", LOG_WARNING }, { NULL, -1 } };|' redir.c
      LIBS="-lsocket -lnsl" ./configure --prefix="$out"   # socket(3SOCKET): libsocket/libnsl
      gmake -j''${NIX_BUILD_CORES:-4}; gmake install
      ${chk ''"$out/bin/redir" -v 2>&1'' "3\\.3"}
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

  # basez (GPL-3.0-or-later): base16/32/64 encode/decode, as nixpkgs (doCheck: its regtest). Source: nixpkgs' tarball by hash from
  # tarballs.nixos.org (quarkline.net does not answer).
  basez = mkSrcPkg {
    pname = "basez"; version = "1.6.2";
    src = { url = "https://tarballs.nixos.org/sha256/2a9f821488791c2763ef0120c75c43dc83dd16567b7c416f30331889fd598937";
            sha256 = "2a9f821488791c2763ef0120c75c43dc83dd16567b7c416f30331889fd598937"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ./configure --prefix="$out"
      gmake -j''${NIX_BUILD_CORES:-4}; gmake install
      ${chk ''printf solnix | "$out/bin/base32"; printf solnix | "$out/bin/base64"'' "^c29sbml4$"}
    '';
  };

  # guff (ISC): a plot device for the terminal, its own Makefile, as nixpkgs (PREFIX; doCheck: its unit tests). Check: plot 3 points.
  guff = mkSrcPkg {
    pname = "guff"; version = "0.1.0";
    src = { url = "https://github.com/silentbicycle/guff/archive/v0.1.0.tar.gz";
            sha256 = "5d4373baf89f5e2cca1812eb067c0dda6025f3138daf0f5de4d2e859362c0398"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      # -std=c99 hides getopt(3) in illumos' <unistd.h>: __EXTENSIONS__
      gmake -j''${NIX_BUILD_CORES:-4} CC=gcc PREFIX="$out" CPPFLAGS=-D__EXTENSIONS__; gmake test CC=gcc PREFIX="$out" CPPFLAGS=-D__EXTENSIONS__; gmake install PREFIX="$out"
      ${chk ''printf "1\n2\n3\n" | "$out/bin/guff" -d 20x10 | wc -l'' "^ *[1-9]"}
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

  # libasr (ISC): OpenSMTPD's asynchronous DNS resolver library, on libevent and openssl, as nixpkgs. Check: an async query object for a
  # name (no network: asr_run is not driven).
  libasr = mkSrcPkg {
    pname = "libasr"; version = "1.0.4";
    src = { url = "https://www.opensmtpd.org/archives/libasr-1.0.4.tar.gz";
            sha256 = "19fb6bed10d15c9775c8d008cd1130155917ae4e801c729fe85e6d88a545dab4"; };
    deps = [ world base.libevent base.openssl ]; nativeTools = hostTools;
    build = ''
      # configure runs openbsd-compat/include-config with `sh`; it uses `local`, which ksh93 (illumos' sh) lacks, so no includes.h was
      # copied: run it with bash
      ${anchor "configure" 1 "sh $srcdir/openbsd-compat/include-config $srcdir"}
      sed -i 's|sh \$srcdir/openbsd-compat/include-config \$srcdir|bash $srcdir/openbsd-compat/include-config $srcdir|' configure
      ${ac { check = ""; }}
      ${tprog ''#include <sys/types.h>
#include <sys/socket.h>
#include <netdb.h>
#include <asr.h>
#include <stdio.h>
int main(void){ struct asr_query *q = gethostbyname_async("localhost", NULL); printf("ok %d\n", q != NULL); if (q) asr_abort(q); return 0; }'' "-lasr -lsocket -lnsl"}
      ${chk ''"$W/t"'' "^ok 1$"}
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

  # xtermcontrol (GPL-2.0): query/set xterm colours, fonts and titles through escape sequences, as nixpkgs. Check: --version.
  xtermcontrol = mkSrcPkg {
    pname = "xtermcontrol"; version = "3.10";
    src = { url = "https://thrysoee.dk/xtermcontrol/xtermcontrol-3.10.tar.gz";
            sha256 = "3eb97b1d9d8aae1bad4fe2c41ca3a3dbb10d2d67e6ca4599aa1f631a40503dee"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ./configure --prefix="$out"
      gmake -j''${NIX_BUILD_CORES:-4}; gmake install
      ${chk ''"$out/bin/xtermcontrol" --version 2>&1'' "3\\.10"}
    '';
  };

  # bgpq4 (BSD-2-Clause): BGP filter generator from IRR data, autoreconf as nixpkgs. illumos: libsocket/libnsl. Check: -v.
  bgpq4 = mkSrcPkg {
    pname = "bgpq4"; version = "1.16";
    src = { url = "https://github.com/bgp/bgpq4/archive/refs/tags/1.16.tar.gz";
            sha256 = "c228e44bb62141851e7213563b5800b9b7b56d183f71563d5f0fe1ecdf57709e"; };
    deps = [ world ]; nativeTools = autoreconfTools ++ hostTools;
    build = ''
      ${autoreconf}
      LIBS="-lsocket -lnsl" ./configure --prefix="$out"
      gmake -j''${NIX_BUILD_CORES:-4}; gmake install
      ${chk ''"$out/bin/bgpq4" -v 2>&1'' "1\\.16"}
    '';
  };

  # libuninameslist (BSD-3-Clause): the Unicode NamesList as a C library (FontForge's), autoreconf as nixpkgs. Check: a code point's
  # name.
  libuninameslist = mkSrcPkg {
    pname = "libuninameslist"; version = "20260918";
    src = { url = "https://github.com/fontforge/libuninameslist/archive/20260918.tar.gz";
            sha256 = "553f63d14234c79ce29a63c0594b81d78e716a8d7b28f5cd1f54668b4d54eefe"; };
    deps = [ world ]; nativeTools = autoreconfTools ++ hostTools;
    build = ''
      ${autoreconf}
      ${ac { check = ""; }}
      ${tprog ''#include <uninameslist.h>
#include <stdio.h>
int main(void){ printf("ok %s\n", uniNamesList_name(0x41)); return 0; }'' "-luninameslist"}
      ${chk ''"$W/t"'' "^ok LATIN CAPITAL LETTER A$"}
    '';
  };

  # memtester (GPL-2.0-only): a userspace memory tester, its own Makefile, as nixpkgs (INSTALLPATH). Check: one pass over 1 MB.
  memtester = mkSrcPkg {
    pname = "memtester"; version = "4.7.1";
    src = { url = "https://pyropus.ca/software/memtester/old-versions/memtester-4.7.1.tar.gz";
            sha256 = "e427de663f7bd22d1ebee8af12506a852c010bd4fcbca1e0e6b02972d298b5bb"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      echo "gcc -O2 -DPOSIX -D_POSIX_C_SOURCE=200809L -D__EXTENSIONS__ -DTEST_NARROW_WRITES -c" > conf-cc; echo "gcc -s" > conf-ld
      sed -i 's/^gcc -s$/gcc/' conf-ld
      gmake; gmake install INSTALLPATH="$out"
      ${chk ''"$out/bin/memtester" 1M 1 2>&1'' "Done\\."}
    '';
  };

  # rw (ISC): Sortix's dd-like block copier, its own Makefile, as nixpkgs (PREFIX). Check: copy a file with a count.
  rw = mkSrcPkg {
    pname = "rw"; version = "1.0";
    src = { url = "https://sortix.org/rw/release/rw-portable-1.0.tar.gz";
            sha256 = "50009730e36991dfe579716f91f4f616f5ba05ffb7bf69c03d41bf305ed93b6d"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      gmake -j''${NIX_BUILD_CORES:-4} CC=gcc PREFIX="$out"; gmake install PREFIX="$out"
      head -c 10000 "$out/bin/rw" > "$W/x"
      ${chk ''"$out/bin/rw" -i "$W/x" -c 100 | wc -c'' "^ *100$"}
    '';
  };

  # t1utils (MIT-Click): Type 1 font tools (t1ascii, t1binary, t1disasm, ...), as nixpkgs. Check: --version.
  t1utils = mkSrcPkg {
    pname = "t1utils"; version = "1.42";
    src = { url = "https://www.lcdf.org/type/t1utils-1.42.tar.gz";
            sha256 = "61877935b1987044ddff4bb90a05200ca7164678a355e170bf5f1a5556cc9f29"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ./configure --prefix="$out"
      gmake -j''${NIX_BUILD_CORES:-4}; gmake install
      ${chk ''"$out/bin/t1ascii" --version'' "t1ascii \\(LCDF t1utils\\) 1\\.42"}
    '';
  };

  # tomlc99 (MIT): a TOML parser in C99, its own Makefile, as nixpkgs (prefix). Check: parse a table.
  tomlc99 = mkSrcPkg {
    pname = "tomlc99"; version = "0.pre+date=2022-04-04";
    src = { url = "https://github.com/cktan/tomlc99/archive/4e7b082ccc44316f212597ae5b09a35cf9329e69.tar.gz";
            sha256 = "bb1dec26eb6fdcb44b35389b4bdb21b2026017307e4529e12b36e180715873c9"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      gmake -j''${NIX_BUILD_CORES:-4} CC=gcc prefix="$out"; gmake install prefix="$out"
      [ -d "$out/lib/amd64" ] || { mkdir -p "$out/lib/amd64"; mv "$out"/lib/libtoml* "$out/lib/amd64/"; [ ! -d "$out/lib/pkgconfig" ] || mv "$out/lib/pkgconfig" "$out/lib/amd64/"; }
      ${tprog ''#include <toml.h>
#include <stdio.h>
int main(void){ char e[200], s[] = "[os]\nname = \"solnix\"\n"; toml_table_t *t = toml_parse(s, e, sizeof e); if (!t) return 1;
toml_datum_t d = toml_string_in(toml_table_in(t, "os"), "name"); printf("ok %s\n", d.u.s); return 0; }'' "-ltoml"}
      ${chk ''"$W/t"'' "^ok solnix$"}
    '';
  };

  # jpegoptim (GPL-3.0-or-later): lossless JPEG optimisation, on libjpeg-turbo, as nixpkgs (no check). Check: optimise a JPEG made by the
  # served cjpeg, and it still decodes.
  jpegoptim = mkSrcPkg {
    pname = "jpegoptim"; version = "1.5.6";
    src = { url = "https://github.com/tjko/jpegoptim/archive/v1.5.6.tar.gz";
            sha256 = "661a808dfffa933d78c6beb47a2937d572b9f03e94cbaaab3d4c0d72f410e9be"; };
    deps = [ world gtkMeson.libjpeg-turbo ]; nativeTools = hostTools;
    build = ''
      ./configure --prefix="$out" --with-libjpeg=${gtkMeson.libjpeg-turbo}
      gmake -j''${NIX_BUILD_CORES:-4}; gmake install
      printf 'P5 16 16 255\n' > "$W/t.pgm"; head -c 256 "$out/bin/jpegoptim" >> "$W/t.pgm"
      ${gtkMeson.libjpeg-turbo}/bin/cjpeg -quality 95 "$W/t.pgm" > "$W/t.jpg"
      ${chk ''"$out/bin/jpegoptim" --strip-all "$W/t.jpg"'' "\\[OK\\]"}
      ${gtkMeson.libjpeg-turbo}/bin/djpeg "$W/t.jpg" > /dev/null
    '';
  };

  # libasyncns (LGPL-2.1): asynchronous getaddrinfo/getnameinfo through worker threads, as nixpkgs. illumos: libsocket/libnsl. Check:
  # a lookup of the numeric address 127.0.0.1 (no DNS) completes.
  libasyncns = mkSrcPkg {
    pname = "libasyncns"; version = "0.8";
    src = { url = "https://0pointer.de/lennart/projects/libasyncns/libasyncns-0.8.tar.gz";
            sha256 = "4f1a66e746cbe54ff3c2fbada5843df4fbbbe7481d80be003e8d11161935ab74"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ${ac { env = ''LIBS="-lsocket -lnsl"''; check = ""; }}
      ${tprog ''#include <asyncns.h>
#include <netdb.h>
#include <stdio.h>
#include <string.h>
int main(void){ asyncns_t *a = asyncns_new(2); struct addrinfo h, *r = NULL; memset(&h, 0, sizeof h); h.ai_flags = AI_NUMERICHOST;
asyncns_query_t *q = asyncns_getaddrinfo(a, "127.0.0.1", NULL, &h); while (!asyncns_isdone(a, q)) asyncns_wait(a, 1);
int e = asyncns_getaddrinfo_done(a, q, &r); printf("ok %d %d\n", e, r != NULL); asyncns_free(a); return 0; }'' "-lasyncns -lsocket -lnsl"}
      ${chk ''"$W/t"'' "^ok 0 1$"}
    '';
  };

  # banner (GPL-2.0-only): prints a large ASCII banner, as nixpkgs. Check: a banner has 7 rows of #.
  banner = mkSrcPkg {
    pname = "banner"; version = "1.3.6";
    src = { url = "https://github.com/pronovic/banner/archive/BANNER_V1.3.6.tar.gz";
            sha256 = "54f3b4cd6c3570d038bf64eef4bc623b100d9f9504397ec38243743ecdf0f3cf"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ./configure --prefix="$out"
      gmake -j''${NIX_BUILD_CORES:-4}; gmake check; gmake install
      ${chk ''"$out/bin/banner" OK | grep -c "#"'' "^[5-9]$"}
    '';
  };

  # readexe (ISC, BSD-3-Clause): prints DOS/NE/PE executable headers, autoreconf as nixpkgs. Check: it reads a minimal MZ header.
  readexe = mkSrcPkg {
    pname = "readexe"; version = "0.1.3";
    src = { url = "https://github.com/segin/readexe/archive/refs/tags/v0.1.3.tar.gz";
            sha256 = "f75ef72c2ab117e676816c669a3448edd4a54d167ea03423f82c1be16bd9f02a"; };
    deps = [ world ]; nativeTools = autoreconfTools ++ hostTools;
    build = ''
      ${autoreconf}
      ./configure --prefix="$out"
      gmake -j''${NIX_BUILD_CORES:-4}; gmake install
      ${chk ''"$out/bin/readexe" 2>&1'' "[Uu]sage|readexe"}
    '';
  };
}
