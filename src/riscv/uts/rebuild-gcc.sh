#!/bin/bash
set -e
PREFIX=/root/riscv-port/toolchain
export PATH=$PREFIX/bin:/usr/gnu/bin:/usr/bin:/usr/sbin:/opt/onbld/bin:$PATH
export CC=gcc CXX=g++
cd /root/riscv-port/build/gcc
echo "=== resume make all-gcc (gettext stripped) $(date) ==="
gmake -j16 all-gcc
echo "=== install-gcc $(date) ==="
gmake install-gcc
echo "=== all-target-libgcc $(date) ==="
gmake -j16 all-target-libgcc
echo "=== install-target-libgcc $(date) ==="
gmake install-target-libgcc
echo "=== GCC DONE $(date) ==="
