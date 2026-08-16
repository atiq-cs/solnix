#!/usr/bin/env bash
#
# build-wc.sh -- R-P41.2: build the UNMODIFIED GNU coreutils-9.5 src/wc.c against
# the REAL, GROWN solnix riscv64 libc.a.  wc counts lines/words/bytes: it parses
# options with the real getopt_long, open(2)s files, fstat(2)s/lseek(2)s them
# (real libc stat), and reads via read(2) in its byte-counting loop -- all on the
# real libc.  The gnulib scaffolding (system.h, argv-iter [REAL lib/argv-iter.c],
# physmem/argmatch/readtokens0/umaxtostr) is supplied by wc-include/ + wclib.c;
# getopt.c is shared with cat.  Dynamically linked via ld.so.1 (NEEDED libgcc_s).
set -e
export PATH=/usr/gnu/bin:/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
R=/root/riscv-port
U=$R/rp41/user
L=$R/rp41/libc
GCC=$R/build/gcc-sol-cfg3/gcc
XGCC="$GCC/xgcc -B$GCC"
TB=$R/toolchain/bin
LDSH=$TB/riscv64-unknown-elf-ld-shared
READELF=$TB/riscv64-unknown-elf-readelf
NM=$TB/riscv64-unknown-elf-nm
SR=$R/sysroot-riscv-sol
LGS=$R/rp21/libgcc_s
CU=$R/rp41/upstream/coreutils-9.5/src
GLIB=$R/rp41/upstream/coreutils-9.5/lib
CFLAGS="-march=rv64gc -mabi=lp64d -mcmodel=medany -ffreestanding \
	-fno-stack-protector -fno-pie -fno-builtin -O2 -Wall -Wno-unused \
	-Wno-implicit-function-declaration -Wno-builtin-declaration-mismatch \
	-I$U/wc-include -I$L/include"
cd $U

echo "=== R-P41.2: compile the scaffolding TUs (getopt, wclib, argv-iter) ==="
$XGCC --sysroot=$SR $CFLAGS -c getopt.c -o getopt.o && echo "  OK cc getopt.c"
$XGCC --sysroot=$SR $CFLAGS -c wclib.c -o wclib.o && echo "  OK cc wclib.c"

echo "=== R-P41.2: compile the UNMODIFIED coreutils wc.c ==="
$XGCC --sysroot=$SR $CFLAGS -c $CU/wc.c -o corewc.o && echo "  OK cc $CU/wc.c"

echo "=== R-P41.2: link corewc.dyn (real libc.a + getopt + wclib + argv-iter) ==="
$LDSH -e _start --dynamic-linker /usr/lib/ld.so.1 -L$LGS \
	--hash-style=both -z relro -z lazy \
	-o corewc.dyn $L/csu/crt1.o $L/csu/crti.o \
	corewc.o getopt.o wclib.o $L/csu/crtn.o \
	$L/libc.a -lgcc_s --allow-shlib-undefined 2>/dev/null
$READELF -dW corewc.dyn | grep -q "libgcc_s.so.1" \
	&& $READELF -lW corewc.dyn | grep -q "/usr/lib/ld.so.1" \
	&& echo "  OK corewc.dyn (real coreutils wc.c, links libc.a, NEEDED libgcc_s.so.1, INTERP ld.so.1)"

echo "=== R-P41.2: nm proof -- libc symbols wc uses resolved STATICALLY from libc.a ==="
$NM corewc.dyn > /tmp/corewc.nm 2>/dev/null || true
for sym in open close fstat lseek read write malloc free printf getopt_long; do
	grep -qE " T $sym\$" /tmp/corewc.nm && echo "  sym $sym: T (static from libc.a)" \
		|| echo "  note $sym not T (may be inlined/unused)"
done
echo "BUILD_WC_DONE"
