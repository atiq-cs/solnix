# solnix-torrent: the BitTorrent client the community cache proxy and seeder use (modules/config/community/seed.nix).
# libtorrent-rasterbar 2.0.11, BSD-3. Compiled in: try_signal (BSD-3), puff and ed25519 (zlib licence), sha1/sha256
# (public domain). In the tarball, NOT built: simulation/libsimulator (GPL-3, build_tests only), deps/asio-gnutls
# (BSL-1.0, gnutls=ON only), aux_/route.h (APSL-2.0, iPhone only). TLS is the store openssl; boost 1.86 is used as
# headers only (libtorrent 2.0 needs no Boost.System on boost >= 1.69), from nixChain, as nix itself builds.
# The one source change is OpenIndiana's (oi-userland 01-enum_net.cpp.patch): enum_net.cpp has no route
# enumeration for illumos and #errors; there it returns no routes.
{ mkSrcPkg, openssl, boost, cmake, pkgconf, gccWrapper, binutils, gcc, gate, libc, hostTools ? [ ], system ? "x86_64-solaris" }:

rec {
  libtorrent-rasterbar = mkSrcPkg {
    pname = "libtorrent-rasterbar"; version = "2.0.11";
    src = { url = "https://github.com/arvidn/libtorrent/releases/download/v2.0.11/libtorrent-rasterbar-2.0.11.tar.gz";
            sha256 = "f0db58580f4f29ade6cc40fa4ba80e2c9a70c90265cd77332d3cdec37ecf1e6d"; };
    deps = [ openssl ];
    linkDeps = [ boost ];   # headers only: kept out of RUNPATH and the runtime closure
    build = ''
      export PATH=${cmake}/bin:$PATH
      sed -i 's|^#error "don.t know how to enumerate network routes on this platform"|// illumos: no routes (oi-userland)|' src/enum_net.cpp
      grep -q 'illumos: no routes' src/enum_net.cpp || { echo "FATAL: enum_net.cpp change did not apply" >&2; exit 1; }
      mkdir b; cd b
      # -ffile-prefix-map: boost's throw_exception records __FILE__; without it the .so names the 150 MB headers.
      cmake .. -DCMAKE_INSTALL_PREFIX="$out" -DCMAKE_INSTALL_LIBDIR=lib/amd64 -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=17 -DBUILD_SHARED_LIBS=ON -DCMAKE_SKIP_RPATH=ON \
        -DCMAKE_CXX_FLAGS="-ffile-prefix-map=${boost}=/boost" \
        -Dpython-bindings=OFF -Dbuild_tools=OFF -Dbuild_examples=OFF -Dbuild_tests=OFF \
        -DBoost_DIR=${boost}/lib/amd64/cmake/Boost-1.86.0 -DBoost_NO_SYSTEM_PATHS=ON \
        -DOPENSSL_ROOT_DIR=${openssl} -DOPENSSL_INCLUDE_DIR=${openssl}/include \
        -DOPENSSL_CRYPTO_LIBRARY=${openssl}/lib/amd64/libcrypto.so -DOPENSSL_SSL_LIBRARY=${openssl}/lib/amd64/libssl.so \
        -DCMAKE_IGNORE_PREFIX_PATH="/usr;/usr/local;/opt" -DCMAKE_IGNORE_PATH="/usr/lib/64;/usr/lib/amd64;/lib/64" >&2
      grep -q "^Boost_DIR:[A-Z]*=${boost}/" CMakeCache.txt || { echo "FATAL: not the store boost" >&2; grep -i boost_dir CMakeCache.txt >&2; exit 1; }
      gmake -j8; gmake install
      if grep -rl "${boost}" "$out"; then echo "FATAL: libtorrent names the build-only boost" >&2; exit 1; fi
      /usr/bin/elfdump -d "$out/lib/amd64/libtorrent-rasterbar.so.2.0.11" | grep -q 'NEEDED.*libssl.so.3' \
        || { echo "FATAL: libtorrent without the store openssl" >&2; exit 1; }
    '';
  };

  # the ~150-line front end, src/solnix-torrent/solnix-torrent.cpp, built like solnix-cputemp (the store gcc wrapper),
  # its flags from libtorrent's own .pc (they set the ABI: TORRENT_USE_OPENSSL, TORRENT_SSL_PEERS, ...; the .pc names
  # neither openssl's nor boost's headers, so both are added here).
  solnix-torrent = derivation {
    name = "solnix-torrent-1"; inherit system;
    src = ../../src/solnix-torrent/solnix-torrent.cpp;
    builder = "/usr/bin/bash";
    # store-only, as clang-wrapper (llvm/parts.nix): store coreutils/findutils + the world's bins, path-gated (drv-gate A1: it was
    # /usr/gnu/bin:/usr/bin:/usr/sbin). zero-checksum.sh: illumos ld sums $out's hash into DT_CHECKSUM, so --check differed in
    # exactly those 2 bytes (holds1, measured); mk-src-pkg and solnix-cputemp zero it the same way.
    PATH = builtins.concatStringsSep ":" (map (t: "${t}/bin") hostTools);
    args = [ "-c" ''
      set -eu; /usr/bin/bash ${./path-gate.sh}; . ${./illumos-bin.sh}
      W=$(mktemp -d "''${TMPDIR:-$NIX_BUILD_TOP}/sntor.XXXXXX"); cd "$W"; mkdir -p "$out/bin"
      # a copy, as solnix-cputemp: gcc names its input in an STT_FILE symbol, and the store source would be a runtime reference
      cp "$src" solnix-torrent.cpp
      export PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR=${libtorrent-rasterbar}/lib/amd64/pkgconfig
      cf=$(${pkgconf}/bin/pkg-config --cflags libtorrent-rasterbar); lf=$(${pkgconf}/bin/pkg-config --libs libtorrent-rasterbar)
      # -isystem: warnings inside libtorrent's and boost's headers are theirs; -Werror holds for our file
      ${gccWrapper}/bin/g++ -m64 -std=c++17 -O2 -Wall -Werror -D_TS_ERRNO -isystem ${libtorrent-rasterbar}/include $cf -isystem ${openssl}/include -isystem ${boost}/include \
        -ffile-prefix-map=${boost}=/boost -o "$out/bin/solnix-torrent" solnix-torrent.cpp $lf \
        -Wl,-R,${libtorrent-rasterbar}/lib/amd64:${openssl}/lib/amd64:${libc}/lib/amd64
      ${binutils}/bin/gstrip --strip-debug "$out/bin/solnix-torrent"
      : > zc; /usr/bin/bash ${./zero-checksum.sh} "$out" zc; [ ! -s zc ] || { cat zc >&2; exit 1; }
      ! grep -qF "$src" "$out/bin/solnix-torrent" || { echo "FATAL: solnix-torrent names its store source" >&2; exit 1; }
      /usr/bin/bash ${./store-gate.sh} "$out" ${./ts-errno-gate.sh} ${boost} ${gate} ${gcc}/
      # conventions check: the v1 infohash of 600000 'x' bytes named t.nar.xz, 256 KiB pieces, no date/creator,
      # = sha1 of the bencoded info dict computed independently (python hashlib, 2026-10-28)
      dd if=/dev/zero bs=1000 count=600 2>/dev/null | tr '\0' x > t.nar.xz
      got=$("$out/bin/solnix-torrent" infohash t.nar.xz)
      [ "$got" = a44168ed9bc53cf85df7631a7f5a61d41745ba1a ] || { echo "FATAL: infohash $got (the torrent conventions changed)" >&2; exit 1; }
    '' ];
  };
}
