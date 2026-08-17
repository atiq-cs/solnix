#!/usr/bin/env bash
# build-cu10.sh -- R-P52: UNMODIFIED GNU coreutils-9.5 cut.c on the REAL solnix
# riscv64 libc.a.  cut was deferred at R-P51 because it calls ungetc(c, stream)
# + gnulib getndelim2/freadptr/freadseek, which the libc lacked.  R-P52 added
# ungetc/freadahead/freadptr/freadseek to the libc (port/stdio2.c), so cut now
# links.  Links against the rp52 libc.a (NOT rp51 -- the R-P52 libc bits live
# there) + the lean text-util gnulib support objects.  Source stays UNMODIFIED.
set -e
export PATH=/usr/gnu/bin:/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
R=/root/riscv-port; U=$R/rp52/user; L=$R/rp52/libc
GCC=$R/build/gcc-sol-cfg3/gcc; XGCC="$GCC/xgcc -B$GCC"
TB=$R/toolchain/bin; LDSH=$TB/riscv64-unknown-elf-ld-shared
READELF=$TB/riscv64-unknown-elf-readelf; NM=$TB/riscv64-unknown-elf-nm
SR=$R/sysroot-riscv-sol; LGS=$R/rp21/libgcc_s
CF=$R/rp51/upstream/cu-full/coreutils-9.5; GLIB=$CF/lib; SRC=$CF/src
BD=$R/rp51/user/lsup-build
CFLAGS="-march=rv64gc -mabi=lp64d -mcmodel=medany -ffreestanding \
	-fno-stack-protector -fno-pie -fno-builtin -O2 -w \
	-Wno-implicit-function-declaration -Wno-builtin-declaration-mismatch \
	-DHAVE_CONFIG_H -I$GLIB -I$SRC -I$L/include -I$R/rp51/user/lsup-shims"
cd $BD
CRT="$L/csu/crt1.o $L/csu/crti.o"; CRTN="$L/csu/crtn.o"; LIBS="$L/libc.a -lgcc_s"
LDF="-e _start --dynamic-linker /usr/lib/ld.so.1 -L$LGS --hash-style=both -z relro -z lazy"

gcc_obj() { # SRCDIR base
	local dir="$1" base="$2" o
	o=$(echo $base | tr - _).o
	[ -f "$o" ] || $XGCC --sysroot=$SR $CFLAGS -include getopt.h -c $dir/$base.c -o $o
}
# cut deps (a superset of what R-P51 already built for paste/expand).
gcc_obj $SRC set-fields
gcc_obj $GLIB getndelim2
gcc_obj $GLIB memchr2
gcc_obj $GLIB xstrtol
gcc_obj $GLIB xstrtoumax
gcc_obj $GLIB safe-read
gcc_obj $GLIB fadvise
gcc_obj $GLIB long-options
gcc_obj $GLIB quotearg

BASE="progname.o closeout.o exitfail.o xalloc-die.o xmalloc.o \
	version-etc.o version-etc-fsf.o propername-lite.o lsup_support.o \
	localcharset.o setlocale_null.o hard-locale.o quotearg.o \
	c-strcasecmp.o c-strncasecmp.o long-options.o fadvise.o \
	$R/rp51/user/getopt.o"

echo "=== R-P52: UNMODIFIED coreutils-9.5 cut.c on the rp52 libc.a ==="
$XGCC --sysroot=$SR $CFLAGS -include getopt.h -c $SRC/cut.c -o corecut.o
echo "  OK cc UNMODIFIED cut.c"
$LDSH $LDF -o $U/corecut.dyn $CRT corecut.o $BASE \
	set_fields.o getndelim2.o memchr2.o safe_read.o xstrtoumax.o xstrtol.o \
	$CRTN $LIBS --allow-shlib-undefined
$READELF -lW $U/corecut.dyn | grep -q "/usr/lib/ld.so.1" && echo "  OK corecut.dyn INTERP ld.so.1"
$NM $U/corecut.dyn | grep -qE " T main\$" && echo "  cut: main T -- BUILT"
echo BUILD_CU10_DONE
