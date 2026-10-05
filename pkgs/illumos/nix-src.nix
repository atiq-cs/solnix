# nix-src.nix -- Nix 2.24.15 and its whole dependency chain, built FROM SOURCE
# with mk-src-pkg.nix against the from-source gcc (gcc-src.nix).
#
# This replaces two earlier routes, both now forbidden: the /nix-tools224 host
# build with an LD_LIBRARY_PATH wrapper, and nix224.nix, which links the build
# host's IPS boost/sqlite/curl/libarchive/sodium/brotli and copies the host's
# /usr/gcc/14 libstdc++ into $out. Here every library nix links is a derivation
# below, and every C++ object links gcc.lib's libstdc++/libgcc_s.
#
# Configure follows nixpkgs' nix package where illumos allows:
#   --sysconfdir=/etc (reads /etc/nix/nix.conf; install goes to $out/etc),
#   --localstatedir=/nix/var, --with-store-dir=/nix/store.
# Disabled, as nix224.nix did: Boehm GC (--disable-gc), lowdown (markdown),
# libcpuid (x86 microarch detection), tests, docs. seccomp is Linux-only.
{ mkSrcPkg, zlib, openssl, libcSlice, gccLib, system }:

rec {
  # boost: headers + boost_context (the only compiled boost lib nix links).
  boost = mkSrcPkg {
    pname = "boost"; version = "1.86.0";
    selfRunpath = false;
    src = { url = "https://archives.boost.io/release/1.86.0/source/boost_1_86_0.tar.bz2";
            sha256 = "1bed88e40401b2cb7a1f76d4bab499e352fa4d0c5f31c0dbae64e24d34d7513b"; };
    build = ''
      # b2 itself is a build tool, compiled by whatever g++ is on PATH; the
      # library is compiled by $CXX (the from-source gcc) via user-config.jam.
      ./bootstrap.sh --with-toolset=gcc --with-libraries=context >&2
      echo "using gcc : solnix : $CXX ;" > user-config.jam
      ./b2 --user-config=user-config.jam toolset=gcc-solnix --with-context \
        variant=release link=shared threading=multi runtime-link=shared \
        address-model=64 architecture=x86 abi=sysv binary-format=elf target-os=solaris \
        --prefix="$out" --libdir="$out/lib/amd64" -j4 install >&2
    '';
  };

  # libboost_context alone, for the runtime closure: the boost output above is
  # ~150 MB of headers nix needs only to compile. boost is built with
  # selfRunpath = false, so the copied library names no path inside boost.
  boostContext = derivation {
    name = "boost-context-1.86.0"; inherit system boost;
    builder = "/usr/bin/bash";
    args = [ "-c" ''
      set -eu; export PATH=/usr/gnu/bin:/usr/bin
      mkdir -p $out/lib/amd64; cp -P $boost/lib/amd64/libboost_context.so* $out/lib/amd64/
      if grep -rq "$boost" $out; then echo "FATAL: boost-context still names $boost" >&2; exit 1; fi
    '' ];
  };

  # Mozilla CA bundle (curl.se's extract), for nix's ssl-cert-file.
  cacert = derivation {
    name = "cacert-2024-09-24"; inherit system;
    pem = builtins.fetchurl { url = "https://curl.se/ca/cacert-2024-09-24.pem";
            sha256 = "189d3cf6d103185fba06d76c1af915263c6d42225481a1759e853b33ac857540"; };
    builder = "/usr/bin/bash";
    args = [ "-c" "/usr/bin/mkdir -p $out/etc/ssl/certs && /usr/bin/cp $pem $out/etc/ssl/certs/ca-bundle.crt" ];
  };

  sqlite = mkSrcPkg {
    pname = "sqlite"; version = "3.46.1";
    src = { url = "https://www.sqlite.org/2024/sqlite-autoconf-3460100.tar.gz";
            sha256 = "67d3fe6d268e6eaddcae3727fce58fcc8e9c53869bdd07a0c61e38ddf2965071"; };
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --disable-readline --disable-editline
      gmake -j4; gmake install
    '';
  };

  xz = mkSrcPkg {
    pname = "xz"; version = "5.6.3";
    src = { url = "https://github.com/tukaani-project/xz/releases/download/v5.6.3/xz-5.6.3.tar.gz";
            sha256 = "b1d45295d3f71f25a4c9101bd7c8d16cb56348bbef3bbc738da0351e17c73317"; };
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --disable-nls --disable-doc
      gmake -j4; gmake install
    '';
  };

  libsodium = mkSrcPkg {
    pname = "libsodium"; version = "1.0.20";
    src = { url = "https://download.libsodium.org/libsodium/releases/libsodium-1.0.20.tar.gz";
            sha256 = "ebb65ef6ca439333c2bb41a0c1990587288da07f6c7fd07cb3a18cc18d30ce19"; };
    # --disable-ssp: -fstack-protector on this gcc links gcc's libssp.so.0, which
    # gcc.lib does not ship (measured: the closure gate failed on libssp.so.0).
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --disable-ssp
      gmake -j4; gmake install
    '';
  };

  curl = mkSrcPkg {
    pname = "curl"; version = "8.10.1";
    src = { url = "https://curl.se/download/curl-8.10.1.tar.xz";
            sha256 = "73a4b0e99596a09fa5924a4fb7e4b995a85fda0d18a2c02ab9cf134bebce04ee"; };
    deps = [ zlib openssl ];
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static \
        --with-openssl=${openssl} --with-zlib=${zlib} --without-libpsl --without-brotli \
        --without-zstd --without-libidn2 --without-nghttp2 --without-libssh2 --disable-ldap \
        --with-ca-bundle=/etc/ssl/certs/ca-certificates.crt --without-ca-path
      gmake -j4; gmake install
    '';
  };

  libarchive = mkSrcPkg {
    pname = "libarchive"; version = "3.7.6";
    src = { url = "https://www.libarchive.org/downloads/libarchive-3.7.6.tar.xz";
            sha256 = "0a2efdcb185da2eb1e7cd8421434cb9a6119f72417a13335cca378d476fd3ba0"; };
    deps = [ zlib xz ];
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --disable-bsdtar \
        --disable-bsdcpio --disable-bsdcat --disable-bsdunzip --without-xml2 --without-expat \
        --disable-acl --disable-xattr --without-openssl --without-bz2lib --without-zstd --without-lz4 --without-libb2 --with-zlib --with-lzma
      gmake -j4; gmake install
    '';
  };

  brotli = mkSrcPkg {
    pname = "brotli"; version = "1.1.0";
    src = { url = "https://github.com/google/brotli/archive/refs/tags/v1.1.0.tar.gz";
            sha256 = "e720a6ca29428b803f4ad165371771f5398faba397edf6778837a18599ea13ff"; };
    build = ''
      mkdir b; cd b
      # CMAKE_SKIP_RPATH: the compiler wrapper bakes the store RUNPATH; cmake's
      # install-time RPATH rewrite would otherwise strip it.
      cmake .. -DCMAKE_INSTALL_PREFIX="$out" -DCMAKE_INSTALL_LIBDIR=lib/amd64 -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON -DCMAKE_SKIP_RPATH=ON -DBROTLI_DISABLE_TESTS=ON >&2
      gmake -j4; gmake install
    '';
  };

  editline = mkSrcPkg {
    pname = "editline"; version = "1.17.1";
    src = { url = "https://github.com/troglobit/editline/releases/download/1.17.1/editline-1.17.1.tar.xz";
            sha256 = "df223b3333a545fddbc67b49ded3d242c66fadf7a04beb3ada20957fcd1ffc0e"; };
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static
      gmake -j4; gmake install
    '';
  };

  # header-only
  nlohmann_json = mkSrcPkg {
    pname = "nlohmann_json"; version = "3.11.3";
    src = { url = "https://github.com/nlohmann/json/releases/download/v3.11.3/json.tar.xz";
            sha256 = "d6c65aca6b1ed68e7a182f4757257b107ae403032760ed6ef121c9d55e81757d"; };
    build = ''
      mkdir b; cd b
      cmake .. -DCMAKE_INSTALL_PREFIX="$out" -DJSON_BuildTests=OFF -DCMAKE_CXX_COMPILER="$CXX" >&2
      gmake install
    '';
  };

  # header-only; nix's configure checks for <toml.hpp>
  toml11 = mkSrcPkg {
    pname = "toml11"; version = "3.8.1";
    src = { url = "https://github.com/ToruNiina/toml11/archive/refs/tags/v3.8.1.tar.gz";
            sha256 = "6a3d20080ecca5ea42102c078d3415bef80920f6c4ea2258e87572876af77849"; };
    build = ''
      mkdir -p "$out/include"; cp -R toml.hpp toml "$out/include/"
    '';
  };

  libgit2 = mkSrcPkg {
    pname = "libgit2"; version = "1.7.2";
    src = { url = "https://github.com/libgit2/libgit2/archive/refs/tags/v1.7.2.tar.gz";
            sha256 = "de384e29d7efc9330c6cdb126ebf88342b5025d920dcb7c645defad85195ea7f"; };
    deps = [ zlib openssl ];
    build = ''
      mkdir b; cd b
      cmake .. -DCMAKE_INSTALL_PREFIX="$out" -DCMAKE_INSTALL_LIBDIR=lib/amd64 -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTS=OFF -DBUILD_CLI=OFF -DUSE_SSH=OFF -DUSE_HTTPS=OpenSSL \
        -DUSE_BUNDLED_ZLIB=OFF -DREGEX_BACKEND=builtin -DUSE_HTTP_PARSER=builtin -DUSE_NTLMCLIENT=OFF \
        -DCMAKE_SKIP_RPATH=ON >&2
      gmake -j4; gmake install
    '';
  };

  nix = mkSrcPkg {
    pname = "nix"; version = "2.24.15";
    src = { url = "https://github.com/NixOS/nix/archive/refs/tags/2.24.15.tar.gz";
            sha256 = "e395732ec576b7f65359c80bc5a23335ad2a8c382f4f14c370bbc236708d4749"; };
    deps = [ boostContext sqlite curl openssl libsodium libarchive brotli editline libgit2 zlib xz ];
    linkDeps = [ boost nlohmann_json toml11 ];
    build = ''
      for p in ${./nix-illumos-patches/224}/0*.patch; do patch -p1 < "$p" >&2; done
      # The GitHub archive ships no ./configure; the AX_BOOST_BASE macro comes
      # from the build host's autoconf-archive (build tool).
      ACLOCAL_PATH=/usr/share/aclocal autoreconf -fi -I /usr/share/aclocal >&2
      export CONFIG_SHELL=/usr/bin/bash
      # gcc's temporaries: the builder's /tmp is a small tmpfs (824 MB on the build
      # guest) and nix's C++ units filled it (measured: "No space left on device").
      export TMPDIR="$SRC/.tmp"; mkdir -p "$TMPDIR"
      # boost/json/toml11 as system headers (as nixpkgs passes deps): GCC drops a
      # -I that is also -isystem, so their warnings no longer trip nix's own
      # -Werror=suggest-override (measured in boost/format/alt_sstream_impl.hpp).
      SYSI="-isystem ${boost}/include -isystem ${nlohmann_json}/include -isystem ${toml11}/include"
      # Header-only deps leave their store paths in .rodata through __FILE__ in
      # assert strings (measured: libnixutil.so named boost/format/*.hpp after
      # strip-debug), which pulls ~150 MB of boost headers into nix's runtime
      # closure. Map them away, as nixpkgs' remove-references-to does after the fact.
      SYSI="$SYSI -fmacro-prefix-map=${boost}=/boost -fmacro-prefix-map=${nlohmann_json}=/nlohmann_json -fmacro-prefix-map=${toml11}=/toml11"
      export CXXFLAGS="-O2 $SYSI" CFLAGS="-O2"
      bash ./configure --prefix="$out" --sysconfdir=/etc --localstatedir=/nix/var \
        --with-store-dir=/nix/store --with-boost=${boost} --with-boost-libdir=${boost}/lib/amd64 \
        --disable-gc --disable-markdown --disable-cpuid --disable-unit-tests \
        --disable-functional-tests --disable-doc-gen >&2
      [ -f Makefile.config ] || bash ./config.status --file=Makefile.config:Makefile.config.in >&2
      # ERROR_SWITCH_ENUM= : toml11 trips -Werror=switch-enum (upstream's own override).
      # -j3: each nix C++ unit peaks near 1 GB in cc1plus; the build guest has 6 GB, no swap.
      gmake -j3 ERROR_SWITCH_ENUM= OPTIMIZE=1 >&2
      gmake install ERROR_SWITCH_ENUM= sysconfdir="$out/etc" >&2
      unset LD_LIBRARY_PATH LD_LIBRARY_PATH_64 || true
      "$out/bin/nix" --version >&2
      # strip first (mk-src-pkg strips again later; idempotent): DWARF names the
      # headers too, and only what survives the strip is a real reference.
      find "$out" -type f | while read -r f; do
        [ "$(od -An -tx1 -N4 "$f" | tr -d ' \n')" = 7f454c46 ] && { chmod u+w "$f"; /usr/bin/gstrip --strip-debug "$f"; }
        true
      done
      for x in ${boost} ${nlohmann_json} ${toml11}; do
        if grep -rlq "$x" "$out"; then echo "FATAL: nix still references build-only $x" >&2; exit 1; fi
      done
    '';
  };
}
