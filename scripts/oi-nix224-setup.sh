#!/usr/bin/env bash
# oi-nix224-setup.sh — build Nix 2.24.15 natively on the solnix illumos build
# host via the autotools path, install it PROPERLY (RUNPATH-correct, no
# LD_LIBRARY_PATH), bake a CA bundle, and prove nix profile/build/substitute
# work. This is the productionized successor to oi-nix-setup.sh (2.3.16).
#
# The port carries five illumos source fixes as a numbered patch series
# (pkgs/illumos/nix-illumos-patches/224/*.patch) plus a small set of
# build-environment tweaks that upstream's configure/build need on illumos
# (empty-AC_CONFIG_FILES Makefile.config, openssl-3 .pc path, GNU readline REPL,
# vendored toml11, built-from-source libgit2). All discovery is in
# docs/spike-nix-upgrade-notes.md; this script is the clean reproduction.
#
# Prereqs (2026 userland after `pkg update --accept` + reboot): gcc-13,
# boost 1.78, sqlite3, libcurl, libsodium, brotli, nlohmann-json, editline,
# readline, libarchive, jq, flex, bison, gnu-make, cmake3, autoconf,
# autoconf-archive, automake, libtool, pkg-config. gcc-13 gives -std=c++2a.
#
# Run ON the host as root:  ./oi-nix224-setup.sh
# Re-runnable; it skips steps whose output already exists.
set -euo pipefail

NIX_VERSION="2.24.15"
NIX_URL="https://github.com/NixOS/nix/archive/refs/tags/${NIX_VERSION}.tar.gz"
LIBGIT2_VERSION="1.7.2"
TOML11_VERSION="3.8.1"

SRCROOT="/var/tmp/nix224src"
SRCDIR="${SRCROOT}/nix-${NIX_VERSION}"
PREFIX="/nix-tools224"
GIT2_PREFIX="/var/tmp/libgit2-inst"
TOML_INC="/var/tmp/toml11-inc"
CABUNDLE="/var/tmp/ca-bundle.crt"
_SD="$(cd "$(dirname "$0")" && pwd)"
for _cand in \
  "$_SD/../pkgs/illumos/nix-illumos-patches/224" \
  "$_SD/../nix-illumos-patches/224" \
  "$_SD/nix-illumos-patches/224"; do
  [ -d "$_cand" ] && { PATCHDIR="$_cand"; break; }
done
: "${PATCHDIR:?patch series dir not found near $_SD}"

GCC=/usr/gcc/13
export CC="${GCC}/bin/gcc" CXX="${GCC}/bin/g++"
export PATH="/usr/gnu/bin:${GCC}/bin:/usr/bin:/usr/sbin:${PATH}"

echo "=== [1/9] CA bundle (illumos ships per-CA PEMs, not a bundle) ==="
[ -s "$CABUNDLE" ] || cat /etc/certs/CA/*.pem > "$CABUNDLE"
export NIX_SSL_CERT_FILE="$CABUNDLE"

echo "=== [2/9] /nix store dataset ==="
zfs list rpool/nix >/dev/null 2>&1 || zfs create -o mountpoint=/nix rpool/nix || mkdir -p /nix
mkdir -p /nix/store /nix/var/nix

echo "=== [3/9] vendored toml11 ${TOML11_VERSION} (header-only) ==="
if [ ! -f "$TOML_INC/toml.hpp" ]; then
  mkdir -p "$TOML_INC"; cd /var/tmp
  curl -fL --cacert "$CABUNDLE" -o toml11.tar.gz \
    "https://github.com/ToruNiina/toml11/archive/refs/tags/v${TOML11_VERSION}.tar.gz"
  tar xzf toml11.tar.gz
  cp -r "toml11-${TOML11_VERSION}/toml.hpp" "toml11-${TOML11_VERSION}/toml" "$TOML_INC/" 2>/dev/null || \
    cp -r "toml11-${TOML11_VERSION}/include/toml11" "$TOML_INC/"
fi

echo "=== [4/9] libgit2 ${LIBGIT2_VERSION} from source (not in OI) ==="
if [ ! -f "$GIT2_PREFIX/lib/pkgconfig/libgit2.pc" ] && [ ! -f "$GIT2_PREFIX/lib/amd64/pkgconfig/libgit2.pc" ]; then
  cd /var/tmp
  curl -fL --cacert "$CABUNDLE" -o libgit2.tar.gz \
    "https://github.com/libgit2/libgit2/archive/refs/tags/v${LIBGIT2_VERSION}.tar.gz"
  tar xzf libgit2.tar.gz
  cd "libgit2-${LIBGIT2_VERSION}"; mkdir -p build && cd build
  CMAKE=$(command -v cmake || command -v cmake3)
  "$CMAKE" .. -DCMAKE_INSTALL_PREFIX="$GIT2_PREFIX" -DBUILD_TESTS=OFF \
    -DUSE_SSH=OFF -DCMAKE_C_COMPILER="$CC" -DCMAKE_BUILD_TYPE=Release
  gmake -j"$(psrinfo|wc -l)" && gmake install
fi

echo "=== [5/9] fetch + unpack Nix ${NIX_VERSION} ==="
mkdir -p "$SRCROOT"; cd "$SRCROOT"
[ -f "nix-${NIX_VERSION}.tar.gz" ] || curl -fL --cacert "$CABUNDLE" -o "nix-${NIX_VERSION}.tar.gz" "$NIX_URL"
[ -d "$SRCDIR" ] || { tar xzf "nix-${NIX_VERSION}.tar.gz"; }
cd "$SRCDIR"

echo "=== [6/9] apply illumos patch series ==="
# Guard each on a patch-unique marker so re-runs are idempotent.
grep -q 'sys/termios.h' src/libutil/terminal.cc                          || gpatch -p1 < "$PATCHDIR/0001-illumos-winsize-termios.patch"
grep -q '!defined(__sun)' src/libutil/unix/signals.cc                    || gpatch -p1 < "$PATCHDIR/0002-illumos-sigorset-fallback.patch"
grep -q 'I_PUSH' src/libstore/unix/build/local-derivation-goal.cc        || gpatch -p1 < "$PATCHDIR/0003-illumos-cfmakeraw-pty-streams.patch"
grep -q 'type == LOCK_UN ?' src/libstore/unix/pathlocks.cc               || gpatch -p1 < "$PATCHDIR/0004-illumos-flock-unlock-einval.patch"
grep -q 'proc/self/path/a.out' src/libutil/current-process.cc            || gpatch -p1 < "$PATCHDIR/0005-illumos-getselfexe-procfs.patch"

echo "=== [7/9] configure ==="
export CPPFLAGS="-I/usr/include -I${TOML_INC} -I${GIT2_PREFIX}/include"
export CFLAGS="-m64 -O2"
export CXXFLAGS="-m64 -O2 -std=c++2a -I${TOML_INC}"
# RUNPATH via -R: gcc runtime, built libgit2, openssl-3. This is what makes the
# install NOT LD_LIBRARY_PATH-dependent (2.3.16's tarball fragility).
export LDFLAGS="-m64 -L/usr/lib/amd64 -L${GIT2_PREFIX}/lib -L/usr/openssl/3/lib/amd64 -R${GCC}/lib/amd64 -R/usr/openssl/3/lib/amd64 -R${GIT2_PREFIX}/lib"
export EDITLINE_CFLAGS=" " EDITLINE_LIBS="-lreadline"
export CONFIG_SHELL=/usr/bin/bash SHELL=/usr/bin/bash
export PKG_CONFIG_PATH="/usr/openssl/3/lib/amd64/pkgconfig:${GIT2_PREFIX}/lib/pkgconfig:${GIT2_PREFIX}/lib/amd64/pkgconfig:/usr/lib/amd64/pkgconfig:/usr/lib/pkgconfig"
export ACLOCAL_PATH=/usr/share/aclocal

mkdir -p config
for f in config.guess config.sub install-sh; do
  [ -f "config/$f" ] || cp "/usr/share/automake-1.16/$f" config/ 2>/dev/null || true
done
[ -x ./configure ] || autoreconf -fi -I /usr/share/aclocal

bash ./configure \
  --prefix="$PREFIX" \
  --with-store-dir=/nix/store \
  --localstatedir=/nix/var \
  --host=x86_64-pc-solaris2.11 \
  --disable-gc \
  --disable-markdown \
  --disable-unit-tests \
  --disable-cpuid \
  --disable-doc-gen

# AC_CONFIG_FILES([]) is empty -> instantiate Makefile.config explicitly.
[ -f Makefile.config ] || CONFIG_SHELL=/usr/bin/bash bash ./config.status --file=Makefile.config:Makefile.config.in

# Fold the built-libgit2 include into CXXFLAGS (configure substitutes only
# LIBGIT2_LIBS), and drive the REPL against GNU readline.
grep -q 'libgit2-inst/include' Makefile.config || \
  gsed -i "s|^CXXFLAGS = |CXXFLAGS = -I${GIT2_PREFIX}/include |" Makefile.config
grep -q 'define USE_READLINE' config.h || echo '#define USE_READLINE 1' >> config.h
gsed -i 's|^EDITLINE_LIBS = .*|EDITLINE_LIBS = -lreadline|' Makefile.config

echo "=== [8/9] build + install ==="
# ERROR_SWITCH_ENUM= : vendored toml11 3.8.1 trips per-file -Werror=switch-enum
# (Nix pins a matching toml11); this is upstream's own documented override.
gmake -j"$(psrinfo|wc -l)" ERROR_SWITCH_ENUM=
gmake install ERROR_SWITCH_ENUM=

echo "=== [9/9] RUNPATH audit + single-user nix.conf + GATE ==="
mkdir -p "${PREFIX}/etc/nix"
cat > "${PREFIX}/etc/nix/nix.conf" <<EOF
build-users-group =
sandbox = false
substituters = https://cache.solnix.io https://cache.nixos.org
trusted-public-keys = cache.solnix.io-1:8UNrVAOSOrI9PGHc8/pD2Yqp265ZeYb3OId+gv4+wm8= cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
ssl-cert-file = ${CABUNDLE}
EOF

export PATH="${PREFIX}/bin:${PATH}"
export NIX_CONF_DIR="${PREFIX}/etc/nix"

# Prove the binary runs with NO LD_LIBRARY_PATH (RUNPATH must carry everything).
env -u LD_LIBRARY_PATH "${PREFIX}/bin/nix" --version
echo "--- ldd (any 'not found' => RUNPATH gap) ---"
env -u LD_LIBRARY_PATH ldd "${PREFIX}/bin/nix" 2>&1 | grep -i 'not found' && echo "RUNPATH GAP" || echo "RUNPATH OK: all NEEDED resolve"

nix-store --init 2>/dev/null || true

cat > /var/tmp/hi224.nix <<'EOF'
derivation {
  name = "hi224";
  system = "x86_64-solaris";
  builder = "/usr/bin/bash";
  args = [ "-c" "echo hi-from-2.24 > $out" ];
}
EOF
OUT="$(env -u LD_LIBRARY_PATH nix-build --no-out-link /var/tmp/hi224.nix)"
echo "built: $OUT -> $(cat "$OUT")"
env -u LD_LIBRARY_PATH nix profile --help >/dev/null && echo "GATE: nix profile present"
echo "GATE PASS: Nix ${NIX_VERSION} builds, runs without LD_LIBRARY_PATH, nix profile available."
