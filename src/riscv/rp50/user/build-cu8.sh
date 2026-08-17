#!/usr/bin/env bash
# build-cu8.sh -- R-P50: MORE UNMODIFIED GNU coreutils-9.5 utils on the REAL
# solnix riscv64 libc.a.  HEADLINE: stat (exercises the R-P50 blockfs getattr:
# stat /blk/persist reports real size/mode).  Plus link (the R-P50 link(2)
# syscall -> vfs_link), fold + tr (needed only a POSIX_FADV_/O_BINARY shim +
# the fadvise no-op).  Dynamically linked via ld.so.1 as /bin/<name>.
#
# Source stays UNMODIFIED: stat.c builds with -UHAVE_GETATTRAT (config.h also
# #undef's it) so the illumos getattrat/attr.h path is off and the POSIX
# stat(2) path is used; the deep gnulib mount-list + vasnprintf float chains
# are replaced by two small house TUs (stat_stubs.c: empty mount list for the
# --file-system path; xvasprintf_house.c: xasprintf on the libc vsnprintf).
set -e
export PATH=/usr/gnu/bin:/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
R=/root/riscv-port; U=$R/rp50/user; L=$R/rp50/libc
GCC=$R/build/gcc-sol-cfg3/gcc; XGCC="$GCC/xgcc -B$GCC"
TB=$R/toolchain/bin; LDSH=$TB/riscv64-unknown-elf-ld-shared
READELF=$TB/riscv64-unknown-elf-readelf; NM=$TB/riscv64-unknown-elf-nm
SR=$R/sysroot-riscv-sol; LGS=$R/rp21/libgcc_s
CF=$R/rp50/upstream/cu-full/coreutils-9.5; GLIB=$CF/lib; SRC=$CF/src
BD=$U/lsup-build
CFLAGS="-march=rv64gc -mabi=lp64d -mcmodel=medany -ffreestanding \
	-fno-stack-protector -fno-pie -fno-builtin -O2 -w \
	-Wno-implicit-function-declaration -Wno-builtin-declaration-mismatch \
	-DHAVE_CONFIG_H -I$GLIB -I$SRC -I$L/include -I$U/lsup-shims"
cd $BD
CRT="$L/csu/crt1.o $L/csu/crti.o"; CRTN="$L/csu/crtn.o"; LIBS="$L/libc.a -lgcc_s"
LDF="-e _start --dynamic-linker /usr/lib/ld.so.1 -L$LGS --hash-style=both -z relro -z lazy"

# gnulib + house support objects.  Build any not already present.
gcc_obj() { # SRCDIR base
	local dir="$1" base="$2" o
	o=$(echo $base | tr - _).o
	[ -f "$o" ] || $XGCC --sysroot=$SR $CFLAGS -include getopt.h -c $dir/$base.c -o $o
}
gcc_obj $GLIB long-options
gcc_obj $GLIB filemode
gcc_obj $GLIB fadvise
gcc_obj $GLIB safe-read
gcc_obj $GLIB xstrtoumax
gcc_obj $GLIB xstrtol
gcc_obj $GLIB argmatch
gcc_obj $GLIB areadlink-with-size
gcc_obj $GLIB areadlink
gcc_obj $GLIB careadlinkat
gcc_obj $GLIB allocator
gcc_obj $GLIB file-type
gcc_obj $GLIB c-file-type
gcc_obj $GLIB imaxtostr
gcc_obj $GLIB nstrftime
gcc_obj $GLIB time_rz
[ -f stat_stubs.o ]      || $XGCC --sysroot=$SR $CFLAGS -c $U/stat_stubs.c -o stat_stubs.o
[ -f xvasprintf_house.o ] || $XGCC --sysroot=$SR $CFLAGS -c $U/xvasprintf_house.c -o xvasprintf_house.o

BASE="progname.o closeout.o exitfail.o xalloc-die.o xmalloc.o \
	version-etc.o version-etc-fsf.o propername-lite.o lsup_support.o \
	localcharset.o setlocale_null.o hard-locale.o quotearg.o \
	c-strcasecmp.o c-strncasecmp.o long-options.o filemode.o fadvise.o \
	$U/getopt.o"

link_util() { # NAME "extra objs" "extra cflags"
	local name="$1" extra="$2" ecf="$3"
	echo "=== R-P50: UNMODIFIED $name.c ==="
	$XGCC --sysroot=$SR $CFLAGS $ecf -include getopt.h -c $SRC/$name.c -o core$name.o
	echo "  OK cc UNMODIFIED $name.c"
	$LDSH $LDF -o $U/core$name.dyn $CRT core$name.o $BASE $extra $CRTN $LIBS --allow-shlib-undefined
	$READELF -lW $U/core$name.dyn | grep -q "/usr/lib/ld.so.1" && echo "  OK core$name.dyn INTERP ld.so.1"
	$NM $U/core$name.dyn | grep -qE " T main\$" && echo "  $name: main T -- BUILT"
}

# stat: the big one -- the mode/size/time-formatting object set.
STAT_EXTRA="safe_read.o xstrtoumax.o xstrtol.o argmatch.o \
	areadlink_with_size.o areadlink.o careadlinkat.o allocator.o \
	file_type.o c_file_type.o imaxtostr.o nstrftime.o time_rz.o \
	xvasprintf_house.o stat_stubs.o"
link_util stat "$STAT_EXTRA" "-UHAVE_GETATTRAT"

link_util link "" ""
link_util fold "" ""
link_util tr   "safe_read.o xstrtoumax.o" ""

echo BUILD_CU8_DONE
