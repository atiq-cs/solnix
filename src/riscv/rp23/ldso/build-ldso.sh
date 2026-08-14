#!/usr/bin/env bash
#
# build-ldso.sh -- R-P23 sub-task 2: build + run the REDUCED riscv64 ld.so.1
# runtime relocation engine as a freestanding S-mode payload under
# qemu-system-riscv64 -machine virt (OpenSBI).  Proves the core ld.so.1
# riscv64 load-time reloc handling -- R_RISCV_RELATIVE (B+A) + R_RISCV_JUMP_SLOT
# (bind + call through the GOT slot) -- resolved at runtime, the milestone the
# R-P23 anti-wedge directive asks for (a REDUCED ld.so.1 resolving a symbol).
set -e
export PATH=/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
L=/root/riscv-port/rp23/ldso
GCC=/root/riscv-port/build/gcc-sol-cfg3/gcc
XGCC="$GCC/xgcc -B$GCC"
TB=/root/riscv-port/toolchain/bin
LD=$TB/riscv64-unknown-elf-ld
READELF=$TB/riscv64-unknown-elf-readelf
QEMU=/usr/bin/qemu-system-riscv64
BIOS=/usr/share/qemu/opensbi-riscv64-generic-fw_dynamic.bin
CFLAGS="-march=rv64gc -mabi=lp64d -mcmodel=medany -ffreestanding \
	-fno-stack-protector -fno-pie -O2 -Wall -Wno-unused -I$L"
cd $L

echo "=== compiling the REDUCED riscv64 ld.so.1 reloc engine ==="
$XGCC $CFLAGS -c boot.S       -o boot.o
$XGCC $CFLAGS -c sbi.c        -o sbi.o
$XGCC $CFLAGS -c rtld_riscv.c -o rtld_riscv.o
$LD -T virt.lds -nostdlib boot.o sbi.o rtld_riscv.o -o ldso.elf 2>&1 | grep -v RWX || true

MACH=$($READELF -h ldso.elf | awk -F: '/Machine/{print $2}' | tr -d ' ')
[ "$MACH" = "RISC-V" ] || { echo "FAIL: not EM_RISCV"; exit 1; }
echo "  OK: EM_RISCV ldso.elf, entry $($READELF -h ldso.elf | awk -F: '/Entry/{print $2}' | tr -d ' ')"

echo "=== running under qemu-system-riscv64 -machine virt ==="
timeout 30 $QEMU -machine virt -smp 1 -m 256M -nographic \
	-bios $BIOS -kernel ldso.elf > $L/qemu-ldso.log 2>&1 || true
sed -n '/\[ld.so.1\]/,$p' $L/qemu-ldso.log

grep -q "REDUCED ld.so.1 reloc engine PASS" $L/qemu-ldso.log \
	&& echo "R-P23.2 PASS: riscv64 ld.so.1 RELATIVE + JUMP_SLOT resolved at runtime" \
	|| { echo "R-P23.2 FAIL"; exit 1; }
