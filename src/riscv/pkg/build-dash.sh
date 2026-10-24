#!/usr/bin/env bash
# build-dash.sh -- dash 0.5.12 (release tarball), static, natively on the board.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${SRC:-$HOME/ws/rvpkg/dl/dash-0.5.12}"; OUT="${OUT:-$HOME/scratch/rvpkg/out}"
cd "$SRC"
make distclean >/dev/null 2>&1 || true
CC="$HERE/solnix-cc" CFLAGS="-O2 -D_GNU_SOURCE" ./configure --host=riscv64-unknown-elf \
	--build=riscv64-linux-gnu --enable-static --disable-fnmatch --disable-glob --without-libedit
# a link probe that fails for an unrelated reason makes configure claim libc lacks
# everything; these must be found
for h in HAVE_BSEARCH HAVE_STRTOD HAVE_KILLPG HAVE_GETPWNAM; do grep -q "#define $h 1" config.h; done
make -j8
mkdir -p "$OUT"; cp src/dash "$OUT/dash"
# negative control (rvsh): build-vfd.sh relinks these objects against the glue WITH the
# userland fd table (dash-vfd, sbase-box-vfd) for vfd.checks.
echo DASH_DONE
