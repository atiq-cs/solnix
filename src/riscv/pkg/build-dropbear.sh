#!/usr/bin/env bash
# build-dropbear.sh -- dropbear 2025.88 (MIT, release tarball sha256 783f50ea...dc53d4), static, natively on the board.
# Server + dropbearkey only; public-key auth only (localoptions.h); bundled libtom; no zlib, PAM, syslog, utmp.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${SRC:-$HOME/ws/rvlogin/dl/dropbear-2025.88}"; OUT="${OUT:-$HOME/scratch/rvlogin/out}"
cd "$SRC"
# the board gcc is riscv64-linux-gnu and predefines __linux__; this target is not Linux
make distclean >/dev/null 2>&1 || true
cp "$HERE/dropbear-localoptions.h" localoptions.h
CC="$HERE/solnix-cc" CFLAGS="-O2 -D_GNU_SOURCE -U__linux__ -U__gnu_linux__" ./configure --host=riscv64-unknown-elf --build=riscv64-linux-gnu \
	--enable-static --disable-harden --disable-zlib --disable-pam --disable-syslog --disable-lastlog \
	--disable-utmp --disable-utmpx --disable-wtmp --disable-wtmpx --disable-loginfunc --disable-pututline \
	--disable-pututxline --enable-bundled-libtom
make -j8 PROGRAMS="dropbear dropbearkey" STATIC=1
mkdir -p "$OUT"; cp dropbear dropbearkey "$OUT/"
echo DROPBEAR_DONE
