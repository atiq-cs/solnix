#!/usr/bin/env bash
# build-tail.sh -- R-P42.1: UNMODIFIED GNU coreutils-9.5 src/tail.c against the
# real solnix riscv64 libc.a via tail-include/ (tail_glue.h on wc/head glue).
set -e
export PATH=/usr/gnu/bin:/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
R=/root/riscv-port; U=$R/rp42/user; L=$R/rp42/libc
GCC=$R/build/gcc-sol-cfg3/gcc; XGCC="$GCC/xgcc -B$GCC"
TB=$R/toolchain/bin; LDSH=$TB/riscv64-unknown-elf-ld-shared
READELF=$TB/riscv64-unknown-elf-readelf; NM=$TB/riscv64-unknown-elf-nm
SR=$R/sysroot-riscv-sol; LGS=$R/rp21/libgcc_s
CU=$R/rp42/upstream/coreutils-9.5/src
CFLAGS="-march=rv64gc -mabi=lp64d -mcmodel=medany -ffreestanding 	-fno-stack-protector -fno-pie -fno-builtin -O2 -Wall -Wno-unused 	-Wno-implicit-function-declaration -Wno-builtin-declaration-mismatch 	-I$U/tail-include -I$L/include"
cd $U
$XGCC --sysroot=$SR $CFLAGS -c getopt.c -o getopt.o
$XGCC --sysroot=$SR $CFLAGS -c wclib.c -o wclib.o
echo '=== compile UNMODIFIED tail.c ==='
$XGCC --sysroot=$SR $CFLAGS -c $CU/tail.c -o coretail.o && echo '  OK cc UNMODIFIED tail.c'
echo '=== link coretail.dyn ==='
$LDSH -e _start --dynamic-linker /usr/lib/ld.so.1 -L$LGS --hash-style=both -z relro -z lazy 	-o coretail.dyn $L/csu/crt1.o $L/csu/crti.o coretail.o getopt.o wclib.o $L/csu/crtn.o 	$L/libc.a -lgcc_s --allow-shlib-undefined
$READELF -lW coretail.dyn | grep -q '/usr/lib/ld.so.1' && echo '  OK coretail.dyn INTERP ld.so.1'
echo BUILD_TAIL_DONE
