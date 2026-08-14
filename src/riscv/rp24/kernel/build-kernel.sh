#!/usr/bin/env bash
#
# build-kernel.sh -- R-P24: grow the R-P23 booting illumos riscv64 kernel toward
# genunix.  Compiles the native EM_RISCV kernel (riscv64-unknown-solaris2.11
# gcc + R-P17 binutils) and boots it under qemu-system-riscv64 -machine virt via
# OpenSBI, verifying each R-P24 sub-task from the boot log:
#   1 Sv39 paging enabled + kernel keeps running virtual
#   2 periodic clock ticks counted through the trap path
#   3 a PLIC external interrupt claimed
#   4 kmem_alloc + page_t seed + a dispatcher swtch into the idle loop
set -e
export PATH=/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
K=/root/riscv-port/rp24/kernel
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

echo "=== compiling the native EM_RISCV kernel (R-P24) ==="
$XGCC $CFLAGS -c locore.S     -o locore.o
$XGCC $CFLAGS -c mach_trap.S  -o mach_trap.o
$XGCC $CFLAGS -c mach_clock.S -o mach_clock.o
$XGCC $CFLAGS -c mach_mmu.S   -o mach_mmu.o
$XGCC $CFLAGS -c mach_swtch.S -o mach_swtch.o
$XGCC $CFLAGS -c sbi.c        -o sbi.o
$XGCC $CFLAGS -c hat_boot.c   -o hat_boot.o
$XGCC $CFLAGS -c clock_riscv.c -o clock_riscv.o
$XGCC $CFLAGS -c plic.c       -o plic.o
$XGCC $CFLAGS -c startup.c    -o startup.o
$XGCC $CFLAGS -c main.c       -o main.o

echo "=== linking the kernel ELF (EM_RISCV, entry _start @ 0x80200000) ==="
$LD -T kernel.lds -nostdlib -e _start \
	locore.o mach_trap.o mach_clock.o mach_mmu.o mach_swtch.o \
	sbi.o hat_boot.o clock_riscv.o plic.o startup.o main.o \
	-o unix.elf 2>&1

MACH=$($READELF -h unix.elf | awk -F: '/Machine/{print $2}' | tr -d ' ')
ENTRY=$($READELF -h unix.elf | awk -F: '/Entry point/{print $2}' | tr -d ' ')
echo "  Machine=$MACH  Entry=$ENTRY"
[ "$MACH" = "RISC-V" ] || { echo "FAIL: not EM_RISCV"; exit 1; }
if $READELF -rW unix.elf 2>/dev/null | grep -qE "R_RISCV_(CALL|PCREL|JUMP|HI20|BRANCH)"; then
	echo "FAIL: unresolved relocs in the kernel image"; exit 1
fi
echo "  OK: zero residual relocs (self-contained kernel image)"

echo "=== booting the kernel under qemu-system-riscv64 -machine virt ==="
timeout 40 $QEMU -machine virt -smp 1 -m 256M -nographic \
	-bios $BIOS -kernel unix.elf > $K/qemu-boot.log 2>&1 || true
echo "--- qemu-boot.log ---"
cat $K/qemu-boot.log
echo "--- end log ---"

FAIL=0
grep -q "paging enabled (Sv39)" $K/qemu-boot.log \
	&& echo "R-P24.1 PASS: Sv39 paging enabled + kernel runs virtual" \
	|| { echo "R-P24.1 FAIL: paging not enabled"; FAIL=1; }
grep -q "clock tick 10" $K/qemu-boot.log \
	&& echo "R-P24.2 PASS: periodic clock ticks counted through the trap path" \
	|| { echo "R-P24.2 FAIL: clock ticks not counted"; FAIL=1; }
grep -qE "claimed \+ completed" $K/qemu-boot.log \
	&& echo "R-P24.3 PASS: PLIC external interrupt claimed + completed" \
	|| { echo "R-P24.3 FAIL: PLIC claim not seen"; FAIL=1; }
grep -q "on-ramp proven" $K/qemu-boot.log \
	&& echo "R-P24.4 PASS: kmem_alloc + page_t + dispatcher idle loop reached" \
	|| { echo "R-P24.4 FAIL: dispatcher on-ramp not reached"; FAIL=1; }
[ $FAIL -eq 0 ] && echo "=== R-P24 ALL PASS ===" || { echo "=== R-P24 FAIL ==="; exit 1; }
