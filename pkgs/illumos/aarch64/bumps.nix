# aarch64/bumps.nix -- a64t: security and version bumps for the store-only aarch64 set, applied on top of ./default.nix perPkg (so
# the a64r/a64s fixes still apply), final stage only: the seed (stage0 tools, served rows) does not move. Same versions and tarballs
# as wave6's x86 recipes (d45eeb6) where wave6 has the target; xz 5.8.4 and sqlite 3.54.1 are ahead of wave6 (5.8.1, 3.53.2).
# Each package's own test suite runs in the build where it has one (openssl, xz, expat, libarchive, sqlite; brotli's ctest too).
# Tarball provenance (a64t progress step5): openssl .sha256 + .asc (OpenSSL B146647E...2D40); xz .sig (Lasse Collin 3690C240...);
# expat .asc (Sebastian Pipping 3176EF7D...); libarchive .asc (Martin Matuska 659C84C0...); wget .sig (Darshit Shah 7845120B...);
# sqlite sha3-256 = sqlite.org's download page; brotli: no signature, the tag archive == a clone of tag v1.1.1; socat: no signature,
# sha512 == Alpine's APKBUILD.
# wave6: the sqlite and python3 anchors are wave6's own check strings (c-net 3.53.2, c-dev OpenSSL 3.4.8 + 3.53.2; main's say 3.50.4/3.4.0), else
# the anchors throw and the aarch64 set loses sqlite, python3 and their 14 dependents (wave6w, measured: 186 -> 170 attrs).
{ tcl }:   # the fixed tcl (main 8017bf8, little-endian): sqlite's TCL test suite, build-time only
args:
let
  rep = what: a: b: s: let r = builtins.replaceStrings [ a ] [ b ] s; in if r == s then throw "a64t ${what}: anchor not found: ${a}" else r;
  src = url: sha256: { inherit url sha256; };
  sqTree = import <nix/fetchurl.nix> { url = "https://github.com/sqlite/sqlite/archive/refs/tags/version-3.54.1.tar.gz";
    sha256 = "41bba7dd1793db5a7c2c24de168226d30c4cc969b3d786c353afe55e49d7e5bf"; };
in {
  # 3.4.8: 30 High/Critical in 3.4.0 fixed. Tests enabled (no no-tests) and the whole suite runs, as nixpkgs' doCheck: 328 files,
  # 3844 tests on dixa, all pass. (A host-gcc build fails 3 QUIC tests there, on 3.4.0 too; this store-toolchain build passes them.)
  openssl = { version = "3.4.8";
    src = src "https://github.com/openssl/openssl/releases/download/openssl-3.4.8/openssl-3.4.8.tar.gz" "9de9ce2f29e584044ae07ab93fc601637be01fdc91d109c5a655ec7419e6022b";
    build = rep "openssl" "gmake install_sw" (''HARNESS_JOBS=16 timeout 5400 gmake test > "$W/ossl-test.out" 2>&1 || { tail -60 "$W/ossl-test.out" >&2; echo "FATAL: openssl gmake test failed" >&2; exit 1; }'' + "\n"
      + ''grep -E '^(Files=|Result:)' "$W/ossl-test.out" >&2; grep -qx 'Result: PASS' "$W/ossl-test.out" && grep -Eq '^Files=3[2-9][0-9], ' "$W/ossl-test.out" || { echo "FATAL: openssl tests did not PASS" >&2; exit 1; }'' + "\ngmake install_sw")
      (rep "openssl" " no-tests no-docs" " no-docs" args.build); };
  # 5.8.4 (CVE-2025-31115). --enable-path-for-scripts=no: configure's solaris* default puts PATH=/usr/xpg4/bin: in xzgrep and friends
  # (a host path; wave6 does the same, NixOS adds no prefix). gmake check: its 22 tests (liblzma units, the CLI and the scripts).
  xz = { version = "5.8.4";
    src = src "https://github.com/tukaani-project/xz/releases/download/v5.8.4/xz-5.8.4.tar.gz" "0014c7886930454fe8bd4228665b51af55eeae560ea135c9c4cd33f55b2591d9";
    build = rep "xz" "gmake -j4; gmake install" (''gmake -j4; gmake -j8 check >&2 || { cat tests/test-suite.log >&2; echo "FATAL: xz gmake check failed" >&2; exit 1; }'' + "\n"
      + ''grep -E '^# [A-Z]+: ' tests/test-suite.log >&2; grep -Eq '^# PASS: +2[1-9]$' tests/test-suite.log && [ "$(grep -Ec '^# (FAIL|ERROR|XPASS): +0$' tests/test-suite.log)" = 3 ] || { echo "FATAL: xz test counts" >&2; exit 1; }'' + "\ngmake install\n"
      + ''! grep -l /usr/xpg4 "$out"/bin/* | grep . || { echo "FATAL: xz names /usr/xpg4" >&2; exit 1; }'')
      (rep "xz" "--disable-doc" "--disable-doc --enable-path-for-scripts=no" args.build); };
  # 2.10.0 (11 High in 2.6.4; CVE-2026-115506). Tests built and run (tests/runtests: 5328 checks on dixa), not installed.
  expat = { version = "2.10.0";
    src = src "https://github.com/libexpat/libexpat/releases/download/R_2_10_0/expat-2.10.0.tar.xz" "c624ba2998fc65df1163a49641ff3f9ab73138b11641d92c86bee0fb01b1bc7f";
    build = rep "expat" "gmake -j8 && gmake install" (''gmake -j8; gmake -j8 check >&2 || { cat tests/test-suite.log >&2; echo "FATAL: expat gmake check failed" >&2; exit 1; }'' + "\n"
      + ''grep -E 'Checks: [0-9]+, Failed: ' tests/runtests.log >&2; grep -Eq 'Checks: [0-9]{4,}, Failed: 0$' tests/runtests.log || { echo "FATAL: expat runtests" >&2; exit 1; }'' + "\ngmake install")
      (rep "expat" " --without-tests" "" args.build); };
  # 3.8.7 (CVE-2026-5121/4424; same soname libarchive.so.13). libarchive_test runs in the build (702 tests on dixa). Two fail on
  # illumos and may fail here, no others: test_archive_string_conversion_fail_c/_fail_latin1 (new in 3.8) expect iconv(UTF-8 -> 646 or
  # ISO8859-1) to return -1 on U+043F, and illumos iconv returns 1 (the count of non-identical conversions, POSIX) with '?' put in its
  # place (measured on dixa, a64t step16). Arch-independent libc behaviour, not this bump.
  libarchive = { version = "3.8.7";
    src = src "https://github.com/libarchive/libarchive/releases/download/v3.8.7/libarchive-3.8.7.tar.xz" "d3a8ba457ae25c27c84fd2830a2efdcc5b1d40bf585d4eb0d35f47e99e5d4774";
    build = rep "libarchive" "gmake -j4; gmake install" (''gmake -j4; gmake -j8 libarchive_test; r=0; ./libarchive_test -r "$PWD/libarchive/test" > "$W/la-test.out" 2>&1 || r=$?'' + "\n"
      + ''sed -n '/^Totals:/,/^Details/p' "$W/la-test.out" >&2; run=$(sed -n 's/^  Tests run: *//p' "$W/la-test.out")'' + "\n"
      + ''bad=$(sed -n '/^Failing tests:/,/^$/p' "$W/la-test.out" | grep -E '^ +[0-9]+: ' | grep -Ev ': test_archive_string_conversion_fail_(c|latin1) ' || true)'' + "\n"
      + ''[ "''${run:-0}" -ge 700 ] && [ -z "$bad" ] && { [ $r = 0 ] || grep -q '^Failing tests:' "$W/la-test.out"; } || { tail -40 "$W/la-test.out" >&2; echo "FATAL: libarchive_test rc=$r run=$run unexpected: $bad" >&2; exit 1; }'' + "\ngmake install")
      args.build; };
  # 3.54.1 (the queue's target). The autoconf tarball is what ships; sqlite's TCL suite needs the full tree, so the release tag's
  # archive is fetched too (its 2290 files == sqlite-src-3540100.zip's, and its generated sqlite3.c == the autoconf one: checked
  # here, cmp). testrunner.tcl knows no SunOS: SunOS takes its BSD arm. veryquick (330525 tests, 0 errors on dixa) runs on the
  # fixed tcl (build-time only: not in the out). The summary line is printed without its hostname.
  sqlite = { version = "3.54.1";
    src = src "https://www.sqlite.org/2026/sqlite-autoconf-3540100.tar.gz" "926ef8d3eab93fbf6e06011901273eec076b25594a4e1cdadd50c987f4f6d64e";
    build = rep "sqlite" "^3\\.53\\.2" "^3\\.54\\.1" args.build + ''
      mkdir -p "$W/sqt"; cd "$W/sqt"; tar xzf ${sqTree}; cd sqlite-version-3.54.1
      ./configure --build=aarch64-unknown-solaris2.11 --with-tcl=${tcl}/lib --with-tclsh=${tcl}/bin/tclsh8.6 --disable-readline >&2
      gmake sqlite3.c >&2; cmp sqlite3.c "$SRC/sqlite3.c" || { echo "FATAL: the tested sqlite3.c is not the shipped one" >&2; exit 1; }
      sed -i 's/^  \*freebsd\* -$/  *sunos* -\n  *freebsd* -/' test/testrunner.tcl; grep -q '^  \*sunos\* -$' test/testrunner.tcl || { echo "FATAL: sqlite testrunner sunos anchor" >&2; exit 1; }
      gmake -j16 testfixture >&2; r=0; LD_LIBRARY_PATH=${tcl}/lib ./testfixture test/testrunner.tcl --jobs 16 veryquick > "$W/sqt.out" 2>&1 || r=$?
      s=$(tr '\r' '\n' < "$W/sqt.out" | grep -E '^[0-9]+ errors out of [0-9]+ tests' | tail -1 | sed 's/ on .*//'); echo "sqlite veryquick: $s (rc $r)" >&2
      echo "$s" | grep -Eq '^0 errors out of [0-9]{6,} tests' && [ $r = 0 ] || { tr '\r' '\n' < "$W/sqt.out" | grep -E '^(FAILED|!)' | head -20 >&2; echo "FATAL: sqlite veryquick" >&2; exit 1; }
      cd "$SRC"
    ''; };
  python3 = { build = rep "python3" "OpenSSL 3\\.5\\.9 .* 3\\.53\\.2" "OpenSSL 3\\.4\\.8 .* 3\\.54\\.1" args.build; };   # its in-build ssl/sqlite3 check
  # 1.1.1 (CVE-2026-111497). Its ctest suite (round trips over tests/testdata, compatibility) runs here, as upstream builds it.
  brotli = { version = "1.1.1";
    src = src "https://github.com/google/brotli/archive/refs/tags/v1.1.1.tar.gz" "1a84dfaa740994d19254bf78aa7d74a4a8040d1638f3d5f2cdecb188fd520da8";
    build = rep "brotli" "gmake -j4; gmake install" (''gmake -j4; ctest -j8 --output-on-failure > "$W/ctest.out" 2>&1 || { tail -30 "$W/ctest.out" >&2; echo "FATAL: brotli ctest" >&2; exit 1; }'' + "\n"
      + ''grep -E 'tests passed' "$W/ctest.out" >&2; grep -Eq '^100% tests passed, 0 tests failed out of [0-9]{2,}' "$W/ctest.out" || { echo "FATAL: brotli ctest count" >&2; exit 1; }'' + "\ngmake install")
      (rep "brotli" "-DBROTLI_DISABLE_TESTS=ON" "-DBROTLI_DISABLE_TESTS=OFF" args.build); };
  wget = { version = "1.25.0";
    src = src "https://mirrors.kernel.org/gnu/wget/wget-1.25.0.tar.gz" "766e48423e79359ea31e41db9e5c289675947a7fcf2efdcedb726ac9d0da3784";
    build = rep "wget" "^GNU Wget 1.24.5" "^GNU Wget 1.25.0" args.build; };
  # 1.8.1.3: 1.8.1.2's SOCKS5 fix (CVE-2026-56123) plus its test on non-bash shells. Upstream publishes no checksum or signature.
  socat = { version = "1.8.1.3";
    src = src "http://www.dest-unreach.org/socat/download/socat-1.8.1.3.tar.gz" "06602ffd591e98c75b3dc1d66f0f19136cc666b0b2d95caad987d6ab2cb28097";
    build = rep "socat" "socat version 1.8.1.2" "socat version 1.8.1.3" args.build; };
  # flex 2.6.5, automake 1.20, hunspell 1.7.6 (the queue's versions): cli/ recipes both arches share, bumped here for aarch64 only with
  # wave8's exact strings (floki wave8/SHARED-BUMP-STRINGS.md). wave8's x86 commit bumps the shared recipe and deletes the entry, and the
  # aarch64 drvs stay where they are. flex .sig Good (Flex Releases 15A2D3E3...), automake .sig Good (Kamila Szewczyk D5D527E7...).
  flex = { version = "2.6.5";
    src = src "https://github.com/westes/flex/releases/download/v2.6.5/flex-2.6.5.tar.gz" "4dfb3d6095c0cd58f050dd66fa132ad52c118c5ae26a4bddd916557720920769";
    build = rep "flex" "^flex 2\\.6\\.4" "^flex 2\\.6\\.5" args.build; };
  automake = { version = "1.20";
    src = src "https://mirrors.kernel.org/gnu/automake/automake-1.20.tar.xz" "f6f34dad4cbe395715762b0710f7c511e39bd5cf777e6b95818ccbecf7714248";
    build = rep "automake" "^automake \\(GNU automake\\) 1\\.19" "^automake \\(GNU automake\\) 1\\.20" args.build; };
  hunspell = { version = "1.7.6";
    src = src "https://github.com/hunspell/hunspell/releases/download/v1.7.6/hunspell-1.7.6.tar.gz" "9c650ace31d4d8cc1da925a9507c3de1d50f1a54857af2f72429f517d5d53467";
    build = rep "hunspell" "Hunspell 1\\.7\\.3" "Hunspell 1\\.7\\.6" args.build; };
}
