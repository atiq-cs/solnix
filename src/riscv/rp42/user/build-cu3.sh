#!/usr/bin/env bash
# build-cu3.sh -- R-P42.2: build MORE UNMODIFIED GNU coreutils-9.5 utils
# (verbatim src/basename.c + src/dirname.c, and env.c if it links) against the
# REAL solnix riscv64 libc.a via cu3-include/ (cu3_glue.h: base_name/dir_len/
# strip_trailing_slashes reduced from gnulib basename-lgpl/dirname-lgpl, POSIX
# single-slash; environ from the real libc).  Dynamically linked via ld.so.1.
set -e
export PATH=/usr/gnu/bin:/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
R=/root/riscv-port; U=$R/rp42/user; L=$R/rp42/libc
GCC=$R/build/gcc-sol-cfg3/gcc; XGCC="$GCC/xgcc -B$GCC"
TB=$R/toolchain/bin; LDSH=$TB/riscv64-unknown-elf-ld-shared
READELF=$TB/riscv64-unknown-elf-readelf; NM=$TB/riscv64-unknown-elf-nm
SR=$R/sysroot-riscv-sol; LGS=$R/rp21/libgcc_s
CU=$R/rp42/upstream/coreutils-9.5/src
CFLAGS="-march=rv64gc -mabi=lp64d -mcmodel=medany -ffreestanding \
	-fno-stack-protector -fno-pie -fno-builtin -O2 -Wall -Wno-unused \
	-Wno-implicit-function-declaration -Wno-builtin-declaration-mismatch \
	-I$U/cu3-include -I$L/include"
cd $U
$XGCC --sysroot=$SR $CFLAGS -c getopt.c -o getopt.o
$XGCC --sysroot=$SR $CFLAGS -c wclib.c -o wclib.o
CRT="$L/csu/crt1.o $L/csu/crti.o"; CRTN="$L/csu/crtn.o"
LIBS="$L/libc.a -lgcc_s"
LDF="-e _start --dynamic-linker /usr/lib/ld.so.1 -L$LGS --hash-style=both -z relro -z lazy"

link_one() {
	local name=$1
	$LDSH $LDF -o $name.dyn $CRT $name.o getopt.o wclib.o $CRTN $LIBS --allow-shlib-undefined
	$READELF -lW $name.dyn | grep -q "/usr/lib/ld.so.1" && echo "  OK $name.dyn INTERP ld.so.1"
}

echo "=== R-P42.2: UNMODIFIED basename.c ==="
$XGCC --sysroot=$SR $CFLAGS -c $CU/basename.c -o corebasename.o && echo "  OK cc UNMODIFIED basename.c"
link_one corebasename

echo "=== R-P42.2: UNMODIFIED dirname.c ==="
$XGCC --sysroot=$SR $CFLAGS -c $CU/dirname.c -o coredirname.o && echo "  OK cc UNMODIFIED dirname.c"
link_one coredirname

# env.c is attempted; if it does not link (sig2str/operand2sig heavy), it is
# skipped without failing the build (basename/dirname are the guaranteed pair).
echo "=== R-P42.2: UNMODIFIED env.c (attempt) ==="
if $XGCC --sysroot=$SR $CFLAGS -c $CU/env.c -o coreenv.o 2>/tmp/env-cc.log; then
	echo "  OK cc UNMODIFIED env.c"
	if $LDSH $LDF -o coreenv.dyn $CRT coreenv.o getopt.o wclib.o $CRTN $LIBS --allow-shlib-undefined 2>/tmp/env-ld.log; then
		$READELF -lW coreenv.dyn | grep -q "/usr/lib/ld.so.1" && echo "  OK coreenv.dyn INTERP ld.so.1"
	else
		echo "  NOTE env.c did not LINK (see /tmp/env-ld.log) -- skipped, deferred"
		mv coreenv.dyn coreenv.dyn.nolink 2>/dev/null || true
	fi
else
	echo "  NOTE env.c did not COMPILE (see /tmp/env-cc.log) -- skipped, deferred"
fi

echo "=== nm proof ==="
$NM corebasename.dyn 2>/dev/null | grep -qE " T base_name\$" && echo "  basename: base_name T (from glue)"
echo BUILD_CU3_DONE
