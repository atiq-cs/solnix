#!/usr/bin/env bash
#
# rp31-milestone-check.sh -- re-runnable proof of the R-P31 deliverables, all
# boot-verified under qemu-system-riscv64 -machine virt -smp 2 via OpenSBI:
#
#   R-P31.1  SECONDARIES ON THE W^X ROOT (the headline; drops the boot identity
#            trampoline entirely).  R-P30 dropped the identity map on the PRIMARY
#            but a secondary hart still ran the shared kernel mappings from the
#            identity-bearing BOOT root.  R-P31 brings up the secondary so it
#            enables paging (via the transient boot-root trampoline, needed only
#            for the initial satp flip from its physical PC) then SWITCHES onto
#            the primary's identity-FREE W^X kernel root at high VA -- so both
#            harts run purely high-VA with NO identity map, and the boot-root
#            identity window is scrubbed entirely.  Proof: the secondary's
#            running satp == the primary's W^X root satp; a read of _start via
#            the low identity VA FAULTS on the secondary; SMP work still splits
#            across two hartids; the boot-root identity window is scrubbed.
#   R-P31.2  ld.so.1 HARDENING.  Lazy PLT binding (the PLT0 stub -> the
#            _rtld_bind trampoline -> resolve on first call: the first
#            cross-object __multf3 call fires the bind trampoline + patches the
#            GOT, the second call goes straight through), .gnu.hash lookup,
#            GNU symbol versioning (matching __multf3@GCC_3.0), and mprotecting
#            the PT_GNU_RELRO segment read-only after relocation.
#   R-P31.3  REAL ramfs read(2) path + more syscalls.  A userland process opens
#            a ramfs file, reads its bytes through the kernel's real read(2)
#            path (open -> per-proc fd -> ramfs vnode -> copy bytes), and prints
#            them; plus lseek/fstat/stat/getcwd + uname(2) returning
#            SunOS/solnix-riscv64.
#
# plus the R-P24 (paging/clock/PLIC/dispatcher), R-P26 (fork/exec/wait), R-P27
# (preemption/fs-exec/ld.so.1), R-P28 (cross-object linking/priority disp/SMP),
# R-P29 (W^X HAT/kmem_cache/TLB shootdown/per-CPU disp/FP ctx switch) and R-P30
# (high-VA relink+identity drop/TS-RT sched/as_free) regressions.  Rebuilds the
# userland + ld.so.1 + initramfs + kernel and reboots (via build-kernel.sh,
# which contains every assertion), then re-asserts the R-P31 headline lines.
set -e
K=/root/riscv-port/rp31/kernel
cd $K

# build-kernel.sh rebuilds everything, boots under qemu -smp 2, and asserts the
# R-P24/26/27/28/29/30 regressions + the R-P31 sub-tasks; it exits nonzero on
# any failure.
bash build-kernel.sh

LOG=$K/qemu-boot.log
fail() { echo "FAIL: $1"; exit 1; }

echo
echo "== R-P31 headline assertions =="
grep -q "SECONDARY-ON-W\^X-ROOT PROVEN" $LOG \
	|| fail "R-P31.1 secondary not on the identity-FREE W^X root"
grep -q "boot-root identity window scrubbed" $LOG \
	|| fail "R-P31.1 boot-root identity trampoline not scrubbed (identity survives)"
echo "R-P31.1 PASS: secondaries on the W^X root -- no identity map anywhere (true SMP high-half)"

grep -q "ld.so.1 hardening PROVEN" $LOG \
	|| fail "R-P31.2 ld.so.1 hardening not proven"
grep -q "LAZY bind on first call: __multf3@GCC_3.0" $LOG \
	|| fail "R-P31.2 lazy PLT bind trampoline did not fire"
grep -q "RELRO: mprotect .* read-only" $LOG \
	|| fail "R-P31.2 relro not mprotected read-only"
echo "R-P31.2 PASS: ld.so.1 hardened -- lazy PLT + .gnu.hash + versioning + relro"

grep -q "ramfs read PROVEN" $LOG \
	|| fail "R-P31.3 ramfs read(2) not proven"
grep -q "uname sysname='SunOS' nodename='solnix-riscv64'" $LOG \
	|| fail "R-P31.3 uname did not return SunOS/solnix-riscv64"
echo "R-P31.3 PASS: ramfs read(2) path + more syscalls (uname = SunOS/solnix-riscv64)"

echo
echo "PASS: R-P31 (secondaries on the W^X root -> no identity map ANYWHERE, a"
echo "      true-SMP high-half kernel; ld.so.1 lazy PLT + .gnu.hash + symbol"
echo "      versioning + relro; a real ramfs read(2) path + stat/lseek/getcwd/"
echo "      uname) -- all boot-verified, R-P24/26/27/28/29/30 regressions green"
