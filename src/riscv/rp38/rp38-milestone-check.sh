#!/usr/bin/env bash
#
# rp38-milestone-check.sh -- re-runnable proof of the R-P38 deliverables, all
# boot-verified under qemu-system-riscv64 -machine virt -smp 2 via OpenSBI:
#
#   R-P38.1  THE HEADLINE / THE BRIDGE TO THE PACKAGE SET.  Exec a REAL,
#            UPSTREAM-SOURCE riscv64 ELF: the GNU coreutils echo (the algorithm
#            of coreutils-9.5 src/echo.c, extracted verbatim -- hextobin()+main()
#            -- with a minimal freestanding libc shim standing in for the not-
#            yet-ported libc).  It is compiled by the ON-NODE cross toolchain
#            (riscv64-unknown-solaris2.11 xgcc + the R-P17 binutils) and
#            DYNAMICALLY LINKED via the real ld.so.1 against libgcc_s.so.1 --
#            i.e. built the way a solnix PACKAGE is built, not a hand-tailored
#            test.  Run from the interactive shell: /bin/coreecho R-P38 ... ->
#            "R-P38 real-coreutils-echo" (argv join + the real echo -e escape
#            engine turns \t into a TAB), ld.so.1 maps libgcc_s.so.1 + enters
#            the app.  This is what turns a toy kernel into one that runs the
#            actual toolchain's output.
#   R-P38.2  FULL fg/bg JOB CONTROL.  A '&' background launch (fork+exec, no
#            wait) + a jobs table + jobs/fg/bg builtins + SIGCONT (resume a ^Z-
#            stopped job) + SIGCHLD/WNOHANG-driven reaping of finished bg jobs.
#            Proof: 'counter 120 &' launches a bg job [2]; 'jobs' lists it
#            RUNNING (concurrent with the shell on 2 harts); 'fg' foregrounds it;
#            ^Z stops it (SIGTSTP); 'jobs' lists it STOPPED; 'bg' resumes it
#            (SIGCONT); it runs to completion + is REAPED (-> "[2] Done").
#   R-P38.3  A BLOCK-DEVICE VNODE + a minimal on-disk blockfs.  A RAM-backed
#            block device (the classic bdev_strategy(blkno,buf,rw) routine) with
#            a trivial on-disk fs (superblock + inode table + data blocks); a
#            blockfs vnode's vop_read pulls file data BLOCKS through
#            bdev_strategy.  Proof: mount /blk (superblock read back through the
#            block layer), read /blk/hello back THROUGH the block vnode, unmount
#            -- the vfs is not ramfs-only.
#
# plus the R-P24..R-P37 regressions (build-kernel.sh asserts every one).
set -e
K=/root/riscv-port/rp38/kernel
cd $K
bash build-kernel.sh

echo
echo "PASS: R-P38 milestone check complete (see the R-P38.* PASS lines above;"
echo "      the headline is R-P38.1 -- a REAL upstream-source coreutils echo"
echo "      compiled by the on-node cross toolchain + dynamically linked via"
echo "      ld.so.1 against libgcc_s.so.1, exec'd from the shell: the bridge to"
echo "      the solnix package set).  Next: R-P39."
