#!/usr/bin/env bash
# Spike: attempt to build Nix 2.24.x natively on x86_64 illumos via the
# classic autotools path (2.24 ships BOTH meson and autotools; autotools is the
# lower-friction route and mirrors the 2.3.16 build).
#
# Prereqs the host must already have (pkg): gcc-13, boost 1.78, sqlite3, curl,
# libsodium, brotli, nlohmann-json, libedit/readline, GNU make/sed/patch,
# pkg-config. Missing/handled here: toml11 (vendored header), Boehm GC
# (disabled), lowdown (disabled), libgit2 (built from source), aws-sdk (off).
set -x
NIX_SRC=/var/tmp/nix-2.24.15
GCC=/usr/gcc/13
CC="${GCC}/bin/gcc"; CXX="${GCC}/bin/g++"
export CC CXX
export PATH="/usr/gnu/bin:${GCC}/bin:/usr/bin:/usr/sbin:$PATH"
export PKG_CONFIG_PATH=/usr/lib/amd64/pkgconfig:/usr/lib/pkgconfig
CABUNDLE=/var/tmp/ca-bundle.crt
[ -s "$CABUNDLE" ] || cat /etc/certs/CA/*.pem > "$CABUNDLE"

# ---- toml11: header-only, just drop toml.hpp on the include path ----
TOML_INC=/var/tmp/toml11-inc
if [ ! -f "$TOML_INC/toml.hpp" ]; then
  mkdir -p "$TOML_INC"
  cd /var/tmp
  curl -fL --cacert "$CABUNDLE" -o toml11.tar.gz \
    https://github.com/ToruNiina/toml11/archive/refs/tags/v3.8.1.tar.gz
  tar xzf toml11.tar.gz
  # single-header amalgam lives at the repo root as toml.hpp in 3.x
  cp -r toml11-3.8.1/toml.hpp toml11-3.8.1/toml "$TOML_INC/" 2>/dev/null || \
    cp -r toml11-3.8.1/include/toml11 "$TOML_INC/" 2>/dev/null || true
  ls "$TOML_INC"
fi

# ---- libgit2: build a shared lib from source (no OI package) ----
GIT2_PREFIX=/var/tmp/libgit2-inst
if [ ! -f "$GIT2_PREFIX/lib/pkgconfig/libgit2.pc" ] && [ ! -f "$GIT2_PREFIX/lib/amd64/pkgconfig/libgit2.pc" ]; then
  cd /var/tmp
  curl -fL --cacert "$CABUNDLE" -o libgit2.tar.gz \
    https://github.com/libgit2/libgit2/archive/refs/tags/v1.7.2.tar.gz
  tar xzf libgit2.tar.gz
  cd libgit2-1.7.2
  mkdir -p build && cd build
  # cmake from OI (SUNWcmake is 2.6 = too old); rely on post-update cmake, else
  # this step reports the cmake gap.
  CMAKE=$(command -v cmake || command -v cmake3)
  "$CMAKE" .. -DCMAKE_INSTALL_PREFIX="$GIT2_PREFIX" -DBUILD_TESTS=OFF \
    -DUSE_SSH=OFF -DCMAKE_C_COMPILER="$CC" -DCMAKE_BUILD_TYPE=Release 2>&1 | tail -20
  gmake_bin=$(command -v gmake)
  "$gmake_bin" -j"$(psrinfo|wc -l)" 2>&1 | tail -10 && "$gmake_bin" install 2>&1 | tail -5
fi

# ---- configure Nix 2.24 ----
cd "$NIX_SRC"
# illumos hazard recurs (was patch 0001 for 2.3.16 util.cc): terminal.cc uses
# struct winsize / TIOCGWINSZ, which on illumos live in <sys/termios.h>, not
# pulled in transitively via <sys/ioctl.h> as on Linux. Inject the include.
if ! grep -q 'sys/termios.h' src/libutil/terminal.cc; then
  gsed -i 's|# include <sys/ioctl.h>|# include <sys/ioctl.h>\n# ifdef __sun\n#  include <sys/termios.h>\n# endif|' src/libutil/terminal.cc
fi
# illumos sigorset() takes k_sigset_t (kernel type), not the glibc 3-arg form
# Nix expects; force the direct-assignment fallback branch on illumos.
python3 - <<'PY'
f="src/libutil/unix/signals.cc"
s=open(f).read()
old="#if _POSIX_C_SOURCE >= 1 || _XOPEN_SOURCE || _POSIX_SOURCE"
new="#if (_POSIX_C_SOURCE >= 1 || _XOPEN_SOURCE || _POSIX_SOURCE) && !defined(__sun)"
if old in s: open(f,"w").write(s.replace(old,new))
PY
# illumos libc lacks cfmakeraw() (build-pty raw mode still uses it in 2.24).
# Inject the standard BSD/glibc body AND push the STREAMS ptem/ldterm modules
# on the pty slave (both halves of the 2.3.16 patch-0002 hazard recur here).
python3 - <<'PY'
f="src/libstore/unix/build/local-derivation-goal.cc"
s=open(f).read()
if "static void cfmakeraw" not in s:
    body='''#ifdef __sun\n#include <termios.h>\n#include <stropts.h>\nstatic void cfmakeraw(struct termios *t){\n    t->c_iflag &= ~(IMAXBEL|IGNBRK|BRKINT|PARMRK|ISTRIP|INLCR|IGNCR|ICRNL|IXON);\n    t->c_oflag &= ~OPOST;\n    t->c_lflag &= ~(ECHO|ECHONL|ICANON|ISIG|IEXTEN);\n    t->c_cflag &= ~(CSIZE|PARENB); t->c_cflag |= CS8;\n    t->c_cc[VMIN]=1; t->c_cc[VTIME]=0;\n}\n#endif\n'''
    s=s.replace("namespace nix {", body+"\nnamespace nix {", 1)
# STREAMS: push ptem+ldterm on the pty slave so tcgetattr/tcsetattr work.
anchor='''        AutoCloseFD builderOut = open(slaveName.c_str(), O_RDWR | O_NOCTTY);\n        if (!builderOut)\n            throw SysError("opening pseudoterminal slave");'''
if anchor in s and "I_PUSH" not in s:
    inject=anchor+'''\n\n#ifdef __sun\n        if (ioctl(builderOut.get(), I_PUSH, "ptem") < 0)\n            throw SysError("pushing ptem module on pseudoterminal slave");\n        if (ioctl(builderOut.get(), I_PUSH, "ldterm") < 0)\n            throw SysError("pushing ldterm module on pseudoterminal slave");\n#endif'''
    s=s.replace(anchor, inject, 1)
open(f,"w").write(s)
PY
# illumos rejects flock(fd, LOCK_UN | LOCK_NB) with EINVAL (Linux ignores it);
# ~FdLock unlocks with wait=false -> LOCK_NB -> SysError in the destructor ->
# terminate on EVERY build. Drop LOCK_NB for the unlock (LOCK_UN) case.
python3 - <<'PY'
f="src/libstore/unix/pathlocks.cc"
s=open(f).read()
old="        while (flock(desc, type | LOCK_NB) != 0) {"
new="        while (flock(desc, type == LOCK_UN ? type : (type | LOCK_NB)) != 0) {"
if old in s: open(f,"w").write(s.replace(old,new,1))
PY
# getSelfExe(): the non-Linux #else returns nullopt so Nix can't find its own
# binary ("not an absolute path: 'nix'"). illumos exposes it at
# /proc/self/path/a.out.
python3 - <<'PY'
f="src/libutil/current-process.cc"
s=open(f).read()
old='''        #if __linux__ || __GNU__\n        return readLink("/proc/self/exe");'''
new='''        #if __linux__ || __GNU__\n        return readLink("/proc/self/exe");\n        #elif __sun\n        return readLink("/proc/self/path/a.out");'''
if old in s and "/proc/self/path/a.out" not in s: open(f,"w").write(s.replace(old,new,1))
PY
export CPPFLAGS="-I/usr/include -I${TOML_INC} -I${GIT2_PREFIX}/include"
export CFLAGS="-m64 -O2"
export CXXFLAGS="-m64 -O2 -std=c++2a -I${TOML_INC}"
export LDFLAGS="-m64 -L/usr/lib/amd64 -L${GIT2_PREFIX}/lib -L/usr/openssl/3/lib/amd64 -R${GCC}/lib/amd64 -R/usr/openssl/3/lib/amd64"
export EDITLINE_CFLAGS=" " EDITLINE_LIBS="-ledit"
export CONFIG_SHELL=/usr/bin/bash SHELL=/usr/bin/bash
# point pkg-config at the built libgit2 AND openssl-3 (the /usr default .pc is
# openssl-1.0 = libcrypto 1.0.2u, but Nix wants libcrypto >= 1.1.1).
export PKG_CONFIG_PATH="/usr/openssl/3/lib/amd64/pkgconfig:${GIT2_PREFIX}/lib/pkgconfig:${GIT2_PREFIX}/lib/amd64/pkgconfig:${PKG_CONFIG_PATH}"

# regenerate configure if only configure.ac present (2.24 tarball ships no ./configure)
export ACLOCAL_PATH=/usr/share/aclocal
mkdir -p config
for f in config.guess config.sub install-sh; do
  [ -f config/$f ] || cp /usr/share/automake-1.16/$f config/ 2>/dev/null || true
done
if [ ! -x ./configure ]; then
  autoreconf -fi -I /usr/share/aclocal 2>&1 | tail -20
fi

bash ./configure \
  --prefix=/nix-tools224 \
  --with-store-dir=/nix/store \
  --localstatedir=/nix/var \
  --host=x86_64-pc-solaris2.11 \
  --disable-gc \
  --disable-markdown \
  --disable-unit-tests \
  --disable-cpuid \
  --disable-doc-gen 2>&1 | tail -60
echo "CONFIGURE_RC=$?"

# Nix's configure.ac has AC_CONFIG_FILES([]) -> it computes every @VAR@ but
# never instantiates Makefile.config. Drive it explicitly (same trick as 2.3.16).
if [ ! -f Makefile.config ] && [ -x ./config.status ]; then
  CONFIG_SHELL=/usr/bin/bash bash ./config.status --file=Makefile.config:Makefile.config.in 2>&1 | tail
fi

# ---- build Nix 2.24 (GNU make; shared libs, RUNPATH via -R) ----
if [ -f Makefile.config ]; then
  # vendored toml11 3.8.1 has non-exhaustive switches that trip Nix's per-file
# -Werror=switch-enum (Nix pins a different toml11). Use Nix's own escape hatch:
# ERROR_SWITCH_ENUM is designed to be overridden for dependency-header cases.
# Also fold the built-libgit2 include into the global CXXFLAGS (configure only
# substitutes LIBGIT2_LIBS, not its CFLAGS, into Makefile.config).
grep -q 'libgit2-inst/include' Makefile.config || \
  gsed -i "s|^CXXFLAGS = |CXXFLAGS = -I${GIT2_PREFIX}/include |" Makefile.config
# illumos has GNU readline + BSD libedit (<histedit.h>) but NOT troglobit
# <editline.h>; build the REPL against GNU readline (same as the 2.3.16 fix).
grep -q 'define USE_READLINE' config.h || echo '#define USE_READLINE 1' >> config.h
gsed -i 's|^EDITLINE_LIBS = .*|EDITLINE_LIBS = -lreadline|' Makefile.config
gmake -j"$(psrinfo|wc -l)" ERROR_SWITCH_ENUM= 2>&1 | tail -40
echo "BUILD_RC=$?"
fi
