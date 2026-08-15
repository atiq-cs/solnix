#!/usr/bin/env bash
#
# rp30-milestone-check.sh -- re-runnable proof of the R-P30 deliverables, all
# boot-verified under qemu-system-riscv64 -machine virt (-smp 2) via OpenSBI:
#
#   R-P30.1  HIGH-VA RELINK + DROP THE IDENTITY MAP (the headline, closes the
#            R-P29 gap).  The kernel is now LINKED + EXECUTES at high VA
#            (KERNEL_DMAP_BASE + 0x80200000) while LOADING at physical
#            0x80200000: a locore bootstrap runs position-independently at the
#            physical load address, builds the Sv39 tables (a low identity
#            window to survive the satp flip + the kernel HIGH map + the
#            direct-map), enables paging, and JUMPS PC to the high-VA
#            _start_high; hat_kernel_setup then installs the identity-FREE W^X
#            root and hat_drop_identity proves the primary runs PURELY high-VA
#            (a read of _start via the low identity VA FAULTS).  The ELF entry is
#            the HIGH VA; the LOAD segments carry VirtAddr=high, PhysAddr=low.
#   R-P30.2  TS/RT PRIORITY SCHEDULER ON BOTH HARTS.  A real scheduling-class
#            dispatcher: SC_RT globally above SC_TS (RT preempts TS), TS round-
#            robins within a band, tick-driven kpreempt, priority-inheritance-
#            lite (an RT waiter boosts the TS lock-holder), and BOTH harts
#            dispatch from the shared class runq.
#   R-P30.3  as_free + more lifecycle.  A process's address space is freed on
#            exec/exit (walk the private user half, unmap + free the user page
#            tables + frames); fork+exec+exit an AS N times and the page-frame
#            free count returns to baseline (no leak, vs the R-P26 leak).
#
# plus the R-P24 (paging/clock/PLIC/dispatcher), R-P26 (fork/exec/wait), R-P27
# (preemption/fs-exec/ld.so.1), R-P28 (cross-object linking/priority disp/SMP)
# and R-P29 (W^X HAT/kmem_cache/TLB shootdown/per-CPU disp/FP ctx switch)
# regressions.  Rebuilds the userland + ld.so.1 + initramfs + kernel and reboots
# (via build-kernel.sh, which contains every assertion), then re-asserts the
# R-P30 headline lines here.
set -e
K=/root/riscv-port/rp30/kernel
cd $K

# build-kernel.sh rebuilds everything, boots under qemu -smp 2, and asserts the
# R-P24/26/27/28/29 regressions + the R-P30 sub-tasks; it exits nonzero on any
# failure.
bash build-kernel.sh

LOG=$K/qemu-boot.log
fail() { echo "FAIL: $1"; exit 1; }

echo
echo "== R-P30 headline assertions =="
grep -q "identity map dropped; running purely high-VA" $LOG \
	|| fail "R-P30.1 identity map not dropped (kernel not purely high-VA)"
grep -q "read of _start via LOW identity VA 0x80200000: FAULTED" $LOG \
	|| fail "R-P30.1 low identity VA still readable (identity not gone)"
echo "R-P30.1 PASS: high-VA relink + identity map dropped (true high-half kernel)"

grep -q "TS/RT sched PROVEN" $LOG \
	|| fail "R-P30.2 TS/RT scheduler not proven"
grep -q "\[PI\] TS proc .* released the lock" $LOG \
	|| fail "R-P30.2 priority-inheritance-lite not observed"
echo "R-P30.2 PASS: TS/RT priority scheduler on both harts (RT>TS, TS round-robin, PI-lite)"

grep -q "as_free PROVEN" $LOG \
	|| fail "R-P30.3 as_free not proven (AS leaked)"
echo "R-P30.3 PASS: as_free -- fork+exec+exit N times, frames reclaimed (no leak)"

echo
echo "PASS: R-P30 (high-VA relink + DROP the identity map -> a true high-half"
echo "      kernel; TS/RT priority scheduler on both harts; as_free no-leak)"
echo "      -- all boot-verified, R-P24/26/27/28/29 regressions green"
