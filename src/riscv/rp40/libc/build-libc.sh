#!/usr/bin/env bash
#
# build-libc.sh -- R-P39.1: build the REAL solnix riscv64 libc (libc.a) that
# solnix programs link against, replacing the per-program coreutils_shim.h.
# The libc is compiled from separate translation units (syscall stubs, stdio,
# string, stdlib, ctype, the libc start routine + real crt1/crti/crtn) into a
# genuine static archive libc.a, cross-compiled by the on-node
# riscv64-unknown-solaris2.11 toolchain -- a real reusable libc, not a shim.
set -e
export PATH=/usr/gnu/bin:/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
R=/root/riscv-port
L=$R/rp40/libc
GCC=$R/build/gcc-sol-cfg3/gcc
XGCC="$GCC/xgcc -B$GCC"
TB=$R/toolchain/bin
AS=$TB/riscv64-unknown-elf-as
AR=$TB/riscv64-unknown-elf-ar
RANLIB=$TB/riscv64-unknown-elf-ranlib
CFLAGS="-march=rv64gc -mabi=lp64d -mcmodel=medany -ffreestanding \
	-fno-stack-protector -fno-pie -O2 -Wall -Wno-unused -I$L/include"
cd $L

echo "=== R-P39.1: building the real solnix riscv64 libc.a ==="

# crt objects: real crt1 (libc start), crti/crtn (init/fini brackets).
$AS -march=rv64gc -mabi=lp64d csu/crt1.s -o csu/crt1.o
cp $R/csu/crti.s csu/crti.s
cp $R/csu/crtn.s csu/crtn.s
$AS -march=rv64gc -mabi=lp64d csu/crti.s -o csu/crti.o
$AS -march=rv64gc -mabi=lp64d csu/crtn.s -o csu/crtn.o
echo "  OK crt1.o crti.o crtn.o"

# the libc port objects.
OBJS=""
for u in syscall string ctype stdlib stdio stdio2 stat dir signal libc_start progname; do
	$XGCC $CFLAGS -c port/$u.c -o port/$u.o
	OBJS="$OBJS port/$u.o"
	echo "  OK cc port/$u.c"
done

# the archive: a REAL libc.a.
rm -f libc.a
$AR rcs libc.a $OBJS
$RANLIB libc.a
echo "  OK ar libc.a:"
$AR t libc.a | sed 's/^/     /'

# quick sanity: the archive is riscv64 and exports the core libc symbols.
NM=$TB/riscv64-unknown-elf-nm
$NM libc.a > /tmp/libc.nm 2>/dev/null || true
for sym in malloc free getenv exit atexit printf fwrite fputs strlen memcpy \
           isxdigit write read open close __libc_start \
           fopen fread fgets fseek ftell fclose snprintf sprintf \
           opendir readdir closedir stat fstat lstat signal sigaction kill; do
	grep -q " T $sym\$" /tmp/libc.nm && echo "  sym $sym: defined" \
		|| { echo "  FAIL: libc.a missing $sym"; exit 1; }
done
echo "LIBC_BUILD_DONE"
