#!/usr/bin/env bash
#
# rp41-milestone-check.sh -- re-runnable proof of the R-P41 deliverables, all
# boot-verified under qemu-system-riscv64 -machine virt -smp 2 via OpenSBI:
#
#   R-P41.1  THE HEADLINE (part 1) -- GROW the REAL, REUSABLE libc.a further.
#            On top of R-P40's libc.a, add (as a new separately compiled TU
#            port/misc.c into the SAME real ar archive; nm shows static
#            resolution, not shims) the surface a real ls/wc needs:
#              - qsort:   shellsort over arbitrary-width elements (ls sorts)
#              - strcoll: C-locale collation == strcmp (ls -> compare)
#              - getpwuid/getgrgid: /etc/passwd|group scan, else numeric id
#                                   (ls -l owner/group names)
#              - fileno/isatty/setvbuf: stdio glue ls/wc call at startup
#              - readlink (ENOSYS; no symlinks), strtoul, strdup/strnlen/
#                strspn/strcspn/strpbrk/strstr/memchr/mempcpy
#            plus printf %*s (dynamic field width) + %z in port/stdio.c, and a
#            2-word kernel stat ABI (size + type code) so the libc cooks a real
#            st_mode (S_ISDIR) from the kernel getattr.
#   R-P41.2  THE HEADLINE (part 2) -- link + run a REAL coreutils SET.
#            The UNMODIFIED GNU coreutils-9.5 src/wc.c, compiled with a
#            wc-include/ gnulib scaffolding (getopt_long, argv-iter, physmem/
#            argmatch/readtokens0, umaxtostr) onto the REAL grown libc.a, is
#            dynamically linked via ld.so.1 as /bin/corewc: `wc /etc/release`
#            prints "2 5 44 /etc/release" (real fopen/read/fstat byte-counting).
#            A real ls (opendir/readdir/lstat/qsort/strcoll on the grown libc)
#            is /bin/corels: `ls /` lists the root entries SORTED, `ls /bin`
#            lists the coreutils utils SORTED, `ls -l /etc` prints the long
#            form.  So echo/true/cat (R-P38..R-P40) + wc = a real coreutils SET
#            from UNMODIFIED upstream source, on one real reusable libc.a.
#            (ls itself is written from scratch to EXERCISE the grown libc --
#            coreutils' unmodified src/ls.c pulls ~32 gnulib modules [obstack/
#            quotearg/human/mbswidth/hash/mpsort/...] deferred to R-P42+; the
#            unmodified-upstream utils this phase links are cat.c + wc.c.)
#   R-P41.3  RICHER PERSISTENT FS -- SUBDIRECTORIES.  The disk-backed blockfs
#            gains a directory inode (i_type==1, written back through
#            bdev_strategy).  run_blockfs mkdirs /blk/sub, creates the NESTED
#            leaf /blk/sub/f (inode name "sub/f"), writes it through the block
#            layer, unmounts, REMOUNTS (no re-mkfs), LISTS /blk/sub (its child
#            "f" enumerated from the on-disk inode table read through
#            bdev_strategy) and READS /blk/sub/f back -- the nested path + its
#            bytes survive the round-trip, a real subdirectory persisted on the
#            disk-backed fs.  proc_mkdir routes /blk/* to blockfs_mkdir and
#            proc_openf routes a /blk/dir to a blockfs dir vnode.
#
# plus the R-P24..R-P40 regressions (build-kernel.sh asserts every one).
set -e
K=/root/riscv-port/rp41/kernel
cd $K
bash build-kernel.sh

echo
echo "PASS: R-P41 milestone check complete (see the R-P41.* PASS lines above;"
echo "      the headline is R-P41.1/.2 -- the R-P40 real libc.a GROWN [qsort,"
echo "      strcoll, getpwuid/getgrgid, fileno/setvbuf/isatty, printf %*s] links"
echo "      a REAL coreutils SET: the UNMODIFIED GNU coreutils wc.c + a real ls"
echo "      [opendir/readdir/lstat/qsort/strcoll], so echo/true/cat/wc are real"
echo "      upstream utils on one real libc.a; the disk-backed blockfs gains"
echo "      SUBDIRECTORIES [a nested /blk/sub/f persists across unmount+remount]."
echo "      Next: R-P42."
