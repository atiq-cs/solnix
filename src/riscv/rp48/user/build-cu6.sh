#!/usr/bin/env bash
# build-cu6.sh -- R-P48: two MORE UNMODIFIED GNU coreutils-9.5 utils on the REAL
# solnix riscv64 libc.a: uname (uname(2) + sysinfo(SI_*) libc) and nproc
# (num_processors -> sysconf(_SC_NPROCESSORS_ONLN) -> the SYS_ncpu kernel count).
# Links against the gnulib support objects already built for lsup, plus the
# house getopt.  Dynamically linked via ld.so.1 as /bin/uname, /bin/nproc.
set -e
export PATH=/usr/gnu/bin:/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
R=/root/riscv-port; U=$R/rp48/user; L=$R/rp48/libc
GCC=$R/build/gcc-sol-cfg3/gcc; XGCC="$GCC/xgcc -B$GCC"
TB=$R/toolchain/bin; LDSH=$TB/riscv64-unknown-elf-ld-shared
READELF=$TB/riscv64-unknown-elf-readelf; NM=$TB/riscv64-unknown-elf-nm
SR=$R/sysroot-riscv-sol; LGS=$R/rp21/libgcc_s
CF=$R/rp48/upstream/cu-full/coreutils-9.5; GLIB=$CF/lib; SRC=$CF/src
BD=$U/lsup-build
CFLAGS="-march=rv64gc -mabi=lp64d -mcmodel=medany -ffreestanding \
	-fno-stack-protector -fno-pie -fno-builtin -O2 -w \
	-Wno-implicit-function-declaration -Wno-builtin-declaration-mismatch \
	-DHAVE_CONFIG_H -I$GLIB -I$SRC -I$L/include -I$U/lsup-shims"
cd $BD

CRT="$L/csu/crt1.o $L/csu/crti.o"; CRTN="$L/csu/crtn.o"; LIBS="$L/libc.a -lgcc_s"
LDF="-e _start --dynamic-linker /usr/lib/ld.so.1 -L$LGS --hash-style=both -z relro -z lazy"
SUPP="progname.o closeout.o exitfail.o xalloc-die.o xmalloc.o \
	version-etc.o version-etc-fsf.o propername-lite.o lsup_support.o \
	localcharset.o setlocale_null.o hard-locale.o quotearg.o \
	c-strcasecmp.o c-strncasecmp.o $U/getopt.o"

echo "=== R-P48: UNMODIFIED uname.c (uname(2) + sysinfo(SI_*)) ==="
$XGCC --sysroot=$SR $CFLAGS -c $SRC/uname.c -o coreuname.o && echo "  OK cc UNMODIFIED uname.c"
$XGCC --sysroot=$SR $CFLAGS -c $SRC/uname-uname.c -o uname-uname.o && echo "  OK cc UNMODIFIED uname-uname.c"
$LDSH $LDF -o $U/coreuname.dyn $CRT coreuname.o uname-uname.o $SUPP $CRTN $LIBS --allow-shlib-undefined
$READELF -lW $U/coreuname.dyn | grep -q "/usr/lib/ld.so.1" && echo "  OK coreuname.dyn INTERP ld.so.1"
$NM $U/coreuname.dyn | grep -qE " T main\$" && echo "  uname: main T"

echo "=== R-P48: UNMODIFIED nproc.c (num_processors -> sysconf(_SC_NPROCESSORS_ONLN)) ==="
$XGCC --sysroot=$SR $CFLAGS -c $SRC/nproc.c -o corenproc.o && echo "  OK cc UNMODIFIED nproc.c"
$XGCC --sysroot=$SR $CFLAGS -c $GLIB/nproc.c -o nproc-lib.o && echo "  OK cc UNMODIFIED lib/nproc.c"
# xdectoumax/xnumtoumax come from lsup_support.o (the C-locale reduction).
$LDSH $LDF -o $U/corenproc.dyn $CRT corenproc.o nproc-lib.o $SUPP $CRTN $LIBS --allow-shlib-undefined
$READELF -lW $U/corenproc.dyn | grep -q "/usr/lib/ld.so.1" && echo "  OK corenproc.dyn INTERP ld.so.1"
$NM $U/corenproc.dyn | grep -qE " T main\$" && echo "  nproc: main T"
echo BUILD_CU6_DONE
