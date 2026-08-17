#!/usr/bin/env bash
# build-cu7.sh -- R-P49: two MORE UNMODIFIED GNU coreutils-9.5 utils on the REAL
# solnix riscv64 libc.a: unlink (the unlink(2) syscall wrapper -> vfs_unlink) and
# tty (isatty + ttyname of stdin).  Both are syscall-light and link against the
# gnulib support objects already built for lsup plus the house getopt/long-options.
# Dynamically linked via ld.so.1 as /bin/unlink, /bin/tty.
set -e
export PATH=/usr/gnu/bin:/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
R=/root/riscv-port; U=$R/rp49/user; L=$R/rp49/libc
GCC=$R/build/gcc-sol-cfg3/gcc; XGCC="$GCC/xgcc -B$GCC"
TB=$R/toolchain/bin; LDSH=$TB/riscv64-unknown-elf-ld-shared
READELF=$TB/riscv64-unknown-elf-readelf; NM=$TB/riscv64-unknown-elf-nm
SR=$R/sysroot-riscv-sol; LGS=$R/rp21/libgcc_s
CF=$R/rp49/upstream/cu-full/coreutils-9.5; GLIB=$CF/lib; SRC=$CF/src
BD=$U/lsup-build
CFLAGS="-march=rv64gc -mabi=lp64d -mcmodel=medany -ffreestanding \
	-fno-stack-protector -fno-pie -fno-builtin -O2 -w \
	-Wno-implicit-function-declaration -Wno-builtin-declaration-mismatch \
	-DHAVE_CONFIG_H -I$GLIB -I$SRC -I$L/include -I$U/lsup-shims"
cd $BD

CRT="$L/csu/crt1.o $L/csu/crti.o"; CRTN="$L/csu/crtn.o"; LIBS="$L/libc.a -lgcc_s"
LDF="-e _start --dynamic-linker /usr/lib/ld.so.1 -L$LGS --hash-style=both -z relro -z lazy"

# long-options.c supplies parse_gnu_standard_options_only (unlink.c calls it);
# quote.c provides quote/quotearg for the error path.  Build any not already here.
[ -f long-options.o ] || { $XGCC --sysroot=$SR $CFLAGS -c $GLIB/long-options.c -o long-options.o && echo "  OK cc long-options.c"; }
[ -f quote.o ] || { $XGCC --sysroot=$SR $CFLAGS -c $GLIB/quote.c -o quote.o 2>/dev/null && echo "  OK cc quote.c" || echo "  (quote.c not needed / absorbed)"; }

SUPP="progname.o closeout.o exitfail.o xalloc-die.o xmalloc.o \
	version-etc.o version-etc-fsf.o propername-lite.o lsup_support.o \
	localcharset.o setlocale_null.o hard-locale.o quotearg.o \
	c-strcasecmp.o c-strncasecmp.o long-options.o $U/getopt.o"

echo "=== R-P49: UNMODIFIED unlink.c (unlink(2) -> vfs_unlink) ==="
# unlink.c uses optind but (unlike uname.c) does not #include <getopt.h>; force
# the libc getopt.h (which declares optind) with -include (source stays UNMODIFIED).
$XGCC --sysroot=$SR $CFLAGS -include getopt.h -c $SRC/unlink.c -o coreunlink.o && echo "  OK cc UNMODIFIED unlink.c"
$LDSH $LDF -o $U/coreunlink.dyn $CRT coreunlink.o $SUPP $CRTN $LIBS --allow-shlib-undefined
$READELF -lW $U/coreunlink.dyn | grep -q "/usr/lib/ld.so.1" && echo "  OK coreunlink.dyn INTERP ld.so.1"
$NM $U/coreunlink.dyn | grep -qE " T main\$" && echo "  unlink: main T"

echo "=== R-P49: UNMODIFIED tty.c (isatty + ttyname of stdin) ==="
$XGCC --sysroot=$SR $CFLAGS -c $SRC/tty.c -o coretty.o && echo "  OK cc UNMODIFIED tty.c"
$LDSH $LDF -o $U/coretty.dyn $CRT coretty.o $SUPP $CRTN $LIBS --allow-shlib-undefined
$READELF -lW $U/coretty.dyn | grep -q "/usr/lib/ld.so.1" && echo "  OK coretty.dyn INTERP ld.so.1"
$NM $U/coretty.dyn | grep -qE " T main\$" && echo "  tty: main T"
echo BUILD_CU7_DONE
