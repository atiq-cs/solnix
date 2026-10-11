# pkgs/illumos/nix224.nix — pkgs.solnix.nix224: Nix 2.24.15 built FROM SOURCE as
# a proper hermetic x86_64-solaris derivation (the first-release Nix; supersedes
# the 2.3.16 ingest in nix.nix). This is the productionized form of the spike
# recipe in docs/spike-nix-upgrade-notes.md + scripts/oi-nix224-setup.sh.
#
# Standalone (plain `derivation` + bash builder), Nix 2.3.16 seed, sandbox=false,
# so the builder may fetch (each source is sha256-verified; the store path is
# content-addressed by the built NAR — deterministic given pinned srcs + patch
# store paths + host toolchain). The fork maps this onto stdenv.mkDerivation.
#
# Why "properly hermetic, not LD_LIBRARY_PATH-fragile": after `make install` the
# builder rewrites DT_RUNPATH/DT_RPATH on every produced ELF (via /usr/bin/elfedit,
# in place — illumos ELF, no patchelf) so nix and its libs resolve boost, sqlite,
# curl, openssl-3, libgit2, the gcc-13 C++ runtime, and Nix's own libs by baked
# RUNPATH. A CA bundle (illumos ships per-CA PEMs, not a bundle) is baked into
# $out/etc/ssl/certs and pointed to by ssl-cert-file in $out/etc/nix/nix.conf, so
# HTTPS substitution works with no NIX_SSL_CERT_FILE in the environment.
#
# Deps not in OI: libgit2 (built from source here), toml11 (vendored header),
# Boehm GC (--disable-gc), lowdown (--disable-markdown), libcpuid (--disable-cpuid).
#
# Host build-env prerequisites (build-time only, NOT in nix's runtime closure):
#   pkg install text/jq developer/build/autoconf-archive \
#               library/c++/nlohmann-json library/libarchive
# jq + the AX_BOOST_BASE macro (autoconf-archive) are needed by configure;
# nlohmann-json is a header-only build dep; libarchive supplies the OI system
# libarchive.so.13 that nix links (same /usr/lib/amd64 baseline as sqlite/curl/
# sodium/brotli). cmake (for the from-source libgit2) is taken from a store
# gcc14Stdenv cmake-minimal via the `cmake` arg default below.

{ nixVersion ? "2.24.15"
, nixSha256 ? "SKIP"            # sha256 of the GitHub source tarball; SKIP = trust-on-first-build
, libgit2Version ? "1.7.2"
, libgit2Sha256 ? "SKIP"
, toml11Version ? "3.8.1"
, toml11Sha256 ? "SKIP"
, gcc ? "/usr/gcc/14"           # gcc-14 gives full -std=c++2a (C++20); /usr/gcc/13
                               # is not installed on the buildhost. The C++
                               # runtime (libstdc++/libgcc_s) is bundled into
                               # $out/lib below so the closure stays host-free.
, cmake ? "/nix/store/27hi0il968a9h3hv5svfy6n95gsxbkxd-cmake-minimal-4.3.4/bin"
                               # OI ships no cmake; libgit2's build needs it.
                               # This is a from-source gcc14Stdenv cmake in the
                               # store (build-time only, not in nix's closure).
, patchDir ? ./nix-illumos-patches/224
}:

let
  # Import the patch series dir into the store once, then reference each file
  # as a sub-path of that store dir.
  patchStore = builtins.path { path = patchDir; name = "nix-illumos-patches-224"; };
  patchNames = [
    "0001-illumos-winsize-termios.patch"
    "0002-illumos-sigorset-fallback.patch"
    "0003-illumos-cfmakeraw-pty-streams.patch"
    "0004-illumos-flock-unlock-einval.patch"
    "0005-illumos-getselfexe-procfs.patch"
  ];
  patchList = builtins.concatStringsSep " " (map (n: "${patchStore}/${n}") patchNames);
in
derivation {
  name = "nix-${nixVersion}";
  system = builtins.currentSystem; # x86_64-solaris
  builder = "/usr/bin/bash";
  PATH = "/usr/gnu/bin:${gcc}/bin:/usr/bin:/usr/sbin";

  inherit nixVersion libgit2Version toml11Version gcc cmake patchList;
  nixUrl = "https://github.com/NixOS/nix/archive/refs/tags/${nixVersion}.tar.gz";
  libgit2Url = "https://github.com/libgit2/libgit2/archive/refs/tags/v${libgit2Version}.tar.gz";
  toml11Url = "https://github.com/ToruNiina/toml11/archive/refs/tags/v${toml11Version}.tar.gz";
  inherit nixSha256 libgit2Sha256 toml11Sha256;

  args = [ "-c" ''
    set -eu
    GCC="$gcc"
    export CC="$GCC/bin/gcc" CXX="$GCC/bin/g++"
    export PATH="/usr/gnu/bin:$GCC/bin:$cmake:/usr/bin:/usr/sbin"
    WORK=$(mktemp -d /tmp/nix224.XXXXXX); cd "$WORK"

    # CA bundle: illumos ships per-CA PEMs in /etc/certs/CA/, no bundle.
    CABUNDLE="$WORK/ca-bundle.crt"
    cat /etc/certs/CA/*.pem > "$CABUNDLE"

    fetch() { # url out sha
      /usr/bin/curl -fsSL --cacert "$CABUNDLE" -o "$2" "$1"
      if [ "$3" != "SKIP" ]; then
        got=$(/usr/bin/digest -a sha256 "$2")  # illumos-native; lowercase hex matches sha
        [ "$got" = "$3" ] || { echo "FATAL sha256 $2: want $3 got $got" >&2; exit 1; }
      fi
    }

    echo "=== toml11 (header-only) ===" >&2
    TOML_INC="$WORK/toml11-inc"; mkdir -p "$TOML_INC"
    fetch "$toml11Url" toml11.tar.gz "$toml11Sha256"
    /usr/gnu/bin/tar xzf toml11.tar.gz
    cp -r toml11-*/toml.hpp toml11-*/toml "$TOML_INC/" 2>/dev/null || \
      cp -r toml11-*/include/toml11 "$TOML_INC/"

    echo "=== libgit2 from source ===" >&2
    GIT2="$WORK/libgit2-inst"
    fetch "$libgit2Url" libgit2.tar.gz "$libgit2Sha256"
    /usr/gnu/bin/tar xzf libgit2.tar.gz
    ( cd libgit2-* && mkdir -p b && cd b
      CMAKE=$(command -v cmake || command -v cmake3)
      "$CMAKE" .. -DCMAKE_INSTALL_PREFIX="$GIT2" -DBUILD_TESTS=OFF -DUSE_SSH=OFF \
        -DCMAKE_C_COMPILER="$CC" -DCMAKE_BUILD_TYPE=Release >/dev/null
      gmake -j"$(psrinfo|wc -l)" >/dev/null && gmake install >/dev/null )

    echo "=== fetch + unpack Nix ===" >&2
    fetch "$nixUrl" nix.tar.gz "$nixSha256"
    /usr/gnu/bin/tar xzf nix.tar.gz
    cd nix-*/

    echo "=== apply illumos patch series ===" >&2
    for _p in $patchList; do
      /usr/gnu/bin/patch -p1 < "$_p" || { echo "FATAL: patch $_p failed" >&2; exit 1; }
    done

    echo "=== configure ===" >&2
    export CPPFLAGS="-I/usr/include -I$TOML_INC -I$GIT2/include"
    export CFLAGS="-m64 -O2"
    export CXXFLAGS="-m64 -O2 -std=c++2a -I$TOML_INC"
    export LDFLAGS="-m64 -L/usr/lib/amd64 -L$GIT2/lib -L/usr/openssl/3/lib/amd64 -R$GCC/lib/amd64 -R/usr/openssl/3/lib/amd64 -R$GIT2/lib"
    export EDITLINE_CFLAGS=" " EDITLINE_LIBS="-lreadline"
    export CONFIG_SHELL=/usr/bin/bash SHELL=/usr/bin/bash
    # /usr/share/pkgconfig carries nlohmann_json.pc (header-only lib); the
    # amd64 pkgconfig dirs carry libarchive/sqlite3/libcurl/libsodium/brotli.
    export PKG_CONFIG_PATH="/usr/share/pkgconfig:/usr/openssl/3/lib/amd64/pkgconfig:$GIT2/lib/pkgconfig:$GIT2/lib/amd64/pkgconfig:/usr/lib/amd64/pkgconfig:/usr/lib/pkgconfig"
    export ACLOCAL_PATH=/usr/share/aclocal
    mkdir -p config
    for f in config.guess config.sub install-sh; do
      [ -f "config/$f" ] || cp "/usr/share/automake-1.16/$f" config/ 2>/dev/null || true
    done
    [ -x ./configure ] || autoreconf -fi -I /usr/share/aclocal >/dev/null 2>&1

    bash ./configure \
      --prefix="$out" \
      --with-store-dir=/nix/store \
      --localstatedir=/nix/var \
      --sysconfdir="$out/etc" \
      --host=x86_64-pc-solaris2.11 \
      --disable-gc --disable-markdown --disable-unit-tests \
      --disable-cpuid --disable-doc-gen >&2

    [ -f Makefile.config ] || CONFIG_SHELL=/usr/bin/bash bash ./config.status --file=Makefile.config:Makefile.config.in
    grep -q 'libgit2-inst/include' Makefile.config || \
      /usr/gnu/bin/sed -i "s|^CXXFLAGS = |CXXFLAGS = -I$GIT2/include |" Makefile.config
    grep -q 'define USE_READLINE' config.h || echo '#define USE_READLINE 1' >> config.h
    /usr/gnu/bin/sed -i 's|^EDITLINE_LIBS = .*|EDITLINE_LIBS = -lreadline|' Makefile.config

    echo "=== build + install ===" >&2
    # ERROR_SWITCH_ENUM= : vendored toml11 trips -Werror=switch-enum; upstream's
    # own documented override for dependency-header cases.
    gmake -j"$(psrinfo|wc -l)" ERROR_SWITCH_ENUM= >&2
    gmake install ERROR_SWITCH_ENUM= >&2

    echo "=== bundle libgit2 into \$out/lib (so RUNPATH has no build-temp path) ===" >&2
    # libgit2 was built into a build-temp prefix that will not exist at runtime;
    # copy its shared objects into $out/lib so nix resolves them from the store.
    mkdir -p "$out/lib"
    cp -P "$GIT2"/lib/libgit2.so* "$out/lib/" 2>/dev/null || cp -P "$GIT2"/lib64/libgit2.so* "$out/lib/" 2>/dev/null || true

    echo "=== bundle gcc-14 C++ runtime into \$out/lib (host-free closure) ===" >&2
    # nix's binaries NEED libstdc++.so.6 / libgcc_s.so.1 from the compiler. To
    # keep the closure host-free (all /nix/store + /lib/64 libc-family), copy
    # the gcc-14 runtime into $out/lib and let RUNPATH resolve it there — the
    # file content is baked into the store NAR, so it lives in /nix/store, not
    # under /usr/gcc at runtime.
    for _l in libstdc++.so.6 libstdc++.so.6.0.33 libgcc_s.so.1; do
      if [ -e "$GCC/lib/amd64/$_l" ]; then
        cp -P "$GCC/lib/amd64/$_l" "$out/lib/" 2>/dev/null || true
      fi
    done
    # Preserve the .so.6 -> .so.6.0.33 symlink shape if cp -P flattened it.
    ( cd "$out/lib" && [ -e libstdc++.so.6.0.33 ] && { rm -f libstdc++.so.6; ln -s libstdc++.so.6.0.33 libstdc++.so.6; } ) 2>/dev/null || true

    echo "=== bake CA bundle + nix.conf ===" >&2
    mkdir -p "$out/etc/ssl/certs" "$out/etc/nix"
    cp "$CABUNDLE" "$out/etc/ssl/certs/ca-bundle.crt"
    cat > "$out/etc/nix/nix.conf" <<CONF
build-users-group =
sandbox = false
substituters = https://cache.solnix.io https://cache.nixos.org
trusted-public-keys = cache.solnix.io-1:5HAVNxgJW1VK0O6lHSq45MSUwddLO6EM2Rz4NEjRUVk= cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
ssl-cert-file = $out/etc/ssl/certs/ca-bundle.crt
CONF

    echo "=== RUNPATH relocate: bake dep dirs so nix runs with NO LD_LIBRARY_PATH ===" >&2
    # Real dep lib dirs (keep tight: existing dirs only, so the .dynstr grow stays
    # under the illumos ~500-char ceiling). $out/lib carries Nix's own libnix*.so,
    # the bundled libgit2.so, AND the bundled gcc-14 libstdc++/libgcc_s; no
    # build-temp path and no /usr/gcc path is referenced at runtime.
    RP="$out/lib:$out/lib/amd64:/usr/openssl/3/lib/amd64:/usr/lib/amd64"
    find "$out" -type f 2>/dev/null | while read -r f; do
      if /usr/bin/elfdump -d "$f" 2>/dev/null | grep -Eq 'SONAME|NEEDED|RUNPATH|RPATH'; then
        chmod u+w "$f" 2>/dev/null || true
        /usr/bin/elfedit -e "dyn:runpath $RP" "$f" 2>/dev/null || echo "WARN relocate $f (len ''${#RP})" >&2
      fi
    done

    echo "=== self-check: nix runs WITHOUT LD_LIBRARY_PATH ===" >&2
    env -u LD_LIBRARY_PATH "$out/bin/nix" --version >&2
    if env -u LD_LIBRARY_PATH ldd "$out/bin/nix" 2>&1 | grep -qi 'not found'; then
      echo "FATAL: RUNPATH gap — nix has unresolved NEEDED" >&2
      env -u LD_LIBRARY_PATH ldd "$out/bin/nix" 2>&1 | grep -i 'not found' >&2
      exit 1
    fi
    echo "=== nix-${nixVersion} installed -> $out (RUNPATH-correct, CA baked) ===" >&2
  '' ];
}
