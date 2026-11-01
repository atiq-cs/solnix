#!/usr/bin/env bash
# build-zlib.sh -- zlib (upstream release tarball) for the solnix riscv64 kernel, built
# natively on the board with solnix-cc; installs libz.a + zlib.h into the sysroot.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${SRC:-$HOME/ws/rvpkg/dl/zlib-1.3.2}"
SR="${SOLNIX_SYSROOT:-$HOME/scratch/rvpkg/sysroot}"
OUT="${OUT:-$HOME/scratch/rvpkg/out}"
cd "$SRC"
make distclean >/dev/null 2>&1 || true
CC="$HERE/solnix-cc" CFLAGS="-O2" ./configure --static --prefix="$SR"
# configure must find vsnprintf (a missing one silently turns gzprintf into a stub)
grep -q 'Checking for vsnprintf() in stdio.h... Yes' configure.log
make -j8 libz.a example minigzip
cp libz.a "$SR/lib/"; cp zlib.h zconf.h "$SR/include/solnix/"
mkdir -p "$OUT"; cp example minigzip "$OUT/"
echo ZLIB_DONE
