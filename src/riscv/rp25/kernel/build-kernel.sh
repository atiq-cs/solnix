#!/usr/bin/env bash
#
# build-kernel.sh -- R-P25: grow the R-P24 booting illumos riscv64 kernel with
# the SYSCALL/EXEC path so a userland PROCESS runs.  Compiles the native
# EM_RISCV kernel (riscv64-unknown-solaris2.11 gcc + R-P17 binutils), embeds
# the static userland hello ELF, and boots under qemu-system-riscv64 -machine
# virt via OpenSBI, verifying each R-P25 sub-task from the boot log:
#   1 U-mode entry + trap-based write(2)/exit(2) syscall path
#   2 the R-P22 static hello RUNS as a userland process (its own write output)
#   3 a minimal exec (map the static ELF PT_LOAD segments into a fresh user AS)
# plus re-asserting the R-P24 subsystems (Sv39 paging, clock, PLIC, dispatcher).
set -e
export PATH=/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
K=/root/riscv-port/rp25/kernel
U=/root/riscv-port/rp25/user
GCC=/root/riscv-port/build/gcc-sol-cfg3/gcc
XGCC="$GCC/xgcc -B$GCC"
TB=/root/riscv-port/toolchain/bin
LD=$TB/riscv64-unknown-elf-ld
READELF=$TB/riscv64-unknown-elf-readelf
OBJDUMP=$TB/riscv64-unknown-elf-objdump
OBJCOPY=$TB/riscv64-unknown-elf-objcopy
QEMU=/usr/bin/qemu-system-riscv64
BIOS=/usr/share/qemu/opensbi-riscv64-generic-fw_dynamic.bin
CFLAGS="-march=rv64gc -mabi=lp64d -mcmodel=medany -ffreestanding \
	-fno-stack-protector -fno-pie -O2 -Wall -Wno-unused -I$K"
cd $K

echo "=== building the userland process (static EM_RISCV hello) ==="
bash $U/build-user.sh
# embed the whole static ELF; exec_user maps its PT_LOAD segments.
cp $U/hello_user $K/user_hello.bin

echo "=== compiling the native EM_RISCV kernel (R-P25) ==="
$XGCC $CFLAGS -c locore.S     -o locore.o
$XGCC $CFLAGS -c mach_trap.S  -o mach_trap.o
$XGCC $CFLAGS -c mach_clock.S -o mach_clock.o
$XGCC $CFLAGS -c mach_mmu.S   -o mach_mmu.o
$XGCC $CFLAGS -c mach_swtch.S -o mach_swtch.o
$XGCC $CFLAGS -c mach_uentry.S -o mach_uentry.o
$XGCC $CFLAGS -c user_elf.S   -o user_elf.o
$XGCC $CFLAGS -c sbi.c        -o sbi.o
$XGCC $CFLAGS -c hat_boot.c   -o hat_boot.o
$XGCC $CFLAGS -c hat_user.c   -o hat_user.o
$XGCC $CFLAGS -c exec_elf.c   -o exec_elf.o
$XGCC $CFLAGS -c clock_riscv.c -o clock_riscv.o
$XGCC $CFLAGS -c plic.c       -o plic.o
$XGCC $CFLAGS -c startup.c    -o startup.o
$XGCC $CFLAGS -c main.c       -o main.o

echo "=== linking the kernel ELF (EM_RISCV, entry _start @ 0x80200000) ==="
$LD -T kernel.lds -nostdlib -e _start \
	locore.o mach_trap.o mach_clock.o mach_mmu.o mach_swtch.o \
	mach_uentry.o user_elf.o \
	sbi.o hat_boot.o hat_user.o exec_elf.o clock_riscv.o plic.o \
	startup.o main.o \
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
# R-P24 regression: the four subsystems still reached.
grep -q "paging enabled (Sv39)" $K/qemu-boot.log \
	&& echo "R-P24.1 (regress) PASS: Sv39 paging enabled" \
	|| { echo "R-P24.1 FAIL"; FAIL=1; }
grep -q "clock tick 10" $K/qemu-boot.log \
	&& echo "R-P24.2 (regress) PASS: clock ticks counted" \
	|| { echo "R-P24.2 FAIL"; FAIL=1; }
grep -qE "claimed \+ completed" $K/qemu-boot.log \
	&& echo "R-P24.3 (regress) PASS: PLIC claim" \
	|| { echo "R-P24.3 FAIL"; FAIL=1; }
grep -q "on-ramp proven" $K/qemu-boot.log \
	&& echo "R-P24.4 (regress) PASS: dispatcher idle loop" \
	|| { echo "R-P24.4 FAIL"; FAIL=1; }
# R-P25 headline: the userland process ran and printed its OWN write(2) output.
grep -q "hello from riscv64-solaris userland process" $K/qemu-boot.log \
	&& echo "R-P25.2 PASS: static hello RUNS as a userland process (own write(2))" \
	|| { echo "R-P25.2 FAIL: userland process output not seen"; FAIL=1; }
grep -q "the userland process called exit" $K/qemu-boot.log \
	&& echo "R-P25.1 PASS: U-mode entry + write(2)/exit(2) syscall path" \
	|| { echo "R-P25.1 FAIL: exit(2) path not seen"; FAIL=1; }
grep -q "sret -> U-mode" $K/qemu-boot.log \
	&& echo "R-P25.3 PASS: minimal exec (PT_LOAD map + U-mode sret)" \
	|| { echo "R-P25.3 FAIL: exec path not seen"; FAIL=1; }
[ $FAIL -eq 0 ] && echo "=== R-P25 ALL PASS ===" || { echo "=== R-P25 FAIL ==="; exit 1; }
