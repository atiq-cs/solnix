#!/usr/bin/env bash
# sparc-nix224-setup.sh — build Nix 2.24.15 natively on `sun` (sun4u sparcv9,
# OI-Hipster, gcc-13) via the autotools path, installed PARALLEL to the running
# 2.3.16 (/nix/nix-tools) at /nix/nix-tools224 so sparc breadth on 2.3.16 is
# never disrupted. Merges the x86_64 224 recipe (scripts/oi-nix224-setup.sh:
# 5 illumos source patches + autotools flow + vendored toml11) with the four
# sparc-only fixes from scripts/sparc-nix-setup.sh (the 2.3.16 sparc nix build).
#
# ILLUMOS SOURCE PATCHES (OS-level, arch-neutral — same series as x86_64 224):
#   0001 terminal.cc            <sys/termios.h> for struct winsize/TIOCGWINSZ
#   0002 signals.cc             exclude __sun from the glibc sigorset branch
#   0003 local-derivation-goal  cfmakeraw body + STREAMS ptem/ldctl on build pty
#   0004 pathlocks.cc           drop LOCK_NB on flock unlock (illumos EINVAL)
#   0005 current-process.cc     getSelfExe via /proc/self/path/a.out
#
# SPARC DELTAS vs oi-nix224-setup.sh (x86_64):
#   * gcc-13 (sun has no gcc-14; libstdc++ 6.0.32 satisfies boost 1.78).
#   * sparcv9 lib dirs: /usr/lib/sparcv9, /usr/openssl/3/lib/sparcv9.
#   * --host=sparcv9-sun-solaris2.11 ; system=sparc64-solaris.
#   * libgit2 is NATIVE in OI-sparc (1.9.6, .pc + header) — no from-source build
#     (x86_64 had to build it; sparc does not).
#
#   * SPARC FIX A — boost.coroutine2 ucontext backend. illumos boost 1.78's
#     libboost_context ships ONLY stack_traits (no sparc64 fcontext asm), so
#     nix's serialise.cc (boost/coroutine2 -> fiber.hpp, fcontext default)
#     fails to link. -DBOOST_USE_UCONTEXT selects fiber_ucontext.hpp (libc
#     getcontext/makecontext/swapcontext) + stack_traits. The backend's
#     out-of-line current()/schwarz-counter live in boost's own src/fiber.cpp,
#     which the illumos pkg did not build for ucontext; drop the verbatim
#     upstream TU (boost-fiber-ucontext.cc) into src/libutil/ so nix links it.
#
#   * SPARC FIX B — static gcc runtime + static nix libs. The illumos gcc-13
#     *shared* libgcc_s.so.1 SPARC unwinder is broken (any C++ throw aborts in
#     uw_init_context_1: _Unwind_Find_FDE returns 0 walking PT_SUNW_UNWIND via
#     dl_iterate_phdr). The STATIC libgcc unwinder works. -static-libgcc only
#     fixes the final exe, so we ALSO build nix's libs static (BUILD_SHARED_LIBS=0)
#     -> monolithic exes, one consistent static libgcc each, exceptions never
#     cross a .so boundary. 2.24's static-lib rule partial-links every object
#     (ld -r -o lib.o) then `ar crs lib.a lib.o` — the single combined .o means
#     C++ static-init self-registrations (primops/store-backends) are pulled in
#     whole, so the 2.3.16 -zallextract whole-archive wrap is NOT needed here.
#
#   * SPARC FIX C — AR=/usr/bin/ar, LD=/usr/bin/ld (SVR4/Solaris). GNU ar
#     (binutils 2.46) bus-errors archiving the large static-libstdc++ objects;
#     illumos /usr/bin/ar handles them. /usr/bin/ld is the Solaris link editor
#     used for the `ld -r` object combine.
#
# Run ON sun as gburd (non-root; /nix is a gburd-owned ZFS dataset):
#   ./sparc-nix224-setup.sh
# Re-runnable; steps whose output exists are skipped. GENTLE: -j2.
set -euo pipefail

NIX_VERSION="2.24.15"
NIX_URL="https://github.com/NixOS/nix/archive/refs/tags/${NIX_VERSION}.tar.gz"
TOML11_VERSION="3.8.1"

SRCROOT="/scratch/gburd-nixbuild/nix224src"
SRCDIR="${SRCROOT}/nix-${NIX_VERSION}"
PREFIX="/nix/nix-tools224"          # PARALLEL to /nix/nix-tools (2.3.16)
STOREDIR="/nix/store"
STATEDIR="/nix/var"
TOML_INC="${SRCROOT}/toml11-inc"
CABUNDLE="/scratch/gburd-nixbuild/ca-bundle.crt"
PATCHDIR="/scratch/gburd-nixbuild/patches224"
FIBER_SHIM="/scratch/gburd-nixbuild/patches/boost-fiber-ucontext.cc"
DONE="/scratch/gburd-nixbuild/DONE-nix224"
rm -f "${DONE}"

GCC=/usr/gcc/13
export CC="${GCC}/bin/gcc" CXX="${GCC}/bin/g++"
export PATH="/usr/gnu/bin:${GCC}/bin:/usr/bin:/usr/sbin:${PATH}"

echo "=== [1/8] CA bundle (illumos ships per-CA PEMs) ==="
[ -s "${CABUNDLE}" ] || cat /etc/certs/CA/*.pem > "${CABUNDLE}"
export NIX_SSL_CERT_FILE="${CABUNDLE}"

echo "=== [2/8] store + state dirs (real /nix, gburd-owned) ==="
mkdir -p "${STOREDIR}" "${STATEDIR}/nix" "${PREFIX}"

echo "=== [3/8] vendored toml11 ${TOML11_VERSION} (header-only, not in OI) ==="
if [ ! -f "${TOML_INC}/toml.hpp" ]; then
  mkdir -p "${SRCROOT}"; cd "${SRCROOT}"
  /usr/bin/curl -fL --cacert "${CABUNDLE}" -o toml11.tar.gz \
    "https://github.com/ToruNiina/toml11/archive/refs/tags/v${TOML11_VERSION}.tar.gz"
  /usr/gnu/bin/tar xzf toml11.tar.gz
  mkdir -p "${TOML_INC}"
  cp -r "toml11-${TOML11_VERSION}/toml.hpp" "toml11-${TOML11_VERSION}/toml" "${TOML_INC}/" 2>/dev/null || \
    cp -r "toml11-${TOML11_VERSION}/include/toml11" "${TOML_INC}/"
fi

echo "=== [4/8] fetch + unpack Nix ${NIX_VERSION} ==="
mkdir -p "${SRCROOT}"; cd "${SRCROOT}"
[ -f "nix-${NIX_VERSION}.tar.gz" ] || /usr/bin/curl -fL --cacert "${CABUNDLE}" -o "nix-${NIX_VERSION}.tar.gz" "${NIX_URL}"
[ -d "${SRCDIR}" ] || /usr/gnu/bin/tar xzf "nix-${NIX_VERSION}.tar.gz"
cd "${SRCDIR}"

echo "=== [5/8] illumos patch series + sparc ucontext shim ==="
grep -q 'sys/termios.h'         src/libutil/terminal.cc                        || /usr/gnu/bin/patch -p1 < "${PATCHDIR}/0001-illumos-winsize-termios.patch"
grep -q '!defined(__sun)'       src/libutil/unix/signals.cc                    || /usr/gnu/bin/patch -p1 < "${PATCHDIR}/0002-illumos-sigorset-fallback.patch"
grep -q 'I_PUSH'                src/libstore/unix/build/local-derivation-goal.cc || /usr/gnu/bin/patch -p1 < "${PATCHDIR}/0003-illumos-cfmakeraw-pty-streams.patch"
grep -q 'type == LOCK_UN ?'     src/libstore/unix/pathlocks.cc                 || /usr/gnu/bin/patch -p1 < "${PATCHDIR}/0004-illumos-flock-unlock-einval.patch"
grep -q 'proc/self/path/a.out'  src/libutil/current-process.cc                 || /usr/gnu/bin/patch -p1 < "${PATCHDIR}/0005-illumos-getselfexe-procfs.patch"
# SPARC FIX A: out-of-line ucontext-backend symbols.
cp "${FIBER_SHIM}" src/libutil/boost-fiber-ucontext.cc

echo "=== [6/8] configure (autotools) ==="
# ax_boost_base.m4 is not shipped in the GitHub archive and OI-sparc has no
# autoconf-archive pkg installed -> drop the single macro into m4/ so
# AX_BOOST_BASE (configure.ac:188) resolves at autoreconf time.
if [ ! -f m4/ax_boost_base.m4 ]; then
  /usr/bin/curl -fsSL --cacert "${CABUNDLE}" -o m4/ax_boost_base.m4 \
    https://raw.githubusercontent.com/autoconf-archive/autoconf-archive/master/m4/ax_boost_base.m4
fi
export ACLOCAL_PATH=/usr/share/aclocal
mkdir -p config
for f in config.guess config.sub install-sh; do
  [ -f "config/$f" ] || cp "/usr/share/automake-1.16/$f" config/ 2>/dev/null || true
done
[ -x ./configure ] || autoreconf -fi -I /usr/share/aclocal -I m4

export CPPFLAGS="-I/usr/include -I${TOML_INC}"
export CFLAGS="-m64 -O2"
# SPARC FIX A: ucontext coroutine backend (no sparc64 fcontext asm in boost).
export CXXFLAGS="-m64 -O2 -std=c++2a -DBOOST_USE_UCONTEXT -I${TOML_INC}"
# SPARC FIX B: static gcc runtime (working unwinder). With BUILD_SHARED_LIBS=0
# there are no nix .so runtime deps, so no -R plumbing is needed.
export LDFLAGS="-m64 -L/usr/lib/sparcv9 -L/usr/openssl/3/lib/sparcv9 -static-libgcc -static-libstdc++"
export EDITLINE_CFLAGS=" " EDITLINE_LIBS="-lreadline"
export CONFIG_SHELL=/usr/bin/bash SHELL=/usr/bin/bash
# openssl-3 first (the /usr default .pc is openssl-1.0); sparcv9 dep .pc dirs.
export PKG_CONFIG_PATH="/usr/openssl/3/lib/sparcv9/pkgconfig:/usr/lib/sparcv9/pkgconfig:/usr/share/pkgconfig:/usr/lib/pkgconfig"

bash ./configure \
  --prefix="${PREFIX}" \
  --with-store-dir="${STOREDIR}" \
  --localstatedir="${STATEDIR}" \
  --host=sparcv9-sun-solaris2.11 \
  --disable-gc \
  --disable-markdown \
  --disable-unit-tests \
  --disable-cpuid \
  --disable-doc-gen

# AC_CONFIG_FILES([]) is empty -> instantiate Makefile.config explicitly.
[ -f Makefile.config ] || CONFIG_SHELL=/usr/bin/bash bash ./config.status --file=Makefile.config:Makefile.config.in

# system tag = sparc64-solaris (configure guesses sparcv9-...).
/usr/gnu/bin/sed -i 's|^system = .*|system = sparc64-solaris|' Makefile.config
# Fold vendored toml11 include into CXXFLAGS; drive the REPL against GNU readline
# (illumos libedit lacks the symbols nix's REPL wants).
grep -q "toml11-inc" Makefile.config || \
  /usr/gnu/bin/sed -i "s|^CXXFLAGS = |CXXFLAGS = -I${TOML_INC} |" Makefile.config
grep -q 'define USE_READLINE' config.h || echo '#define USE_READLINE 1' >> config.h
/usr/gnu/bin/sed -i 's|^EDITLINE_LIBS = .*|EDITLINE_LIBS = -lreadline|' Makefile.config
# 64-bit boost lib search path (configure may guess -L/usr/lib = 32-bit).
/usr/gnu/bin/sed -i 's|^BOOST_LDFLAGS = .*|BOOST_LDFLAGS = -L/usr/lib/sparcv9|' Makefile.config
# SPARC FIX B: static gcc runtime in the global link flags too (so any lib link
# also carries the working static unwinder).
grep -q -- '-static-libstdc++' Makefile.config || \
  /usr/gnu/bin/sed -i 's|^LDFLAGS = |LDFLAGS = -static-libgcc -static-libstdc++ |' Makefile.config

echo "=== [7/8] build + install (static nix libs; sparc AR/LD) ==="
# SPARC FIX B: BUILD_SHARED_LIBS=0 -> static libs (ld -r combine + ar crs).
# SPARC FIX C: SVR4 ar + Solaris ld. ERROR_SWITCH_ENUM= disarms toml11's
# per-file -Werror=switch-enum (upstream's own documented override).
MK="BUILD_SHARED_LIBS=0 AR=/usr/bin/ar LD=/usr/bin/ld ERROR_SWITCH_ENUM="
gmake -j2 ${MK}
gmake install ${MK}

echo "=== [8/8] single-user nix.conf + GATE ==="
mkdir -p "${PREFIX}/etc/nix"
cat > "${PREFIX}/etc/nix/nix.conf" <<EOF
build-users-group =
sandbox = false
substituters = https://cache.solnix.io
trusted-public-keys = cache.solnix.io-1:8UNrVAOSOrI9PGHc8/pD2Yqp265ZeYb3OId+gv4+wm8=
system = sparc64-solaris
ssl-cert-file = ${CABUNDLE}
EOF

export PATH="${PREFIX}/bin:${PATH}"
export NIX_CONF_DIR="${PREFIX}/etc/nix"

echo "--- nix --version ---"
"${PREFIX}/bin/nix" --version
echo "--- EM_SPARCV9? ---"
/usr/bin/elfdump -e "${PREFIX}/bin/nix" 2>/dev/null | grep -i machine || \
  file "${PREFIX}/bin/nix"
echo "--- ldd (any 'not found' => runtime gap) ---"
ldd "${PREFIX}/bin/nix" 2>&1 | grep -i 'not found' && echo "RUNTIME GAP" || echo "RUNTIME OK: all NEEDED resolve"
echo "--- nix eval ---"
"${PREFIX}/bin/nix" --extra-experimental-features 'nix-command' eval --expr '1 + 2'
echo "--- structuredAttrs (native in 2.24) ---"
"${PREFIX}/bin/nix" --extra-experimental-features 'nix-command' config show 2>/dev/null | grep -i 'experimental-features\|structured' | head || true

"${PREFIX}/bin/nix-store" --init 2>/dev/null || true

cat > "${SRCROOT}/trivial224.nix" <<'EOF'
derivation {
  name = "hello-sparc224-trivial";
  system = "sparc64-solaris";
  builder = "/usr/bin/bash";
  args = [ "-c" "echo hello-from-sparc-2.24 > $out" ];
}
EOF
OUT="$("${PREFIX}/bin/nix-build" --no-out-link "${SRCROOT}/trivial224.nix")"
echo "TRIVIAL built: ${OUT} -> $(cat "${OUT}")"
"${PREFIX}/bin/nix-store" --verify-path "${OUT}" && echo "TRIVIAL GATE PASS"

echo "ALL-OK" > "${DONE}"
echo "=== nix-${NIX_VERSION} for sparcv9 installed -> ${PREFIX} ==="
