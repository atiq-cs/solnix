#!/usr/bin/env bash
#
# build-ldso.sh -- R-P27: build the userland riscv64 ld.so.1 that the kernel
# exec path enters as the INTERP for the DYNAMIC hello.  A static EM_RISCV
# ET_EXEC linked at 0x30000000 (above the app, below the user stack), entry
# _rtld_start: reads the auxv, relocates the app, jumps to the app entry.
set -e
export PATH=/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
L=/root/riscv-port/rp31/ldso
GCC=/root/riscv-port/build/gcc-sol-cfg3/gcc
XGCC="$GCC/xgcc -B$GCC"
TB=/root/riscv-port/toolchain/bin
LD=$TB/riscv64-unknown-elf-ld
READELF=$TB/riscv64-unknown-elf-readelf
CFLAGS="-march=rv64gc -mabi=lp64d -mcmodel=medany -ffreestanding \
	-fno-stack-protector -fno-pie -O2 -Wall -Wno-unused -I$L"
cd $L

echo "=== compiling the userland riscv64 ld.so.1 (R-P27) ==="
$XGCC $CFLAGS -c rtld_start.S  -o rtld_start.o
$XGCC $CFLAGS -c rtld_riscv.c  -o rtld_riscv.o
$LD -T ld.so.1.lds -static -e _rtld_start \
	rtld_start.o rtld_riscv.o -o ld.so.1 2>&1 | grep -v RWX || true

MACH=$($READELF -h ld.so.1 | awk -F: '/Machine/{print $2}' | tr -d ' ')
[ "$MACH" = "RISC-V" ] || { echo "FAIL: not EM_RISCV"; exit 1; }
$READELF -rW ld.so.1 2>/dev/null | grep -qE "R_RISCV_(CALL|PCREL|HI20|BRANCH|JUMP)" \
	&& { echo "FAIL: unresolved relocs in ld.so.1"; exit 1; } || true
echo "  OK: static EM_RISCV ld.so.1, entry $($READELF -h ld.so.1 | awk -F: '/Entry/{print $2}' | tr -d ' ')"
$READELF -lW ld.so.1 | grep -E "LOAD|Entry" || true
