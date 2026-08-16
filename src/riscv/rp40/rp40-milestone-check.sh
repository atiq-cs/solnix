#!/usr/bin/env bash
#
# rp40-milestone-check.sh -- re-runnable proof of the R-P40 deliverables, all
# boot-verified under qemu-system-riscv64 -machine virt -smp 2 via OpenSBI:
#
#   R-P40.1  THE HEADLINE (part 1) -- GROW the REAL, REUSABLE libc.a.  On top of
#            R-P39's libc.a (syscall/stdio/string/stdlib/ctype + real crt), add
#            the surface a BIGGER real coreutils util needs, as separately
#            compiled TUs into the SAME real ar archive (nm shows static
#            resolution, not shims):
#              - dir.c:    opendir/readdir/closedir + struct dirent (over the
#                          kernel SYS_getdents, one entry name per call)
#              - stat.c:   stat/fstat/lstat + struct stat + the S_IF* macros
#                          (over the kernel SYS_stat/SYS_fstat size-getattr;
#                          fstat of a console fd -> S_IFCHR so a util's
#                          input==output dev/ino guard does not misfire)
#              - stdio2.c: a READ-capable FILE* family fopen/fclose/fread/fgets/
#                          fgetc/getc/fseek/ftell (real FILE* over open/read/
#                          lseek/close) + snprintf/sprintf/vsnprintf
#              - signal.c: signal/sigaction/kill/raise wrappers (over the R-P33/
#                          34 kernel signal syscalls) + the sa_restorer stub
#            plus getpagesize (syscall.c) and stpcpy (string.c).
#   R-P40.2  THE HEADLINE (part 2) -- link + run a BIGGER real coreutils util.
#            The UNMODIFIED GNU coreutils-9.5 src/cat.c, compiled with a
#            cat-include/ gnulib scaffolding (getopt_long, full_write/safe_read,
#            io_blksize/xalignalloc/fdadvise, error/quotef) onto the REAL grown
#            libc.a, dynamically linked via ld.so.1 (NEEDED libgcc_s.so.1) as
#            /bin/corecat.  cat open(2)s a real file, fstat(2)s it, and reads+
#            writes it via the real libc: `cat /etc/release` prints both lines
#            of the release file -- a real program much bigger than echo/true.
#   R-P40.3  A PERSISTENT ROOT FS AT BOOT.  The R-P39 disk-backed blockfs is now
#            LEFT MOUNTED at boot (a boot remount reuses bdev0's persisted
#            contents), and proc_openf routes a /blk/* path to the block vnode,
#            so the interactive shell can `cat /blk/persist` -- a file served
#            from the DISK-BACKED fs (its read crosses bdev_strategy, not ramfs),
#            persisted from the write-back step -- during the boot session.
#            Proves the boot path can use a persistent fs, not just ramfs.
#
# plus the R-P24..R-P39 regressions (build-kernel.sh asserts every one).
set -e
K=/root/riscv-port/rp40/kernel
cd $K
bash build-kernel.sh

echo
echo "PASS: R-P40 milestone check complete (see the R-P40.* PASS lines above;"
echo "      the headline is R-P40.1/.2 -- the R-P39 real libc.a GROWN [dir,"
echo "      stat, read-capable stdio, signal] links + runs a BIGGER real,"
echo "      UNMODIFIED GNU coreutils util [cat] against real files, and a"
echo "      disk-backed blockfs is LEFT MOUNTED at boot so the shell cats a"
echo "      file served from it).  Next: R-P41."
