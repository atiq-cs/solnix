#!/usr/bin/env bash
#
# rp42-milestone-check.sh -- re-runnable proof of the R-P42 deliverables, all
# boot-verified under qemu-system-riscv64 -machine virt -smp 2 via OpenSBI:
#
#   R-P42.1  THE HEADLINE -- MORE real, UNMODIFIED upstream coreutils utils on
#            the SAME reusable libc.a.  The verbatim GNU coreutils-9.5 src/head.c
#            and src/tail.c LINK the REAL rp42/libc/libc.a via per-util gnulib
#            scaffolding built on the proven wc_glue.h C-locale reduction
#            (head-include/head_glue.h: safe_read/full_read [gnulib safe-read.c+
#            full-write.c reduced], xdectoumax, xmalloc/xnrealloc, offtostr,
#            ISDIGIT, emit_mandatory_arg_note, quote/assure; tail-include/
#            tail_glue.h adds cl_strtod/xstrtod, xstrtoumax+LONGINT_*, iopoll/
#            isapipe/xnanosleep stubs, struct timespec+get_stat_mtime, xpalloc,
#            last_component, main_exit/write_error).  The libc grew memrchr
#            (port/misc.c) + clearerr/fpurge (port/stdio2.c) for them.  Run:
#            head -2 /etc/release -> both lines; tail -1 -> the last line.
#   R-P42.2  Two more syscall-light utils: the verbatim src/basename.c +
#            src/dirname.c (pure string; cu3-include/cu3_glue.h reduces gnulib
#            basename-lgpl/dirname-lgpl/stripslash + filename.h macros).  Run:
#            basename /usr/lib/ld.so.1 -> ld.so.1 ; dirname -> /usr/lib.
#            So echo/true/cat/wc/head/tail + basename/dirname = 8 real upstream
#            utils on ONE libc.a.  (env.c deferred to R-P43 [sig2str/operand2sig];
#            unmodified ls.c [5658 lines, 31 gnulib modules incl. obstack/mpsort/
#            hash/human/mbswidth] stays deferred -- the from-scratch R-P41 ls is
#            the exerciser.)
#
# plus the R-P24..R-P41 regressions (build-kernel.sh asserts every one).
set -e
K=/root/riscv-port/rp42/kernel
cd $K
bash build-kernel.sh

echo
echo "PASS: R-P42 milestone check complete (see the R-P42.* PASS lines above;"
echo "      the headline is R-P42.1 -- the UNMODIFIED coreutils head.c + tail.c"
echo "      link the SAME real libc.a [libc grew memrchr]: head -2 /etc/release"
echo "      prints both lines, tail -1 the last; R-P42.2 adds basename + dirname"
echo "      [gnulib base_name/dir_len reduced], so echo/true/cat/wc/head/tail +"
echo "      basename/dirname are 8 real upstream utils on one libc.a.  env.c +"
echo "      unmodified ls.c deferred to R-P43."
echo "      Next: R-P43."
