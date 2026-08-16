#!/usr/bin/env bash
#
# build-cu.sh -- R-P39.1/.2: build REAL upstream GNU coreutils utilities against
# the REAL solnix riscv64 libc.a (NOT the per-program coreutils_shim.h).  Each
# util is the UNMODIFIED upstream src/*.c, compiled with the gnulib scaffolding
# headers in cu-include/ (config.h/system.h/assure.h/c-ctype.h -> the real libc
# + coreutils_glue.h), linked against libc.a + real crt1/crti/crtn, and
# DYNAMICALLY linked via ld.so.1 against libgcc_s.so.1 -- built the way a solnix
# package is.
#   R-P39.1  coreecho2  = coreutils-9.5 src/echo.c, unmodified, links libc.a.
#   R-P39.2  coretrue   = coreutils-9.5 src/true.c, unmodified, links libc.a --
#            a 2nd real util proving the libc + exec path generalizes.
set -e
export PATH=/usr/gnu/bin:/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
R=/root/riscv-port
U=$R/rp39/user
L=$R/rp39/libc
GCC=$R/build/gcc-sol-cfg3/gcc
XGCC="$GCC/xgcc -B$GCC"
TB=$R/toolchain/bin
LDSH=$TB/riscv64-unknown-elf-ld-shared
READELF=$TB/riscv64-unknown-elf-readelf
SR=$R/sysroot-riscv-sol
LGS=$R/rp21/libgcc_s
CU=$R/rp38/upstream/coreutils-9.5/src
# NB: -I cu-include FIRST so <config.h>/system.h/c-ctype.h resolve to our
# gnulib scaffolding; -I $L/include gives the real libc headers.
CFLAGS="-march=rv64gc -mabi=lp64d -mcmodel=medany -ffreestanding \
	-fno-stack-protector -fno-pie -fno-builtin -O2 -Wall -Wno-unused \
	-Wno-implicit-function-declaration \
	-I$U/cu-include -I$L/include"
cd $U

link_cu() {
	# $1 = output basename, $2 = upstream source file, $3.. = extra -D
	local out=$1 src=$2; shift 2
	$XGCC --sysroot=$SR $CFLAGS "$@" -c $src -o $out.o
	$LDSH -e _start --dynamic-linker /usr/lib/ld.so.1 -L$LGS \
		--hash-style=both -z relro -z lazy \
		-o $out.dyn $L/csu/crt1.o $L/csu/crti.o $out.o $L/csu/crtn.o \
		$L/libc.a -lgcc_s --allow-shlib-undefined 2>/dev/null
	$READELF -dW $out.dyn | grep -q "libgcc_s.so.1" \
		&& $READELF -lW $out.dyn | grep -q "/usr/lib/ld.so.1" \
		&& echo "  OK $out.dyn (real coreutils $src, links libc.a, NEEDED libgcc_s.so.1, INTERP ld.so.1)"
}

echo "=== R-P39.1: rebuild the REAL coreutils echo against the REAL libc.a ==="
link_cu coreecho2 $CU/echo.c

echo "=== R-P39.2: a 2nd REAL coreutils util (true) against the REAL libc.a ==="
link_cu coretrue $CU/true.c

echo "BUILD_CU_DONE"
