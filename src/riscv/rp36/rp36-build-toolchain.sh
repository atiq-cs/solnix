#!/usr/bin/env bash
set -e
export PATH=/usr/gnu/bin:/usr/bin:/usr/sbin:/opt/onbld/bin:/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
export CC=gcc CXX=g++
PREFIX=/root/riscv-port/toolchain
SB=/root/riscv-port/build
mkdir -p $SB /root/riscv-port/logs

echo "=== [1/2] binutils riscv64-unknown-elf $(date) ==="
if [ ! -x $PREFIX/bin/riscv64-unknown-elf-ld ]; then
  mkdir -p $SB/binutils; cd $SB/binutils
  /root/riscv-port/src/binutils-2.44/configure \
    --target=riscv64-unknown-elf --prefix=$PREFIX \
    --disable-nls --disable-werror --disable-gdb --disable-gdbserver --disable-sim \
    --with-system-zlib MAKEINFO=/usr/bin/makeinfo >>/root/riscv-port/logs/bu.log 2>&1
  gmake -j16 >>/root/riscv-port/logs/bu.log 2>&1
  gmake install >>/root/riscv-port/logs/bu.log 2>&1
fi
echo "binutils: $($PREFIX/bin/riscv64-unknown-elf-ld --version | head -1)"

echo "=== [2/2] gcc riscv64-unknown-solaris2.11 (all-gcc) $(date) ==="
if [ ! -x $SB/gcc-sol-cfg3/gcc/xgcc ]; then
  mkdir -p $SB/gcc-sol-cfg3; cd $SB/gcc-sol-cfg3
  /root/riscv-port/src/gcc-14.3.0/configure \
    --target=riscv64-unknown-solaris2.11 --prefix=/root/riscv-port/toolchain-sol \
    --without-headers --with-newlib \
    --disable-nls --disable-shared --disable-threads --disable-libssp \
    --disable-libgomp --disable-libquadmath --disable-libatomic --disable-libvtv \
    --enable-languages=c --with-arch=rv64gc --with-abi=lp64d --disable-multilib \
    MAKEINFO=/usr/bin/makeinfo >>/root/riscv-port/logs/gccsol.log 2>&1
  gmake -j16 all-gcc >>/root/riscv-port/logs/gccsol.log 2>&1
fi
X="$SB/gcc-sol-cfg3/gcc/xgcc -B$SB/gcc-sol-cfg3/gcc"
echo "gcc-sol dumpmachine: $($X -dumpmachine)"
echo "TOOLCHAIN_BUILD_DONE $(date)"
