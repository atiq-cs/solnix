#!/usr/bin/env bash
#
# rp33-milestone-check.sh -- re-runnable proof of the R-P33 deliverables, all
# boot-verified under qemu-system-riscv64 -machine virt -smp 2 via OpenSBI:
#
#   R-P33.1  SIGNALS + kill(2) (the headline).  A minimal signal framework:
#            sigaction/signal handler registration + a per-proc pending mask +
#            disposition table; kill(2) posts a signal to a proc; delivery on the
#            RETURN-TO-U edge builds a signal frame on the user stack, sret's to
#            the handler (a0=signo, ra=the sa_restorer), and sigreturn restores
#            the interrupted frame.  Default actions terminate (SIGKILL/SIGTERM);
#            an unresolved user fault raises SIGSEGV.  Proof: a child installs a
#            SIGUSR1 handler, the parent kill(2)s it, the handler RUNS + returns
#            via sigreturn (the child resumes); SIGKILL terminates an uncatchable
#            spinner (status 128+9=137).
#   R-P33.2  pipe(2) + directories.  pipe(2) is a kernel ring buffer with two
#            fds (read + write end), blocking read/write mediated by the R-P30
#            scheduler; fork inherits the fds.  Directory support in the vnode
#            layer: a VT_DIR tmpfs vnode + VOP_READDIR, mkdir + getdents.  Proof:
#            a parent writes + a fork-inherited child reads a pipe message; mkdir
#            + readdir list a tmpfs directory's entries.
#   R-P33.3  Per-CPU idle + wfi + file-backed demand-exec.  A hart with an empty
#            runq parks in wfi (low power, woken by the timer) instead of
#            spinning.  exec maps a PT_LOAD text segment FILE-BACKED + LAZY and
#            demand-pages it in from the ELF image on the first fetch fault
#            (exec_image_demand + exec_demand_fault over the R-P32 lazy leaves),
#            instead of the eager exec_image copy.  Proof: the hart idles in wfi
#            across N timer wakeups; an exec'd program's text is paged in on the
#            fetch fault + runs.
#
# plus the R-P24 (paging/clock/PLIC/dispatcher), R-P26 (fork/exec/wait), R-P27
# (preemption/fs-exec/ld.so.1), R-P28 (cross-object linking/priority disp/SMP),
# R-P29 (W^X HAT/kmem_cache/TLB shootdown/per-CPU disp/FP ctx switch), R-P30
# (high-VA relink+identity drop/TS-RT sched/as_free), R-P31 (secondaries on the
# W^X root/ld.so.1 hardening/ramfs read(2)) and R-P32 (procs on both harts/COW
# fork+demand paging/vfs write(2)) regressions.  Rebuilds the userland + ld.so.1
# + initramfs + kernel and reboots (via build-kernel.sh, which contains every
# assertion), then re-asserts the R-P33 headline lines.
set -e
K=/root/riscv-port/rp33/kernel
cd $K

# build-kernel.sh rebuilds everything, boots under qemu -smp 2, and asserts the
# R-P24..R-P32 regressions + the R-P33 sub-tasks; it exits nonzero on any failure.
bash build-kernel.sh

LOG=$K/qemu-boot.log
fail() { echo "FAIL: $1"; exit 1; }

echo
echo "== R-P33 headline assertions =="
grep -q "signals + kill PROVEN" $LOG \
	|| fail "R-P33.1 signals + kill not proven"
grep -q "SIGUSR1 handler RAN" $LOG \
	|| fail "R-P33.1 the installed SIGUSR1 handler did not run on delivery"
grep -q "resumed after the handler returned (sigreturn OK)" $LOG \
	|| fail "R-P33.1 the proc did not resume after the handler (sigreturn)"
grep -q "reaped SIGKILL child2 status=137" $LOG \
	|| fail "R-P33.1 SIGKILL did not terminate the uncatchable proc (137)"
echo "R-P33.1 PASS: signals + kill(2) -- handler runs on delivery + returns via sigreturn; SIGKILL terminates"

grep -q "pipe + dirs PROVEN" $LOG \
	|| fail "R-P33.2 pipe + directories not proven"
grep -q "hello from parent over the pipe" $LOG \
	|| fail "R-P33.2 the pipe IPC message was not delivered to the child"
grep -q "dir entries listed: 2 (mkdir+readdir OK)" $LOG \
	|| fail "R-P33.2 mkdir/readdir did not list the directory entries"
echo "R-P33.2 PASS: pipe(2) IPC across fork + mkdir/readdir over the vnode dir layer"

grep -q "idle+wfi PROVEN" $LOG \
	|| fail "R-P33.3 per-CPU idle + wfi not proven"
grep -q "file-backed demand-exec PROVEN" $LOG \
	|| fail "R-P33.3 file-backed demand-exec not proven"
grep -q "\[exec-demand\] fault -> paged text from file" $LOG \
	|| fail "R-P33.3 no file-backed text page-in observed on the fetch fault"
echo "R-P33.3 PASS: per-CPU idle + wfi + file-backed demand-exec (text demand-paged from the ELF file)"

echo
echo "PASS: R-P33 (a minimal signal framework -- sigaction/kill(2)/sigreturn with"
echo "      real delivery on return-to-U [a signal frame on the user stack, sret"
echo "      to the handler] + default actions [SIGKILL/SIGTERM terminate, SIGSEGV"
echo "      on an unresolved fault]; pipe(2) -- a kernel ring buffer with two fds"
echo "      + blocking read/write + fork-inherited fds -- plus directories"
echo "      [VOP_READDIR/mkdir/getdents over tmpfs]; per-CPU idle threads that"
echo "      wfi + file-backed demand-exec [exec demand-pages PT_LOAD text from the"
echo "      ELF on the fetch fault]) -- all boot-verified, R-P24..R-P32"
echo "      regressions green"
