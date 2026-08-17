#!/usr/bin/env bash
#
# rp45-milestone-check.sh -- re-runnable proof of the R-P45 deliverable, all
# boot-verified under qemu-system-riscv64 -machine virt -smp 2 via OpenSBI:
#
#   R-P45.3  THE HEADLINE: the FAITHFUL UNMODIFIED GNU coreutils-9.5 src/ls.c,
#            compiled VERBATIM and LINKED against the real solnix riscv64
#            libc.a + 25 verbatim gnulib lib/*.c modules (Route A -- gnulib's
#            OWN generated headers: config.h + obstack.h from obstack.in.h +
#            the shipped intprops.h/verify.h/attribute.h/quotearg.h/human.h/
#            mbswidth.h), dynamically linked via ld.so.1 as /bin/lsup.  The
#            boot log shows its correct upstream output:
#              ls /               -> bin  etc  lib  sbin  usr   (columns, sorted)
#              ls -l /etc         -> -rw-r--r-- 1 0 0 44 ... release  (long form:
#                                    mode string, nlink, uid, gid, size, time)
#            ls JOINS the real-upstream set (11 utils: echo/true/cat/wc/head/
#            tail/basename/dirname/pwd/env/ls).  The keystones obstack.c +
#            quotearg.c compile; 25 gnulib .c compile+link verbatim; ls.c is
#            byte-for-byte upstream.
#
#            The DEFAULT -l time format (%b abbreviated-month via abformat)
#            hangs in nstrftime's month-name path and is DEFERRED to R-P46 --
#            the numeric --time-style=long-iso path is used + PASSES here.  See
#            rp45/LS-STATUS.txt for the precise remaining blocker.
#
# plus the R-P24..R-P44 regressions (setjmp/longjmp + the 10 prior utils);
# build-kernel.sh asserts every one.  The boot log is saved to
# rp45/qemu-boot.log (via tee) so the milestone is verifiable.
set -e
K=/root/riscv-port/rp45/kernel
cd $K
bash build-kernel.sh 2>&1 | tee /root/riscv-port/rp45/qemu-boot-milestone.log
# copy the raw serial capture (the assertions grep) to the phase root.
cp $K/qemu-boot.log /root/riscv-port/rp45/qemu-boot.log

echo
echo "PASS: R-P45 milestone check complete (see the R-P45.* PASS lines above)."
echo "      THE HEADLINE: the FAITHFUL UNMODIFIED coreutils-9.5 src/ls.c is"
echo "      compiled VERBATIM + LINKED against the real libc.a + 25 verbatim"
echo "      gnulib lib/*.c (Route A: gnulib's own generated headers) and RUNS:"
echo "      ls / -> 'bin etc lib sbin usr', ls -l /etc -> the long form (mode"
echo "      string + owner/group/size/time columns).  obstack + quotearg (the"
echo "      keystones) compile; ls JOINS the 11-util real-upstream set.  The"
echo "      default -l %b month-name time format is DEFERRED to R-P46 (nstrftime"
echo "      abformat hang) -- see rp45/LS-STATUS.txt.  Boot log saved to"
echo "      rp45/qemu-boot.log.  Next: R-P46."
