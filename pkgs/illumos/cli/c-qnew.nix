# cli/c-qnew.nix -- new recipes for top-level x86 queue names solnix lacked (qnew lane, 2026-11-11): each attr's drv pname and version
# are the queue job's (pname, target), so the builders' eval match (solnix-builder.sh eplan) turns the job into a build. A new file, so
# no served drv moves. Store-only builds (nativeTools), each with an in-build check that runs it on real input. Every source is the one
# nixpkgs f4a03c0 fetches (same tree or file hash), pinned by sha256.
{ base, mkSrcPkg, world, chk, hostTools, cmake, python3, flex, bison, fmt, spdlog, sqlite, gtkMeson, ... }:
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
}
