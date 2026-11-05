# cli/c-libdb.nix -- libdb 2026.10.7.2 (github berkeleydb/libdb, the community Berkeley DB fork's LTS line), replacing Oracle's
# Berkeley DB 5.3.28 (32 open advisories; infra 2026-11-04). pname libdb: the fork's own project name and soname
# (libdb-2026.0.so); `berkeleydb` stays as an alias attr. Store-only (mk-src-pkg nativeTools). A new file, so no served drv moves.
# Source: the signed tag v2026.10.7.2 (2625d8cd; `git tag -v`: ED25519 SHA256:VJVWvZHY...), whose GitHub tarball's tree is
# byte-equal to `git archive` of the tag (libdb1 progress step4). Licence: LICENSE is Oracle's Sleepycat text, unchanged from
# v5.3.28 (git diff empty), 233 files SPDX "Sleepycat", meson.build license 'Sleepycat'; no GPL/AGPL code is built.
# Old packages.nix recipe's sed (__atomic_compare_exchange) and --with-mutex dropped: the tag has no such name in src/, and
# configure picks the mutex itself (the choice is asserted below).
{ mkSrcPkg, world, hostTools, chk, dropDocs, python3, tcl, ... }:
rec {
  # meta attached outside the derivation (nixpkgs' lib.addMetaAttrs): it is not a builder input, so it moves no drv. Licence read from
  # the tag: LICENSE (Oracle's Sleepycat text, as nixpkgs' db: lib.licenses.sleepycat), plus the UCB BSD and Harvard notices in it.
  libdb = mkSrcPkg {
    pname = "libdb"; version = "2026.10.7.2";
    src = { url = "https://github.com/berkeleydb/libdb/archive/refs/tags/v2026.10.7.2.tar.gz";
            sha256 = "c1d44c023b24e868ed934720ff09a7385857ed6e58f53c10a382357155e873af"; };
    deps = [ world ];
    # python3: test/db's page-corruption runners (run_db_verify_multifile, run_upgrade); tcl: the test suite only (not in $out)
    nativeTools = [ python3 ] ++ hostTools;
    build = ''
      # -L gcc.lib: libtool found libstdc++.la in the compiler out and baked that libdir into libdb_cxx as -R (closure gate, measured;
      # gmp6/hunspell in c-recipes2.nix have the same fix). A plain .so found first adds no rpath.
      cfg="--disable-static LDFLAGS=-L$gccLib/amd64"
      # the tag's config.guess (2011) has no aarch64 SunOS arm: name the build from the drv's system (both arches, one text)
      case "$system" in x86_64-*) cfg="--build=x86_64-pc-solaris2.11 $cfg";; aarch64-*) cfg="--build=aarch64-unknown-solaris2.11 $cfg";;
        *) echo "FATAL: libdb: no build triple for $system" >&2; exit 1;; esac
      fails() { echo "FATAL: libdb $1:" >&2; grep -E "$2" "$3" | head -20 >&2; tail -20 "$3" >&2; exit 1; }
      # ---- the release's Tcl suite, in its own build (--enable-test: CONFIG_TEST must not ship), BEFORE $out exists, so its
      # test programs cannot load a shipped library through the wrapper's -R $out/lib/amd64. CI's targeted subset (test/MANIFEST).
      mkdir build_tcl; cd build_tcl
      ../dist/configure $cfg --enable-debug --enable-test --with-tcl=${tcl}/lib/amd64 > "$W/cfg-tcl.log" 2>&1 || fails configure-tcl . "$W/cfg-tcl.log"
      gmake -j16 > "$W/make-tcl.log" 2>&1 || fails make-tcl 'error' "$W/make-tcl.log"
      TCLSH=${tcl}/bin/tclsh LIBDB_RESULTS_DIR="$W/res" sh ../test/tcl/run_targeted.sh > "$W/tcl.log" 2>&1 || fails tcl-suite 'VERDICT|FAIL' "$W/tcl.log"
      # run_upgrade's old-format pass needs libdb_tcl, so it runs here for real (in build_unix it notes the skip)
      TCLSH=${tcl}/bin/tclsh BUILD=. sh ../test/db/run_upgrade.sh > "$W/upgrade.log" 2>&1 || fails run_upgrade 'FAIL' "$W/upgrade.log"
      grep -q 'skipping current/old' "$W/upgrade.log" && fails 'run_upgrade skipped its Tcl pass' 'skipping' "$W/upgrade.log"
      cd ..
      # ---- the shipped build: nixpkgs' flags (--enable-cxx --enable-compat185)
      cd build_unix
      ../dist/configure --prefix="$out" --libdir="$out/lib/amd64" $cfg --enable-cxx --enable-compat185 > "$W/cfg.log" 2>&1 || fails configure . "$W/cfg.log"
      grep -E '^checking for mutexes' "$W/cfg.log" >&2
      gmake -j16 > "$W/make.log" 2>&1 || fails make 'error' "$W/make.log"
      # region signature of this configure (dist/env_sig_print.sh; Linux/gcc default is 0x841f4ea8)
      sig=$(CC="$CC" BUILD_DIR="$PWD" sh ../dist/env_sig_print.sh ..)
      echo "REGION-SIGNATURE $sig" >&2
      # ---- the release's own tests: `make test` (cutest), test/db's runners + the manifest gate, nixpkgs' examples
      gmake cutest > "$W/cutest-make.log" 2>&1 || fails make-cutest 'error' "$W/cutest-make.log"
      ./cutest > "$W/cutest.log" 2>&1 || fails cutest 'Fail|FAIL|fail' "$W/cutest.log"
      LIBDB_RESULTS_DIR="$W/res" sh ../test/db/run_all.sh > "$W/db.log" 2>&1 || fails test/db 'FAILED|FAIL' "$W/db.log"
      sh ../test/check_manifest.sh --tier db "$W/res" > "$W/manifest.log" 2>&1 || fails manifest-db . "$W/manifest.log"
      sh ../test/check_manifest.sh --tier tcl "$W/res" >> "$W/manifest.log" 2>&1 || fails manifest-tcl . "$W/manifest.log"
      grep -E 'SKIP' "$W/db.log" >&2 || true
      echo "TESTS: $(grep -c ' pass$' "$W/res/db.results") db + $(grep -c ' pass$' "$W/res/tcl.results") tcl pass; cutest: $(grep -cE '^Finished suite' "$W/cutest.log") suites" >&2
      gmake examples_c examples_cxx > "$W/ex.log" 2>&1 || fails examples 'error' "$W/ex.log"
      ${chk ''printf 'hello\nworld\n' | ./ex_access'' "^hello : olleh$"}
      ${chk ''printf 'hello\nworld\n' | ./excxx_access'' "^world : dlrow$"}
      gmake install > "$W/install.log" 2>&1 || fails install . "$W/install.log"
      rm -rf "$out/docs"; ${dropDocs}
      # ---- the installed library: soname, version, and a smoke test (env, 10k put/get, close, reopen, verify)
      /usr/bin/elfdump -d "$out/lib/amd64/libdb-2026.0.so" | grep -q 'SONAME.*libdb-2026.0.so' || { echo "FATAL: libdb SONAME" >&2; exit 1; }
      ${chk ''"$out/bin/db_verify" -V'' "libdb 2026\\.10\\.7\\.2"}
      $CC -I"$out/include" -o "$W/smoke" ${./libdb-smoke.c} -L"$out/lib/amd64" -ldb
      mkdir "$W/env"; "$W/smoke" "$W/env" > "$W/smoke.log" 2>&1 || fails smoke . "$W/smoke.log"
      cat "$W/smoke.log" >&2
      grep -qx 'reopen 10000' "$W/smoke.log" && grep -qx 'verify ok' "$W/smoke.log" || fails smoke-output . "$W/smoke.log"
      grep -qx "library signature $sig" "$W/smoke.log" || fails "library signature != env_sig_print $sig" signature "$W/smoke.log"
      "$out/bin/db_verify" -h "$W/env" smoke.db >&2
      # negative control: the same db_verify must FAIL on a copy with a page overwritten (else the check above proves nothing)
      cp "$W/env/smoke.db" "$W/bad.db"; printf 'XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX' | dd of="$W/bad.db" bs=1 seek=12300 conv=notrunc 2>/dev/null
      if "$out/bin/db_verify" "$W/bad.db" > "$W/bad.log" 2>&1; then fails 'db_verify passed a corrupted file' . "$W/bad.log"; fi
      echo "NEGCTL: db_verify rejects the corrupted copy: $(head -1 "$W/bad.log")" >&2
    '';
  } // { meta = {
    description = "libdb, the community Berkeley DB fork (LTS): embedded key/value database, C and C++ APIs";
    homepage = "https://github.com/berkeleydb/libdb";
    license = { spdxId = "Sleepycat"; fullName = "Sleepycat License"; url = "https://spdx.org/licenses/Sleepycat.html"; free = true; redistributable = true; };
  }; };
  berkeleydb = libdb;   # the old attr name (Oracle 5.3.28 lived in packages.nix), so nothing downstream renames
}
