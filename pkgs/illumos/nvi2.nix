# pkgs/illumos/nvi2.nix -- nvi2 (github.com/lichray/nvi2), the maintained fork of
# Berkeley nvi, built from source with mk-src-pkg (base-src.nix calls it).
#
# solnix's default vi: installs bin/nvi with vi/ex/view links to it (nvi picks its
# mode from argv[0], as nixpkgs' nvi does), and man/vi.1 with nvi/ex/view links.
#
# NO CMAKE. Upstream builds with CMake, which is not in the from-source chain (a
# bare solnix system has none). The CMakeLists is mechanical, so this replays it:
#   * the generated headers are the same sed/awk one-liners its add_custom_command
#     rules run (PUBLIC: prototypes -> *_extern.h, options.awk, ex.awk, README ->
#     version.h);
#   * config.h holds what CMake's checks find on illumos (ncurses.h, term.h, no
#     libutil.h/pty.h), with ICONV_TRADITIONAL probed the way CMake probes it;
#   * the sources are CMake's lists: every .c under cl common ex vi, plus the
#     wide-char BSD regex (regcomp/regerror/regexec/regfree; engine.c is #included).
# Departures from the CMake build, and why:
#   * no -fstack-protector: gcc.lib ships no libssp, so it would NEED libssp.so.0
#     (the smartmontools failure in base-src.nix).
#   * HAVE_STRUCT_STAT_ST_MTIM is defined: CMake detects it but its config.h.in
#     never emits it, so upstream falls back to whole-second mtimes.
#   * GNU libiconv, not the illumos iconv: nvi always opens a "utf-16be"
#     converter from the locale codeset ("646" in the C locale), and the world has
#     no 64-bit iconv modules (see libiconv in base-src.nix).
#
# illumos fixups: <bitstring.h> (the CSRG bit macros) and <util.h> (an openpty
# shim over posix_openpt, for :script) are BSD headers illumos lacks, vendored from
# patches/. b64_ntop/b64_pton (recover.c) are in libresolv on illumos.
# The 1.85 dbopen() API comes from db1 (./db1.nix); Berkeley DB 5's compat185 is
# not a drop-in (its RECNO rejects nvi's record-0 append).
{ mkSrcPkg, ncurses, db1, libiconv }:

mkSrcPkg {
  pname = "nvi"; version = "2.2.2-unstable-2026-05-31";
  # lichray/nvi2 eea5df8b (2026-05-31), 5 commits past v2.2.2.
  src = { url = "https://github.com/lichray/nvi2/archive/eea5df8b71205df101f05125281c67be33e24a53.tar.gz";
          sha256 = "c6cdf038d213f75152d7adbef7a55802835826b056f571e3fb202f55eecc391b"; };
  deps = [ ncurses db1 libiconv ];
  build = ''
    cp ${./patches/bitstring.h} bitstring.h
    cp ${./patches/util.h} util.h
    mkdir -p build
    for d in cl common ex vi; do
      sed -n 's/^ \* PUBLIC: \(.*\)/\1/p' $d/*.c > "build/$d"_extern.h
    done
    awk -f common/options.awk common/options.c > build/options_def.h
    awk -f ex/ex.awk ex/ex_cmd.c > build/ex_def.h
    sed -n 's/^.*version \([^)]*)\).*/#define VI_VERSION "\1"/p' README > build/version.h
    grep -q '^#define VI_VERSION "2\.' build/version.h || { echo "FATAL: no VI_VERSION in README" >&2; exit 1; }
    sed -e 's,@vi_cv_path_msgcat@,/usr/share/vi/catalog/,' -e 's,@vi_cv_path_preserve@,/var/tmp/vi.recover/,' \
      files/pathnames.h.in > build/pathnames.h
    printf '%s\n' '#define USE_WIDECHAR 1' '#define USE_ICONV 1' '#define HAVE_NCURSES_H 1' \
      '#define HAVE_TERM_H 1' '#define HAVE_STRUCT_STAT_ST_MTIM 1' > build/config.h
    # CMake's ICONV_TRADITIONAL probe: does iconv(3) take a non-const char ** ?
    # A wrong answer cannot ship: conv.c then fails to compile (gcc 14 rejects
    # incompatible pointer types).
    printf '%s\n' '#include <iconv.h>' \
      'int main(void) { iconv_t c = 0; char *i = 0, *o = 0; size_t il = 0, ol = 0; iconv(c, &i, &il, &o, &ol); return 0; }' > build/iconvt.c
    if $CC -Werror -c build/iconvt.c -o build/iconvt.o; then echo '#define ICONV_TRADITIONAL 1' >> build/config.h; fi

    CF="-O2 -D_XOPEN_SOURCE_EXTENDED -D__REGEX_PRIVATE -Ibuild -I. -Iregex"
    objs=""
    for f in cl/*.c common/*.c ex/*.c vi/*.c regex/regcomp.c regex/regerror.c regex/regexec.c regex/regfree.c; do
      o="build/$(echo "$f" | tr / _).o"
      $CC $CF -c "$f" -o "$o" || { echo "FATAL: compile $f" >&2; exit 1; }
      objs="$objs $o"
    done
    $CC -o build/nvi $objs -lncursesw -ldb1 -liconv -lresolv

    mkdir -p "$out/bin" "$out/share/man/man1"
    cp build/nvi "$out/bin/nvi"
    for n in vi ex view; do ln -s nvi "$out/bin/$n"; done
    cp man/vi.1 "$out/share/man/man1/vi.1"
    for n in nvi ex view; do ln -s vi.1 "$out/share/man/man1/$n.1"; done

    # Edit smoke test, no LD_LIBRARY_PATH: a scripted ex session appends a line,
    # writes and quits; the file must hold exactly that line. This is the
    # operation a Berkeley-DB-5 build fails.
    unset LD_LIBRARY_PATH LD_LIBRARY_PATH_64 || true
    tf=$(mktemp /var/tmp/nvi-smoke.XXXXXX)
    printf 'a\nhello world\n.\nw\nq\n' | "$out/bin/ex" -s "$tf"
    [ "$(cat "$tf")" = "hello world" ] || { echo "FATAL: nvi edit smoke test; file holds:" >&2; cat "$tf" >&2; exit 1; }
    rm -f "$tf"
    grep -q 'Version 2\.2\.2 (' "$out/bin/nvi" || { echo "FATAL: nvi binary carries no 2.2.2 version string" >&2; exit 1; }
  '';
}
