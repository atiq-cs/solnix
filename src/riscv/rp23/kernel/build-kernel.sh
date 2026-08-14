#!/usr/bin/env bash
#
# build-kernel.sh -- R-P23 sub-task 1: build + boot the illumos riscv64 MD
# kernel SKELETON with the NATIVE riscv64-unknown-solaris2.11 toolchain, on
# qemu-system-riscv64 -machine virt via OpenSBI.  This is the R-P23 headline:
# the FIRST BOOTING illumos-riscv64 kernel built from the solnix native
# toolchain -- locore -> mlsetup -> banner via SBI -> known halt.
set -e
export PATH=/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
K=/root/riscv-port/rp23/kernel
GCC=/root/riscv-port/build/gcc-sol-cfg3/gcc
XGCC="$GCC/xgcc -B$GCC"
TB=/root/riscv-port/toolchain/bin
LD=$TB/riscv64-unknown-elf-ld
READELF=$TB/riscv64-unknown-elf-readelf
OBJDUMP=$TB/riscv64-unknown-elf-objdump
QEMU=/usr/bin/qemu-system-riscv64
BIOS=/usr/share/qemu/opensbi-riscv64-generic-fw_dynamic.bin
CFLAGS="-march=rv64gc -mabi=lp64d -mcmodel=medany -ffreestanding \
	-fno-stack-protector -fno-pie -O2 -Wall -Wno-unused -I$K"
cd $K

echo "=== compiling the native EM_RISCV kernel skeleton ==="
$XGCC $CFLAGS -c locore.S    -o locore.o
$XGCC $CFLAGS -c mach_trap.S -o mach_trap.o
$XGCC $CFLAGS -c mach_clock.S -o mach_clock.o
$XGCC $CFLAGS -c mach_mmu.S  -o mach_mmu.o
$XGCC $CFLAGS -c sbi.c       -o sbi.o
$XGCC $CFLAGS -c main.c      -o main.o

echo "=== linking the kernel ELF (EM_RISCV, entry _start @ 0x80200000) ==="
$LD -T kernel.lds -nostdlib -e _start \
	locore.o mach_trap.o mach_clock.o mach_mmu.o sbi.o main.o \
	-o unix.elf 2>&1

MACH=$($READELF -h unix.elf | awk -F: '/Machine/{print $2}' | tr -d ' ')
ENTRY=$($READELF -h unix.elf | awk -F: '/Entry point/{print $2}' | tr -d ' ')
echo "  Machine=$MACH  Entry=$ENTRY"
[ "$MACH" = "RISC-V" ] || { echo "FAIL: not EM_RISCV"; exit 1; }
$READELF -r unix.elf 2>&1 | grep -qi "no relocations" \
	|| echo "  (note: inspect relocs below)"
# every reloc must be resolved in a static kernel image
if $READELF -rW unix.elf 2>/dev/null | grep -qE "R_RISCV_(CALL|PCREL|JUMP|HI20|BRANCH)"; then
	echo "FAIL: unresolved relocs in the kernel image"; exit 1
fi
echo "  OK: zero residual relocs (self-contained kernel image)"

echo "=== booting the kernel under qemu-system-riscv64 -machine virt ==="
timeout 30 $QEMU -machine virt -smp 1 -m 256M -nographic \
	-bios $BIOS -kernel unix.elf > /root/riscv-port/rp23/kernel/qemu-boot.log 2>&1 || true
echo "--- qemu-boot.log ---"
cat /root/riscv-port/rp23/kernel/qemu-boot.log
echo "--- end log ---"

grep -q "first booting illumos-riscv64 kernel" /root/riscv-port/rp23/kernel/qemu-boot.log \
	&& echo "R-P23.1 PASS: illumos-riscv64 kernel BOOTED + banner printed" \
	|| { echo "R-P23.1 FAIL: banner not found"; exit 1; }
