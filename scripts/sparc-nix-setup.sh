#!/usr/bin/env bash
# sparc-nix-setup.sh — build + install Nix 2.3.16 natively on `sun` (sun4u
# sparcv9, OI-Hipster, gcc-13), store at the REAL /nix/store (gburd-writable
# ZFS dataset, single-user, no root). Mirrors scripts/oi-nix-setup.sh with
# sparc/gcc-13 adjustments and two sparc-only fixes.
#
# SPARC DELTAS vs oi-nix-setup.sh (x86_64):
#   * gcc-13 (sun has no gcc-14; libstdc++ 6.0.32 already satisfies boost 1.78).
#   * store at /nix/store, prefix /nix-tools, state /nix/var (the real dataset).
#   * boost path /usr/lib/sparcv9 not /usr/lib/amd64.
#
#   * FIX 1 — static libgcc/libstdc++ + --disable-shared (the decisive combo).
#     The illumos gcc-13 *shared* libgcc_s.so.1 SPARC unwinder is broken: any
#     C++ throw aborts in uw_init_context_1 because _Unwind_Find_FDE returns 0
#     (the dynamic unwinder can't locate the FDE via dl_iterate_phdr on illumos
#     PT_SUNW_UNWIND binaries). The STATIC libgcc unwinder works (crtbegin
#     __register_frame, no phdr walk). But -static-libgcc only helps the final
#     executable; nix's own .so libs would still pull dynamic libgcc_s, and
#     mixing static libgcc across a .so boundary breaks cross-.so exceptions
#     (terminate/wrong type). So we also pass --disable-shared: nix builds its
#     internal libs as static .a, linked into monolithic executables, one
#     consistent static libgcc each, exceptions never cross a .so boundary.
#
#   * FIX 2 — boost.coroutine2 ucontext backend. illumos boost 1.78's
#     libboost_context has ONLY stack_traits (boost ships NO sparc64 fcontext
#     asm), so nix's serialise.cc (boost/coroutine2 -> boost/context/fiber.hpp,
#     fcontext backend by default) fails to link. -DBOOST_USE_UCONTEXT selects
#     fiber_ucontext.hpp (libc getcontext/makecontext/swapcontext, all present)
#     + stack_traits (present). The ucontext backend's out-of-line
#     current()/schwarz-counter live in boost's src/fiber.cpp, which the
#     illumos package didn't build for ucontext; we drop that verbatim upstream
#     TU (boost-fiber-ucontext.cc) into src/libutil/ so nix compiles+links it.
#     BOOST_LDFLAGS is pointed at the 64-bit lib dir.
set -euo pipefail

NIX_VERSION="2.3.16"
NIX_URL="https://releases.nixos.org/nix/nix-${NIX_VERSION}/nix-${NIX_VERSION}.tar.xz"
SRCROOT="/scratch/gburd-nixbuild"
SRCDIR="${SRCROOT}/nix-${NIX_VERSION}"
PREFIX="/nix/nix-tools"           # Nix binaries/libs (off the store path,
                                   # under gburd-owned /nix so no root needed)
STOREDIR="/nix/store"
STATEDIR="/nix/var"
PATCHDIR="${SRCROOT}/patches"
DONE="${SRCROOT}/DONE-setup"
rm -f "${DONE}"

GCC=/usr/gcc/13
export CC="${GCC}/bin/gcc"
export CXX="${GCC}/bin/g++"

echo "=== [1/6] prepare store + state dirs (real /nix) ==="
mkdir -p "${STOREDIR}" "${STATEDIR}/nix" "${PREFIX}"

echo "=== [2/6] fetch + unpack Nix ${NIX_VERSION} source ==="
mkdir -p "${SRCROOT}"; cd "${SRCROOT}"
[ -f "nix-${NIX_VERSION}.tar.xz" ] || curl -sS -L -O "${NIX_URL}"
rm -rf "${SRCDIR}"                 # fresh: no half-built objects from prior try
tar xf "nix-${NIX_VERSION}.tar.xz"

echo "=== [3/6] apply illumos source patches + sparc coroutine shim ==="
cd "${SRCDIR}"
grep -q "sys/termios.h" src/libutil/util.cc || \
  /usr/gnu/bin/patch -p1 < "${PATCHDIR}/0001-illumos-winsize-termios.patch"
grep -q "I_PUSH" src/libstore/build.cc || \
  /usr/gnu/bin/patch -p1 < "${PATCHDIR}/0002-illumos-cfmakeraw-pty-streams.patch"
# FIX 2: supply the ucontext backend's out-of-line symbols (compiled by nix's
# libutil rules with the same CXXFLAGS incl -DBOOST_USE_UCONTEXT).
cp "${PATCHDIR}/boost-fiber-ucontext.cc" src/libutil/boost-fiber-ucontext.cc

echo "=== [4/6] configure ==="
export PATH="/usr/gnu/bin:${GCC}/bin:/usr/bin:/usr/sbin:${PATH}"
export PKG_CONFIG_PATH=/usr/lib/sparcv9/pkgconfig:/usr/lib/pkgconfig
export CPPFLAGS="-I/usr/include"
export CFLAGS="-m64 -O2"
# FIX 2: ucontext coroutine backend.
export CXXFLAGS="-m64 -O2 -std=c++17 -DBOOST_USE_UCONTEXT"
# FIX 1: static libgcc/libstdc++ (working unwinder). No -R needed: with
# static gcc runtime + --disable-shared there are no nix/gcc .so runtime deps.
export LDFLAGS="-m64 -L/usr/lib/sparcv9 -static-libgcc -static-libstdc++"
export EDITLINE_CFLAGS=" "
export EDITLINE_LIBS="-lreadline"
export CONFIG_SHELL=/usr/bin/bash SHELL=/usr/bin/bash

bash ./configure \
  --prefix="${PREFIX}" \
  --with-store-dir="${STOREDIR}" \
  --localstatedir="${STATEDIR}" \
  --disable-shared \
  --disable-doc-gen \
  --disable-gc \
  --with-boost=/usr

CONFIG_SHELL=/usr/bin/bash bash ./config.status --file=Makefile.config:Makefile.config.in

# -DREADLINE: repl.cc against GNU readline instead of editline.
grep -q -- "-DREADLINE" Makefile.config || \
  /usr/gnu/bin/sed -i "s|^CXXFLAGS = |CXXFLAGS = -DREADLINE |" Makefile.config
/usr/gnu/bin/sed -i "s|^EDITLINE_LIBS = -ledit|EDITLINE_LIBS = -lreadline|" Makefile.config
# FIX 2: make sure -DBOOST_USE_UCONTEXT is in the compile flags used for *.cc.
grep -q -- "-DBOOST_USE_UCONTEXT" Makefile.config || \
  /usr/gnu/bin/sed -i "s|^CXXFLAGS = |CXXFLAGS = -DBOOST_USE_UCONTEXT |" Makefile.config
# 64-bit boost lib search path (configure guesses -L/usr/lib = 32-bit).
/usr/gnu/bin/sed -i "s|^BOOST_LDFLAGS = .*|BOOST_LDFLAGS = -L/usr/lib/sparcv9|" Makefile.config
# FIX 1: ensure static-libgcc/libstdc++ land in the global link flags, not just
# the program LDFLAGS (so the .so shared libs also carry the working unwinder).
grep -q -- "-static-libstdc++" Makefile.config || \
  /usr/gnu/bin/sed -i "s|^LDFLAGS = |LDFLAGS = -static-libgcc -static-libstdc++ |" Makefile.config

# --disable-shared uses static archives via `$(AR) crs`. Two sparc traps:
#  (a) nix's mk/ never probes AR; the Makefile.config default `ar` (SVR4)
#      produces an armap the Solaris ld can read — use /usr/bin/ar.
#  (b) GNU ar (/usr/gnu/bin/ar, binutils 2.46.1) BUS-ERRORS building the
#      large libnixstore.a/libnixexpr.a (>100 MB, static-libstdc++ bloats the
#      objects); illumos /usr/bin/ar handles them. So force /usr/bin/ar.
grep -q "^AR = /usr/bin/ar" Makefile.config || \
  /usr/gnu/bin/sed -i "s|^AR = .*|AR = /usr/bin/ar|" Makefile.config

# FIX 3 — whole-archive for the nix static libs. With --disable-shared, nix's
# primops/store-backends self-register via C++ static initializers in their
# own .o files (fromTOML.o, fetchGit.o, local-store.o, ...). The linker drops
# those objects from a static .a because nothing references their symbols, so
# `builtins.fromTOML` etc. silently vanish at runtime. Wrap the nix archives
# in the program link with Solaris ld -zallextract/-zdefaultextract so every
# object (incl. the registrations) is pulled in. Patch the static-lib branch
# of mk/libraries.mk to emit the wrap in each lib's LDFLAGS_USE.
grep -q "zallextract" mk/libraries.mk || /usr/gnu/bin/sed -i \
  's|^    $(1)_LDFLAGS_USE += $$($(1)_PATH) $$($(1)_LDFLAGS)|    $(1)_LDFLAGS_USE += -Wl,-zallextract $$($(1)_PATH) -Wl,-zdefaultextract $$($(1)_LDFLAGS)|' \
  mk/libraries.mk

echo "=== [5/6] build + install ==="
gmake -j2 AR=/usr/bin/ar
gmake install AR=/usr/bin/ar

echo "=== [6/6] single-user nix.conf + init store DB + trivial-drv GATE ==="
mkdir -p "${PREFIX}/etc/nix"
# NB: no `store = /nix/store` line — that equals the compiled-in default and,
# with a non-default state dir, nix misreads it as a "diverted store" and
# refuses to build. Compiled --with-store-dir=/nix/store handles it.
cat > "${PREFIX}/etc/nix/nix.conf" <<EOF
build-users-group =
sandbox = false
substituters = https://cache.solnix.io
trusted-public-keys = cache.solnix.io-1:8UNrVAOSOrI9PGHc8/pD2Yqp265ZeYb3OId+gv4+wm8=
system = sparc64-solaris
EOF

export PATH="${PREFIX}/bin:${PATH}"
export NIX_CONF_DIR="${PREFIX}/etc/nix"

nix-store --init

cat > "${SRCROOT}/trivial.nix" <<'EOF'
derivation {
  name = "hello-sparc-trivial";
  system = "sparc64-solaris";
  builder = "/usr/bin/bash";
  args = [ "-c" "echo hello-from-sparc > $out" ];
}
EOF

OUT="$(nix-build "${SRCROOT}/trivial.nix" --no-out-link)"
echo "TRIVIAL built store path: ${OUT}"
echo "TRIVIAL contents: $(cat "${OUT}")"
nix-store --verify-path "${OUT}" && echo "TRIVIAL GATE PASS"
"${PREFIX}/bin/nix-store" --version

echo "ALL-OK" > "${DONE}"
