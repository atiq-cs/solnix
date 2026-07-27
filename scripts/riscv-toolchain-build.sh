#!/bin/sh
# Build a riscv64-unknown-elf cross toolchain (binutils + gcc stage-1, C only,
# bare-metal, no libc) on the ouch OI build host. Standard upstream cross build
# -- riscv64 is well-supported (--target=riscv64-unknown-elf). This is the
# substrate that will LATER be re-targeted to riscv64-unknown-solaris2.11 once a
# uts/riscv + sysroot exist (the hard part; see docs/design-riscv-port.md).
set -eu
PREFIX=/export/riscv-toolchain
SRC=/export/riscv-src
BINUTILS_VER=2.44
GCC_VER=14.3.0
JOBS=16
export PATH="$PREFIX/bin:/usr/gnu/bin:/usr/bin:/usr/sbin:/bin"
export MAKE=gmake

mkdir -p "$SRC" "$PREFIX"
cd "$SRC"

# Solaris /usr/bin/tar mishandles GNU pax extended headers (typeflag 'x'),
# creating junk PaxHeaders/ dirs and risking corrupt long-path files. Use
# python3's tarfile (pax-aware, present on the host) for all extraction.
extract() { # extract() <tarball>
  python3 - "$1" <<'PYEOF'
import sys, tarfile
with tarfile.open(sys.argv[1]) as t:
    t.extractall(".")
print("extracted", sys.argv[1])
PYEOF
}

echo "=== fetch binutils $BINUTILS_VER ==="
[ -f binutils-$BINUTILS_VER.tar.xz ] || \
  curl -fL -o binutils-$BINUTILS_VER.tar.xz \
    https://ftp.gnu.org/gnu/binutils/binutils-$BINUTILS_VER.tar.xz
[ -d binutils-$BINUTILS_VER ] || extract binutils-$BINUTILS_VER.tar.xz

echo "=== fetch gcc $GCC_VER ==="
# scrub any prior corrupt/partial gcc tree (Solaris-tar pax damage).
rm -rf gcc-$GCC_VER
[ -f gcc-$GCC_VER.tar.xz ] || \
  curl -fL -o gcc-$GCC_VER.tar.xz \
    https://ftp.gnu.org/gnu/gcc/gcc-$GCC_VER/gcc-$GCC_VER.tar.xz
extract gcc-$GCC_VER.tar.xz
( cd gcc-$GCC_VER && [ -d gmp ] || ./contrib/download_prerequisites )
# gcc's in-tree gettext fails to build on illumos (gnulib getlocalename_l
# conflict); it is only for GCC's own message catalogs and is unneeded for a
# cross compiler. Remove it so the top-level Makefile skips all-gettext.
# (--disable-nls alone does not stop the in-tree gettext build on 14.x.)
rm -rf gcc-$GCC_VER/gettext

echo "=== build binutils (riscv64-unknown-elf) ==="
if [ -x "$PREFIX/bin/riscv64-unknown-elf-as" ]; then
  echo "binutils already installed, skipping"
else
  [ -d build-binutils ] && rm -rf build-binutils; mkdir build-binutils; cd build-binutils
  ../binutils-$BINUTILS_VER/configure \
    --target=riscv64-unknown-elf --prefix="$PREFIX" \
    --disable-nls --disable-werror --with-system-zlib
  gmake -j$JOBS
  gmake install
  cd "$SRC"
fi

echo "=== build gcc stage-1 (C, no headers/libc -- bare-metal) ==="
[ -d build-gcc ] && rm -rf build-gcc; mkdir build-gcc; cd build-gcc
../gcc-$GCC_VER/configure \
  --target=riscv64-unknown-elf --prefix="$PREFIX" \
  --enable-languages=c --without-headers --disable-nls \
  --disable-shared --disable-threads --disable-libssp \
  --disable-libgomp --disable-libmudflap --disable-libquadmath \
  --disable-libatomic --disable-libstdcxx \
  --with-arch=rv64imac --with-abi=lp64 --disable-multilib
gmake -j$JOBS all-gcc
gmake install-gcc
# libgcc for a usable bare-metal compiler (no libc needed)
gmake -j$JOBS all-target-libgcc || true
gmake install-target-libgcc || true

echo "=== verify ==="
"$PREFIX/bin/riscv64-unknown-elf-gcc" --version | head -1
"$PREFIX/bin/riscv64-unknown-elf-as" --version | head -1
echo 'int f(int x){return x+1;}' > /tmp/t.c
"$PREFIX/bin/riscv64-unknown-elf-gcc" -march=rv64imac -mabi=lp64 -c /tmp/t.c -o /tmp/t.o
file /tmp/t.o
echo "TOOLCHAIN_OK prefix=$PREFIX"
ls "$PREFIX/bin" | grep riscv64 | head
