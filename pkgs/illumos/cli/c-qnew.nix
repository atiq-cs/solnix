# cli/c-qnew.nix -- new recipes for top-level x86 queue names solnix lacked (qnew lane, 2026-11-11): each attr's drv pname and version
# are the queue job's (pname, target), so the builders' eval match (solnix-builder.sh eplan) turns the job into a build. A new file, so
# no served drv moves. Store-only builds (nativeTools), each with an in-build check that runs it on real input. Every source is the one
# nixpkgs f4a03c0 fetches (same tree or file hash), pinned by sha256.
{ base, mkSrcPkg, world, chk, hostTools, cmake, python3, flex, bison, gnum4, fmt, spdlog, sqlite, gtkMeson, ... }:
let
  inherit (base) zlib;
  inherit (gtkMeson) gperf;
  # cmake projects: the store cmake, store prefixes only (c-recipes4.nix's cmakeB, but -j from --cores: WAVE7-NOTES "cmakeB ignores
  # the host's --cores")
  cmakeB = extra: ''
    cmake -S . -B _b -DCMAKE_INSTALL_PREFIX="$out" -DCMAKE_INSTALL_LIBDIR=lib/amd64 -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_SKIP_RPATH=ON -DCMAKE_IGNORE_PREFIX_PATH="/usr;/usr/local;/opt" \
      -DCMAKE_IGNORE_PATH="/usr/lib/64;/usr/lib/amd64;/lib/64" ${extra} >&2
    cmake --build _b -j''${NIX_BUILD_CORES} >&2; cmake --install _b >&2
  '';
  # a C test program against the just-installed library: <src> <link flags>
  tprog = src: libs: ''
    cat > "$W/t.c" <<'TPROG'
${src}
TPROG
    "$CC" -I"$out/include" "$W/t.c" -L"$out/lib/amd64" ${libs} -Wl,-R,"$out/lib/amd64" -o "$W/t"
  '';
in {
  # libid3tag (GPL-2.0-or-later): ID3 tag reading and writing (mad, audacity, sox), Tenacity's cmake fork, shared, on zlib (compressed
  # frames) and gperf at build time, as nixpkgs. Source: the 0.16.4 release asset (nixpkgs' codeberg archive plus .github: same tree
  # otherwise). The check writes a title frame that zlib compresses, renders the tag with its CRC, and parses it back.
  libid3tag = mkSrcPkg {
    pname = "libid3tag"; version = "0.16.4";
    src = { url = "https://codeberg.org/tenacityteam/libid3tag/releases/download/0.16.4/id3tag-0.16.4-source.tar.gz";
            sha256 = "8b6bc96016f6ab3a52b753349ed442e15181de9db1df01884f829e3d4f3d1e78"; };
    deps = [ world zlib ]; nativeTools = [ cmake gperf ] ++ hostTools;
    build = ''
      ${cmakeB "-DBUILD_SHARED_LIBS=ON -DZLIB_ROOT=${zlib} -DZLIB_LIBRARY=${zlib}/lib/amd64/libz.so -DZLIB_INCLUDE_DIR=${zlib}/include"}
      grep -q "^GPERF:FILEPATH=${gperf}/bin/gperf$" _b/CMakeCache.txt || { echo "FATAL: libid3tag: gperf not from the store" >&2; grep GPERF _b/CMakeCache.txt >&2; exit 1; }
      ${tprog ''#include <id3tag.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(void){ char s[301]; memset(s, 's', 300); s[300] = 0;
struct id3_tag *t = id3_tag_new(); struct id3_frame *f = id3_frame_new(ID3_FRAME_TITLE); if (!t || !f) return 1;
id3_ucs4_t *u = id3_latin1_ucs4duplicate((id3_latin1_t const *)s);
if (id3_field_settextencoding(id3_frame_field(f, 0), ID3_FIELD_TEXTENCODING_ISO_8859_1) || id3_field_setstrings(id3_frame_field(f, 1), 1, &u)
    || id3_tag_attachframe(t, f)) return 2;
id3_length_t n = id3_tag_render(t, 0); id3_byte_t *b = malloc(n); n = id3_tag_render(t, b);
struct id3_tag *p = id3_tag_parse(b, n); if (!p) return 3; struct id3_frame *g = id3_tag_findframe(p, ID3_FRAME_TITLE, 0); if (!g) return 4;
id3_latin1_t *l = id3_ucs4_latin1duplicate(id3_field_getstrings(id3_frame_field(g, 1), 0));
printf("ok %s %d %d\n", id3_version, n < 300, strcmp((char *)l, s) == 0 && (g->flags & ID3_FRAME_FLAG_COMPRESSION) != 0); return 0; }'' "-lid3tag"}
      ${chk ''"$W/t"'' "^ok ID3 Tag Library 0\\.16\\.4 1 1$"}
      grep -qx "prefix=$out" "$out/lib/amd64/pkgconfig/id3tag.pc" && grep -Eqx 'libdir=[$][{]prefix[}]/lib/amd64' "$out/lib/amd64/pkgconfig/id3tag.pc" \
        || { echo "FATAL: libid3tag: id3tag.pc libdir" >&2; cat "$out/lib/amd64/pkgconfig/id3tag.pc" >&2; exit 1; }
    '';
  };

  # doxygen (GPL-2.0-only): the source documentation generator, cmake, on main's spdlog, fmt and sqlite (use_sys_*), flex, bison and the
  # store python3 at build time, as nixpkgs (with its C++20 / char8_t JavaCC switch; no GUI, no examples output). TZ=UTC: the man page's
  # date is cmake's string(TIMESTAMP) of SOURCE_DATE_EPOCH in local time, and illumos takes the zone from the host's /etc/default/init
  # when TZ is unset (WAVE7-NOTES "A build's local time zone"). The check documents a C header and reads the XML doxygen writes.
  doxygen = mkSrcPkg {
    pname = "doxygen"; version = "1.17.0";
    src = { url = "https://codeload.github.com/doxygen/doxygen/tar.gz/refs/tags/Release_1_17_0";
            sha256 = "28199ea88989fc56e302c927ef979596fe9247dd231e767ba6edcdbaa49f78aa"; };
    # gnum4: flex execs m4 from PATH (-P), and the world's is SVR4 ("bad option: -P", measured); nixpkgs' flex propagates GNU m4
    deps = [ world spdlog fmt sqlite ]; nativeTools = [ cmake python3 flex bison gnum4 ] ++ hostTools;
    build = ''
      export TZ=UTC
      grep -qF 'JAVACC_CHAR_TYPE=\"unsigned char\"' CMakeLists.txt && grep -q 'CMAKE_CXX_STANDARD 17' CMakeLists.txt || { echo "FATAL: doxygen C++ std anchors" >&2; exit 1; }
      sed -i 's/JAVACC_CHAR_TYPE=\\"unsigned char\\"/JAVACC_CHAR_TYPE=\\"char8_t\\"/; s/CMAKE_CXX_STANDARD 17/CMAKE_CXX_STANDARD 20/' CMakeLists.txt
      ! grep -q 'CMAKE_CXX_STANDARD 17' CMakeLists.txt && grep -qF 'JAVACC_CHAR_TYPE=\"char8_t\"' CMakeLists.txt || { echo "FATAL: doxygen C++20 switch" >&2; exit 1; }
      # GIT_EXECUTABLE pinned to a non-path: libversion's git_watcher only runs it when the tree has a .git (an archive has none)
      # illumos iconv(3C) takes const char ** unless _XPG6, so FindIconv's libc probe (char **) and src/portable_c.c (a char ** cast) hit
      # gcc 15's incompatible-pointer-types error: a warning, as libass and lame (c-recipes4.nix); the two pointer types are one ABI
      ${cmakeB "-Duse_sys_spdlog=ON -Duse_sys_fmt=ON -Duse_sys_sqlite3=ON -DGIT_EXECUTABLE=/nonexistent/git -DCMAKE_C_FLAGS=-Wno-error=incompatible-pointer-types"}
      grep -q "^Iconv_IS_BUILT_IN:INTERNAL=1$" _b/CMakeCache.txt || { echo "FATAL: doxygen: iconv is not libc's" >&2; grep Iconv _b/CMakeCache.txt >&2; exit 1; }
      grep -q "^spdlog_DIR:PATH=${spdlog}/" _b/CMakeCache.txt && grep -q "^fmt_DIR:PATH=${fmt}/" _b/CMakeCache.txt && grep -Eq "^SQLite3_LIBRARY(_RELEASE)?:FILEPATH=${sqlite}/" _b/CMakeCache.txt \
        && grep -q "^FLEX_EXECUTABLE:FILEPATH=${flex}/bin/flex$" _b/CMakeCache.txt && grep -q "^BISON_EXECUTABLE:FILEPATH=${bison}/bin/bison$" _b/CMakeCache.txt \
        || { echo "FATAL: doxygen: a dep not from the store" >&2; grep -E '^(spdlog_DIR|fmt_DIR|SQLite3_|FLEX_EXE|BISON_EXE)' _b/CMakeCache.txt >&2; exit 1; }
      ${chk ''"$out/bin/doxygen" --version'' "^1\\.17\\.0$"}
      grep -q '^\.TH DOXYGEN "1" "01-01-1980" "doxygen 1\.17\.0"' "$out/share/man/man1/doxygen.1" || { echo "FATAL: doxygen man date" >&2; head -1 "$out/share/man/man1/doxygen.1" >&2; exit 1; }
      mkdir "$W/dx"; cd "$W/dx"
      printf '/** @file t.h */\n/** @brief Adds two solnix numbers. */\nint solnix_add(int a, int b);\n' > t.h
      printf 'INPUT = t.h\nOUTPUT_DIRECTORY = out\nGENERATE_HTML = NO\nGENERATE_LATEX = NO\nGENERATE_XML = YES\nQUIET = YES\n' > Doxyfile
      ${chk ''"$out/bin/doxygen" Doxyfile && grep -h "Adds two solnix numbers" out/xml/t_8h.xml'' "Adds two solnix numbers\\."}
      cd "$SRC"
    '';
  };
}
