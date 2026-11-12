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

  # conduit (BSD-3-Clause, LLNL): simplified data exchange for HPC simulations (a C++ hierarchical data model, relay I/O, blueprint mesh
  # conventions), cmake on its bundled BLT, shared, serial (no MPI, no Fortran, no Python), as nixpkgs; its bundled yyjson, libyaml,
  # libb64, fmt and civetweb. Source: the release asset with BLT (= nixpkgs' fetchFromGitHub fetchSubmodules tree, by NAR hash).
  # Upstream's ctest suite is off (hundreds of gtest programs); the check below saves and reloads a node and verifies a blueprint mesh.
  conduit = mkSrcPkg {
    pname = "conduit"; version = "0.9.9";
    src = { url = "https://github.com/llnl/conduit/releases/download/v0.9.9/conduit-v0.9.9-src-with-blt.tar.gz";
            sha256 = "53cb6258de9b846ccc5a05205db36e88209fe45c5b786a1f0c0ae63a4302148b"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    # libconduit_relay's DWARF names $out (CONDUIT_RELAY_SOURCE_DIR below): split-debug-od.sh keeps that .debug uncompressed, or
    # --check DIFFERS in -debug only (one .debug_info, measured on the qnew host; glib's case)
    build = ''
      cd src
      # conduit::about() and conduit_config.h record CMAKE_CXX_COMPILER, which is the build dir's wrapper (/var/tmp/srcpkg-<key>/bin64/g++):
      # the compiler by name instead, as every other *-config here records it
      grep -qx '#define CONDUIT_CPP_COMPILER "@CMAKE_CXX_COMPILER@"' libs/conduit/conduit_config.h.in || { echo "FATAL: conduit compiler anchor" >&2; exit 1; }
      sed -i 's|^#define CONDUIT_CPP_COMPILER "@CMAKE_CXX_COMPILER@"$|#define CONDUIT_CPP_COMPILER "g++"|' libs/conduit/conduit_config.h.in
      # illumos <sys/int_types.h> makes int8_t plain char (_CHAR_IS_SIGNED, as Solaris always has), and conduit_int8 is signed char:
      # conduit's one std::int8_t use is this static_assert: it also accepts that layout (int8_t = char, char signed, conduit_int8 =
      # signed char, the same 1-byte signed type). A consumer passing int8_t data gets conduit's char overloads, as on any Solaris.
      f=libs/conduit/conduit_data_type.cpp
      grep -qx 'static_assert(std::is_same<conduit_int8, std::int8_t>::value,' $f || { echo "FATAL: conduit int8 assert anchor" >&2; exit 1; }
      sed -i 's/^static_assert(std::is_same<conduit_int8, std::int8_t>::value,$/static_assert(std::is_same<conduit_int8, std::int8_t>::value || (std::is_same<std::int8_t, char>::value \&\& std::is_signed<char>::value \&\& std::is_same<conduit_int8, signed char>::value),/' $f
      [ "$(grep -c 'std::is_same<std::int8_t, char>::value && std::is_signed<char>::value' $f)" = 1 ] || { echo "FATAL: conduit int8 assert edit" >&2; exit 1; }
      # relay records its SOURCE dir (the build dir) in conduit_relay_config.h and libconduit_relay, and looks there for web_clients/
      # and scripts/ before the install prefix: the installed share/conduit instead (web_clients is there; entangle falls back to bin/)
      grep -q '^convert_to_native_escaped_file_path(''${CMAKE_CURRENT_SOURCE_DIR}$' libs/relay/CMakeLists.txt || { echo "FATAL: conduit relay source-dir anchor" >&2; exit 1; }
      sed -i 's|^convert_to_native_escaped_file_path(''${CMAKE_CURRENT_SOURCE_DIR}$|convert_to_native_escaped_file_path(''${CMAKE_INSTALL_PREFIX}/share/conduit|' libs/relay/CMakeLists.txt
      # illumos <sys/types.h> declares a global `typedef short index_t` (a VM type), which makes conduit's index_t ambiguous in every .cpp
      # that has `using namespace conduit` (blueprint: "reference to 'index_t' is ambiguous", measured): <sys/types.h> is force-included
      # first with that one name renamed, so its include guard keeps the global one out of conduit's own sources. Not in the headers it
      # installs: inside namespace conduit the name is conduit's.
      printf '%s\n' '#define index_t illumos_sys_index_t' '#include <sys/types.h>' '#undef index_t' > "$W/idx.h"
      # illumos keeps socket(3SOCKET) and friends in libsocket/libnsl (relay's civetweb web server)
      ${cmakeB ''-DCMAKE_CXX_FLAGS="-include $W/idx.h" -DENABLE_TESTS=OFF -DENABLE_DOCS=OFF -DENABLE_MPI=OFF -DENABLE_FORTRAN=OFF -DENABLE_PYTHON=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_SHARED_LINKER_FLAGS="-lsocket -lnsl" -DCMAKE_EXE_LINKER_FLAGS="-lsocket -lnsl"''}
      # upstream installs its entangle helper (python, no #! line) into bin/ with install(FILES), 0644 (gate B7); relay runs it as
      # `python <install_prefix>/bin/conduit_relay_entangle.py`, so it stays there, with its exec bit
      chmod 555 "$out/bin/conduit_relay_entangle.py"
      grep -qx "#define CONDUIT_RELAY_SOURCE_DIR  \"$out/share/conduit\"" "$out/include/conduit/conduit_relay_config.h" || { echo "FATAL: conduit relay source dir" >&2; grep SOURCE_DIR "$out/include/conduit/conduit_relay_config.h" >&2; exit 1; }
      ! grep -rlF "$W/" "$out" 2>/dev/null | grep . || { echo "FATAL: conduit: build dir in a shipped file" >&2; exit 1; }
      cat > "$W/t.cc" <<'TPROG'
#include <conduit.hpp>
#include <conduit_relay.hpp>
#include <conduit_blueprint.hpp>
#include <iostream>
int main(){ conduit::Node n; n["os"] = "solnix"; n["v"] = 42; conduit::relay::io::save(n, "t.yaml");
conduit::Node y; conduit::relay::io::load("t.yaml", y); conduit::Node m, info; conduit::blueprint::mesh::examples::braid("hexs", 3, 3, 3, m);
std::cout << "ok " << CONDUIT_VERSION << " " << y["os"].as_string() << " " << y["v"].to_int64() << " " << conduit::blueprint::mesh::verify(m, info) << std::endl; return 0; }
TPROG
      "$CXX" -std=c++14 -I"$out/include/conduit" "$W/t.cc" -L"$out/lib" -lconduit_blueprint -lconduit_relay -lconduit -Wl,-R,"$out/lib" -o "$W/t"
      ${chk ''cd "$W" && ./t'' "^ok 0\\.9\\.9 solnix 42 1$"}
      ${chk ''"$out/bin/conduit_relay_io_ls" "$W/t.yaml"'' "number of steps = "}
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
