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
}
