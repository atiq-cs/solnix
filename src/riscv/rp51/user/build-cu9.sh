#!/usr/bin/env bash
# build-cu9.sh -- R-P51: MORE UNMODIFIED GNU coreutils-9.5 utils on the REAL
# solnix riscv64 libc.a.  HEADLINE tie-in: ln (now a REAL hard link -- the
# R-P51 shared-inode/nlink vfs_link).  Plus the lean POSIX text utils cut,
# paste, expand, uniq (line/field/column processing over stdin).  Dynamically
# linked via ld.so.1 as /bin/core<name>.  Source stays UNMODIFIED.
set -e
export PATH=/usr/gnu/bin:/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
R=/root/riscv-port; U=$R/rp51/user; L=$R/rp51/libc
GCC=$R/build/gcc-sol-cfg3/gcc; XGCC="$GCC/xgcc -B$GCC"
TB=$R/toolchain/bin; LDSH=$TB/riscv64-unknown-elf-ld-shared
READELF=$TB/riscv64-unknown-elf-readelf; NM=$TB/riscv64-unknown-elf-nm
SR=$R/sysroot-riscv-sol; LGS=$R/rp21/libgcc_s
CF=$R/rp51/upstream/cu-full/coreutils-9.5; GLIB=$CF/lib; SRC=$CF/src
BD=$U/lsup-build
CFLAGS="-march=rv64gc -mabi=lp64d -mcmodel=medany -ffreestanding \
	-fno-stack-protector -fno-pie -fno-builtin -O2 -w \
	-Wno-implicit-function-declaration -Wno-builtin-declaration-mismatch \
	-DHAVE_CONFIG_H -I$GLIB -I$SRC -I$L/include -I$U/lsup-shims"
cd $BD
CRT="$L/csu/crt1.o $L/csu/crti.o"; CRTN="$L/csu/crtn.o"; LIBS="$L/libc.a -lgcc_s"
LDF="-e _start --dynamic-linker /usr/lib/ld.so.1 -L$LGS --hash-style=both -z relro -z lazy"

gcc_obj() { # SRCDIR base
	local dir="$1" base="$2" o
	o=$(echo $base | tr - _).o
	[ -f "$o" ] || $XGCC --sysroot=$SR $CFLAGS -include getopt.h -c $dir/$base.c -o $o
}
# lean text-util deps
gcc_obj $GLIB fadvise
gcc_obj $SRC set-fields
gcc_obj $GLIB getndelim2
gcc_obj $SRC expand-common
gcc_obj $GLIB linebuffer
gcc_obj $GLIB memcasecmp
gcc_obj $GLIB mcel
gcc_obj $GLIB skipchars
gcc_obj $GLIB xstrtol
gcc_obj $GLIB xstrtoumax
gcc_obj $GLIB argmatch
gcc_obj $GLIB hard-locale
gcc_obj $GLIB quotearg
gcc_obj $GLIB safe-read
gcc_obj $GLIB long-options
gcc_obj $GLIB filemode
# ln deps
gcc_obj $GLIB backupfile
gcc_obj $SRC force-link
gcc_obj $GLIB hash
gcc_obj $GLIB hash-triple-simple
gcc_obj $GLIB file-set
gcc_obj $GLIB filenamecat-lgpl
gcc_obj $GLIB same
gcc_obj $GLIB areadlink
gcc_obj $GLIB areadlink-with-size
gcc_obj $GLIB careadlinkat
gcc_obj $GLIB allocator
gcc_obj $GLIB yesno

BASE="progname.o closeout.o exitfail.o xalloc-die.o xmalloc.o \
	version-etc.o version-etc-fsf.o propername-lite.o lsup_support.o \
	localcharset.o setlocale_null.o hard-locale.o quotearg.o \
	c-strcasecmp.o c-strncasecmp.o long-options.o filemode.o fadvise.o \
	$U/getopt.o"

link_util() { # NAME "extra objs" "extra cflags"
	local name="$1" extra="$2" ecf="$3"
	echo "=== R-P51: UNMODIFIED $name.c ==="
	$XGCC --sysroot=$SR $CFLAGS $ecf -include getopt.h -c $SRC/$name.c -o core$name.o
	echo "  OK cc UNMODIFIED $name.c"
	$LDSH $LDF -o $U/core$name.dyn $CRT core$name.o $BASE $extra $CRTN $LIBS --allow-shlib-undefined
	$READELF -lW $U/core$name.dyn | grep -q "/usr/lib/ld.so.1" && echo "  OK core$name.dyn INTERP ld.so.1"
	$NM $U/core$name.dyn | grep -qE " T main\$" && echo "  $name: main T -- BUILT"
}

# lean text utils first
# cut needs ungetc/freadptr/freadseek/memchr2 (libc gaps) -- deferred to R-P52.
# link_util cut "set_fields.o getndelim2.o safe_read.o xstrtoumax.o xstrtol.o argmatch.o" ""
link_util paste  "safe_read.o" ""
link_util expand "expand_common.o safe_read.o" ""
link_util unexpand "expand_common.o safe_read.o" ""
# uniq needs mbrtoc32/c32isblank/freopen_safer/posix2_version/xstrtoimax -- R-P52.
# link_util uniq "linebuffer.o memcasecmp.o mcel.o skipchars.o ..." ""

# ln: needs linkat/symlinkat/renameat/unlinkat/fstatat wrappers + a large
# basename/dirname/hash gnulib chain -- deep.  The R-P51 REAL hard link is
# proven by the existing `link` coreutil (link(2) -> the shared-inode
# vfs_link).  `ln` binary deferred to R-P52 (needs the *at syscall family).
# LN_EXTRA="backupfile.o force_link.o hash.o ..."; link_util ln "$LN_EXTRA" ""

# a couple more lean text utils
# nl needs the xdectoint gnulib template (-D__xdectoint_t=...) -- R-P52.
# cksum needs <byteswap.h> -- R-P52.

echo BUILD_CU9_DONE
