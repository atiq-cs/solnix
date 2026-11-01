#!/usr/bin/env bash
# build-userland.sh -- tryit1: the demo's riscv64 userland (sysroot, zlib, sbase, dash, ncurses, less) with
# the riscv64-none-elf cross gcc on an x86_64 Linux host. Env from env.sh: SOLNIX_GCC, SOLNIX_BUILD,
# SOLNIX_SYSROOT, OUT, NEWLIB; DL = the unpacked sources (fetch.sh).
set -euo pipefail
R="$(cd "$(dirname "$0")/.." && pwd)"; P="$R/pkg"; DL="${DL:-$HOME/w/dl}"
mkdir -p "$OUT"
NEWLIB="$NEWLIB/riscv64-none-elf" NEWLIB_SRC="$DL/newlib-4.5.0.20241231" UTS="$R/uts" \
	GLUE_DEFS=-DSOLNIX_NO_VFD bash "$P/build-sysroot.sh"
SRC="$DL/zlib-1.3.2" CHOST=riscv64 bash "$P/build-zlib.sh"
SRC="$DL/sbase" bash "$P/build-sbase.sh"
SRC="$DL/dash-0.5.12" CC_FOR_BUILD=gcc bash "$P/build-dash.sh"
SRC="$DL/ncurses-6.5" bash "$P/build-ncurses.sh"
SRC="$DL/less-668" bash "$P/build-less.sh"
echo USERLAND_DONE
