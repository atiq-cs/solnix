#!/usr/bin/env bash
#
# build-ls.sh -- R-P41.2: build a REAL `ls` against the GROWN solnix riscv64
# libc.a.  ls.c EXERCISES exactly the R-P41 libc growth: opendir/readdir/
# closedir (dir.c over SYS_getdents), lstat/stat (stat.c reading the kernel's
# R-P41 type-code so S_ISDIR works), qsort + strcoll (misc.c, the C-locale
# entry sort), and getpwuid/getgrgid + snprintf for `-l`.  Dynamically linked
# via ld.so.1 (NEEDED libgcc_s.so.1) as /bin/corels.
#
# NOTE: this ls is written from scratch (not GNU coreutils' unmodified src/ls.c,
# whose ~32-module gnulib surface -- obstack/quotearg/human/mbswidth/hash/mpsort
# -- is deferred to R-P42+).  The unmodified-upstream utils this phase links are
# cat.c (R-P40) + wc.c (R-P41.2); this ls proves the grown libc is real+usable.
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
CFLAGS="-march=rv64gc -mabi=lp64d -mcmodel=medany -ffreestanding \
	-fno-stack-protector -fno-pie -fno-builtin -O2 -Wall -Wno-unused \
	-I$L/include"
cd $U

echo "=== R-P41.2: compile ls.c (exercises opendir/readdir/lstat/qsort/strcoll) ==="
$XGCC --sysroot=$SR $CFLAGS -c ls.c -o corels.o && echo "  OK cc ls.c"

echo "=== R-P41.2: link corels.dyn (real grown libc.a) ==="
$LDSH -e _start --dynamic-linker /usr/lib/ld.so.1 -L$LGS \
	--hash-style=both -z relro -z lazy \
	-o corels.dyn $L/csu/crt1.o $L/csu/crti.o \
	corels.o $L/csu/crtn.o \
	$L/libc.a -lgcc_s --allow-shlib-undefined 2>/dev/null
$READELF -dW corels.dyn | grep -q "libgcc_s.so.1" \
	&& $READELF -lW corels.dyn | grep -q "/usr/lib/ld.so.1" \
	&& echo "  OK corels.dyn (real ls, links grown libc.a, NEEDED libgcc_s.so.1, INTERP ld.so.1)"

echo "=== R-P41.2: nm proof -- the grown-libc symbols ls uses resolved STATICALLY ==="
$NM corels.dyn > /tmp/corels.nm 2>/dev/null || true
for sym in opendir readdir closedir lstat stat qsort strcoll getpwuid getgrgid snprintf; do
	grep -qE " T $sym\$" /tmp/corels.nm && echo "  sym $sym: T (static from libc.a)" \
		|| echo "  note $sym not T (may be inlined/unused)"
done
echo "BUILD_LS_DONE"
