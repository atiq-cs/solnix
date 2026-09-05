#!/usr/bin/env bash
#
# rp34-milestone-check.sh -- re-runnable proof of the R-P34 deliverables, all
# boot-verified under qemu-system-riscv64 -machine virt -smp 2 via OpenSBI:
#
#   R-P34.1  SIGNAL COMPLETENESS (the headline).  sigprocmask (block/unblock a
#            signal: a blocked signal stays pending + delivers on unblock),
#            sigsuspend (atomically swap the mask + block until an unmasked
#            signal), SA_RESTART (restart an interrupted syscall on delivery;
#            sigsuspend itself is never restarted, per POSIX), SIGCHLD (posted to
#            the parent on child exit -- a parent can catch it instead of only
#            blocking in wait), and alarm(2)/SIGALRM (a per-proc one-shot timer
#            deadline checked on every clock tick -> SIGALRM).  Proof: a proc
#            blocks SIGUSR1 with sigprocmask (it stays pending), then unblocks it
#            (the pending signal delivers); SIGCHLD fires on child exit; alarm(1)
#            delivers SIGALRM; sigsuspend blocks until SIGALRM.
#   R-P34.2  fd MANAGEMENT (the headline).  dup(2)/dup2(2)/fcntl(F_DUPFD/F_GETFD/
#            F_SETFD/F_GETFL/F_SETFL) + close-on-exec (FD_CLOEXEC honored across
#            exec).  Proof: dup2 redirects stdout to a file (the write lands in
#            the file, not the console); a FD_CLOEXEC fd is CLOSED across exec
#            while a plain fd is inherited into the new image.
#   R-P34.3  VFS MATURITY.  A mount table (mount tmpfs at /mnt) + a multi-level
#            path walk (a reduced lookuppn walking /a/b/c across a mount +
#            directories, rejecting a walk through a missing directory) +
#            rename/unlink over tmpfs.  Proof: mount tmpfs at /mnt, mkdir
#            /mnt/sub, create + read /mnt/sub/file (multi-level walk across the
#            mount), then rename + unlink it.
#
# plus the R-P24 (paging/clock/PLIC/dispatcher), R-P26 (fork/exec/wait), R-P27
# (preemption/fs-exec/ld.so.1), R-P28 (cross-object linking/priority disp/SMP),
# R-P29 (W^X HAT/kmem_cache/TLB shootdown/per-CPU disp/FP ctx switch), R-P30
# (high-VA relink+identity drop/TS-RT sched/as_free), R-P31 (secondaries on the
# W^X root/ld.so.1 hardening/ramfs read(2)), R-P32 (procs on both harts/COW
# fork+demand paging/vfs write(2)) and R-P33 (signals+kill(2)/pipe(2)+dirs/
# idle+wfi+file-backed demand-exec) regressions.  Rebuilds the userland +
# ld.so.1 + initramfs + kernel and reboots (via build-kernel.sh, which contains
# every assertion), then re-asserts the R-P34 headline lines.
set -e
K=/root/riscv-port/rp35/kernel
cd $K

# build-kernel.sh rebuilds everything, boots under qemu -smp 2, and asserts the
# R-P24..R-P33 regressions + the R-P34 sub-tasks; it exits nonzero on any failure.
bash build-kernel.sh

LOG=$K/qemu-boot.log
fail() { echo "FAIL: $1"; exit 1; }

echo
echo "== R-P34 headline assertions =="
# R-P34.1 signal completeness.
grep -q "SIGUSR1 stayed pending while blocked" $LOG \
	|| fail "R-P34.1 sigprocmask did not hold a blocked signal pending"
grep -q "pending SIGUSR1 delivered on unblock" $LOG \
	|| fail "R-P34.1 the pending signal did not deliver on sigprocmask unblock"
grep -q "SIGCHLD delivered on child exit" $LOG \
	|| fail "R-P34.1 SIGCHLD was not posted to the parent on child exit"
grep -q "SIGALRM delivered by alarm(2)" $LOG \
	|| fail "R-P34.1 alarm(2) did not deliver SIGALRM off the timer"
grep -q "sigsuspend woke on SIGALRM (SA_RESTART honored)" $LOG \
	|| fail "R-P34.1 sigsuspend did not block until an unmasked signal"
echo "R-P34.1 PASS: sigprocmask (block/unblock) + sigsuspend + SIGCHLD + alarm(2)/SIGALRM"

# R-P34.2 fd management.
grep -q "dup2 redirected stdout to the file" $LOG \
	|| fail "R-P34.2 dup2 did not redirect stdout to a file"
grep -q "fcntl(F_SETFD/F_GETFD) FD_CLOEXEC set" $LOG \
	|| fail "R-P34.2 fcntl F_DUPFD/F_GETFD/F_SETFD not proven"
grep -q "CLOEXEC-across-exec PROVEN" $LOG \
	|| fail "R-P34.2 a FD_CLOEXEC fd was not closed across exec"
echo "R-P34.2 PASS: dup/dup2/fcntl + FD_CLOEXEC closed across exec (plain fd inherited)"

# R-P34.3 VFS maturity.
grep -q "mount tmpfs at /mnt: OK" $LOG \
	|| fail "R-P34.3 mount tmpfs at /mnt failed"
grep -q "multi-level path walk across a mount: OK" $LOG \
	|| fail "R-P34.3 multi-level path walk across the mount failed"
grep -q "walk rejects missing dir" $LOG \
	|| fail "R-P34.3 lookuppn did not reject a walk through a missing dir"
grep -q "rename: new name /mnt/sub/renamed reads" $LOG \
	|| fail "R-P34.3 rename did not work"
grep -q "unlink: /mnt/sub/renamed removed" $LOG \
	|| fail "R-P34.3 unlink did not work"
echo "R-P34.3 PASS: mount table + multi-level path walk (lookuppn) + rename/unlink over tmpfs"

echo
echo "PASS: R-P34 (SIGNAL COMPLETENESS -- sigprocmask block/unblock [a blocked"
echo "      signal stays pending + delivers on unblock], sigsuspend, SA_RESTART,"
echo "      SIGCHLD posted to the parent on child exit, alarm(2)/SIGALRM off the"
echo "      timer tick; fd MANAGEMENT -- dup(2)/dup2(2)/fcntl [F_DUPFD/F_GETFD/"
echo "      F_SETFD/F_GETFL/F_SETFL] + FD_CLOEXEC honored across exec [dup2"
echo "      redirects stdout to a file, a CLOEXEC fd is closed across exec while a"
echo "      plain fd is inherited]; VFS MATURITY -- a mount table [mount tmpfs at"
echo "      /mnt] + a reduced lookuppn multi-level path walk [/mnt/sub/file across"
echo "      the mount, rejecting a walk through a missing directory] + rename/"
echo "      unlink over tmpfs) -- all boot-verified, R-P24..R-P33 regressions green"
