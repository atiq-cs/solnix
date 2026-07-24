#!/usr/bin/env bash
# oi-nix-setup.sh — build and install the Nix package manager NATIVELY on the
# solnix OpenIndiana (illumos) build host, create the /nix store, and prove a
# trivial derivation realises into /nix/store.  This is solnix task P0.2.
#
# Route chosen (after research): BUILD FROM SOURCE.  There is no prebuilt Nix
# for illumos — OpenIndiana IPS has none, and the SmartOS pkgsrc binary set
# (25k+ packages) carries no nix-* package.  So we compile Nix 2.3.16 (the last
# classic autotools release, smallest dependency footprint, and the release
# line whose ./configure already resolves the canonical system name to
# "x86_64-solaris") from source, carrying three small illumos fixes.
#
# Single-user mode is used (no nix-daemon, no build-users group).  That is
# sufficient for the bootstrap gate; a daemon under SMF is a later task.
#
# Prereq dependencies come from OpenIndiana IPS (the "Bootstrap exception" — the
# host's pkg is allowed for build-only tooling).  The only twist is the C++ ABI:
# IPS boost 1.78 was compiled against gcc-14's libstdc++ (needs CXXABI_1.3.15),
# so Nix must be built with gcc-14 too, NOT gcc-10.
#
# Run ON the host as root:  ./oi-nix-setup.sh
# It is written to be re-runnable; it skips steps whose output already exists.

set -euo pipefail

NIX_VERSION="2.3.16"
NIX_URL="https://releases.nixos.org/nix/nix-${NIX_VERSION}/nix-${NIX_VERSION}.tar.xz"
SRCROOT="/var/tmp/nixsrc"
SRCDIR="${SRCROOT}/nix-${NIX_VERSION}"
PREFIX="/nix-tools"                 # Nix binaries/libs (kept off the store path)
PATCHDIR="$(cd "$(dirname "$0")" && pwd)/nix-illumos-patches"

# Build toolchain: gcc-14 to match the ABI of IPS boost 1.78 (CXXABI_1.3.15).
GCC=/usr/gcc/14
export CC="${GCC}/bin/gcc"
export CXX="${GCC}/bin/g++"

echo "=== [1/7] install build prerequisites from IPS (bootstrap exception) ==="
# Everything Nix 2.3 needs at build time.  openssl(1.0)/sqlite3/curl/bz2/lzma/
# brotli headers ship in the base image; these are the ones that do not:
#   - developer/gcc-14: the C++ compiler whose libstdc++ matches IPS boost
#   - system/library/boost: boost/format.hpp + boost/lexical_cast.hpp + the
#     boost_context/thread/system libs used by nix's coroutine code
#   - autoconf/automake/libtool/pkg-config: run ./configure
#   - text/gnu-patch: ./configure hard-requires `patch`
#   - file/gnu-coreutils: GNU `install` (illumos /usr/sbin/install is the SVR4
#     one that "searches" for the source file and breaks `gmake install`)
#   - library/readline-8: GNU readline (we build the REPL against it, see below)
env PKG_CLIENT_CONNECT_TIMEOUT=60 \
    PKG_CLIENT_LOWSPEED_TIMEOUT=180 \
  pkg install -v \
    developer/gcc-14 \
    system/library/boost \
    developer/build/autoconf \
    developer/build/automake \
    developer/build/libtool \
    developer/build/pkg-config \
    text/gnu-patch \
    file/gnu-coreutils \
    library/readline-8 \
  || true   # already-installed packages make pkg exit non-zero; ignore

echo "=== [2/7] create the /nix store on its own ZFS dataset ==="
if ! zfs list rpool/nix >/dev/null 2>&1; then
  zfs create -o mountpoint=/nix rpool/nix
fi
mkdir -p /nix/store /nix/var/nix

echo "=== [3/7] fetch + unpack Nix ${NIX_VERSION} source ==="
mkdir -p "${SRCROOT}"
cd "${SRCROOT}"
if [ ! -f "nix-${NIX_VERSION}.tar.xz" ]; then
  curl -sS -L -O "${NIX_URL}"
fi
if [ ! -d "${SRCDIR}" ]; then
  tar xf "nix-${NIX_VERSION}.tar.xz"
fi

echo "=== [4/7] apply illumos source patches ==="
# Two source patches (idempotent: skip if the marker already present):
#   0001  util.cc  — pull in <sys/termios.h> so struct winsize / TIOCGWINSZ are
#                    defined (Linux gets them transitively via <sys/ioctl.h>).
#   0002  build.cc — (a) provide cfmakeraw() (absent from illumos libc), and
#                    (b) push the STREAMS modules ptem+ldterm onto the build
#                    pty slave, without which tcgetattr fails EINVAL and every
#                    build dies with "getting pseudoterminal attributes".
cd "${SRCDIR}"
if ! grep -q "sys/termios.h" src/libutil/util.cc; then
  gpatch -p1 < "${PATCHDIR}/0001-illumos-winsize-termios.patch"
fi
if ! grep -q "cfmakeraw" src/libstore/build.cc; then
  gpatch -p1 < "${PATCHDIR}/0002-illumos-cfmakeraw-pty-streams.patch"
fi

echo "=== [5/7] configure ==="
# Notes:
#  - CONFIG_SHELL=bash: the generated ./configure contains a bash `declare -a
#    arr=(...)` array (in the S3 detection block) that illumos /bin/sh (ksh93)
#    cannot even parse.  Force bash.
#  - editline: illumos has libedit but not troglobit-editline, and libedit lacks
#    the el_hist_size/rl_set_complete_func symbols nix's REPL uses under the
#    "not READLINE" path.  We instead build the REPL against GNU readline by
#    forcing -DREADLINE (below) and pointing EDITLINE_LIBS at -lreadline; the
#    EDITLINE_CFLAGS/LIBS env vars short-circuit configure's editline probe.
#  - --with-boost=/usr: header-only usage; libs are in /usr/lib(/amd64).
export PATH="/usr/gnu/bin:${GCC}/bin:/usr/bin:/usr/sbin:${PATH}"
export PKG_CONFIG_PATH=/usr/lib/amd64/pkgconfig:/usr/lib/pkgconfig
export CPPFLAGS="-I/usr/include"
export CFLAGS="-m64 -O2"
export CXXFLAGS="-m64 -O2 -std=c++17"
export LDFLAGS="-m64 -L/usr/lib/amd64 -R${GCC}/lib/amd64"
export EDITLINE_CFLAGS=" "
export EDITLINE_LIBS="-lreadline"
export CONFIG_SHELL=/usr/bin/bash SHELL=/usr/bin/bash

bash ./configure \
  --prefix="${PREFIX}" \
  --with-store-dir=/nix/store \
  --localstatedir=/nix/var \
  --disable-doc-gen \
  --disable-gc \
  --with-boost=/usr

# configure writes Makefile.config from the environment; force the two final
# tweaks in case they were not picked up (idempotent):
#   -DREADLINE : make repl.cc use <readline/readline.h> instead of <editline.h>
#   EDITLINE_LIBS -> -lreadline : link the REPL against GNU readline
grep -q -- "-DREADLINE" Makefile.config || \
  gsed -i "s|^CXXFLAGS = |CXXFLAGS = -DREADLINE |" Makefile.config
gsed -i "s|^EDITLINE_LIBS = -ledit|EDITLINE_LIBS = -lreadline|" Makefile.config

echo "=== [6/7] build + install ==="
gmake -j"$(psrinfo | wc -l)"
gmake install

echo "=== [7/7] configure single-user nix + init store DB + GATE ==="
# Single-user: no build-users group.  No sandbox: illumos has zones/privileges,
# not Linux namespaces, so the Linux chroot sandbox does not apply here.
mkdir -p "${PREFIX}/etc/nix"
cat > "${PREFIX}/etc/nix/nix.conf" <<EOF
build-users-group =
sandbox = false
EOF

export PATH="${PREFIX}/bin:${PATH}"
export NIX_CONF_DIR="${PREFIX}/etc/nix"
# The installed binaries carry a baked RUNPATH (${GCC}/lib/amd64:${PREFIX}/lib),
# so no LD_LIBRARY_PATH is needed at runtime.

nix-store --init

# GATE: a trivial derivation must realise into /nix/store.
cat > /var/tmp/hello.nix <<'EOF'
derivation {
  name = "hello-illumos";
  system = "x86_64-solaris";
  builder = "/usr/bin/bash";
  args = [ "-c" "echo hello-from-illumos > $out" ];
}
EOF

OUT="$(nix-build /var/tmp/hello.nix)"
echo "built store path: ${OUT}"
echo "contents: $(cat "${OUT}")"
nix-store --verify-path "${OUT}" && echo "GATE PASS: path verified in /nix/store"

cat <<EOF

--------------------------------------------------------------------------
Nix ${NIX_VERSION} is installed at ${PREFIX} and works natively on illumos.
To use it in a shell:
    export PATH=${PREFIX}/bin:\$PATH
    export NIX_CONF_DIR=${PREFIX}/etc/nix
--------------------------------------------------------------------------
EOF
