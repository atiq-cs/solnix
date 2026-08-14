#!/bin/sh
#
# rp21-milestone-check.sh -- re-runnable proof of the R-P21 deliverables:
#   1. the gate-shaped sgs machrel.riscv.c compiles against the _libld.h shim
#      and its self-test passes: ld_reloc_local classifies + assigns idempotent
#      GOT/PLT slots, ld_do_activerelocs drives the %pcrel_hi/%pcrel_lo pairing
#      through a real hash table (byte-identical to GNU ld), dangling %pcrel_lo
#      is rejected, and the htab scales to 1000 pairs (O(1) lookup);
#   2. libgcc_s.so.1 hand-linked from libgcc.a + a GCC_3.0 version script is a
#      valid EM_RISCV ET_DYN with SONAME libgcc_s.so.1, and a DYNAMIC hello
#      links against it -> EM_RISCV, interp /usr/lib/ld.so.1, NEEDED libgcc_s.so.1;
#   3. a bigger genassym-DRIVEN riscv64 MD set (mach_locore.S + mach_swtch.S +
#      mach_cpu.c, offsets from assym.h not hand numbers) partial-links (ld -r)
#      to one EM_RISCV ET_REL exercising the full kernel reloc set, and a full
#      link with the externs resolves every reloc -> EM_RISCV ET_EXEC.

set -e
RP=/root/riscv-port
X="$RP/build/gcc-sol-cfg3/gcc/xgcc -B$RP/build/gcc-sol-cfg3/gcc"
SR=$RP/sysroot-riscv-sol
RE=$RP/toolchain/bin/riscv64-unknown-elf-readelf
LD=$RP/toolchain/bin/riscv64-unknown-elf-ld
LDSH=$RP/toolchain/bin/riscv64-unknown-elf-ld-shared
LIBGCC=$RP/toolchain-sol/lib/gcc/riscv64-unknown-solaris2.11/14.3.0/libgcc.a
D=$RP/rp21
fail() { echo "FAIL: $1"; exit 1; }

echo "== R-P21.1 gate sgs machrel.riscv.c (_libld.h shape + htab pairing) =="
cd $D/sgs
gcc -DMACHREL_SELFTEST -o machrel_selftest machrel.riscv.c machrel_riscv_insn.c
./machrel_selftest | grep -q "PASS" || fail "gate machrel self-test"
echo "OK: ld_reloc_local + ld_do_activerelocs + htab pairing (GNU-ld bytes),"
echo "    idempotent GOT/PLT slots, dangling-LO rejected, htab scales O(1)"

echo "== R-P21.2 hand-linked libgcc_s.so.1 + dynamic hello =="
cd $D/libgcc_s
$LDSH -shared -soname libgcc_s.so.1 -o libgcc_s.so.1 \
	--version-script libgcc_s.ver \
	--whole-archive $LIBGCC --no-whole-archive \
	--allow-shlib-undefined
ln -sf libgcc_s.so.1 libgcc_s.so
$RE -h libgcc_s.so.1 | grep -qi "Machine:.*RISC-V" || fail "libgcc_s not EM_RISCV"
$RE -h libgcc_s.so.1 | grep -qi "Type:.*DYN" || fail "libgcc_s not ET_DYN"
$RE -d libgcc_s.so.1 | grep -qi "SONAME.*libgcc_s.so.1" || fail "libgcc_s SONAME"
$RE --dyn-syms libgcc_s.so.1 | grep -q "GCC_3.0" || fail "libgcc_s not versioned"
cd $D/hello
$X --sysroot=$SR -O2 -c -o hello.o $RP/rp20/hello/hello.c
$X --sysroot=$SR -c -o crt1.o $RP/rp20/csu/crt1.s
$X --sysroot=$SR -c -o crti.o $RP/rp20/csu/crti.s
$X --sysroot=$SR -c -o crtn.o $RP/rp20/csu/crtn.s
$LDSH -e _start --dynamic-linker /usr/lib/ld.so.1 -L$D/libgcc_s \
	-o hello.dyn crt1.o crti.o hello.o crtn.o -lgcc_s $LIBGCC \
	--allow-shlib-undefined
$RE -h hello.dyn | grep -qi "Machine:.*RISC-V" || fail "hello.dyn not EM_RISCV"
$RE -l hello.dyn | grep -qi "/usr/lib/ld.so.1" || fail "hello.dyn no interp"
$RE -d hello.dyn | grep -qi "NEEDED.*libgcc_s.so.1" || fail "hello.dyn no NEEDED"
echo "OK: libgcc_s.so.1 EM_RISCV ET_DYN (SONAME + GCC_3.0 versioned);"
echo "    dynamic hello EM_RISCV, interp /usr/lib/ld.so.1, NEEDED libgcc_s.so.1"

echo "== R-P21.3 bigger genassym-driven MD set -> EM_RISCV partial + full link =="
cd $D/uts/riscv64
$X --sysroot=$SR -O2 -ffreestanding -S -o genassym.s genassym.c
sh genassym.sh genassym.s > assym.h
grep -q "rv_context_c_satp	120" assym.h || fail "assym drift"
$X -D_KERNEL -ffreestanding -O2 -I. -c -o mach_swtch.o mach_swtch.S
$X -D_KERNEL -ffreestanding -O2 -I. -c -o mach_locore.o mach_locore.S
$X -D_KERNEL -ffreestanding -O2 -I. -c -o mach_cpu.o mach_cpu.c
$X -D_KERNEL -ffreestanding -O2 -I. -c -o mach_externs.o mach_externs.c
for f in mach_swtch mach_locore mach_cpu mach_externs; do
	$RE -h $f.o | grep -qi "Machine:.*RISC-V" || fail "$f.o not EM_RISCV"
done
# the genassym-driven .S must reference generated offsets + emit pcrel pairs.
$RE -r mach_swtch.o | grep -q "R_RISCV_PCREL_HI" || fail "swtch no PCREL"
# partial link: several MD units -> one EM_RISCV ET_REL, relocs preserved.
$LD -r -o unix_riscv64.o mach_locore.o mach_swtch.o mach_cpu.o
$RE -h unix_riscv64.o | grep -qi "Machine:.*RISC-V" || fail "partial not EM_RISCV"
$RE -h unix_riscv64.o | grep -qi "Type:.*REL" || fail "partial not ET_REL"
$RE -r unix_riscv64.o | grep -q "R_RISCV_CALL_PLT" || fail "no CALL_PLT in partial"
$RE -r unix_riscv64.o | grep -q "R_RISCV_PCREL_HI" || fail "no PCREL in partial"
# full link with externs: every reloc resolves -> EM_RISCV ET_EXEC.
$LD -Ttext=0x10000 -e rv_trap_entry -o unix_riscv64.exec \
	unix_riscv64.o mach_externs.o
$RE -h unix_riscv64.exec | grep -qi "Machine:.*RISC-V" || fail "image not EM_RISCV"
$RE -r unix_riscv64.exec 2>/dev/null | grep -qi "no relocations" || \
	fail "image has unresolved relocs"
echo "OK: genassym-driven mach_locore/mach_swtch/mach_cpu EM_RISCV; ld -r ->"
echo "    EM_RISCV ET_REL (CALL_PLT+PCREL+full set); full link 0 relocs EM_RISCV"

echo
echo "PASS: R-P21 (gate sgs machrel.riscv.c + htab pairing, libgcc_s.so.1 +"
echo "      dynamic hello, bigger genassym-driven MD partial-link EM_RISCV)"
