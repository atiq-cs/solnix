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

  # libtiff (libtiff licence, BSD-like): the TIFF library and tools, cmake, shared, on libjpeg-turbo, zlib, zstd, libdeflate, xz, libwebp
  # (above, as nixpkgs: the TIFF-less one) and lerc, nixpkgs' rename-version patch and VERSION move. Source: the 4.7.2 release tarball
  # (the same code as nixpkgs' gitlab tag archive, which lacks only the dist files), whose doc/man-prebuilt is the sphinx man pages
  # nixpkgs builds: installed from there (solnix has no sphinx). nixpkgs' dev_private headers (tif_config.h, tif_dir.h, tif_hash_set.h,
  # tiffiop.h) go to include/private, one output as every solnix recipe.
  libtiff = mkSrcPkg {
    pname = "libtiff"; version = "4.7.2";
    src = { url = "https://download.osgeo.org/libtiff/tiff-4.7.2.tar.xz"; sha256 = "4996f0c4f93094719b1ca5c6279b20e588773ba8a247533e486416fb662ddb88"; };
    deps = [ world libjpeg-turbo zlib zstd libdeflate xz libwebp lerc ]; nativeTools = [ cmake gnupatch ] ++ hostTools;
    build = ''
      patch -p1 < ${npFile "by-name/li/libtiff/rename-version.patch" "acac73cbdadc081aae7eaa47f0a18fbb2fd59f73955ad22212585f5adaf84ace"}
      mv VERSION VERSION.txt
      ${cmakeB "-DCMAKE_FIND_PACKAGE_PREFER_CONFIG=ON -Dtiff-docs=OFF -Dtiff-tests=OFF -Dtiff-contrib=OFF -Djbig=OFF"}
      # each codec library resolves to its store dep (libjpeg-turbo is found in CONFIG mode, the others by Find modules: one check for all)
      /usr/bin/ldd "$out/lib/amd64/libtiff.so.6" > "$W/ldd" || { echo "FATAL: libtiff ldd" >&2; exit 1; }
      # (libz.so.1 is not in the list: the world precedes zlib in deps, so RUNPATH resolves the world's, as every recipe here with
      # deps = [ world zlib ... ]; the headers and the link were zlib's)
      for v in "libjpeg.so.62 ${libjpeg-turbo}" "libzstd.so.1 ${zstd}" "libdeflate.so.0 ${libdeflate}" "liblzma.so.5 ${xz}" \
               "libwebp.so.7 ${libwebp}" "libLerc.so.4 ${lerc}"; do
        set -- $v; grep -Eq "^[[:space:]]+$1 =>[[:space:]]+$2/" "$W/ldd" || { echo "FATAL: libtiff: $1 not from $2" >&2; cat "$W/ldd" >&2; exit 1; }
      done
      for o in jpeg zlib zstd libdeflate lzma webp lerc; do grep -q "^$o:BOOL=ON$" _b/CMakeCache.txt || { echo "FATAL: libtiff codec $o off" >&2; exit 1; }; done
      # the man pages nixpkgs' sphinx build installs (21 in man1, 59 in man3), from the release's prebuilt copy
      mkdir -p "$out/share/man/man1" "$out/share/man/man3"
      cp doc/man-prebuilt/*.1 "$out/share/man/man1/"; cp doc/man-prebuilt/*.3tiff "$out/share/man/man3/"
      [ "$(ls "$out/share/man/man1" | wc -l)" -eq 21 ] && [ "$(ls "$out/share/man/man3" | wc -l)" -eq 59 ] || { echo "FATAL: libtiff man pages" >&2; exit 1; }
      mkdir -p "$out/include/private"; cp _b/libtiff/tif_config.h libtiff/tif_dir.h libtiff/tif_hash_set.h libtiff/tiffiop.h "$out/include/private/"
      find "$out/share/doc" -delete 2>/dev/null || true
      ${chk ''"$out/bin/tiffinfo" test/images/rgb-3c-8b.tiff'' "Image Width: 157 Image Length: 151"}
      # every external codec, through tiffcp and back: each round trip must give the original pixels (tiffcmp exits 0)
      # -r 16 everywhere (JPEG needs rows per strip a multiple of 8; tiffcmp compares RowsPerStrip): the reference is the same layout
      "$out/bin/tiffcp" -r 16 -c none test/images/rgb-3c-8b.tiff "$W/ref.tif" || { echo "FATAL: libtiff tiffcp ref" >&2; exit 1; }
      for c in zip zstd lzma webp:p100 lerc jpeg:r:100 lzw; do   # webp:p100 = lossless (tiffcp.c: preset 100)
        "$out/bin/tiffcp" -r 16 -c "$c" "$W/ref.tif" "$W/c.tif" && "$out/bin/tiffcp" -r 16 -c none "$W/c.tif" "$W/d.tif" || { echo "FATAL: libtiff tiffcp -c $c" >&2; exit 1; }
        case $c in jpeg*) ;; *) "$out/bin/tiffcmp" "$W/ref.tif" "$W/d.tif" >&2 || { echo "FATAL: libtiff $c round trip differs" >&2; exit 1; };; esac
      done
      ${tprog ''#include <tiffio.h>
#include <stdio.h>
int main(int c, char **v){ TIFF *t = TIFFOpen(v[1], "r"); uint32_t w = 0; if (!t) return 1; TIFFGetField(t, TIFFTAG_IMAGEWIDTH, &w);
printf("ok %d %u %d %d\n", TIFFLIB_VERSION > 20250000, w, TIFFIsCODECConfigured(COMPRESSION_WEBP), TIFFIsCODECConfigured(COMPRESSION_LERC)); TIFFClose(t); return 0; }'' "-ltiff"}
      ${chk ''"$W/t" test/images/rgb-3c-8b.tiff'' "^ok 1 157 1 1$"}
      grep -qx "Version: 4.7.2" "$out/lib/amd64/pkgconfig/libtiff-4.pc" || { echo "FATAL: libtiff-4.pc version" >&2; exit 1; }
      ${noBuildDir}
    '';
  };

  # lcms2 (MIT): Little CMS, the colour management engine and its tools (tificc, transicc, linkicc, jpgicc, psicc), autotools, shared, on
  # libtiff, libjpeg-turbo and zlib, as nixpkgs. The check runs upstream's own testbed (testcms2) and a transform through transicc.
  lcms2 = mkSrcPkg {
    pname = "lcms2"; version = "2.19.1";
    src = { url = "https://downloads.sourceforge.net/lcms/lcms2-2.19.1.tar.gz"; sha256 = "bfc54f7bab59fbc921012014a8032e4cba4abd46db47d46b76416a8c0b2815c8"; };
    deps = [ world libtiff libjpeg-turbo zlib ]; nativeTools = hostTools;
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --with-tiff=${libtiff} --with-jpeg=${libjpeg-turbo}
      gmake -j''${NIX_BUILD_CORES} >&2; gmake install >&2
      for b in tificc transicc linkicc jpgicc psicc; do [ -x "$out/bin/$b" ] || { echo "FATAL: lcms2: no $b" >&2; exit 1; }; done
      # upstream's testbed: exits with its failure count (and prints FAIL! per failed check); the speed tests are part of it
      ( cd testbed && gmake -j''${NIX_BUILD_CORES} testcms >&2 && ./testcms ) > "$W/tb.out" 2>&1 || { echo "FATAL: lcms2 testbed" >&2; grep -B1 "FAIL!" "$W/tb.out" | head -20 >&2; tail -5 "$W/tb.out" >&2; exit 1; }
      ! grep -q "FAIL!" "$W/tb.out" && [ "$(grep -c '^Checking .*\.\.\.' "$W/tb.out")" -gt 100 ] || { echo "FATAL: lcms2 testbed output" >&2; tail -5 "$W/tb.out" >&2; exit 1; }
      ${chk ''printf '128 128 128\n' | "$out/bin/transicc" -i '*sRGB' -o '*Lab' -n | tail -1'' "^53\\.5[0-9]+ +-?0\\.0000 +-?0\\.0000"}   # mid-grey: L* 53.585, a* b* 0 (either sign)
      ${tprog ''#include <lcms2.h>
#include <stdio.h>
int main(void){ cmsHPROFILE s = cmsCreate_sRGBProfile(), l = cmsCreateLab4Profile(NULL); cmsHTRANSFORM x = cmsCreateTransform(s, TYPE_RGB_8, l, TYPE_Lab_DBL, INTENT_PERCEPTUAL, 0);
unsigned char w[3] = { 255, 255, 255 }; cmsCIELab o; cmsDoTransform(x, w, &o, 1); printf("ok %d %d\n", cmsGetEncodedCMMversion(), (int)(o.L + 0.5)); return 0; }'' "-llcms2"}
      ${chk ''"$W/t"'' "^ok 2190 100$"}
      ${noBuildDir}
    '';
  };

  # openjpeg (BSD-2-Clause): the JPEG 2000 codec (libopenjp2, opj_compress/opj_decompress/opj_dump), cmake, shared, on libpng, libtiff,
  # zlib and lcms2, nixpkgs' flags (no JPIP, no viewer, no java, no thirdparty) and its CVE-2026-6192 fix (upstream PR 1621, merged).
  # nixpkgs runs ctest on a test-data checkout; the check here encodes and decodes a lossless image and compares the pixels.
  openjpeg = mkSrcPkg {
    pname = "openjpeg"; version = "2.5.4";
    src = gh "uclouvain/openjpeg" "v2.5.4" "a695fbe19c0165f295a8531b1e4e855cd94d0875d2f88ec4b61080677e27188a";
    deps = [ world libpng libtiff zlib lcms2 ]; nativeTools = [ cmake gnupatch ] ++ hostTools;
    build = ''
      patch -p1 < ${fetch "https://patch-diff.githubusercontent.com/raw/uclouvain/openjpeg/pull/1621.patch?full_index=1" "40648d63bfbb0f6c3a41cb9425ac48c396772c3527fff4b2979b07f42aaea6b8"}
      ${cmakeB "-DBUILD_SHARED_LIBS=ON -DBUILD_CODEC=ON -DBUILD_THIRDPARTY=OFF -DBUILD_JPIP=OFF -DBUILD_JPIP_SERVER=OFF -DBUILD_VIEWER=OFF -DBUILD_JAVA=OFF -DBUILD_TESTING=OFF"}
      # opj_compress reads PNG and TIFF and links lcms2 for ICC: each resolves to its store dep (one ldd check for the three)
      /usr/bin/ldd "$out/bin/opj_compress" > "$W/ldd" || { echo "FATAL: openjpeg ldd" >&2; exit 1; }
      for v in "libpng16.so.16 ${libpng}" "libtiff.so.6 ${libtiff}" "liblcms2.so.2 ${lcms2}"; do
        set -- $v; grep -Eq "^[[:space:]]+$1 =>[[:space:]]+$2/" "$W/ldd" || { echo "FATAL: openjpeg: $1 not from $2" >&2; cat "$W/ldd" >&2; exit 1; }
      done
      printf 'P6\n4 2\n255\n' > "$W/a.ppm"; printf '\377\000\000\000\377\000\000\000\377\377\377\377\000\000\000\200\200\200\001\002\003\375\376\377' >> "$W/a.ppm"
      "$out/bin/opj_compress" -n 1 -i "$W/a.ppm" -o "$W/a.jp2" >&2 && "$out/bin/opj_decompress" -i "$W/a.jp2" -o "$W/b.ppm" >&2
      # opj_decompress writes its own header ("# OpenJPEG-2.5.4" comment): compare the 24 pixel bytes
      [ "$(tail -c 24 "$W/a.ppm" | od -An -tx1)" = "$(tail -c 24 "$W/b.ppm" | od -An -tx1)" ] && head -2 "$W/b.ppm" | grep -q "^# OpenJPEG-2.5.4" \
        || { echo "FATAL: openjpeg lossless round trip" >&2; od -c "$W/b.ppm" | head -4 >&2; exit 1; }
      ${chk ''"$out/bin/opj_dump" -i "$W/a.jp2"'' "x1=4, y1=2"}
      ${tprog ''#include <openjpeg.h>
#include <stdio.h>
int main(void){ printf("ok %s\n", opj_version()); return 0; }'' "-I$out/include/openjpeg-2.5 -lopenjp2"}
      ${chk ''"$W/t"'' "^ok 2\\.5\\.4$"}
      # upstream installs its man pages only with BUILD_DOC (which also needs doxygen for HTML), off in nixpkgs, so nixpkgs' out has none:
      # the four pages by hand (a page added later would republish the out)
      mkdir -p "$out/share/man/man1" "$out/share/man/man3"; cp doc/man/man1/opj_*.1 "$out/share/man/man1/"; cp doc/man/man3/libopenjp2.3 "$out/share/man/man3/"
      [ "$(ls "$out/share/man/man1" | wc -l)" -eq 3 ] || { echo "FATAL: openjpeg man pages" >&2; exit 1; }
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

  # libxslt (MIT): XSLT 1.0 (libxslt, libexslt, xsltproc), autotools (autoreconf, as nixpkgs), on libxml2, without python and crypto,
  # nixpkgs' list-of-cached-RVTs fix (upstream issue 77). One output (nixpkgs splits bin/dev/doc/devdoc). Its version scripts go through
  # version-script-mapfile.sh (illumos ld takes mapfiles); --with-debugger stays on (the default), which the .syms file needs (phase3
  # H31). nixpkgs' postFixup points libxslt-config.cmake at $out/lib: here, at $out/lib/amd64.
  libxslt = mkSrcPkg {
    pname = "libxslt"; version = "1.1.45";
    src = { url = "https://download.gnome.org/sources/libxslt/1.1/libxslt-1.1.45.tar.xz"; sha256 = "9acfe68419c4d06a45c550321b3212762d92f41465062ca4ea19e632ee5d216e"; };
    # zlib: libxml-2.0.pc's Requires.private, which pkg-config resolves even for --cflags (configure: "Could not find libxml2", measured)
    deps = [ world libxml2 zlib ]; nativeTools = autoreconfTools ++ [ gnupatch pkgconf ] ++ hostTools;
    build = ''
      patch -p1 < ${npFile "by-name/li/libxslt/77-Use-a-dedicated-node-type-to-maintain-the-list-of-cached-rv-ts.patch" "fe14924cbde2cb5e3a61326d6967f2aca24255bc775fc47251f1800128a33ec9"}
      ${autoreconf}
      "$BASH" ${../version-script-mapfile.sh} wrap
      # configure greps `$LD --help` for version-script: illumos ld has none, so the probe says -M (a v1 mapfile it cannot read);
      # the GNU spelling instead, which the shim translates
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --without-python --without-crypto lt_cv_prog_gnu_ld=no
      sed -i 's|^VERSION_SCRIPT_FLAGS = .*|VERSION_SCRIPT_FLAGS = -Wl,--version-script=|' libxslt/Makefile libexslt/Makefile
      grep -q '^VERSION_SCRIPT_FLAGS = -Wl,--version-script=$' libxslt/Makefile || { echo "FATAL: libxslt version script flags" >&2; exit 1; }
      gmake -j''${NIX_BUILD_CORES} >&2; gmake install >&2
      /usr/bin/pvs -dos "$out/lib/amd64/libxslt.so.1" | grep -q "LIBXML2_1.0.11: xsltApplyStylesheet;" || { echo "FATAL: libxslt version nodes" >&2; /usr/bin/pvs -do "$out/lib/amd64/libxslt.so.1" | head >&2; exit 1; }
      f="$out/lib/amd64/cmake/libxslt/libxslt-config.cmake"
      grep -qF '"''${PACKAGE_PREFIX_DIR}/lib"' "$f" || { echo "FATAL: libxslt cmake anchor" >&2; exit 1; }
      sed -i "s|\"\''${PACKAGE_PREFIX_DIR}/lib\"|\"$out/lib/amd64\"|g" "$f"
      find "$out/share/doc" "$out/share/gtk-doc" -delete 2>/dev/null || true
      ${chk ''"$out/bin/xsltproc" --version'' "libxslt 10145"}
      printf '<r><i>so</i><i>lnix</i></r>\n' > "$W/a.xml"
      printf '<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform" xmlns:str="http://exslt.org/strings" extension-element-prefixes="str"><xsl:output method="text"/><xsl:template match="/">ok <xsl:value-of select="str:concat(//i)"/> <xsl:value-of select="count(//i)"/></xsl:template></xsl:stylesheet>\n' > "$W/a.xsl"
      ${chk ''"$out/bin/xsltproc" "$W/a.xsl" "$W/a.xml"'' "^ok solnix2$"}
      ${noBuildDir}
    '';
  };

  # lua5_4 (MIT): Lua 5.4, the interpreter, luac and liblua.so (nixpkgs' lua-dso.make: liblua.so.5.4), its own Makefile, on readline,
  # as nixpkgs' interpreter.nix: pname is the queue's attr (lua5_4; nixpkgs' drv pname is lua), compat 5.3 off, LUA_ROOT = $out, the
  # nixpkgs pkg-config files, MYLIBS=-lncurses. PLAT=solaris is nixpkgs' isSunOS answer, and upstream's solaris target links no readline
  # (nixpkgs reads readline only through linux-readline): the interpreter has no line editing, as nixpkgs' lua on SunOS.
  lua5_4 = mkSrcPkg {
    pname = "lua5_4"; version = "5.4.9";
    src = { url = "https://www.lua.org/ftp/lua-5.4.9.tar.gz"; sha256 = "2335b6c582a52654f94612bf10d2f4672805d05329aa6568b1d8cd9e5c6fb8e6"; };
    deps = [ world base.ncurses ]; nativeTools = hostTools;
    build = ''
      grep -q '^#define LUA_ROOT	"/usr/local/"$' src/luaconf.h || { echo "FATAL: lua LUA_ROOT anchor" >&2; exit 1; }
      sed -i "s@#define LUA_ROOT[[:space:]]*\"/usr/local/\"@#define LUA_ROOT  \"$out/\"@g" src/luaconf.h
      sed -e '1s/^/LUA_SO = liblua.so/' -e 's/ALL_T *= */&$(LUA_SO) /' -i src/Makefile
      cat ${npFile "development/interpreters/lua-5/lua-dso.make" "33c0692540c79140291f27f0dd46cc7df82b6ebac29da2a178654644458aaf4b"} >> src/Makefile
      # GNU -soname: illumos ld's is -h
      sed -i 's/-Wl,-soname,/-Wl,-h,/' src/Makefile
      gmake -j''${NIX_BUILD_CORES} INSTALL_TOP="$out" INSTALL_MAN="$out/share/man/man1" R=5.4.9 LDFLAGS=-fPIC V=5.4 PLAT=solaris CC=gcc RANLIB=ranlib \
        MYLIBS=-lncurses CFLAGS='-O2 -fPIC $(SYSCFLAGS)' solaris >&2
      gmake INSTALL_TOP="$out" INSTALL_MAN="$out/share/man/man1" R=5.4.9 V=5.4 TO_BIN="lua luac" INSTALL_DATA='cp -d' \
        TO_LIB="liblua.a liblua.so liblua.so.5.4 liblua.so.5.4.9" install >&2
      mkdir -p "$out/share/doc/lua-5.4.9" "$out/lib/pkgconfig"; cp doc/*.png doc/*.css doc/*.html "$out/share/doc/lua-5.4.9/"   # 5.4.9 ships no .gif (nixpkgs' glob)
      rmdir "$out/share/lua/5.4" "$out/lib/lua/5.4" "$out/share/lua" "$out/lib/lua"
      printf '%s\n' "prefix=$out" "libdir=$out/lib" "includedir=$out/include" "INSTALL_BIN=$out/bin" "INSTALL_INC=$out/include" "INSTALL_LIB=$out/lib" \
        "INSTALL_MAN=$out/man/man1" "" "Name: Lua" "Description: An Extensible Extension Language" "Version: 5.4.9" "Requires:" "Libs: -L$out/lib -llua" "Cflags: -I$out/include" > "$out/lib/pkgconfig/lua.pc"
      for n in lua-5.4 lua5.4 lua54; do ln -s "$out/lib/pkgconfig/lua.pc" "$out/lib/pkgconfig/$n.pc"; done
      /usr/bin/elfdump -d "$out/lib/liblua.so.5.4.9" | grep -Eq 'SONAME +0x[0-9a-f]+ +liblua\.so\.5\.4$' || { echo "FATAL: liblua soname" >&2; exit 1; }
      ${chk ''"$out/bin/lua" -v'' "^Lua 5\\.4\\.9"}
      ${chk ''"$out/bin/lua" -e 'print(string.format("ok %s %d %s", _VERSION, 7 // 2, package.path:find("'"$out"'", 1, true) and "root" or "noroot"))' '' "^ok Lua 5\\.4 3 root$"}
      printf 'return 6 * 7\n' > "$W/a.lua"; "$out/bin/luac" -o "$W/a.luac" "$W/a.lua"
      ${chk ''"$out/bin/lua" -e 'print("ok", dofile("'"$W/a.luac"'"))' '' "^ok	42$"}
      ${tprog ''#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <stdio.h>
int main(void){ lua_State *L = luaL_newstate(); luaL_openlibs(L); luaL_dostring(L, "return ('solnix'):upper()"); printf("ok %s %s\n", LUA_RELEASE, lua_tostring(L, -1)); lua_close(L); return 0; }'' "-L$out/lib -llua -lm -Wl,-R,$out/lib"}
      ${chk ''"$W/t"'' "^ok Lua 5\\.4\\.9 SOLNIX$"}
      ${noBuildDir}
    '';
  };
}
