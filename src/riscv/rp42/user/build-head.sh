#!/usr/bin/env bash
# build-head.sh -- R-P42.1: build the UNMODIFIED GNU coreutils-9.5 src/head.c
# against the REAL solnix riscv64 libc.a via the head-include/ glue (built on
# wc_glue.h + head_glue.h: safe_read/full_read/xdectoumax/quote reduced to the
# C-locale read loop).  Dynamically linked via ld.so.1 (NEEDED libgcc_s).
set -e
export PATH=/usr/gnu/bin:/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
R=/root/riscv-port
U=$R/rp42/user
L=$R/rp42/libc
GCC=$R/build/gcc-sol-cfg3/gcc
XGCC="$GCC/xgcc -B$GCC"
TB=$R/toolchain/bin
LDSH=$TB/riscv64-unknown-elf-ld-shared
READELF=$TB/riscv64-unknown-elf-readelf
NM=$TB/riscv64-unknown-elf-nm
SR=$R/sysroot-riscv-sol
LGS=$R/rp21/libgcc_s
CU=$R/rp42/upstream/coreutils-9.5/src
CFLAGS="-march=rv64gc -mabi=lp64d -mcmodel=medany -ffreestanding 	-fno-stack-protector -fno-pie -fno-builtin -O2 -Wall -Wno-unused 	-Wno-implicit-function-declaration -Wno-builtin-declaration-mismatch 	-I$U/head-include -I$L/include"
cd $U
echo '=== R-P42.1: compile scaffolding (getopt, wclib for umaxtostr) ==='
$XGCC --sysroot=$SR $CFLAGS -c getopt.c -o getopt.o && echo '  OK cc getopt.c'
$XGCC --sysroot=$SR $CFLAGS -c wclib.c -o wclib.o && echo '  OK cc wclib.c'
echo '=== R-P42.1: compile the UNMODIFIED coreutils head.c ==='
$XGCC --sysroot=$SR $CFLAGS -c $CU/head.c -o corehead.o && echo '  OK cc UNMODIFIED head.c'
echo '=== R-P42.1: link corehead.dyn ==='
$LDSH -e _start --dynamic-linker /usr/lib/ld.so.1 -L$LGS 	--hash-style=both -z relro -z lazy 	-o corehead.dyn $L/csu/crt1.o $L/csu/crti.o 	corehead.o getopt.o wclib.o $L/csu/crtn.o 	$L/libc.a -lgcc_s --allow-shlib-undefined
$READELF -lW corehead.dyn | grep -q '/usr/lib/ld.so.1' && echo '  OK corehead.dyn INTERP ld.so.1'
echo '=== nm proof ==='
$NM corehead.dyn > /tmp/corehead.nm 2>/dev/null || true
for s in open close read lseek write printf getopt_long; do
	grep -qE " T $s\$" /tmp/corehead.nm && echo "  sym $s: T (static from libc.a)"
done
echo BUILD_HEAD_DONE
