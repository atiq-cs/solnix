#!/usr/bin/env bash
# build-ncurses.sh -- ncurses 6.5 (release tarball), static, natively on the board.
# No terminfo database (the root holds 16 files, no dirs): vt100 and dumb are
# compiled in as fallbacks. Narrow-char only (newlib's wide-char locale is minimal).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${SRC:-$HOME/ws/rvpkg/dl/ncurses-6.5}"; OUT="${OUT:-$HOME/scratch/rvpkg/out}"
SR="${SOLNIX_SYSROOT:-$HOME/scratch/rvpkg/sysroot}"
cd "$SRC"
make distclean >/dev/null 2>&1 || true
CC="$HERE/solnix-cc" CFLAGS="-O2" ./configure --host=riscv64-unknown-elf --build=riscv64-linux-gnu \
	--without-shared --without-cxx --without-cxx-binding --without-ada --without-progs \
	--without-tests --without-manpages --disable-db-install --with-fallbacks=vt100,dumb \
	--without-dlsym --disable-home-terminfo --disable-widec --without-pthread \
	--disable-database --without-debug --with-build-cc=gcc --prefix="$SR"
make -j8 libs
cp lib/libncurses.a "$SR/lib/"
mkdir -p "$SR/include/solnix/ncurses"
cp include/curses.h include/term.h include/ncurses_dll.h include/unctrl.h include/termcap.h \
	include/term_entry.h "$SR/include/solnix/" 2>/dev/null || true
cp include/curses.h include/term.h include/ncurses_dll.h include/unctrl.h "$SR/include/solnix/ncurses/"
"$HERE/solnix-cc" -O2 -o "$OUT/curstest" "$HERE/tests/curstest.c" -lncurses
# Linux-native oracle build of the same test against the same ncurses SOURCE
# is done by the caller (needs a host build); see tests/ncurses.checks.
echo NCURSES_DONE
