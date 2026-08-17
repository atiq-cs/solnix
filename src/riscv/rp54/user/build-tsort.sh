#!/usr/bin/env bash
# build-tsort.sh -- R-P54: UNMODIFIED GNU coreutils-9.5 tsort.c on the REAL
# solnix riscv64 libc.a.  tsort (topological sort) reads whitespace-separated
# tokens through the plain gnulib readtokens (no regex, no multibyte), builds a
# dependency graph, and prints a topological ordering.  Its deps -- readtokens,
# fadvise, long-options, quotearg -- are all already supported by the libc +
# the R-P51 gnulib support set.  Source stays UNMODIFIED.
set -e
export PATH=/usr/gnu/bin:/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
R=/root/riscv-port; U=$R/rp54/user; L=$R/rp54/libc
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
# tsort deps beyond the shared BASE set.
gcc_obj $GLIB readtokens
# the reduced libc has no freopen; a small house shim supplies freopen_safer
# (fopen + dup2 onto the target fd) -- the one behaviour tsort needs (redirect
# stdin to a named file).  tsort.c itself stays UNMODIFIED.
$XGCC --sysroot=$SR $CFLAGS -c $U/freopen_safer_shim.c -o freopen_safer.o
gcc_obj $GLIB fadvise
gcc_obj $GLIB long-options
gcc_obj $GLIB quotearg

BASE="progname.o closeout.o exitfail.o xalloc-die.o xmalloc.o \
	version-etc.o version-etc-fsf.o propername-lite.o lsup_support.o \
	localcharset.o setlocale_null.o hard-locale.o quotearg.o \
	c-strcasecmp.o c-strncasecmp.o long-options.o fadvise.o \
	$R/rp51/user/getopt.o"

echo "=== R-P54: UNMODIFIED coreutils-9.5 tsort.c on the rp54 libc.a ==="
$XGCC --sysroot=$SR $CFLAGS -include getopt.h -c $SRC/tsort.c -o coretsort.o
echo "  OK cc UNMODIFIED tsort.c"
$LDSH $LDF -o $U/coretsort.dyn $CRT coretsort.o $BASE \
	readtokens.o freopen_safer.o \
	$CRTN $LIBS --allow-shlib-undefined
$READELF -lW $U/coretsort.dyn | grep -q "/usr/lib/ld.so.1" && echo "  OK coretsort.dyn INTERP ld.so.1"
$NM $U/coretsort.dyn | grep -qE " T main\$" && echo "  tsort: main T -- BUILT"
echo BUILD_TSORT_DONE
