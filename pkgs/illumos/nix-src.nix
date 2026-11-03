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
{ mkSrcPkg, zlib, openssl, libcSlice, gccLib, system, libSub ? "lib/amd64", nixCxxFlags ? ""
, hostTools ? [ ]   # store-only PATH base (base-src.nix): [] on the exempt seed instance
, cmake ? null      # store cmake for brotli/nlohmann_json/libgit2 (the OI host had /usr/bin/cmake); null on the seed/aarch64
, perl ? null      # the store perl (cli), for curl's man pages (main 4784cde); null on the seed/aarch64
, bzip2Bin ? null   # bzip2 CLI for boost's .tar.bz2 (GNU tar runs bzip2 from PATH; the OI host had /usr/bin/bzip2)
, nixBuildTools ? [ ]   # nix's autoreconf/configure tools from the store: autotools, autoconf-archive (AX_BOOST_BASE), m4, bison,
                        # flex, patch, pkg-config (the OI host's /usr/bin and /usr/share/aclocal before; [ ] = that old text)
}:
let # xz's configure, on solaris*, gives xzgrep/xzdiff/xzless/xzmore "#!/usr/xpg4/bin/sh" and a PATH=/usr/xpg4/bin prefix: host
    # paths in the out (wave6 out-host-refs, P0 run i). /bin/sh is POSIX ksh93 on illumos; NixOS adds no PATH prefix. The seed
    # instance keeps upstream's text (its xz is build-only and its drv must not move).
    xzScripts = if hostTools == [ ] then "" else " gl_cv_posix_shell=/bin/sh --enable-path-for-scripts=no";
    withTools = extra: if hostTools == [ ] then { } else { nativeTools = builtins.filter (x: x != null) extra ++ hostTools; }; in
# libSub: the 64-bit lib dir of the plain derivations below ("lib" on aarch64, LP64 only).
# nixCxxFlags: extra CXXFLAGS for nix itself (aarch64: see aarch64/src.nix). "" keeps the x86 text byte-identical.

rec {
  # boost: headers + boost_context (the only compiled boost lib nix links).
  boost = mkSrcPkg ({
    pname = "boost"; version = "1.86.0";
    selfRunpath = false;
    src = { url = "https://archives.boost.io/release/1.86.0/source/boost_1_86_0.tar.bz2";
            sha256 = "1bed88e40401b2cb7a1f76d4bab499e352fa4d0c5f31c0dbae64e24d34d7513b"; };
    build = ''
      # b2 itself is a build tool, compiled by whatever g++ is on PATH; the
      # library is compiled by $CXX (the from-source gcc) via user-config.jam.
      # b2's engine build clears CXX and runs `g++` by name (tools/build/src/engine/build.sh test_compiler; the OI host had
      # /usr/bin/g++): the builder's own wrappers under those names, on PATH for this step only.
      mkdir -p "$W/b2bin"; ln -sf "$(command -v $CXX)" "$W/b2bin/g++"; ln -sf "$(command -v $CC)" "$W/b2bin/gcc"
      PATH="$W/b2bin:$PATH" ./bootstrap.sh --with-toolset=gcc --with-libraries=context >&2
      echo "using gcc : solnix : $(command -v $CXX) ;" > user-config.jam
      ./b2 --user-config=user-config.jam toolset=gcc-solnix --with-context \
        variant=release link=shared threading=multi runtime-link=shared \
        address-model=64 architecture=x86 abi=sysv binary-format=elf target-os=solaris \
        --prefix="$out" --libdir="$out/lib/amd64" -j4 install >&2
    '';
  } // withTools [ bzip2Bin ]);

  # libboost_context alone, for the runtime closure: the boost output above is
  # ~150 MB of headers nix needs only to compile. boost is built with
  # selfRunpath = false, so the copied library names no path inside boost.
  boostContext = derivation {
    name = "boost-context-1.86.0"; inherit system boost;
    builder = "/usr/bin/bash";
    # store-only (wave6, gate2 A1): coreutils (mkdir cp) + grep, from the store tools nix-src's recipes use
    PATH = builtins.concatStringsSep ":" (map (d: "${d}/bin") hostTools);
    args = [ "-c" (''
      set -eu
    '' + (if hostTools == [ ] then "export PATH=/usr/gnu/bin:/usr/bin\n" else "/usr/bin/bash ${./path-gate.sh}\n") + ''
      mkdir -p $out/${libSub}; cp -P $boost/${libSub}/libboost_context.so* $out/${libSub}/
      if grep -rq "$boost" $out; then echo "FATAL: boost-context still names $boost" >&2; exit 1; fi
    '') ];
  };

  # Mozilla CA bundle (curl.se's extract), for nix's ssl-cert-file.
  cacert = derivation {
    name = "cacert-2024-09-24"; inherit system;
    pem = import <nix/fetchurl.nix> { url = "https://curl.se/ca/cacert-2024-09-24.pem";
            sha256 = "189d3cf6d103185fba06d76c1af915263c6d42225481a1759e853b33ac857540"; };
    builder = "/usr/bin/bash";
    # store-only (wave6, gate2 A1) when the instance has store tools; the seed instance keeps /usr/bin (bootstrap set)
    PATH = builtins.concatStringsSep ":" (map (d: "${d}/bin") hostTools);
    args = [ "-c" (if hostTools == [ ] then "/usr/bin/mkdir -p $out/etc/ssl/certs && /usr/bin/cp $pem $out/etc/ssl/certs/ca-bundle.crt"
      else "/usr/bin/bash ${./path-gate.sh} && mkdir -p $out/etc/ssl/certs && cp $pem $out/etc/ssl/certs/ca-bundle.crt") ];
  };

  sqlite = mkSrcPkg {
    pname = "sqlite"; version = "3.53.2";   # queue target (CVE feed fixed_in: CVE-2026-11824); 3.46.1 had 5 High/Critical
    # sha3-256 of sqlite3.c = 44fd61b9... = the 3.53.2 release log's
    src = { url = "https://www.sqlite.org/2026/sqlite-autoconf-3530200.tar.gz";
            sha256 = "588ad51949419a56ebe81fe56193d510c559eb94c9a57748387860b5d3069316"; };
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --disable-readline --disable-editline
      gmake -j4; gmake install
    '';
  };

  xz = mkSrcPkg {
    pname = "xz"; version = "5.8.1";   # queue target (CVE-2025-31115 fixed_in); .sig: Lasse Collin 3690C240CE51B467
    src = { url = "https://github.com/tukaani-project/xz/releases/download/v5.8.1/xz-5.8.1.tar.gz";
            sha256 = "507825b599356c10dca1cd720c9d0d0c9d5400b9de300af00e4d1ea150795543"; };
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --disable-nls --disable-doc${xzScripts}
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
    pname = "curl"; version = "8.23.0";
    src = { url = "https://curl.se/download/curl-8.23.0.tar.xz";   # .asc: Daniel Stenberg 27EDEAF2; == nixpkgs
            sha256 = "8dadd7d2536a314f982ad05a651b713f426bf7d02cc2c76cffb9796f2218e6c5"; };
    deps = [ zlib openssl ];
    # store-only PATH + config.site (recipes1). perl renders the man pages (NixOS: nativeBuildInputs = [ perl ... ]): configure looks for it
    # in $PATH:/usr/local/bin/perl:/usr/bin/, so without a store perl an OI host's /usr/bin/perl turned the docs on and a solnix host's
    # absence turned them off (two different outs; recipes1 W4).
    nativeTools = (if perl == null then [ ] else [ perl ]) ++ hostTools;
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static \
        --with-openssl=${openssl} --with-zlib=${zlib} --without-libpsl --without-brotli \
        --without-zstd --without-libidn2 --without-nghttp2 --without-libssh2 --disable-ldap \
        --with-ca-bundle=${cacert}/etc/ssl/certs/ca-bundle.crt --without-ca-path
      gmake -j4; gmake install
      # curl --version's CA line comes from the compiled default; a wrong one
      # reads as "network is NOT up" (rc 77) on a root with no /etc/ssl bundle.
      grep -q '#define CURL_CA_BUNDLE "${cacert}/etc/ssl/certs/ca-bundle.crt"' lib/curl_config.h \
        || { echo "FATAL: curl CA bundle default is not the store cacert" >&2; exit 1; }
    '';
  };

  # zstd and bzip2 for libarchive, which nix uses for every compression filter.
  # Without them nix cannot substitute: cache.solnix.io serves its 404 bodies
  # with `Content-Encoding: zstd` (nix asks for it, filetransfer.cc), and nix
  # writes build logs bzip2-compressed (compress-build-log, derivation-goal.cc).
  # Measured: "failed to get libarchive filter by name: Using external zstd
  # program" and "couldn't initialize compression (Using external bzip2 program)".
  zstd = mkSrcPkg {
    pname = "zstd"; version = "1.5.6";
    src = { url = "https://github.com/facebook/zstd/releases/download/v1.5.6/zstd-1.5.6.tar.gz";
            sha256 = "8c29e06cf42aacc1eafc4077ae2ec6c6fcb96a626157e0593d5e82a34fd403c1"; };
    # library only (multi-threaded, as nixpkgs' default); the zstd CLI is not needed.
    build = ''
      gmake -C lib -j4 CC="$CC" PREFIX="$out" LIBDIR="$out/lib/amd64" libzstd libzstd.pc
      gmake -C lib CC="$CC" PREFIX="$out" LIBDIR="$out/lib/amd64" INSTALL=install install-shared install-includes install-pc   # GNU install (store coreutils), not the OI host's ginstall
    '';
  };

  bzip2 = mkSrcPkg {
    pname = "bzip2"; version = "1.0.8";
    src = { url = "https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz";
            sha256 = "ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269"; };
    # Makefile-libbz2_so builds the shared lib with soname libbz2.so.1.0 (as
    # nixpkgs and every distro ship it); headers are the one bzlib.h.
    build = ''
      gmake -f Makefile-libbz2_so CC="$CC" >&2
      mkdir -p "$out/lib/amd64" "$out/include"
      cp libbz2.so.1.0.8 "$out/lib/amd64/"
      ln -s libbz2.so.1.0.8 "$out/lib/amd64/libbz2.so.1.0"
      ln -s libbz2.so.1.0.8 "$out/lib/amd64/libbz2.so.1"
      ln -s libbz2.so.1.0.8 "$out/lib/amd64/libbz2.so"
      cp bzlib.h "$out/include/"
    '';
  };

  libarchive = mkSrcPkg {
    pname = "libarchive"; version = "3.8.7";   # queue target (CVE-2026-5121/4424 fixed_in); same soname libarchive.so.13; .asc: Martin Matuska C040B508D63D2B36
    src = { url = "https://github.com/libarchive/libarchive/releases/download/v3.8.7/libarchive-3.8.7.tar.xz";
            sha256 = "d3a8ba457ae25c27c84fd2830a2efdcc5b1d40bf585d4eb0d35f47e99e5d4774"; };
    deps = [ zlib xz zstd bzip2 ];
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --disable-bsdtar \
        --disable-bsdcpio --disable-bsdcat --disable-bsdunzip --without-xml2 --without-expat \
        --disable-acl --disable-xattr --without-openssl --without-lz4 --without-libb2 \
        --with-zlib --with-lzma --with-zstd --with-bz2lib
      # configure silently drops a library it cannot find; insist on all four.
      for h in HAVE_ZSTD_H HAVE_LIBZSTD HAVE_ZSTD_compressStream HAVE_BZLIB_H HAVE_LIBBZ2 HAVE_LZMA_H HAVE_ZLIB_H; do
        grep -q "^#define $h 1" config.h || { echo "FATAL: libarchive configured without $h" >&2; exit 1; }
      done
      gmake -j4; gmake install
    '';
  };

  brotli = mkSrcPkg ({
    pname = "brotli"; version = "1.1.1";   # CVE-2026-111497 (fixed 1.1.1)
    src = { url = "https://github.com/google/brotli/archive/refs/tags/v1.1.1.tar.gz";
            sha256 = "1a84dfaa740994d19254bf78aa7d74a4a8040d1638f3d5f2cdecb188fd520da8"; };
    build = ''
      mkdir b; cd b
      # CMAKE_SKIP_RPATH: the compiler wrapper bakes the store RUNPATH; cmake's
      # install-time RPATH rewrite would otherwise strip it.
      cmake .. -DCMAKE_INSTALL_PREFIX="$out" -DCMAKE_INSTALL_LIBDIR=lib/amd64 -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON -DCMAKE_SKIP_RPATH=ON -DBROTLI_DISABLE_TESTS=ON >&2
      gmake -j4; gmake install
    '';
  } // withTools [ cmake ]);

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
  nlohmann_json = mkSrcPkg ({
    pname = "nlohmann_json"; version = "3.11.3";
    src = { url = "https://github.com/nlohmann/json/releases/download/v3.11.3/json.tar.xz";
            sha256 = "d6c65aca6b1ed68e7a182f4757257b107ae403032760ed6ef121c9d55e81757d"; };
    build = ''
      mkdir b; cd b
      cmake .. -DCMAKE_INSTALL_PREFIX="$out" -DJSON_BuildTests=OFF -DCMAKE_CXX_COMPILER="$CXX" >&2
      gmake install
    '';
  } // withTools [ cmake ]);

  # header-only; nix's configure checks for <toml.hpp>
  toml11 = mkSrcPkg {
    pname = "toml11"; version = "3.8.1";
    src = { url = "https://github.com/ToruNiina/toml11/archive/refs/tags/v3.8.1.tar.gz";
            sha256 = "6a3d20080ecca5ea42102c078d3415bef80920f6c4ea2258e87572876af77849"; };
    build = ''
      mkdir -p "$out/include"; cp -R toml.hpp toml "$out/include/"
    '';
  };

  libgit2 = mkSrcPkg ({
    pname = "libgit2"; version = "1.8.6";   # queue target (CVE-2026-53587 fixed_in); 1.7 has no later release (GitHub tag, no signature)
    src = { url = "https://github.com/libgit2/libgit2/archive/refs/tags/v1.8.6.tar.gz";
            sha256 = "c171e9c6fcc33455e3df46d422f4e1b3ea7c049a645051664c9cdbdc081208e7"; };
    deps = [ zlib openssl ];
    build = ''
      mkdir b; cd b
      cmake .. -DCMAKE_INSTALL_PREFIX="$out" -DCMAKE_INSTALL_LIBDIR=lib/amd64 -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTS=OFF -DBUILD_CLI=OFF -DUSE_SSH=OFF -DUSE_HTTPS=OpenSSL \
        -DOPENSSL_ROOT_DIR=${openssl} -DOPENSSL_INCLUDE_DIR=${openssl}/include \
        -DOPENSSL_CRYPTO_LIBRARY=${openssl}/lib/amd64/libcrypto.so \
        -DOPENSSL_SSL_LIBRARY=${openssl}/lib/amd64/libssl.so -DOPENSSL_USE_STATIC_LIBS=OFF \
        -DUSE_BUNDLED_ZLIB=OFF -DREGEX_BACKEND=builtin -DUSE_HTTP_PARSER=builtin -DUSE_NTLMCLIENT=OFF \
        -DCMAKE_SKIP_RPATH=ON >&2
      gmake -j4; gmake install
    '';
  } // withTools [ cmake ]);

  # aclocal dirs: AX_BOOST_BASE (autoconf-archive), PKG_CHECK_MODULES (pkgconf's pkg.m4), LT_INIT (libtool), as /usr/share/aclocal had.
  nix = let ac = builtins.filter (t: builtins.elem (t.pname or "") [ "autoconf-archive" "libtool" "pkgconf" ]) nixBuildTools;
    acDirs = map (t: "${t}/share/aclocal") ac;
    aclocalLine = if nixBuildTools == [ ] then "ACLOCAL_PATH=/usr/share/aclocal autoreconf -fi -I /usr/share/aclocal >&2"
      else "for d in ${toString acDirs}; do [ -d $d ] || { echo \"FATAL: no aclocal dir $d\" >&2; exit 1; }; done; "
        + "ACLOCAL_PATH=${builtins.concatStringsSep ":" acDirs} autoreconf -fi ${toString (map (d: "-I " + d) acDirs)} >&2"; in mkSrcPkg ({
    pname = "nix"; version = "2.24.15";
    src = { url = "https://github.com/NixOS/nix/archive/refs/tags/2.24.15.tar.gz";
            sha256 = "e395732ec576b7f65359c80bc5a23335ad2a8c382f4f14c370bbc236708d4749"; };
    deps = [ boostContext sqlite curl openssl libsodium libarchive brotli editline libgit2 zlib xz ];
    linkDeps = [ boost nlohmann_json toml11 ];
    build = ''
      for p in ${./nix-illumos-patches/224}/0*.patch; do patch -p1 < "$p" >&2; done
      # The GitHub archive ships no ./configure; the AX_BOOST_BASE macro comes
      # from the build host's autoconf-archive (build tool).
      ${aclocalLine}
      export CONFIG_SHELL=/usr/bin/bash   # the builder interpreter (path-gate's documented exemption)
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
      export CXXFLAGS="-O2 $SYSI${nixCxxFlags}" CFLAGS="-O2"
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
        [ "$(od -An -tx1 -N4 "$f" | tr -d ' \n')" = 7f454c46 ] && { chmod u+w "$f"; ${if nixBuildTools == [ ] then "/usr/bin/gstrip" else "gstrip"} --strip-debug "$f"; }
        true
      done
      for x in ${boost} ${nlohmann_json} ${toml11}; do
        if grep -rlq "$x" "$out"; then echo "FATAL: nix still references build-only $x" >&2; exit 1; fi
      done
    '';
  } // withTools nixBuildTools);   # store-only (wave6): the autotools above; [ ] (seed / aarch64) keeps the old drv
}
