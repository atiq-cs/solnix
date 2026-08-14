#!/usr/bin/env bash
#
# rp23-milestone-check.sh -- re-runnable proof of the R-P23 deliverables:
#   1. BOOTING illumos-riscv64 kernel: the illumos-MD kernel skeleton
#      (locore -> mlsetup -> banner) built with the NATIVE
#      riscv64-unknown-solaris2.11 toolchain, booted under
#      qemu-system-riscv64 -machine virt via OpenSBI, prints a SunOS banner via
#      SBI + proves the trap path (deliberate breakpoint dispatched + resumed)
#      + reaches the known halt.  The FIRST booting illumos-riscv64 kernel.
#   2. REDUCED riscv64 ld.so.1: the core runtime relocation engine resolves
#      R_RISCV_RELATIVE + R_RISCV_JUMP_SLOT at runtime under qemu and calls
#      through the bound GOT slot.
#   3. REAL native ld: a minimal illumos `ld` driver (ldmin) links a real
#      EM_RISCV object THROUGH the sgs backend (ld_config_target selection +
#      machrel.riscv.c), relocated .text byte-identical to GNU ld (no GNU ld
#      in the reloc path).
set -e
export PATH=/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
RP=/root/riscv-port/rp23
fail() { echo "FAIL: $1"; exit 1; }

echo "=== R-P23.1: BOOTING illumos-riscv64 kernel (native toolchain) ==="
cd $RP/kernel
bash build-kernel.sh > /tmp/rp23_k.log 2>&1 || fail "kernel build/boot"
grep -q "first booting illumos-riscv64 kernel: locore -> mlsetup -> banner" $RP/kernel/qemu-boot.log \
	|| fail "kernel banner not printed under qemu"
grep -q "trap path self-test: PASS" $RP/kernel/qemu-boot.log \
	|| fail "trap path self-test did not pass"
echo "  OK: booted under qemu-system-riscv64 -machine virt. Banner:"
sed -n '/SunOS Release/,/reached the known halt/p' $RP/kernel/qemu-boot.log | sed 's/^/    /'

echo "=== R-P23.2: REDUCED riscv64 ld.so.1 runtime reloc engine ==="
cd $RP/ldso
bash build-ldso.sh > /tmp/rp23_l.log 2>&1 || fail "ld.so.1 build/run"
grep -q "REDUCED ld.so.1 reloc engine PASS" $RP/ldso/qemu-ldso.log \
	|| fail "ld.so.1 reloc engine did not pass"
echo "  OK: R_RISCV_JUMP_SLOT + R_RISCV_RELATIVE resolved at runtime under qemu"

echo "=== R-P23.3: REAL native ld (ldmin) links real EM_RISCV via sgs backend ==="
cd $RP/gate-ld
bash build-gate-ld.sh > /tmp/rp23_g.log 2>&1 || { cat /tmp/rp23_g.log; fail "gate-ld"; }
grep -q "R-P23.3 PASS" /tmp/rp23_g.log \
	|| fail "ldmin output not byte-identical to GNU ld"
echo "  OK: illumos sgs backend linked a real EM_RISCV object == GNU ld bytes"

echo
echo "R-P23 ALL PASS:"
echo "  1. BOOTING illumos-riscv64 kernel skeleton (native solaris toolchain):"
echo "     locore -> mlsetup -> SBI banner -> trap self-test PASS -> known halt"
echo "     (the FIRST booting illumos-riscv64 kernel)"
echo "  2. REDUCED riscv64 ld.so.1 reloc engine: RELATIVE + JUMP_SLOT at runtime"
echo "  3. REAL native ld (ldmin): links a real EM_RISCV object through the sgs"
echo "     backend, relocated .text byte-identical to GNU ld"
