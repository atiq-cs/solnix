#!/usr/bin/env bash
#
# rp39-milestone-check.sh -- re-runnable proof of the R-P39 deliverables, all
# boot-verified under qemu-system-riscv64 -machine virt -smp 2 via OpenSBI:
#
#   R-P39.1  THE HEADLINE -- a REAL, REUSABLE libc.  Instead of R-P38's per-
#            program coreutils_shim.h, build a genuine libc.a (separate TUs
#            cross-compiled by the on-node riscv64-unknown-solaris2.11 toolchain
#            into a real ar archive): syscall stubs (the illumos riscv64 SYSTRAP
#            idiom) + buffered stdio (FILE/stdout/fwrite/putchar/fputs/fflush +
#            a minimal printf) + string.h + stdlib (malloc/free/getenv/exit/
#            atexit + an sbrk-over-SYS_brk heap) + ctype + real crt1/crti/crtn.
#            Proof: the SAME unmodified GNU coreutils-9.5 src/echo.c, rebuilt
#            against libc.a (dynamically linked via ld.so.1, NEEDED libgcc_s),
#            runs from the shell: /bin/coreecho2 R-P39 real-libc-echo ->
#            "R-P39 real-libc-echo" + /bin/coreecho2 -e libc\tstdio ->
#            "libc<TAB>stdio" (nm shows the libc symbols resolved statically
#            from the archive -- a REAL libc, not a shim).
#   R-P39.2  A 2ND REAL COREUTILS UTIL against the same libc.  The unmodified
#            GNU coreutils-9.5 src/true.c, linked against libc.a, run as
#            /bin/coretrue -> "[exit 0]" (the shell reports foreground exit
#            status), proving the libc + exec path generalizes beyond echo.
#   R-P39.3  A PERSISTENT (disk-backed) block fs.  blockfs_vop_write now writes
#            data blocks back THROUGH bdev_strategy (+ updates the on-disk inode
#            size); blockfs_create allocates inodes/data blocks; mount mkfs's
#            only ONCE per boot.  Proof: create /blk/persist, write it through
#            the block vnode, UNMOUNT, REMOUNT (no re-mkfs), read it back -- the
#            bytes survived the round-trip (persistence through the block layer).
#
# plus the R-P24..R-P38 regressions (build-kernel.sh asserts every one).
set -e
K=/root/riscv-port/rp39/kernel
cd $K
bash build-kernel.sh

echo
echo "PASS: R-P39 milestone check complete (see the R-P39.* PASS lines above;"
echo "      the headline is R-P39.1 -- a REAL, REUSABLE solnix riscv64 libc.a"
echo "      [syscall/stdio/string/stdlib/ctype + real crt1/crti/crtn] that a"
echo "      REAL, UNMODIFIED GNU coreutils program LINKS, not the R-P38 per-"
echo "      program shim).  Next: R-P40."
