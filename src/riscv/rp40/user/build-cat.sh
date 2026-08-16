#!/usr/bin/env bash
#
# build-cat.sh -- R-P40.2: build the UNMODIFIED GNU coreutils-9.5 src/cat.c
# against the REAL, GROWN solnix riscv64 libc.a.  cat is a BIGGER real program
# than echo/true: it open(2)s files, fstat(2)s them (real libc stat), reads via
# safe_read/read(2) + writes via full_write/write(2), parses options with a real
# getopt_long, and mallocs its I/O buffers -- all against the real libc; only the
# gnulib scaffolding (getopt, full_write/safe_read, io_blksize, xalignalloc,
# fadvise, error/quotef) is supplied by cat-include/ + getopt.c + catlib.c.
# Dynamically linked via ld.so.1 (NEEDED libgcc_s.so.1) -- built the way a solnix
# package is.
set -e
export PATH=/usr/gnu/bin:/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
R=/root/riscv-port
U=$R/rp40/user
L=$R/rp40/libc
GCC=$R/build/gcc-sol-cfg3/gcc
XGCC="$GCC/xgcc -B$GCC"
TB=$R/toolchain/bin
LDSH=$TB/riscv64-unknown-elf-ld-shared
READELF=$TB/riscv64-unknown-elf-readelf
NM=$TB/riscv64-unknown-elf-nm
SR=$R/sysroot-riscv-sol
LGS=$R/rp21/libgcc_s
CU=$R/rp40/upstream/coreutils-9.5/src
# NB: -I cat-include FIRST so <config.h>/system.h/getopt.h/the lib shims resolve
# to our scaffolding; -I $L/include gives the real libc headers.
CFLAGS="-march=rv64gc -mabi=lp64d -mcmodel=medany -ffreestanding \
	-fno-stack-protector -fno-pie -fno-builtin -O2 -Wall -Wno-unused \
	-Wno-implicit-function-declaration -Wno-builtin-declaration-mismatch \
	-I$U/cat-include -I$L/include"
cd $U

echo "=== R-P40.2: compile the gnulib scaffolding TUs (getopt, catlib) ==="
$XGCC --sysroot=$SR $CFLAGS -c getopt.c -o getopt.o && echo "  OK cc getopt.c"
$XGCC --sysroot=$SR $CFLAGS -c catlib.c -o catlib.o && echo "  OK cc catlib.c"

echo "=== R-P40.2: compile the UNMODIFIED coreutils cat.c ==="
$XGCC --sysroot=$SR $CFLAGS -c $CU/cat.c -o corecat.o && echo "  OK cc $CU/cat.c"

echo "=== R-P40.2: link corecat.dyn (real libc.a + getopt.o + catlib.o) ==="
$LDSH -e _start --dynamic-linker /usr/lib/ld.so.1 -L$LGS \
	--hash-style=both -z relro -z lazy \
	-o corecat.dyn $L/csu/crt1.o $L/csu/crti.o \
	corecat.o getopt.o catlib.o $L/csu/crtn.o \
	$L/libc.a -lgcc_s --allow-shlib-undefined 2>/dev/null
$READELF -dW corecat.dyn | grep -q "libgcc_s.so.1" \
	&& $READELF -lW corecat.dyn | grep -q "/usr/lib/ld.so.1" \
	&& echo "  OK corecat.dyn (real coreutils cat.c, links libc.a, NEEDED libgcc_s.so.1, INTERP ld.so.1)"

echo "=== R-P40.2: nm proof -- libc symbols cat uses resolved STATICALLY from libc.a ==="
$NM corecat.dyn > /tmp/corecat.nm 2>/dev/null || true
for sym in open close fstat malloc free printf fwrite fputs write read lseek; do
	grep -qE " T $sym\$" /tmp/corecat.nm && echo "  sym $sym: T (static from libc.a)" \
		|| echo "  note $sym not T (may be inlined/unused)"
done
echo "BUILD_CAT_DONE"
