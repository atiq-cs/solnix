#!/usr/bin/env bash
#
# rp35-milestone-check.sh -- re-runnable proof of the R-P35 deliverables, all
# boot-verified under qemu-system-riscv64 -machine virt -smp 2 via OpenSBI:
#
#   R-P35.1  PER-CPU IDLE + IPI WAKEUP (the enabler).  Each hart runs the shared
#            dispatcher; when its runq has nothing RUNNABLE but a proc is blocked
#            (P_WAITING) or running on the peer, it PARKS in `wfi` (low power)
#            instead of busy-polling -- replacing the R-P34 wfi-poll in
#            proc_wait_signal with a real P_WAITING block + sched().  A runnable
#            transition (a child exit / signal / alarm) posts an SBI SOFTWARE
#            IPI (sbi_send_ipi_hart) that wakes the sleeping hart to re-dispatch.
#            Proof: a proc forks a child + blocks in wait(2); a hart parks in the
#            idle wfi; the child exit IPI-wakes the blocked parent (no busy poll).
#   R-P35.2  A REAL init PROCESS (pid 1) (a headline).  The kernel execs the
#            embedded /sbin/init as PID 1; init opens the ramfs script /etc/rc,
#            dup2's it onto the shell's stdin, fork+execs /bin/sh, and reaps
#            children in a wait(2) loop -- ADOPTING a re-parented orphan (a
#            grandchild whose parent exited early is re-parented to init by the
#            kernel and reaped by init).  Proof: init runs as pid 1, forks the
#            shell, adopts+reaps the orphan, then reaps the shell.
#   R-P35.3  A MINIMAL INTERACTIVE SHELL (/bin/sh) (a headline).  The shell reads
#            a scripted stdin (/etc/rc) line-by-line, parses argv, fork+exec+waits
#            each command (echo/cat/true exec'd from the ramfs WITH REAL ARGV --
#            argv now passes through exec(2)), and runs a PIPELINE (cmd1 | cmd2)
#            over the R-P33 pipe + R-P34 dup2.  Proof: the shell runs
#            "echo hello" -> hello, "cat /etc/release" -> the release contents,
#            and "echo hi | cat" -> hi (a pipe + dup2).
#
# plus the R-P24 (paging/clock/PLIC/dispatcher), R-P26 (fork/exec/wait), R-P27
# (preemption/fs-exec/ld.so.1), R-P28 (cross-object linking/priority disp/SMP),
# R-P29 (W^X HAT/kmem_cache/TLB shootdown/per-CPU disp/FP ctx switch), R-P30
# (high-VA relink+identity drop/TS-RT sched/as_free), R-P31 (secondaries on the
# W^X root/ld.so.1 hardening/ramfs read(2)), R-P32 (procs on both harts/COW
# fork+demand paging/vfs write(2)), R-P33 (signals+kill(2)/pipe(2)+dirs/
# idle+wfi+file-backed demand-exec) and R-P34 (sigprocmask/sigsuspend/SA_RESTART/
# SIGCHLD/alarm; dup/dup2/fcntl/FD_CLOEXEC; mount table+multi-level walk+rename/
# unlink) regressions.  Rebuilds the userland + ld.so.1 + initramfs + kernel and
# reboots (via build-kernel.sh, which contains every assertion), then re-asserts
# the R-P35 headline lines.
set -e
K=/root/riscv-port/rp35/kernel
cd $K

# build-kernel.sh rebuilds everything, boots under qemu -smp 2, and asserts the
# R-P24..R-P34 regressions + the R-P35 sub-tasks; it exits nonzero on any failure.
bash build-kernel.sh

LOG=$K/qemu-boot.log
fail() { echo "FAIL: $1"; exit 1; }

echo
echo "== R-P35 headline assertions =="
# R-P35.1 per-CPU idle + IPI wakeup.
grep -q "idle+IPI PROVEN" $LOG \
	|| fail "R-P35.1 idle+IPI wakeup not proven"
grep -q "an idle hart parks in wfi" $LOG \
	|| fail "R-P35.1 the idle-wfi path was not reached"
echo "R-P35.1 PASS: per-CPU idle wfi on an empty runq + SBI-IPI wake on a runnable transition"

# R-P35.2 init pid 1 + orphan adoption/reaping.
grep -q "\[init\] pid 1 running" $LOG \
	|| fail "R-P35.2 init did not run as pid 1"
grep -q "\[init\] forked shell pid" $LOG \
	|| fail "R-P35.2 init did not fork+exec the shell"
grep -q "grandchild (adopted by init) exiting" $LOG \
	|| fail "R-P35.2 the orphan grandchild did not run"
grep -q "\[init\] reaped pid 4 status 23" $LOG \
	|| fail "R-P35.2 init did not reap the adopted orphan"
grep -q "\[init\] reaped pid 3 status 0 (the shell)" $LOG \
	|| fail "R-P35.2 init did not reap the shell"
grep -q "init done" $LOG \
	|| fail "R-P35.2 init did not finish its reap loop"
echo "R-P35.2 PASS: init ran as pid 1, forked the shell, adopted+reaped an orphan, reaped the shell"

# R-P35.3 minimal shell runs commands + a pipe.
grep -q "solnix sh: reading commands from stdin" $LOG \
	|| fail "R-P35.3 the shell did not start"
awk '{sub(/\r$/,"")} /sh\$ echo hello/{e=1} e&&/^hello$/{print "y"; exit}' $LOG | grep -q y \
	|| fail "R-P35.3 the shell did not run 'echo hello'"
grep -q "solnix riscv64 (R-P31)" $LOG \
	|| fail "R-P35.3 the shell did not run 'cat /etc/release'"
awk '{sub(/\r$/,"")} /sh\$ echo hi \| cat/{e=1} e&&/^hi$/{print "y"; exit}' $LOG | grep -q y \
	|| fail "R-P35.3 the pipeline 'echo hi | cat' did not print hi"
echo "R-P35.3 PASS: shell ran echo/cat (argv across exec) + a pipe (echo hi | cat) over pipe+dup2"

echo
echo "PASS: R-P35 (PER-CPU IDLE + IPI WAKEUP -- an idle hart wfi's on an empty"
echo "      runq [real P_WAITING block, not the R-P34 wfi-poll] + an SBI software"
echo "      IPI wakes a sleeping hart on a runnable transition; a REAL init"
echo "      PROCESS as pid 1 -- execs /sbin/init which fork+execs /bin/sh + reaps"
echo "      orphans [adopting a re-parented grandchild]; a MINIMAL SHELL /bin/sh --"
echo "      reads a scripted /etc/rc, parses argv, fork+exec+waits echo/cat/true"
echo "      [argv passes through exec(2)] + runs a pipe echo hi | cat over the"
echo "      pipe + dup2) -- the riscv64 kernel now runs a real userland session,"
echo "      all boot-verified, R-P24..R-P34 regressions green.  Next: R-P36."
