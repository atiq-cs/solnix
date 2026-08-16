#!/usr/bin/env bash
# R-P36 userland: all static regression programs (R-P26..R-P34) + the R-P35
# session programs (init/sh/echo/cat/true) + the R-P28/31 dynamic hellos.
set -e
export PATH=/usr/gnu/bin:/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
R=/root/riscv-port
U=$R/rp36/user
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
            init sh echo cat true; do
	build_one $prog
done

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
echo "BUILD_USER_DONE"
