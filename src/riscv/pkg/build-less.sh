#!/usr/bin/env bash
# build-less.sh -- less 668 (release tarball), static, natively, against the sysroot ncurses.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${SRC:-$HOME/ws/rvpkg/dl/less-668}"; OUT="${OUT:-$HOME/scratch/rvpkg/out}"
cd "$SRC"
make distclean >/dev/null 2>&1 || true
CC="$HERE/solnix-cc" CFLAGS="-O2" LIBS="-lncurses" ./configure --host=riscv64-unknown-elf \
	--build="${SOLNIX_BUILD:-riscv64-linux-gnu}" --with-regex=posix --with-editor=/bin/sbase-box
grep -q '#define HAVE_POSIX_REGCOMP 1' defines.h
make -j8
mkdir -p "$OUT"; cp less "$OUT/less"
echo LESS_DONE
