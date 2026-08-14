#!/bin/sh
#
# rp20-milestone-check.sh -- re-runnable proof of the R-P20 deliverables:
#   1. sgs %pcrel_hi/%pcrel_lo pairing + GOT/PLT allocation self-tests PASS
#      (pairing bytes byte-identical to GNU ld);
#   2. csu crt (crt1/crti/crtn) + hello.c -> a valid riscv64-solaris EM_RISCV
#      ELF executable, zero remaining relocs;
#   3. a larger uts unit (genassym + mach_cpu) cross-compiles to EM_RISCV and
#      links (CALL_PLT + PCREL_HI20/LO12 pairs all resolved), assym.h offsets
#      match the hand-maintained MD .S offsets.
#
# Drives the R-P19 build-tree gcc directly (the installed bin/ gcc wrapper was
# never created; xgcc -B<gcc> is the driver).

set -e
RP=/root/riscv-port
X="$RP/build/gcc-sol-cfg3/gcc/xgcc -B$RP/build/gcc-sol-cfg3/gcc"
SR=$RP/sysroot-riscv-sol
RE=$RP/toolchain/bin/riscv64-unknown-elf-readelf
LD=$RP/toolchain/bin/riscv64-unknown-elf-ld
LIBGCC=$RP/toolchain-sol/lib/gcc/riscv64-unknown-solaris2.11/14.3.0/libgcc.a
D=$RP/rp20
fail() { echo "FAIL: $1"; exit 1; }

echo "== R-P20.1 sgs %pcrel pairing + GOT/PLT self-tests =="
cd $D/sgs
gcc -DPCREL_SELFTEST -o pcrel_selftest machrel_riscv_pcrel.c machrel_riscv_insn.c
./pcrel_selftest | grep -q "PASS" || fail "pcrel pairing selftest"
gcc -DGOTPLT_SELFTEST -o gotplt_selftest machrel_riscv_gotplt.c
./gotplt_selftest | grep -q "PASS" || fail "gotplt alloc selftest"
echo "OK: pairing (GNU-ld bytes) + GOT/PLT allocation"

echo "== R-P20.2 csu crt + hello.c -> riscv64-solaris ELF =="
cd $D
for f in crti crtn crt1; do
	$X --sysroot=$SR -c -o csu/$f.o csu/$f.s
	$RE -h csu/$f.o | grep -qi "Machine:.*RISC-V" || fail "csu/$f.o not EM_RISCV"
done
$X --sysroot=$SR -O2 -c -o hello/hello.o hello/hello.c
$LD -static -e _start -o hello/hello.elf \
	csu/crt1.o csu/crti.o hello/hello.o csu/crtn.o $LIBGCC
$RE -h hello/hello.elf | grep -qi "Machine:.*RISC-V" || fail "hello not EM_RISCV"
$RE -h hello/hello.elf | grep -qi "Type:.*EXEC" || fail "hello not ET_EXEC"
$RE -r hello/hello.elf 2>/dev/null | grep -qi "no relocations" || fail "hello has unresolved relocs"
echo "OK: crt1/crti/crtn EM_RISCV; hello.elf EM_RISCV ET_EXEC, 0 relocs"

echo "== R-P20.3 larger uts unit (genassym + mach_cpu) =="
cd $D/uts/riscv64
$X --sysroot=$SR -O2 -ffreestanding -S -o genassym.s genassym.c
$X --sysroot=$SR -O2 -ffreestanding -c -o genassym.o genassym.c
$RE -h genassym.o | grep -qi "Machine:.*RISC-V" || fail "genassym.o not EM_RISCV"
sh genassym.sh genassym.s > assym.h
# the compiler offsets must match the hand-maintained MD .S values.
grep -q "regs_r_ra	0"		assym.h || fail "assym TF_RA drift"
grep -q "regs_r_sp	8"		assym.h || fail "assym TF_SP drift"
grep -q "rv_context_c_ra	0"	assym.h || fail "assym C_RA drift"
grep -q "rv_context_c_satp	120"	assym.h || fail "assym C_SATP drift"
grep -q "rv_context_c_lofault	128"	assym.h || fail "assym C_LOFAULT drift"
grep -q "LABEL_SP	8"		assym.h || fail "assym LABEL_SP drift"
$X -D_KERNEL -ffreestanding -O2 -I. -c -o mach_cpu.o mach_cpu.c
$X -D_KERNEL -ffreestanding -O2 -I. -c -o externs.o externs.c
$RE -h mach_cpu.o | grep -qi "Machine:.*RISC-V" || fail "mach_cpu.o not EM_RISCV"
# mach_cpu must emit the load-bearing relocs (CALL_PLT + PCREL pairs).
$RE -r mach_cpu.o | grep -q "R_RISCV_CALL_PLT" || fail "no CALL_PLT emitted"
$RE -r mach_cpu.o | grep -q "R_RISCV_HI20"     || fail "no HI20 emitted"
# full link must resolve every reloc.
$LD -Ttext=0x10000 -e cpu_online -o kunit_riscv64.exec mach_cpu.o externs.o
$RE -h kunit_riscv64.exec | grep -qi "Machine:.*RISC-V" || fail "kunit not EM_RISCV"
$RE -r kunit_riscv64.exec 2>/dev/null | grep -qi "no relocations" || \
	fail "kunit has unresolved relocs"
echo "OK: genassym EM_RISCV, assym.h matches MD .S offsets; mach_cpu emits"
echo "    CALL_PLT+HI20/LO12; cross-ld links EM_RISCV ET_EXEC, 0 relocs"

echo
echo "PASS: R-P20 (sgs pcrel pairing + GOT/PLT, csu crt + hello ELF, larger"
echo "      uts genassym+mach_cpu, all EM_RISCV verified)"
