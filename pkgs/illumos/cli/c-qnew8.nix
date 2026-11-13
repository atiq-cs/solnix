# cli/c-qnew8.nix -- cmake leaves of the x86 queue (qnew8 lane, 2026-11-13; idle1's byname.tsv pool, every nixpkgs input already
# served or on main, ranked as RANKING.md): each attr's drv pname and version are the queue job's (pname, target), so the builders'
# eval match (solnix-builder.sh eplan) turns the job into a build. A new file, so no served drv moves; x86 only (null gtkMeson on
# aarch64 drops it), as c-qnew.nix. Store-only builds (nativeTools), each with an in-build check that runs it on real input. Sources,
# patches and flags are nixpkgs f4a03c0's, pinned by sha256 (equal to nixpkgs' flat or NAR hash); where a recipe departs from
# nixpkgs, the comment says why.
{ base, mkSrcPkg, world, chk, hostTools, cmake, perl, flex, bison, gnupatch, utf8cpp, gtest, gtkMeson, ... }:
let
  inherit (base) zlib openssl;
  fetch = url: sha256: import <nix/fetchurl.nix> { inherit url sha256; };
  gh = path: sha256: { url = "https://github.com/${path}"; inherit sha256; };
  # cmake projects: the store cmake, store prefixes only, -j from --cores (c-qnew6.nix's cmakeB)
  cmakeB = extra: ''
    cmake -S . -B _b -DCMAKE_INSTALL_PREFIX="$out" -DCMAKE_INSTALL_LIBDIR=lib/amd64 -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_SKIP_RPATH=ON -DCMAKE_IGNORE_PREFIX_PATH="/usr;/usr/local;/opt" \
      -DCMAKE_IGNORE_PATH="/usr/lib/64;/usr/lib/amd64;/lib/64" ${extra} >&2
    cmake --build _b -j''${NIX_BUILD_CORES:-4} >&2; cmake --install _b >&2
  '';
  # a C (or C++) test program against the just-installed library: <src> <link flags>
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
in {
  # libitl (LGPL-2.1-only): the Islamic Tools and Libraries (prayer times, Hijri dates), cmake, as nixpkgs (its cmake_minimum_required
  # 3.10). The check converts a Gregorian date to Hijri: 2024-03-11 is 1 Ramadan 1445 (Umm al-Qura).
  libitl = mkSrcPkg {
    pname = "libitl"; version = "0.1.8-unstable-2024-05-26";
    src = gh "arabeyes-org/ITL/archive/07de1851722d0818d1f981df234e1b585eb60e05.tar.gz" "2642e87d8e0d5f1f930a55e36a59eac48b5fac534c6ee39f9d88066dcb70b495";
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${anchor "CMakeLists.txt" 1 "cmake_minimum_required(VERSION 2.6)"}
      sed -i 's/cmake_minimum_required(VERSION 2.6)/cmake_minimum_required(VERSION 3.10)/' CMakeLists.txt
      ${cmakeB ""}
      ${tprog ''#include <itl/hijri.h>
#include <stdio.h>
int main(void){ sDate h; G2H(&h, 11, 3, 2024); printf("ok %d %d %d\n", h.year, h.month, h.day); return 0; }'' "-litl -lm"}
      ${chk ''"$W/t"'' "^ok 1445 9 1$"}
    '';
  };

  # libebml (LGPL-2.1): the EBML parser under Matroska (libmatroska, mkvtoolnix), shared, cmake, on the store utf8cpp (nixpkgs: utf8cpp
  # in nativeBuildInputs; without it cmake FetchContent's a git clone). The check writes an EBML element and reads it back.
  libebml = mkSrcPkg {
    pname = "libebml"; version = "1.4.7";
    src = gh "Matroska-Org/libebml/archive/release-1.4.7.tar.gz" "c55c5528e7510bc41b574dcac47bc6e3503fb3b9e78ad8c42541bf07d5ed71a9";
    deps = [ world ]; linkDeps = [ utf8cpp ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DBUILD_SHARED_LIBS=YES"}
      grep -q "^utf8cpp_DIR:PATH=${utf8cpp}/" _b/CMakeCache.txt || { echo "FATAL: libebml: not the store utf8cpp" >&2; grep utf8cpp _b/CMakeCache.txt >&2; exit 1; }
      ${tprogxx ''#include <ebml/EbmlVersion.h>
#include <ebml/MemIOCallback.h>
#include <ebml/EbmlUInteger.h>
#include <cstdio>
using namespace libebml;
int main(){ MemIOCallback m; m.write("\x1a\x45\xdf\xa3", 4); m.setFilePointer(0); unsigned char b[4]; m.read(b, 4);
std::printf("ok %s %02x%02x\n", EbmlCodeVersion.c_str(), b[0], b[3]); return 0; }'' "-L$out/lib/amd64 -lebml -Wl,-R,$out/lib/amd64"}
      ${chk ''"$W/t"'' "^ok 1\\.4\\.7 1aa3$"}
    '';
  };

  # qdldl (Apache-2.0): a free LDL' factorisation for quasi-definite sparse systems (OSQP), shared + static, cmake, as nixpkgs: its
  # include-dir fix ($<INSTALL_PREFIX>/ dropped from the INSTALL_INTERFACE path). The check factors a 2x2 system and solves it.
  qdldl = mkSrcPkg {
    pname = "qdldl"; version = "0.1.9";
    src = gh "osqp/qdldl/archive/refs/tags/v0.1.9.tar.gz" "7d1285b2db15cf2730dc83b3d16ed28412f558591108cca4f28d4438bf72ceed";
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${anchor "CMakeLists.txt" 2 "$<INSTALL_PREFIX>/\${CMAKE_INSTALL_INCLUDEDIR}"}
      sed -i 's|$<INSTALL_PREFIX>/''${CMAKE_INSTALL_INCLUDEDIR}|''${CMAKE_INSTALL_INCLUDEDIR}|' CMakeLists.txt
      ${cmakeB ""}
      ${tprog ''#include <qdldl/qdldl.h>
#include <stdio.h>
/* A = [4 1; 1 3] (upper triangle, CSC), b = [1 2]: x = [1/11 7/11] */
int main(void){ QDLDL_int Ap[] = { 0, 1, 3 }, Ai[] = { 0, 0, 1 }, work[2], Lnz[2], etree[2], Lp[3], Li[1], iwork[6];
QDLDL_float Ax[] = { 4, 1, 3 }, Lx[1], D[2], Dinv[2], fwork[2], x[] = { 1, 2 }; QDLDL_bool bwork[2];
QDLDL_etree(2, Ap, Ai, work, Lnz, etree); QDLDL_factor(2, Ap, Ai, Ax, Lp, Li, Lx, D, Dinv, Lnz, etree, bwork, iwork, fwork);
QDLDL_solve(2, Lp, Li, Lx, Dinv, x); printf("ok %.4f %.4f\n", x[0] * 11, x[1] * 11); return 0; }'' "-I$out/include/qdldl -lqdldl"}
      ${chk ''"$W/t"'' "^ok 1\\.0000 7\\.0000$"}
    '';
  };

  # nsplist (MIT): a parser for NeXTSTEP property lists (plistcpp, xcbuild), cmake, as nixpkgs: its lexer regenerated with the store
  # flex from NSPlistLexer.l less its 16-line licence header, and cmake_minimum_required 3.10. A static library, as upstream. The check
  # parses a dictionary.
  nsplist = mkSrcPkg {
    pname = "nsplist"; version = "0-unstable-2017-04-11";
    src = gh "matthewbauer/NSPlist/archive/713decf06c1ef6c39a707bc99eb45ac9925f2b8a.tar.gz" "29dd0da868d17e3b7a13bd41e27624ef3db44b0705593242557848db6bef9bfd";
    deps = [ world ]; nativeTools = [ cmake flex ] ++ hostTools;
    build = ''
      ${anchor "CMakeLists.txt" 1 "cmake_minimum_required(VERSION 2.6)"}
      sed -i 's/cmake_minimum_required(VERSION 2.6)/cmake_minimum_required(VERSION 3.10)/' CMakeLists.txt
      tail --lines=+17 src/NSPlistLexer.l > "$W/lexer.l"; flex -o src/NSPlistLexer.cpp "$W/lexer.l"
      ${cmakeB ""}
      ${tprogxx ''#include <NSPlist.h>
#include <cstdio>
#include <string>
int main(){ NSPlistValue *v = nullptr; bool r = loadPlistFromBuffer("{ a = 1; b = (x, y); }", v);
NSPlistDictionary *d = r ? NSPlistDictionary::cast(v) : nullptr; std::printf("ok %d %d\n", (int)r, d ? (int)d->m_dict.size() : -1); return 0; }'' "-L$out/lib -lNSPlist"}
      ${chk ''"$W/t"'' "^ok 1 2$"}
    '';
  };

  # ---- b1 part 2 ---------------------------------------------------------------------------------------------------------------
  # uriparser (BSD-3-Clause): an RFC 3986 URI parsing library (shared, uriparse CLI), cmake, as nixpkgs: docs off, its gtest suite on
  # the store gtest (doCheck; ctest runs it). The check parses a URI and resolves a relative reference against it.
  uriparser = mkSrcPkg {
    pname = "uriparser"; version = "1.0.2";
    src = gh "uriparser/uriparser/archive/refs/tags/uriparser-1.0.2.tar.gz" "2dadd117a27919db41b84dff1ec7e3347fae8e09cfbb868505f2ff44287b57bf";
    deps = [ world ]; linkDeps = [ gtest ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DURIPARSER_BUILD_DOCS=OFF -DURIPARSER_BUILD_TESTS=ON -DGTest_DIR=${gtest}/lib/amd64/cmake/GTest"}
      ( cd _b && LD_LIBRARY_PATH="$PWD:${gtest}/lib/amd64" ctest -j''${NIX_BUILD_CORES:-4} --output-on-failure ) >&2
      ${tprog ''#include <uriparser/Uri.h>
#include <stdio.h>
#include <stdlib.h>
int main(void){ UriUriA base, rel, res; const char *e; char out[256];
if (uriParseSingleUriA(&base, "http://a/b/c/d;p?q", &e) || uriParseSingleUriA(&rel, "../g", &e)) return 1;
if (uriAddBaseUriA(&res, &rel, &base) || uriToStringA(out, &res, sizeof out, NULL)) return 1;
printf("ok %s %.*s\n", out, (int)(base.hostText.afterLast - base.hostText.first), base.hostText.first); return 0; }'' "-luriparser"}
      ${chk ''"$W/t"'' "^ok http://a/b/g a$"}
      ${chk ''"$out/bin/uriparse" "https://solnix.io:8443/x?y#z"'' "8443"}
    '';
  };
}
