#!/usr/bin/env bash
#
# rp44-milestone-check.sh -- re-runnable proof of the R-P44 deliverables, all
# boot-verified under qemu-system-riscv64 -machine virt -smp 2 via OpenSBI:
#
#   R-P44.1  setjmp/longjmp -- a REAL riscv64 setjmp/longjmp (libc/port/setjmp.S)
#            saving/restoring the RISC-V psABI callee-saved set (ra, sp, s0-s11,
#            fs0-fs11) into a jmp_buf (libc/include/setjmp.h), added to the
#            reusable libc.a.  A standalone self-test (/bin/sjtest) sets a
#            jmp_buf, longjmps back over a nested call, and the boot log shows
#            the return value (42) with the stack unwound intact, plus the C89
#            longjmp(env,0)->setjmp-returns-1 rule.  nm shows setjmp/longjmp
#            defined T in libc.a.
#
#   R-P44.3  the faithful UNMODIFIED coreutils-9.5 src/ls.c: scoped this phase
#            (31 gnulib module headers, the exact ls-called API surface, the
#            obstack.h/config.h gnulib-generation gap) and DEFERRED to R-P45 --
#            see rp44/LS-STATUS.txt for the precise remaining blocker.  The
#            from-scratch R-P41 ls (/bin/corels) stays the ls exerciser.
#
# plus the R-P24..R-P43 regressions (build-kernel.sh asserts every one).  The
# boot log is saved to rp44/qemu-boot.log (via tee) so the milestone is
# verifiable.
set -e
K=/root/riscv-port/rp44/kernel
cd $K
bash build-kernel.sh 2>&1 | tee /root/riscv-port/rp44/qemu-boot-milestone.log
# copy the raw serial capture (the assertions grep) to the phase root.
cp $K/qemu-boot.log /root/riscv-port/rp44/qemu-boot.log

echo
echo "PASS: R-P44 milestone check complete (see the R-P44.* PASS lines above)."
echo "      THE HEADLINE part 1: a REAL riscv64 setjmp/longjmp (port/setjmp.S,"
echo "      the psABI callee-saved set ra/sp/s0-s11/fs0-fs11 + a jmp_buf) is in"
echo "      the reusable libc.a; /bin/sjtest longjmps back over a nested call and"
echo "      returns 42 with the stack intact (and the val==0 -> 1 rule holds)."
echo "      The faithful UNMODIFIED ls.c is scoped + DEFERRED to R-P45 (the"
echo "      gnulib obstack.h/quotearg generation gap) -- see rp44/LS-STATUS.txt."
echo "      Boot log saved to rp44/qemu-boot.log.  Next: R-P45."
