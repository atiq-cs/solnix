# cli/c-qdeps.nix -- the shared leaves the x86 queue's image, font and doc names wait on (qdeps lane, 2026-11-12): libwebp, libtiff,
# lcms2, openjpeg, zeromq, cppzmq, libxslt, lua5_4. Each attr's drv pname and version are the queue job's (pname, target), so the
# builders' eval match (solnix-builder.sh eplan) turns the job into a build. A new file, so no served drv moves. Store-only builds
# (nativeTools), each with an in-build check that runs it on real input. Sources, patches and flags are nixpkgs f4a03c0's (the tree
# the queue's targets follow), pinned by sha256; where a recipe departs from it, the comment says why.
{ base, mkSrcPkg, world, chk, hostTools, autoreconfTools, autoreconf, cmake, gnupatch, libdeflate, lerc, giflib, gtkMeson, ... }:
let
  inherit (base) zlib libxml2 pkgconf;
  inherit (base.nixChain) xz zstd libsodium;
  libpng = gtkMeson.libpng; libjpeg-turbo = gtkMeson.libjpeg-turbo;
  fetch = url: sha256: import <nix/fetchurl.nix> { inherit url sha256; };
  # a file of nixpkgs f4a03c0's tree (a package's own patch), by its sha256
  npFile = p: sha256: fetch "https://raw.githubusercontent.com/NixOS/nixpkgs/f4a03c008967841f2a0b3cb7c436fc6fc31671f6/pkgs/${p}" sha256;
  gh = repo: tag: sha256: { url = "https://codeload.github.com/${repo}/tar.gz/refs/tags/${tag}"; inherit sha256; };
  # cmake projects: the store cmake, store prefixes only (c-qnew.nix's cmakeB: -j from --cores)
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
  # <cache var> <store prefix>: cmake found that dependency in the store, not elsewhere (a silent bundled/host fallback fails here)
  found = var: prefix: ''grep -Eq "^${var}(:[A-Z]+)?=${prefix}/" _b/CMakeCache.txt || { echo "FATAL: ${var} not from ${prefix}" >&2; grep -E "^${var}" _b/CMakeCache.txt >&2; exit 1; }'';
  # the build dir must not reach a shipped file
  noBuildDir = ''! grep -rlF "$W/" "$out" 2>/dev/null | grep . || { echo "FATAL: build dir in a shipped file" >&2; exit 1; }'';
in rec {
  # libwebp (BSD-3-Clause): the WebP image codec and its tools (cwebp, dwebp, gif2webp, img2webp, webpinfo, webpmux), cmake, shared, on
  # libpng, libjpeg-turbo and giflib, nixpkgs' flags and its endianness patch. nixpkgs' libtiff links libwebp.override { tiffSupport =
  # false; } (libwebp's TIFF input reads libtiff: a cycle), and this is that build, so libtiff below links the libwebp the queue serves.
  # shortcut: no TIFF input in cwebp/img2webp, nixpkgs' libtiff cycle; a second libwebp attr when a queue job asks for tiffSupport.
  libwebp = mkSrcPkg {
    pname = "libwebp"; version = "1.6.0";
    src = gh "webmproject/libwebp" "v1.6.0" "93a852c2b3efafee3723efd4636de855b46f9fe1efddd607e1f42f60fc8f2136";
    deps = [ world libpng libjpeg-turbo giflib zlib ]; nativeTools = [ cmake gnupatch ] ++ hostTools;
    build = ''
      patch -p1 < ${fetch "https://github.com/webmproject/libwebp/commit/0e5f4ee3deaba5c4381877764005d981f652791f.patch" "d2caec443243cce40e89d824fd0b0e5ce77b260f8999673005e15f431162b2f6"}
      # TIFF off by cmake's own switch (find_package never runs), as the override above
      ${cmakeB "-DBUILD_SHARED_LIBS=ON -DWEBP_USE_THREAD=ON -DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_IMG2WEBP=ON -DWEBP_BUILD_GIF2WEBP=ON -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_EXTRAS=OFF -DWEBP_ENABLE_SWAP_16BIT_CSP=OFF -DWEBP_BUILD_LIBWEBPMUX=ON -DCMAKE_DISABLE_FIND_PACKAGE_TIFF=ON -DCMAKE_DISABLE_FIND_PACKAGE_OpenGL=ON"}
      ${found "PNG_LIBRARY_RELEASE" libpng} ; ${found "JPEG_LIBRARY_RELEASE" libjpeg-turbo} ; ${found "GIF_LIBRARY" giflib}
      ! grep -q "^TIFF_LIBRARY" _b/CMakeCache.txt || { echo "FATAL: libwebp found a libtiff" >&2; exit 1; }
      ${chk ''"$out/bin/cwebp" -version'' "^1\\.6\\.0"}
      # PNG -> lossless WebP -> PNG: the pixels survive (the codec, the png reader/writer and the tools in one round trip)
      printf 'P6\n4 2\n255\n' > "$W/a.ppm"; printf '\377\000\000\000\377\000\000\000\377\377\377\377\000\000\000\200\200\200\001\002\003\375\376\377' >> "$W/a.ppm"
      "$out/bin/cwebp" -quiet -lossless "$W/a.ppm" -o "$W/a.webp" && "$out/bin/dwebp" "$W/a.webp" -ppm -o "$W/b.ppm" >&2
      cmp "$W/a.ppm" "$W/b.ppm" || { echo "FATAL: libwebp lossless round trip" >&2; exit 1; }
      ${chk ''"$out/bin/webpinfo" "$W/a.webp"'' "Width: +4$"}
      ${tprog ''#include <webp/decode.h>
#include <webp/encode.h>
#include <webp/mux.h>
#include <stdio.h>
int main(void){ unsigned char px[4 * 4 * 3]; for (int i = 0; i < 48; i++) px[i] = (unsigned char)(i * 5); uint8_t *o; size_t n = WebPEncodeLosslessRGB(px, 4, 4, 12, &o);
int w, h; uint8_t *d = WebPDecodeRGB(o, n, &w, &h); int same = d && w == 4 && h == 4; for (int i = 0; same && i < 48; i++) same = d[i] == px[i];
printf("ok %x %x %d\n", WebPGetDecoderVersion(), WebPGetMuxVersion(), same); return 0; }'' "-lwebp -lwebpmux -lsharpyuv"}
      ${chk ''"$W/t"'' "^ok 10600 10600 1$"}
      ${noBuildDir}
    '';
  };

  # zeromq (MPL-2.0): libzmq, the ZeroMQ messaging library, cmake, shared, with CURVE on libsodium, no drafts, nixpkgs' three patches
  # and its CMAKE_INSTALL_FULL_* postPatch. Source: the 4.3.5 release tarball (the same code as nixpkgs' tag archive, plus the generated
  # docs), whose doc/*.3 and *.7 are the asciidoc man pages nixpkgs builds: installed from there (solnix has no asciidoc). Poller: devpoll,
  # cmake's own pick on illumos (autotools refuses epoll on Solaris; cmake finds no epoll header and takes /dev/poll). illumos keeps the
  # socket API in libsocket/libnsl (phase3 overlay: zeromq's perf tools failed without them).
  zeromq = mkSrcPkg {
    pname = "zeromq"; version = "4.3.5";
    src = { url = "https://github.com/zeromq/libzmq/releases/download/v4.3.5/zeromq-4.3.5.tar.gz"; sha256 = "6653ef5910f17954861fe72332e68b03ca6e4d9c7160eb3a8de5a5a913bfab43"; };
    deps = [ world libsodium ]; nativeTools = [ cmake gnupatch pkgconf ] ++ hostTools;
    build = ''
      for p in ${fetch "https://github.com/zeromq/libzmq/pull/4711/commits/55bd6b3df06734730d3012c17bc26681e25b549d.patch" "2e56edc8959000c53a64754d94e877bb98d925c182a3c2f7b197577d605a1b20"} \
               ${fetch "https://github.com/zeromq/libzmq/commit/34f7fa22022bed9e0e390ed3580a1c83ac4a2834.patch" "d3e65d9185e5aaa79c324561662ee69ebddcf2a7e6f501a42d6cb1745e948de8"} \
               ${fetch "https://github.com/zeromq/libzmq/commit/b91a6201307b72beb522300366aad763d19b1456.patch" "64d774dece41b7a6c31568b8b02a60cda01c50e226c093ed2361b739887fdaa4"}; do patch -p1 < "$p"; done
      grep -qF 'set(libdir ''${prefix}/''${CMAKE_INSTALL_LIBDIR})' CMakeLists.txt && grep -qF 'set(includedir ''${prefix}/''${CMAKE_INSTALL_INCLUDEDIR})' CMakeLists.txt || { echo "FATAL: zeromq libdir anchors" >&2; exit 1; }
      sed -i 's|''${prefix}/''${CMAKE_INSTALL_LIBDIR}|''${CMAKE_INSTALL_FULL_LIBDIR}|; s|''${prefix}/''${CMAKE_INSTALL_INCLUDEDIR}|''${CMAKE_INSTALL_FULL_INCLUDEDIR}|' CMakeLists.txt
      # upstream links libssp on SunOS ("libsodium depends on libssp" there): solnix's libsodium does not (NEEDED libc, libpthread), and
      # gcc's libssp is in the compiler out, not its runtime -lib (the t below failed: "libssp.so.0: open failed", measured)
      [ "$(grep -c 'target_link_libraries(libzmq\(-static\)\? ssp)' CMakeLists.txt)" = 2 ] || { echo "FATAL: zeromq ssp anchors" >&2; exit 1; }
      sed -i 's/target_link_libraries(libzmq\(-static\)\? ssp)/# solnix: no libssp/' CMakeLists.txt
      # Every I/O thread calls applySchedulingParameters, which resets sched_priority to 0 for a non-RT policy (Linux's only SCHED_OTHER
      # value). On illumos the TS priority is the user priority (-60..60; a niced process has a negative one), so 0 is a RAISE:
      # pthread_setschedparam fails EPERM and posix_assert aborts ("Not owner (src/thread.cpp:315)": every zmq context in a niced
      # unprivileged process, measured with a probe: nice 10 -> priority -30, set 0 -> EPERM). Keep the thread's own priority.
      f=src/thread.cpp
      [ "$(grep -c '^          0; // this is the only supported priority for most scheduling policies$' $f)" = 1 ] || { echo "FATAL: zeromq sched anchor" >&2; exit 1; }
      sed -i 's|^          0; // this is the only supported priority for most scheduling policies$|          param.sched_priority; // solnix: illumos TS priority is the user priority: keep it (0 may raise it: EPERM)|' $f
      ${cmakeB ''-DBUILD_SHARED=ON -DBUILD_STATIC=OFF -DENABLE_CURVE=ON -DENABLE_DRAFTS=OFF -DWITH_LIBSODIUM=ON -DWITH_DOC=OFF -DWITH_DOCS=OFF -DBUILD_TESTS=OFF \
        -DCMAKE_SHARED_LINKER_FLAGS="-lsocket -lnsl" -DCMAKE_EXE_LINKER_FLAGS="-lsocket -lnsl"''}
      grep -q '^POLLER:STRING=devpoll$' _b/CMakeCache.txt || grep -q 'ZMQ_IOTHREAD_POLLER_USE_DEVPOLL' _b/platform.hpp || { echo "FATAL: zeromq poller is not devpoll" >&2; grep -i poller _b/CMakeCache.txt >&2; exit 1; }
      grep -q '^#define ZMQ_USE_LIBSODIUM' _b/platform.hpp || { echo "FATAL: zeromq: no libsodium" >&2; exit 1; }
      ! /usr/bin/elfdump -d "$out/lib/amd64/libzmq.so.5" | grep -q 'NEEDED.*libssp' || { echo "FATAL: libzmq NEEDs libssp" >&2; exit 1; }
      mkdir -p "$out/share/man/man3" "$out/share/man/man7"; cp doc/*.3 "$out/share/man/man3/"; cp doc/*.7 "$out/share/man/man7/"
      [ "$(ls "$out/share/man/man3" | wc -l)" -eq 58 ] && [ "$(ls "$out/share/man/man7" | wc -l)" -eq 12 ] || { echo "FATAL: zeromq man pages" >&2; exit 1; }
      find "$out/share/zmq" "$out/share/doc" -delete 2>/dev/null || true
      grep -qx "libdir=$out/lib/amd64" "$out/lib/amd64/pkgconfig/libzmq.pc" || { echo "FATAL: libzmq.pc libdir" >&2; cat "$out/lib/amd64/pkgconfig/libzmq.pc" >&2; exit 1; }
      # REQ/REP over tcp loopback with CURVE encryption: the poller, the socket libs and libsodium in one exchange
      ${tprog ''#include <zmq.h>
#include <stdio.h>
#include <string.h>
int main(void){ char pk[41], sk[41], cpk[41], csk[41], b[16] = { 0 }; int one = 1, maj, min, pat;
if (zmq_curve_keypair(pk, sk) || zmq_curve_keypair(cpk, csk)) return 1; zmq_version(&maj, &min, &pat);
void *c = zmq_ctx_new(), *s = zmq_socket(c, ZMQ_REP), *q = zmq_socket(c, ZMQ_REQ);
zmq_setsockopt(s, ZMQ_CURVE_SERVER, &one, sizeof one); zmq_setsockopt(s, ZMQ_CURVE_SECRETKEY, sk, 40);
zmq_setsockopt(q, ZMQ_CURVE_SERVERKEY, pk, 40); zmq_setsockopt(q, ZMQ_CURVE_PUBLICKEY, cpk, 40); zmq_setsockopt(q, ZMQ_CURVE_SECRETKEY, csk, 40);
if (zmq_bind(s, "tcp://127.0.0.1:*")) return 2; char ep[64]; size_t el = sizeof ep; zmq_getsockopt(s, ZMQ_LAST_ENDPOINT, ep, &el);
if (zmq_connect(q, ep)) return 3; zmq_send(q, "solnix", 6, 0); int n = zmq_recv(s, b, sizeof b - 1, 0);
printf("ok %d.%d.%d %d %s %d\n", maj, min, pat, zmq_has("curve"), b, n); return 0; }'' "-lzmq"}
      ${chk ''"$W/t"'' "^ok 4\\.3\\.5 1 solnix 6$"}
      ${noBuildDir}
    '';
  };

  # cppzmq (MIT): the header-only C++ binding for libzmq (zmq.hpp, zmq_addon.hpp) and its cmake/pkg-config files, on zeromq, as nixpkgs
  # (tests off). The check sends a message through a PAIR over inproc with the installed headers.
  cppzmq = mkSrcPkg {
    pname = "cppzmq"; version = "4.11.0";
    src = gh "zeromq/cppzmq" "v4.11.0" "0fff4ff311a7c88fdb76fceefba0e180232d56984f577db371d505e4d4c91afd";
    deps = [ world zeromq ]; nativeTools = [ cmake pkgconf ] ++ hostTools;
    build = ''
      ${cmakeB "-DCPPZMQ_BUILD_TESTS=OFF"}
      grep -Eq "^ZeroMQ_DIR:PATH=${zeromq}/" _b/CMakeCache.txt || { echo "FATAL: cppzmq: zeromq not from the store" >&2; grep ZeroMQ _b/CMakeCache.txt >&2; exit 1; }
      cat > "$W/t.cc" <<'TPROG'
#include <zmq.hpp>
#include <zmq_addon.hpp>
#include <iostream>
int main(){ zmq::context_t c; zmq::socket_t a(c, zmq::socket_type::pair), b(c, zmq::socket_type::pair); a.bind("inproc://t"); b.connect("inproc://t");
a.send(zmq::str_buffer("solnix"), zmq::send_flags::none); zmq::message_t m; auto r = b.recv(m, zmq::recv_flags::none);
std::cout << "ok " << CPPZMQ_VERSION_MAJOR << "." << CPPZMQ_VERSION_MINOR << "." << CPPZMQ_VERSION_PATCH << " " << m.to_string() << " " << r.value_or(0) << std::endl; return 0; }
TPROG
      "$CXX" -std=c++17 -I"$out/include" -I${zeromq}/include "$W/t.cc" -L${zeromq}/lib/amd64 -lzmq -Wl,-R,${zeromq}/lib/amd64 -o "$W/t"
      ${chk ''"$W/t"'' "^ok 4\\.11\\.0 solnix 6$"}
      ${noBuildDir}
    '';
  };
}
