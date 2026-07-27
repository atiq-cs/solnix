#!/bin/sh
# aa-cross-build.sh — re-create the richlowe/arm64-gate cross toolchain on an
# ouch builder. The cross gcc ($CROSS, aarch64-unknown-solaris2.11) + OmniOS
# braich sysroot died with the numa host; only proto/root_aarch64 was archived.
# This clones the harness fresh and runs `gmake download` + `gmake setup`, which
# builds cross binutils, the Solaris ld (sgs), the sysroot, and the cross gcc.
#
# Multi-hour. Runs under scripts/oi-job.sh (detached). Isolated under /aarch64/gate
# so the restored proto at /aarch64/arm64-gate/illumos-gate/proto stays untouched.
set -eu
# The harness Makefile is deliberately GNU-make-hostile (line 3). It needs the
# illumos Sun make (/usr/bin/make). Keep /usr/bin ahead of /usr/gnu/bin so `make`
# resolves to Sun make. onbld tools (bldenv/nightly/dmake) on PATH for sub-builds.
export PATH=/usr/bin:/opt/onbld/bin:/usr/gnu/bin:/usr/sbin:/bin
MAKE=/usr/bin/make
BASE=/aarch64/gate
mkdir -p "$BASE"
cd "$BASE"

# 1. Clone the harness (Makefile, env/aarch64, tools/, qemu-setup/). Pin to HEAD
#    (8d182d88 at time of writing). The harness Makefile clones the gate + gcc +
#    binutils itself under `make download`.
if [ ! -d arm64-gate/.git ]; then
  git clone https://github.com/richlowe/arm64-gate arm64-gate
fi
cd arm64-gate
echo "=== harness rev: $(git rev-parse HEAD) ==="
ls

# 2. Host python must match the OmniOS braich sysroot python (was 3.13 per §5).
#    Ensure it's installed (host had 3.9 + 3.14 only). Non-fatal if pkg refuses.
python3.13 --version 2>/dev/null || pkg install -q runtime/python-313 2>&1 | tail -2 || true

# 2b. GDB/GCC configure need GMP + MPFR + MPC headers. OI ships gmp.h directly in
#     /usr/include (NOT /usr/include/gmp like OmniOS), and mpfr/mpc are separate
#     pkgs not installed by default. Install them and override GMPINCDIR so the
#     harness's --with-gmp-include points at the right dir (fixes gdb configure
#     "requires GMP 4.2+, MPFR 3.1.0+").
# Also texinfo (makeinfo, for binutils/gdb .info docs), swig+bison (sgs/gdb),
#     astdev + illumos-closed (sgs/nightly). Per the harness README dep list.
for p in library/mpfr library/mpc text/texinfo developer/swig developer/parser/bison \
         developer/astdev developer/illumos-closed file/gnu-coreutils; do
  pkg list "$p" >/dev/null 2>&1 || pkg install -q "$p" 2>&1 | tail -1 || true
done
MAKEFLAGS_GMP='GMPINCDIR=/usr/include'
# Put texinfo's makeinfo on PATH (OI installs it under /usr/bin normally).
which makeinfo >/dev/null 2>&1 || export PATH="$PATH:$(dirname "$(find /usr -name makeinfo 2>/dev/null | head -1)" 2>/dev/null)"
makeinfo --version 2>/dev/null | head -1 || echo "WARN: makeinfo still missing"

# 3. download — clones gate/gcc/binutils/u-boot/atf/dtc + pkgrecv OmniOS braich
#    aarch64 sysroot. Big (several GB), network-bound. Skip if already done
#    (the gate clone is the last big artifact; presence = download complete).
if [ ! -d "$BASE/arm64-gate/illumos-gate/usr/src" ]; then
  echo "=== make download ==="
  $MAKE download 2>&1 | tail -60
else
  echo "=== make download: SKIP (sources present) ==="
fi

# 4. setup — build sysroot, cross binutils, sgs (Solaris ld + headers),
#    boot-gcc, gcc (the cross compiler), perl, u-boot, atf, dtc, barn.
#    Pass GMPINCDIR=/usr/include (OI layout) so gdb/gcc configure find gmp.h.
echo "=== make setup (GMPINCDIR=/usr/include) ==="
$MAKE $MAKEFLAGS_GMP setup 2>&1 | tail -120

# 5. Gate check: the cross gcc compiles an aarch64 object.
CROSS="$BASE/arm64-gate/build/cross"
echo "=== CROSS=$CROSS ==="
find "$BASE/arm64-gate/build" -name 'aarch64-unknown-solaris2.11-gcc' 2>/dev/null | head
GCC=$(find "$BASE/arm64-gate/build" -name 'aarch64-unknown-solaris2.11-gcc' 2>/dev/null | head -1)
if [ -n "$GCC" ]; then
  echo 'int main(void){return 0;}' > /tmp/aa-hello.c
  "$GCC" -c /tmp/aa-hello.c -o /tmp/aa-hello.o && file /tmp/aa-hello.o
  "$GCC" -dumpmachine
  echo "CROSS-GCC-OK"
else
  echo "CROSS-GCC-MISSING (setup incomplete)"
fi
