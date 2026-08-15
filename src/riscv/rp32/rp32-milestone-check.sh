#!/usr/bin/env bash
#
# rp32-milestone-check.sh -- re-runnable proof of the R-P32 deliverables, all
# boot-verified under qemu-system-riscv64 -machine virt -smp 2 via OpenSBI:
#
#   R-P32.1  PROCS ON BOTH HARTS (a headline).  R-P31 ran secondaries on the W^X
#            root draining a work-item runq; R-P32 runs the REAL proc_t
#            dispatcher (rv_sched_cpu) on BOTH harts against ONE shared,
#            spinlock-guarded proc runq (proc_tab), with per-hart curproc +
#            scheduler context (cpuid() carried in tp).  A first process forks N
#            children; the two harts drain the shared runq so a process forked on
#            hart 0 is dispatched on hart 1 (each child prints its hart), closing
#            the SMP save/load race with a per-proc p_onproc "still-switching"
#            flag + a serialized console.  Proof: procs-on-both-harts PROVEN,
#            children "running on hart 1".
#   R-P32.2  COW FORK + DEMAND PAGING (the headline).  fork now SHARES the
#            parent's user pages read-only + PTE_COW (a software RSW bit) instead
#            of the R-P26 eager copy; a store to a shared page FAULTS (scause 15)
#            into the page-fault handler (rv_trap -> proc_pagefault -> hat_cow_
#            fault), which copies the frame into a private writable one -- the
#            child's write does NOT corrupt the parent.  A demand-paged (PTE_LAZY,
#            V clear) page is reserved without backing and faulted in (a fresh
#            zeroed frame) on first touch (hat_demand_fault).  A per-frame
#            refcount (page_ref_*) frees a shared frame only when the last AS lets
#            go.  Proof: [COW] + [demand] fault-handler lines, COW isolation, +
#            COW + demand paging PROVEN.
#   R-P32.3  vfs write(2) + a real vnode layer.  A vnode op vector
#            (VOP_READ/WRITE/LOOKUP/GETATTR) over two fs types: the read-only
#            ramfs (initramfs blob) and a WRITABLE tmpfs (a kmem buffer grown on
#            write).  A process creates + write(2)s /tmp/hello.txt, reads it back
#            (round-trip MATCH), fstat's it, and a write to the read-only ramfs
#            returns EROFS.  Proof: vfs write(2) PROVEN.
#
# plus the R-P24 (paging/clock/PLIC/dispatcher), R-P26 (fork/exec/wait), R-P27
# (preemption/fs-exec/ld.so.1), R-P28 (cross-object linking/priority disp/SMP),
# R-P29 (W^X HAT/kmem_cache/TLB shootdown/per-CPU disp/FP ctx switch), R-P30
# (high-VA relink+identity drop/TS-RT sched/as_free) and R-P31 (secondaries on
# the W^X root/ld.so.1 hardening/ramfs read(2)) regressions.  Rebuilds the
# userland + ld.so.1 + initramfs + kernel and reboots (via build-kernel.sh,
# which contains every assertion), then re-asserts the R-P32 headline lines.
set -e
K=/root/riscv-port/rp32/kernel
cd $K

# build-kernel.sh rebuilds everything, boots under qemu -smp 2, and asserts the
# R-P24/26/27/28/29/30/31 regressions + the R-P32 sub-tasks; it exits nonzero on
# any failure.
bash build-kernel.sh

LOG=$K/qemu-boot.log
fail() { echo "FAIL: $1"; exit 1; }

echo
echo "== R-P32 headline assertions =="
grep -q "procs-on-both-harts PROVEN" $LOG \
	|| fail "R-P32.1 real proc_t dispatcher not proven on both harts"
grep -q "running on hart 1" $LOG \
	|| fail "R-P32.1 no forked proc was dispatched on the secondary hart"
echo "R-P32.1 PASS: real proc_t processes dispatched on BOTH harts (fork on one, run on either)"

grep -q "COW + demand paging PROVEN" $LOG \
	|| fail "R-P32.2 COW fork + demand paging not proven"
grep -q "\[COW\] store fault -> copied page" $LOG \
	|| fail "R-P32.2 the COW fault handler did not copy a page on a store fault"
grep -q "\[demand\] fault -> mapped zeroed page" $LOG \
	|| fail "R-P32.2 the demand-paging fault handler did not fault in a page"
grep -q "UNCHANGED (COW isolated the child's write)" $LOG \
	|| fail "R-P32.2 COW did not isolate the child's write from the parent"
echo "R-P32.2 PASS: COW fork + demand paging (fault handler copies COW pages + fills lazy pages)"

grep -q "vfs write(2) PROVEN" $LOG \
	|| fail "R-P32.3 vfs write(2) not proven"
grep -q "tmpfs write/read round-trip: MATCH" $LOG \
	|| fail "R-P32.3 tmpfs write/read round-trip did not match"
grep -q "EROFS -- ramfs is read-only" $LOG \
	|| fail "R-P32.3 the read-only ramfs did not reject a write"
echo "R-P32.3 PASS: vfs write(2) via the VOP_READ/WRITE/LOOKUP/GETATTR vnode layer (tmpfs writable, ramfs read-only)"

echo
echo "PASS: R-P32 (the real proc_t dispatcher on BOTH harts via a shared runq;"
echo "      COW fork + demand paging with a page-fault handler that copies COW"
echo "      pages + fills lazy pages; vfs write(2) + a real VOP_* vnode layer"
echo "      over a writable tmpfs) -- all boot-verified, R-P24/26/27/28/29/30/31"
echo "      regressions green"
