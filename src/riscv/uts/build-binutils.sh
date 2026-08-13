#!/bin/bash
set -e
PREFIX=/root/riscv-port/toolchain
TARGET=riscv64-unknown-elf
SRC=/root/riscv-port/src/binutils-2.44
BUILD=/root/riscv-port/build/binutils
export PATH=/usr/gnu/bin:/usr/bin:/usr/sbin:/opt/onbld/bin:$PATH
export CC=gcc CXX=g++
[ -d "$BUILD" ] && mv "$BUILD" "$BUILD.old.$$"
mkdir -p "$BUILD"; cd "$BUILD"
echo "=== configure $(date) ==="
"$SRC/configure" \
  --target=$TARGET \
  --prefix=$PREFIX \
  --disable-nls \
  --disable-werror \
  --disable-gdb --disable-gdbserver --disable-sim \
  --with-system-zlib \
  MAKEINFO=/usr/bin/makeinfo
echo "=== make $(date) ==="
gmake -j16
echo "=== make install $(date) ==="
gmake install
echo "=== DONE $(date) ==="
