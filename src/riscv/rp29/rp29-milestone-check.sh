#!/usr/bin/env bash
#
# rp29-milestone-check.sh -- re-runnable proof of the R-P29 deliverables, all
# boot-verified under qemu-system-riscv64 -machine virt (-smp 2) via OpenSBI:
#
#   R-P29.1  FULL HIGH-VA R^X HAT (the headline).  A real kernel HAT replaces
#            the R-P24 boot map: the kernel image is mapped PER SEGMENT at 4 KiB
#            leaf granularity with W^X permissions (.text R|X, .rodata R,
#            .data/.bss R|W -- no page both writable and executable); the kernel
#            executes through the HIGH direct-map alias (high-VA execution);
#            W^X is ENFORCED (a store to .text faults); a vmem arena + slab
#            kmem_cache (Bonwick vmem/kmem) sits over the boot heap and recycles
#            objects; and a TLB shootdown broadcasts a remote sfence.vma to the
#            secondary hart (SBI RFENCE).
#   R-P29.2  PER-CPU DISPATCH + kpreempt.  Each hart owns its own dispatch queue
#            (cpu_t.cpu_disp); both harts drain their LOCAL queue concurrently
#            and STEAL from a peer when empty (work-stealing balance) -- procs
#            balanced across 2 harts' per-CPU queues; a kpreempt() kernel
#            preemption point fires + yields.
#   R-P29.3  FP CONTEXT SWITCH + more syscalls.  rv_swtch now saves/restores the
#            FP register file (fcsr + f0..f31) per context, so two FP-using
#            procs that pin distinct values in the same FP register preempt each
#            other WITHOUT corrupting each other's FP state; getpid(2)/brk(2)
#            work + the reduced SunOS errno return ABI (mmap/open/read/close/
#            fstat added).
#
# plus the R-P24 (paging/clock/PLIC/dispatcher), R-P26 (fork/exec/wait), R-P27
# (preemption/fs-exec/ld.so.1) and R-P28 (cross-object linking/priority disp/
# SMP) regressions.  Rebuilds the userland + ld.so.1 + initramfs + kernel and
# reboots (via build-kernel.sh, which contains every assertion), then re-asserts
# the R-P29 headline lines here.
set -e
K=/root/riscv-port/rp29/kernel
cd $K

# build-kernel.sh rebuilds everything, boots under qemu -smp 2, and asserts the
# R-P24/26/27/28 regressions + the R-P29 sub-tasks; it exits nonzero on any
# failure.
bash build-kernel.sh

LOG=$K/qemu-boot.log
fail() { echo "FAIL: $1"; exit 1; }

echo
echo "== R-P29 headline assertions =="
grep -q "executed at high VA" $LOG \
	|| fail "R-P29.1 high-VA execution not proven"
grep -q "W^X enforced" $LOG \
	|| fail "R-P29.1 W^X not enforced (store to .text did not fault)"
grep -q "recycle OK)" $LOG \
	|| fail "R-P29.1 vmem/kmem_cache slab recycle not proven"
grep -q "TLB shootdown PROVEN" $LOG \
	|| fail "R-P29.1 cross-hart TLB shootdown not proven"
echo "R-P29.1 PASS: full high-VA R^X HAT -- W^X kernel, kmem_cache, TLB shootdown"

grep -q "percpu disp PROVEN" $LOG \
	|| fail "R-P29.2 per-CPU dispatch not proven"
grep -q "kpreempt PROVEN" $LOG \
	|| fail "R-P29.2 kpreempt not proven"
echo "R-P29.2 PASS: per-CPU disp queues (2 harts + steal) + kpreempt"

FPPRES=$(grep -c "FP state PRESERVED across preemption" $LOG)
[ "$FPPRES" -ge 2 ] && ! grep -q "FP state CORRUPTED" $LOG \
	|| fail "R-P29.3 FP context switch not proven ($FPPRES procs preserved)"
grep -q "parent getpid()=" $LOG || fail "R-P29.3 getpid not proven"
grep -q "brk grew heap to" $LOG || fail "R-P29.3 brk not proven"
echo "R-P29.3 PASS: FP context switch (2 FP procs) + getpid/brk + errno ABI"

echo
echo "PASS: R-P29 (full high-VA R^X HAT: W^X kernel + slab kmem_cache + TLB"
echo "      shootdown; per-CPU disp queues + kpreempt; FP context switch + more"
echo "      syscalls) -- all boot-verified, R-P24/26/27/28 regressions green"
