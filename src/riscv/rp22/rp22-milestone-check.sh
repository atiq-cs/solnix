#!/usr/bin/env bash
#
# rp22-milestone-check.sh -- re-runnable proof of the R-P22 deliverables:
#   1. sgs ld_targ_riscv NATIVE SELECTION: ld_config_target(EM_RISCV) selects
#      the machrel.riscv.c backend + drives a real reloc through it (retires
#      the GNU-ld crutch at the backend-dispatch level).
#   2. riscv64-solaris hello RUNS: a freestanding EM_RISCV payload executes on
#      qemu-system-riscv64 -machine virt via OpenSBI and prints -- the first
#      EXECUTING riscv64-solaris code.  Plus a STATIC illumos-ABI hello
#      (write(2)/exit(2)) linked with crt + the minimal libc.
#   3. LARGER unix.o partial-link: 6 genassym-driven MD units (locore, swtch,
#      cpu, trap-dispatch, clock, mmu) -> one EM_RISCV unix_riscv64.o, full
#      link resolves every reloc.
set -e
export PATH=/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
RP=/root/riscv-port/rp22
GCC=/root/riscv-port/build/gcc-sol-cfg3/gcc
XGCC="$GCC/xgcc -B$GCC"
TB=/root/riscv-port/toolchain/bin
LD=$TB/riscv64-unknown-elf-ld
AS=$TB/riscv64-unknown-elf-as
AR=$TB/riscv64-unknown-elf-ar
READELF=$TB/riscv64-unknown-elf-readelf
OBJDUMP=$TB/riscv64-unknown-elf-objdump
QEMU=/usr/bin/qemu-system-riscv64
BIOS=/usr/share/qemu/opensbi-riscv64-generic-fw_dynamic.bin
fail() { echo "FAIL: $1"; exit 1; }

echo "=== R-P22.1: sgs ld_targ_riscv native selection ==="
cd $RP/sgs
gcc -Wall -Wno-unused -Wno-comment -c machrel.riscv.c -o machrel.riscv.o
gcc -Wall -Wno-unused -Wno-comment -c machrel_riscv_insn.c -o machrel_riscv_insn.o
gcc -Wall -Wno-unused -Wno-comment -c target.c -o target.o
gcc -Wall -Wno-unused -Wno-comment -c target_selftest.c -o target_selftest.o
gcc machrel.riscv.o machrel_riscv_insn.o target.o target_selftest.o -o target_selftest
./target_selftest | grep -q "R-P22.1 sgs target selection PASS" \
	|| fail "sgs target selection self-test"
echo "  OK: ld_config_target(EM_RISCV) -> ld_targ_riscv; reloc via ld_targ.t_mr"

echo "=== R-P22.2a: bare-metal riscv64-solaris hello RUNS on qemu-virt ==="
cd $RP/run
$XGCC -march=rv64gc -mabi=lp64d -mcmodel=medany -ffreestanding -fno-stack-protector \
	-nostdlib -c boot.S -o boot.o
$XGCC -march=rv64gc -mabi=lp64d -mcmodel=medany -ffreestanding -fno-stack-protector \
	-O2 -nostdlib -c kmain.c -o kmain.o
$LD -T virt.lds -nostdlib boot.o kmain.o -o hello.elf 2>/dev/null
[ "$($READELF -h hello.elf | awk -F: '/Machine/{print $2}' | tr -d ' ')" = "RISC-V" ] \
	|| fail "hello.elf not EM_RISCV"
timeout 25 $QEMU -machine virt -nographic -bios $BIOS -kernel hello.elf > /tmp/rp22_run.log 2>&1 || true
grep -q "hello from riscv64-solaris (R-P22)" /tmp/rp22_run.log \
	|| fail "hello did not print under qemu"
grep -q "first executing riscv64-solaris code" /tmp/rp22_run.log \
	|| fail "hello second line missing"
echo "  OK: EXECUTED under qemu-system-riscv64 -machine virt. Output:"
grep -E "hello from|executing riscv64" /tmp/rp22_run.log | sed 's/^/    /'

echo "=== R-P22.2b: STATIC illumos-ABI hello (crt + minimal libc) links ==="
cd $RP
$AS -march=rv64gc libc/libc_syscall.s -o libc/libc_syscall.o
$AR rcs libc/libc.a libc/libc_syscall.o
cp /root/riscv-port/rp20/csu/crt1.o /root/riscv-port/rp20/csu/crti.o \
	/root/riscv-port/rp20/csu/crtn.o hello/
$XGCC -march=rv64gc -mabi=lp64d -mcmodel=medany -ffreestanding -fno-stack-protector \
	-O2 -c hello/hello_static.c -o hello/hello_static.o
$LD -static -e _start hello/crt1.o hello/crti.o hello/hello_static.o hello/crtn.o \
	libc/libc.a -o hello/hello_static 2>/dev/null
[ "$($READELF -h hello/hello_static | awk -F: '/Machine/{print $2}' | tr -d ' ')" = "RISC-V" ] \
	|| fail "hello_static not EM_RISCV"
$READELF -d hello/hello_static 2>&1 | grep -q "no dynamic section" \
	|| fail "hello_static is not static"
$OBJDUMP -d hello/hello_static | grep -A1 "<write>:" | grep -q "li.*a7,4" \
	|| fail "write does not use illumos SYS_write=4"
echo "  OK: static EM_RISCV exe, no dynamic section, write=li a7,4; ecall (illumos ABI)"

echo "=== R-P22.3: larger genassym-driven MD partial-link ==="
cd $RP/uts
for u in mach_trap mach_clock mach_mmu; do
	$XGCC -march=rv64gc -mabi=lp64d -mcmodel=medany -ffreestanding -I. -c $u.S -o $u.o
done
cp /root/riscv-port/rp21/uts/riscv64/mach_locore.o \
	/root/riscv-port/rp21/uts/riscv64/mach_swtch.o \
	/root/riscv-port/rp21/uts/riscv64/mach_cpu.o .
$LD -r mach_locore.o mach_swtch.o mach_cpu.o mach_trap.o mach_clock.o mach_mmu.o \
	-o unix_riscv64.o
[ "$($READELF -h unix_riscv64.o | awk -F: '/Machine/{print $2}' | tr -d ' ')" = "RISC-V" ] \
	|| fail "unix_riscv64.o not EM_RISCV"
NR=$($READELF -r unix_riscv64.o | grep -c "R_RISCV_CALL_PLT")
[ "$NR" -ge 6 ] || fail "expected >=6 CALL_PLT relocs, got $NR"
$XGCC -march=rv64gc -mabi=lp64d -mcmodel=medany -ffreestanding -O2 \
	-c mach_externs22.c -o mach_externs22.o
$LD -Ttext=0x10000 -e rv_trap_dispatch unix_riscv64.o mach_externs22.o \
	-o unix_riscv64.exec 2>/dev/null
$READELF -r unix_riscv64.exec 2>&1 | grep -q "no relocations" \
	|| fail "residual relocs after full link"
$OBJDUMP -d unix_riscv64.exec | grep -qE "jal.*<rv_interrupt>" \
	|| fail "rv_interrupt dispatch not resolved"
echo "  OK: 6-unit EM_RISCV unix_riscv64.o; full link resolves every reloc"

echo
echo "R-P22 ALL PASS:"
echo "  1. sgs ld_targ_riscv native selection (retires GNU-ld crutch at dispatch)"
echo "  2. riscv64-solaris hello RUNS under qemu-system-riscv64 (FIRST executing"
echo "     riscv64-solaris code) + static illumos-ABI hello links"
echo "  3. larger genassym-driven MD partial-link -> EM_RISCV unix_riscv64.o"
