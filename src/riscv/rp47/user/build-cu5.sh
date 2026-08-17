#!/usr/bin/env bash
# build-cu5.sh -- R-P47: one MORE UNMODIFIED GNU coreutils-9.5 util (false.c)
# against the REAL solnix riscv64 libc.a.  false.c #includes true.c verbatim
# (its whole body is true.c with EXIT_FAILURE), so this is the upstream true/false
# pair on the same libc.a.  Links against the gnulib support objects (progname/
# closeout/quotearg/version-etc/proper_name_lite) already built for lsup, plus
# getopt.o from the cu4 glue.  Dynamically linked via ld.so.1 as /bin/false.
set -e
export PATH=/usr/gnu/bin:/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
R=/root/riscv-port; U=$R/rp47/user; L=$R/rp47/libc
GCC=$R/build/gcc-sol-cfg3/gcc; XGCC="$GCC/xgcc -B$GCC"
TB=$R/toolchain/bin; LDSH=$TB/riscv64-unknown-elf-ld-shared
READELF=$TB/riscv64-unknown-elf-readelf; NM=$TB/riscv64-unknown-elf-nm
SR=$R/sysroot-riscv-sol; LGS=$R/rp21/libgcc_s
CF=$R/rp47/upstream/cu-full/coreutils-9.5; GLIB=$CF/lib; SRC=$CF/src
BD=$U/lsup-build
CFLAGS="-march=rv64gc -mabi=lp64d -mcmodel=medany -ffreestanding \
	-fno-stack-protector -fno-pie -fno-builtin -O2 -w \
	-Wno-implicit-function-declaration -Wno-builtin-declaration-mismatch \
	-DHAVE_CONFIG_H -I$GLIB -I$SRC -I$L/include -I$U/lsup-shims"
cd $BD

echo "=== R-P47: UNMODIFIED false.c (== true.c, EXIT_FAILURE) ==="
$XGCC --sysroot=$SR $CFLAGS -c $SRC/false.c -o corefalse.o && echo "  OK cc UNMODIFIED false.c"

CRT="$L/csu/crt1.o $L/csu/crti.o"; CRTN="$L/csu/crtn.o"; LIBS="$L/libc.a -lgcc_s"
LDF="-e _start --dynamic-linker /usr/lib/ld.so.1 -L$LGS --hash-style=both -z relro -z lazy"
SUPP="progname.o closeout.o exitfail.o xalloc-die.o xmalloc.o \
	version-etc.o version-etc-fsf.o propername-lite.o lsup_support.o \
	localcharset.o setlocale_null.o hard-locale.o quotearg.o \
	c-strcasecmp.o c-strncasecmp.o $U/getopt.o"
$LDSH $LDF -o $U/corefalse.dyn $CRT corefalse.o $SUPP $CRTN $LIBS --allow-shlib-undefined
$READELF -lW $U/corefalse.dyn | grep -q "/usr/lib/ld.so.1" && echo "  OK corefalse.dyn INTERP ld.so.1"
$NM $U/corefalse.dyn | grep -qE " T main\$" && echo "  false: main T"
echo BUILD_CU5_DONE
