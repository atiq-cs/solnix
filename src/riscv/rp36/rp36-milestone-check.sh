#!/usr/bin/env bash
#
# rp36-milestone-check.sh -- re-runnable proof of the R-P36 deliverables, all
# boot-verified under qemu-system-riscv64 -machine virt -smp 2 via OpenSBI:
#
#   R-P36.1  PER-AS ASIDs + REMOTE TLB SHOOTDOWN (THE R-P35 SMP FIX).  Every
#            address space carries its own 16-bit ASID tagged into satp
#            (MAKE_SATP_ASID); sfence.vma is ASID-scoped (rv_tlb_flush_asid ->
#            sfence.vma x0, aN).  COW fork + AS teardown no longer rely on a
#            LOCAL-only global flush: after hat_user_cow_share drops PTE_W in the
#            parent's live tables, do_fork does an ASID-scoped local flush + a
#            REMOTE-hart TLB shootdown (hat_tlb_shootdown -> SBI RFENCE remote
#            sfence.vma) so a peer hart cannot keep a stale WRITABLE entry and
#            store into the shared frame -- closing the R-P35 latent COW-vs-wait
#            TLB-aliasing fault under heavy fork/exec churn.  ASID rollover
#            (generation bump + full TLB recycle) is handled.  Proof: the churn
#            loop that used to fault runs CLEAN (no fault, no leak) across a real
#            ASID rollover.
#   R-P36.2  waitpid(2) + WNOHANG/specific-pid.  proc_waitpid(pid, &status,
#            options): pid>0 reaps only that child, WNOHANG polls (returns 0 if
#            no matching zombie).  Proof: a WNOHANG poll of a live child returns
#            0; a specific-pid wait reaps only the named zombie.
#   R-P36.3  cwd + . / .. .  Per-proc p_cwd + chdir(2); path_resolve prepends the
#            cwd to a relative path + collapses . / .. .  Proof: the shell cd's
#            into /tmp, cat's a RELATIVE 'g' (-> /tmp/g), cd ..'s back, and an
#            ABSOLUTE /tmp/g still reads.
#   R-P36.4  shell builtins + redirection.  /bin/sh gains cd + exit builtins and
#            > / < file redirection (over the R-P34 fd + R-P35 dup2).  Proof:
#            'echo redir > /tmp/f; cat < /tmp/f' -> redir; 'cd /tmp; cat g'.
#
# plus the R-P24..R-P35 regressions (build-kernel.sh asserts every one).
set -e
K=/root/riscv-port/rp36/kernel
cd $K
bash build-kernel.sh
echo
echo "== R-P36 headline assertions =="
LOG=$K/qemu-boot.log
fail() { echo "FAIL: $1"; exit 1; }
grep -q "ASID churn PROVEN" $LOG || fail "R-P36.1 ASID churn not clean"
grep -q "ASID rollover handled" $LOG || fail "R-P36.1 ASID rollover not handled"
echo "R-P36.1 PASS: per-AS ASIDs + remote TLB shootdown -- heavy COW/fork/exec churn clean, rollover handled"
grep -q "waitpid PROVEN" $LOG || fail "R-P36.2 waitpid not proven"
echo "R-P36.2 PASS: waitpid(2) specific-pid reap + WNOHANG poll"
awk '{sub(/\r$/,"")} /sh\$ cat g/{e=1} e&&/^rel$/{print "y"; exit}' $LOG | grep -q y \
	|| fail "R-P36.3 relative-path cat after cd did not work"
awk '{sub(/\r$/,"")} /sh\$ cd \.\./{e=1} e&&/^rel$/{print "y"; exit}' $LOG | grep -q y \
	|| fail "R-P36.3 cd .. + absolute path did not resolve"
echo "R-P36.3 PASS: cwd + . / .. (cd /tmp; relative cat; cd ..; absolute cat)"
awk '{sub(/\r$/,"")} /sh\$ cat < \/tmp\/f/{e=1} e&&/^redir$/{print "y"; exit}' $LOG | grep -q y \
	|| fail "R-P36.4 shell redirection did not round-trip"
echo "R-P36.4 PASS: shell cd/exit builtins + > / < redirection round-trip"
echo
echo "PASS: R-P36 (PER-AS ASIDs in satp + ASID-scoped sfence.vma + IPI-driven"
echo "      REMOTE TLB shootdown on COW/teardown -- closing the R-P35 latent"
echo "      COW-vs-wait TLB-aliasing fault under heavy fork/exec churn, ASID"
echo "      rollover handled; waitpid(2) with WNOHANG + specific-pid; per-proc"
echo "      cwd + chdir(2) + . / .. relative-path resolution (lookuppn); a"
echo "      /bin/sh with cd/exit builtins + > / < file redirection) -- all"
echo "      boot-verified under -smp 2, R-P24..R-P35 regressions green.  Next: R-P37."
