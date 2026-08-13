#!/bin/bash
set -e
PREFIX=/root/riscv-port/toolchain
TARGET=riscv64-unknown-elf
SRC=/root/riscv-port/src/gcc-14.3.0
BUILD=/root/riscv-port/build/gcc
export PATH=$PREFIX/bin:/usr/gnu/bin:/usr/bin:/usr/sbin:/opt/onbld/bin:$PATH
export CC=gcc CXX=g++
[ -d "$BUILD" ] && mv "$BUILD" "$BUILD.old.$$"
mkdir -p "$BUILD"; cd "$BUILD"
echo "=== configure $(date) ==="
"$SRC/configure" \
  --target=$TARGET \
  --prefix=$PREFIX \
  --without-headers \
  --with-newlib \
  --disable-nls \
  --disable-shared \
  --disable-threads \
  --disable-libssp \
  --disable-libgomp \
  --disable-libquadmath \
  --disable-libatomic \
  --disable-libvtv \
  --enable-languages=c \
  --with-arch=rv64gc \
  --with-abi=lp64d \
  --disable-multilib \
  MAKEINFO=/usr/bin/makeinfo
echo "=== make all-gcc (stage-1 compiler) $(date) ==="
gmake -j16 all-gcc
echo "=== make install-gcc $(date) ==="
gmake install-gcc
echo "=== make all-target-libgcc $(date) ==="
gmake -j16 all-target-libgcc
echo "=== make install-target-libgcc $(date) ==="
gmake install-target-libgcc
echo "=== DONE $(date) ==="
