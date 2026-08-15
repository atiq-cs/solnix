#!/usr/bin/env bash
#
# rp28-milestone-check.sh -- re-runnable proof of the R-P28 deliverables, all
# boot-verified under qemu-system-riscv64 -machine virt (-smp 2) via OpenSBI:
#
#   R-P28.1  REAL CROSS-OBJECT DYNAMIC LINKING.  ld.so.1 maps the app's
#            DT_NEEDED object (libgcc_s.so.1) into the address space (SYS_mapso),
#            processes its dynamic section, and BINDS the app's cross-object
#            R_RISCV_JUMP_SLOT references (__multf3 / __fixtfsi) to the resolved
#            libgcc_s addresses; the dynamic hello CALLS __multf3 across the
#            object boundary and exits 42 (positive proof the bind worked).
#   R-P28.2  PRIORITY DISPATCH QUEUES + thread_create.  kthread_create builds
#            kernel threads at different dispatch priorities; the priority-aware
#            rv_sched runs them HIGH->LOW regardless of creation order.
#   R-P28.3  SMP SECONDARIES via SBI HSM.  The boot hart starts a secondary hart
#            with the SBI HSM hart_start ecall; both harts drain a shared,
#            lock-protected work runq -- work runs on TWO distinct hartids.
#
# plus the R-P24 (paging/clock/PLIC/dispatcher), R-P26 (fork/exec/wait), and
# R-P27 (preemption/fs-exec/ld.so.1) regressions.  Rebuilds the userland +
# ld.so.1 + initramfs + kernel and reboots (via build-kernel.sh, which contains
# every assertion), then re-asserts the R-P28 headline lines here.
set -e
K=/root/riscv-port/rp28/kernel
cd $K

# build-kernel.sh rebuilds everything, boots under qemu -smp 2, and asserts the
# R-P24/26/27 regressions + prints the R-P28 lines; it exits nonzero on any
# regression failure.
bash build-kernel.sh

LOG=$K/qemu-boot.log
fail() { echo "FAIL: $1"; exit 1; }

echo
echo "== R-P28 headline assertions =="
grep -q "cross-object bind PROVEN" $LOG \
	|| fail "R-P28.1 cross-object dynamic linking not proven"
grep -q "exit status=42" $LOG \
	|| fail "R-P28.1 cross-object hello did not exit 42"
grep -q "bound __multf3 ->" $LOG \
	|| fail "R-P28.1 ld.so.1 did not bind __multf3 cross-object"
echo "R-P28.1 PASS: ld.so.1 maps+binds DT_NEEDED (libgcc_s.so.1); cross-object __multf3 call works (exit 42)"

# priority order: HIGH must print before MID before LOW.
awk '/priority-dispatch proof output/{s=1}
     /end priority-dispatch proof/{s=0}
     s && /kthread\] HIGH/{h=NR}
     s && /kthread\] MID/{m=NR}
     s && /kthread\] LOW/{l=NR}
     END{ exit (h>0 && m>0 && l>0 && h<m && m<l)?0:1 }' $LOG \
	|| fail "R-P28.2 priority dispatch order (HIGH<MID<LOW) not observed"
echo "R-P28.2 PASS: priority disp queues + thread_create -- threads run HIGH->LOW"

grep -q "SMP PROVEN: work ran on BOTH harts" $LOG \
	|| fail "R-P28.3 SMP not proven"
grep -q "SECONDARY hart online: hartid=1" $LOG \
	|| fail "R-P28.3 secondary hart did not come online"
grep -q "\[hart 0\] ran work item" $LOG \
	|| fail "R-P28.3 boot hart ran no work"
grep -q "\[hart 1\] ran work item" $LOG \
	|| fail "R-P28.3 secondary hart ran no work"
echo "R-P28.3 PASS: SMP via SBI HSM -- secondary hart started + work ran on 2 distinct hartids"

echo
echo "PASS: R-P28 (ld.so.1 maps+binds DT_NEEDED / real cross-object dynamic"
echo "      linking, priority disp queues + thread_create, SMP secondaries via"
echo "      SBI HSM) -- all boot-verified, R-P24/26/27 regressions green"
