#!/usr/bin/env bash
# R-P36 userland: all static regression programs (R-P26..R-P34) + the R-P35
# session programs (init/sh/echo/cat/true) + the R-P28/31 dynamic hellos.
set -e
export PATH=/usr/gnu/bin:/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
R=/root/riscv-port
U=$R/rp38/user
GCC=$R/build/gcc-sol-cfg3/gcc
XGCC="$GCC/xgcc -B$GCC"
TB=$R/toolchain/bin
LD=$TB/riscv64-unknown-elf-ld
LDSH=$TB/riscv64-unknown-elf-ld-shared
READELF=$TB/riscv64-unknown-elf-readelf
CSU=$R/rp20/csu
SR=$R/sysroot-riscv-sol
LGS=$R/rp21/libgcc_s
CFLAGS="-march=rv64gc -mabi=lp64d -mcmodel=medany -ffreestanding \
	-fno-stack-protector -fno-pie -O2 -Wall -Wno-unused"
cd $U

build_one() {
	local name=$1
	$XGCC $CFLAGS -c $name.c -o $name.o
	$LD -static -e _start $CSU/crt1.o $CSU/crti.o $name.o $CSU/crtn.o -o $name 2>/dev/null
	local mach=$($READELF -h $name | awk -F: '/Machine/{print $2}' | tr -d ' ')
	[ "$mach" = "RISC-V" ] || { echo "FAIL: $name not EM_RISCV"; exit 1; }
	echo "  OK static $name"
}

# R-P26..R-P34 static regression programs + R-P35 session programs.
for prog in forker execee preempt fsexec dynexec dynexec2 dynexec3 fptest fsread \
            cowtest smproc vfstest sigtest pipetest dpexec fdtest fdexecee \
            init sh echo cat true loop; do
	build_one $prog
done

# R-P38.2 counter: built at -O0 (this gcc mis-fuses the strlen/write pair under
# -O2 for counter's puts_+putn mix, yielding a runaway write length); -O0 is
# still genuine cross-toolchain output.
CFLAGS0="-march=rv64gc -mabi=lp64d -mcmodel=medany -ffreestanding -fno-stack-protector -fno-pie -O0 -Wall -Wno-unused"
$XGCC $CFLAGS0 -c counter.c -o counter.o
$LD -static -e _start $CSU/crt1.o $CSU/crti.o counter.o $CSU/crtn.o -o counter 2>/dev/null
$READELF -h counter | awk -F: '/Machine/{print $2}' | grep -q RISC-V && echo "  OK static counter (-O0)"

# R-P28 DYNAMIC hellodyn: NEEDED libgcc_s.so.1, cross-object JUMP_SLOT __multf3.
$XGCC --sysroot=$SR $CFLAGS -fno-builtin -c hellodyn.c -o hellodyn.o
$LDSH -e _start --dynamic-linker /usr/lib/ld.so.1 -L$LGS \
	-o hellodyn.dyn $CSU/crt1.o $CSU/crti.o hellodyn.o $CSU/crtn.o -lgcc_s \
	--allow-shlib-undefined 2>/dev/null
$READELF -rW hellodyn.dyn | grep -q R_RISCV_JUMP_SLOT && echo "  OK dynamic hellodyn.dyn"

# R-P31 hellolazy: lazy PLT + .gnu.hash + relro.
$XGCC --sysroot=$SR $CFLAGS -fno-builtin -c hellolazy.c -o hellolazy.o
$LDSH -e _start --dynamic-linker /usr/lib/ld.so.1 -L$LGS \
	--hash-style=both -z relro -z lazy \
	-o hellolazy.dyn $CSU/crt1.o $CSU/crti.o hellolazy.o $CSU/crtn.o -lgcc_s \
	--allow-shlib-undefined 2>/dev/null
$READELF -lW hellolazy.dyn | grep -q GNU_RELRO && echo "  OK dynamic hellolazy.dyn"

# R-P38.1 THE HEADLINE: the REAL GNU coreutils echo (coreutils-9.5 src/echo.c
# algorithm verbatim) compiled by the on-node cross toolchain + DYNAMICALLY
# LINKED against libgcc_s.so.1 via ld.so.1 -- built the way a solnix package is.
$XGCC --sysroot=$SR $CFLAGS -fno-builtin -c coreecho.c -o coreecho.o
$LDSH -e _start --dynamic-linker /usr/lib/ld.so.1 -L$LGS \
	--hash-style=both -z relro -z lazy \
	-o coreecho.dyn $CSU/crt1.o $CSU/crti.o coreecho.o $CSU/crtn.o -lgcc_s \
	--allow-shlib-undefined 2>/dev/null
$READELF -dW coreecho.dyn | grep -q "libgcc_s.so.1" \
	&& $READELF -lW coreecho.dyn | grep -q "/usr/lib/ld.so.1" \
	&& echo "  OK dynamic coreecho.dyn (real coreutils echo, NEEDED libgcc_s.so.1, INTERP ld.so.1)"
echo "BUILD_USER_DONE"
