#!/usr/bin/env bash
# build-lsup.sh -- R-P45 Route A: compile the UNMODIFIED coreutils-9.5 src/ls.c
# + the gnulib lib/*.c it needs against the solnix riscv64 libc.a, using gnulib's
# OWN generated headers (config.h + obstack.h from obstack.in.h + the shipped
# intprops.h/verify.h/attribute.h/quotearg.h/human.h/mbswidth.h).  Links dynamic
# via ld.so.1 as /bin/lsup (-> corelsup.dyn).  ls.c stays VERBATIM.
set -e
export PATH=/usr/gnu/bin:/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
R=/root/riscv-port
U=$R/rp45/user
L=$R/rp45/libc
GCC=$R/build/gcc-sol-cfg3/gcc
XGCC="$GCC/xgcc -B$GCC"
TB=$R/toolchain/bin
LDSH=$TB/riscv64-unknown-elf-ld-shared
READELF=$TB/riscv64-unknown-elf-readelf
NM=$TB/riscv64-unknown-elf-nm
SR=$R/sysroot-riscv-sol
LGS=$R/rp21/libgcc_s
CF=$R/rp45/upstream/cu-full/coreutils-9.5
GLIB=$CF/lib
SRC=$CF/src
BD=$U/lsup-build
mkdir -p $BD
CFLAGS="-march=rv64gc -mabi=lp64d -mcmodel=medany -ffreestanding \
	-fno-stack-protector -fno-pie -fno-builtin -O2 -w \
	-Wno-implicit-function-declaration -Wno-builtin-declaration-mismatch \
	-DHAVE_CONFIG_H \
	-I$GLIB -I$SRC -I$L/include -I$U/lsup-shims"
cd $BD

OK_LIST=""; FAIL_LIST=""
cc1() { # $1=src $2=obj  -- compile, track, never abort
	local src=$1 obj=$2 nm=$(basename $1)
	if $XGCC --sysroot=$SR $CFLAGS -c "$src" -o "$obj" 2>$obj.err; then
		echo "  OK   $nm"; OK_LIST="$OK_LIST $obj"
	else
		echo "  FAIL $nm"; head -4 $obj.err | sed 's/^/       /'
		FAIL_LIST="$FAIL_LIST $nm"
	fi
}

echo "=== R-P45 Route A: compile the gnulib module .c set ls.c needs ==="
# self-contained / low-dep first (the keystones + leaf modules), then the rest.
MODS="obstack quotearg human mbswidth mpsort hash filevercmp filemode \
      argmatch xstrtol xstrtoumax idcache areadlink xgethostname gethostname \
      c-strcasecmp c-strncasecmp mbrtowc mbrtoc32 \
      localcharset xalloc-die xmalloc version-etc \
      file-has-acl acl-internal \
      careadlinkat filenamecat filenamecat-lgpl basename-lgpl \
      imaxtostr umaxtostr xstrtol-error closeout exitfail progname \
      mbszero setlocale_null hard-locale nstrftime gettime time_rz \
      propername-lite version-etc-fsf \
      allocator areadlink-with-size"
for m in $MODS; do
	[ -f $GLIB/$m.c ] && cc1 $GLIB/$m.c $m.o
done

echo "=== R-P45 Route A: compile the UNMODIFIED src/ls.c ==="
cc1 $SRC/ls.c ls.o
cc1 $SRC/ls-ls.c ls-ls.o

echo
echo "=== SUMMARY ==="
echo "  compiled OK:$(echo $OK_LIST | tr ' ' '\n' | grep -c .)"
[ -n "$FAIL_LIST" ] && echo "  FAILED:$FAIL_LIST" || echo "  FAILED: none"

# support TU: the C-locale reductions for the 3 gnulib modules we did not take
# verbatim (hard_locale, canonicalize_filename_mode, nstrftime) + any thin libc
# helpers ls/gnulib expect that are not yet in libc.a.
if [ -f $U/lsup_support.c ]; then
	cc1 $U/lsup_support.c lsup_support.o || true
fi
# the house getopt (getopt_long) is shared with the other utils.
cc1 $U/getopt.c getopt.o || true

echo "=== R-P45 Route A: LINK corelsup.dyn (ls.c + 25 verbatim gnulib .c + libc.a) ==="
OBJS=$(echo $OK_LIST | tr ' ' '\n' | grep -v '^$' | tr '\n' ' ')
if $LDSH -e _start --dynamic-linker /usr/lib/ld.so.1 -L$LGS \
	--hash-style=both -z relro -z lazy \
	-o $U/corelsup.dyn $L/csu/crt1.o $L/csu/crti.o \
	$OBJS $L/csu/crtn.o \
	$L/libc.a -lgcc_s --allow-shlib-undefined 2>$U/lsup.link.err; then
	$READELF -dW $U/corelsup.dyn | grep -q "libgcc_s.so.1" \
		&& $READELF -lW $U/corelsup.dyn | grep -q "/usr/lib/ld.so.1" \
		&& echo "  OK corelsup.dyn LINKED (unmodified ls.c, 25 verbatim gnulib .c, real libc.a)"
	$NM $U/corelsup.dyn | grep -qE " T main\$" && echo "  ls.c main: T"
else
	echo "  LINK FAILED -- undefined/other:"
	grep -iE "undefined|undef reference" $U/lsup.link.err | sed 's/^/     /' | sort -u | head -60
fi
echo "BUILD_LSUP_LINK_DONE"
