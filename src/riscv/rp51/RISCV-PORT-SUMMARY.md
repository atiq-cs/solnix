# solnix riscv64 -- RISC-V port status (R-P51 milestone)

This is the "where does the RISC-V port stand" reference, written at R-P50, a
round-number consolidation milestone.  It records the full arc R-P17 -> R-P50,
the current capability, and the gap to a self-hosting / bootable-on-real-
hardware port.

solnix is a Nix distribution of illumos; this is its **riscv64** port.  The
work is a native `riscv64-unknown-solaris2.11` kernel + userland that boots
under `qemu-system-riscv64 -machine virt` via OpenSBI and is boot-verified
under `-smp 2` on every milestone.

--------------------------------------------------------------------------
## The arc: R-P17 -> R-P50

**Toolchain (R-P17..R-P21).**  A native RISC-V cross toolchain:
`riscv64-unknown-elf` binutils (R-P17), a `riscv64-unknown-solaris2.11` gcc
built in stages (R-P36 dynamic-chain), and libgcc_s.so.1 (R-P21) -- the
runtime support the dynamic C programs bind against.

**Kernel boot + the four subsystems (R-P24).**  The kernel enables Sv39
paging, takes clock ticks (the CLINT timer), claims + completes external
interrupts through the PLIC, and reaches the dispatcher idle loop -- the four
bring-up subsystems, all still asserted as regressions today.

**Processes: fork / exec / wait (R-P26).**  A real proc/lwp table; fork(2)
runs both parent and child; exec(2) replaces the image with a different
program; wait(2)/exit rendezvous so the parent reaps the child's status.

**Cross-object dynamic linking (R-P28).**  ld.so.1, the riscv64 runtime
linker: it maps a DT_NEEDED ET_DYN, relocates the app + its libraries, arms a
lazy PLT (resolve-on-first-call), sets RELRO read-only, and enters the app.
R-P28.1 is the canonical proof: a dynamic hello binds `__multf3` in
libgcc_s.so.1 across objects and returns 42.

**High-VA relink + demand paging (R-P30..R-P32).**  The kernel relinks itself
at a high virtual address and drops the low identity map; a lazy/demand-paged
user page is faulted in on first touch.

**Signals, pipes, job control (R-P33..R-P34).**  kill/sigaction/sigreturn,
sigprocmask/sigsuspend/alarm, a real pipe(2) + dup/dup2/fcntl, and setpgid --
the machinery an interactive shell needs.  SIGPIPE is delivered when a reader
closes a pipe (yes | head), and the shell survives it.

**SMP idle + init + shell (R-P35).**  Per-CPU idle harts wfi on an empty runq
and are woken by an SBI software IPI when a peer makes a proc runnable; a real
init (pid 1) fork+execs /bin/sh and reaps orphans; the shell reads /etc/rc,
parses argv, fork+exec+waits each command, and runs a pipeline.

**cwd + a reduced VFS lookuppn (R-P36..R-P37).**  chdir(2)/getcwd, relative
path resolution, mkdir/rmdir, O_TRUNC/O_APPEND -- a real-ish vnode layer
(VOP_READ/WRITE/LOOKUP/GETATTR) over a ramfs (the boot archive, read-only), a
writable tmpfs, and directory vnodes.

**A real, reusable libc.a + a block-backed fs (R-P39).**  A REAL solnix
riscv64 `libc.a` (separate translation units, `nm` shows static resolution --
not per-program shims): syscall wrappers, stdio, string/stdlib, printf.  On
top of a RAM-backed block device (bdev0) with the classic Unix
`bdev_strategy(blkno, buf, rw)`, a minimal on-disk filesystem **blockfs**
(superblock + inode table + data blocks) whose vnode reads/writes cross the
block layer, with write-back persistence across an unmount+remount.

**blockfs subdirectories (R-P41).**  On-disk directory inodes; a nested
`/blk/sub/f` persists across unmount+remount; getdents enumerates on-disk
children through bdev_strategy.

**N real UNMODIFIED upstream GNU coreutils-9.5 (R-P39..R-P50).**  Real,
UNMODIFIED coreutils-9.5 source compiled + linked against the one reusable
libc.a (plus the gnulib support objects), run dynamically via ld.so.1.  Each
milestone added a few, driving out real libc + VFS gaps (qsort/strcoll,
getpwuid/getgrgid, readlink, memrchr, the vfprintf `.prec` precision + `%*s`,
fclose not freeing the static streams, the setlocale_null recursion, uname(2)
+ sysinfo, sysconf(_SC_NPROCESSORS_ONLN) -> SYS_ncpu, unlink(2), ttyname, and
at R-P50 the `%j/%t/%o` printf directives + a blockfs getattr).

**R-P49: the blockfs mount root + the SMP ld.so.1 fence.i race.**  `ls /blk`
works from userland (proc_openf crosses the bare mount point into the mounted
fs's root); and the SMP first-bind race is fixed at the root -- ld.so.1 maps a
DT_NEEDED .so's CODE pages with plain data stores, so a `fence.i` on
exec_map_so + rv_set_satp makes the freshly-mapped code I-cache-coherent on
every hart, making R-P28.1 exit 42 deterministically under -smp 2.

**R-P50: blockfs getattr -> real `ls -l /blk` + more utils (this milestone).**
proc_stat routes a `/blk*` path to a new `vfs_blockfs_getattr` that reads the
on-disk inode's real size + type through bdev_strategy, so `ls -l /blk` prints
real per-entry metadata instead of `?`:

    $ ls -l /blk
    -rw-r--r-- 1 0 0       83 hello
    -rw-r--r-- 1 0 0      103 persist
    drwxr-xr-x 1 0 0        0 sub
    $ stat /blk/persist
      File: /blk/persist
      Size: 103   Blocks: 1  IO Block: 4096  regular file
      Access: (0644/-rw-r--r--)  Uid: (0/0)  Gid: (0/0)

Four more UNMODIFIED coreutils join: **stat** (the natural proof of the
getattr), **link** (a new `link(2)` syscall -> vfs_link), **fold**, **tr**.

**R-P51: REAL hard links (shared inode + nlink) + 3 more utils (this
milestone).**  R-P50's `vfs_link` COPIED bytes (each tmpfs slot conflated a
directory entry with its file bytes).  R-P51 splits the tmpfs slot into a
DIRECTORY ENTRY (name + inode index) and a shared `tmp_inode` (data + len + cap
+ nlink): `link(2)` adds a 2nd entry at the SAME inode and bumps nlink;
`unlink(2)` frees the entry, drops nlink, frees the inode's data only at
nlink==0; `proc_stat`/`proc_fstat` + the libc stat cook now report st_nlink +
st_ino:

    $ echo hardlinkX > /tmp/a; link /tmp/a /tmp/b
    $ stat /tmp/a   ...   Inode: 11  Links: 2
    $ stat /tmp/b   ...   Inode: 11  Links: 2   (SAME inode, nlink 2)
    $ echo hardlinkY >> /tmp/a; cat /tmp/b   ->   hardlinkX / hardlinkY (shared)
    $ unlink /tmp/a; cat /tmp/b   ->   still reads (nlink 2->1)
    $ unlink /tmp/b               ->   last link, inode freed (nlink 1->0)

Three more UNMODIFIED coreutils join: **paste**, **expand**, **unexpand** (25
total).  The virtio-blk MMIO driver is documented for R-P52
(`rp51/VIRTIO-BLK-PLAN.md`); the RAM-blockfs is kept.

--------------------------------------------------------------------------
## Current capability (R-P51)

An **illumos-riscv64 kernel that boots under qemu-system-riscv64** (`-machine
virt`, OpenSBI), **SMP-correct under `-smp 2`**, which:

  * enables Sv39 paging, takes clock/PLIC interrupts, schedules across two
    harts with per-CPU idle + IPI wakeup;
  * runs a real init (pid 1) that fork+execs an **interactive shell** with
    signals, pipes, and job control;
  * runs **25 real, UNMODIFIED upstream GNU coreutils-9.5** binaries --
    echo, true, false, cat, wc, head, tail, basename, dirname, pwd, env,
    whoami, yes, ls, uname, nproc, unlink, tty, stat, link, fold, tr,
    paste, expand, unexpand --
    dynamically linked via ld.so.1 against **one reusable libc.a**;
  * serves files from a **persistent block-backed filesystem** (blockfs over
    a block device via bdev_strategy) with subdirectories, write-back
    persistence, real directory enumeration, and now real per-entry metadata
    (`ls -l /blk`, `stat /blk/...`).

--------------------------------------------------------------------------
## The gap to a self-hosting / bootable-on-real-hardware port (R-P52+)

The port is a working kernel + a real coreutils userland on a real libc, but
it is NOT yet self-hosting or bootable on real hardware.  What is missing:

  * **More of genunix.**  The syscall + VFS surface is a reduced subset.
    The tmpfs now has REAL hard links (R-P51: a shared inode + nlink, link(2)
    aliases + unlink frees at nlink==0).  Still toward a fuller OS: the *at
    syscall family (linkat/renameat/unlinkat/fstatat -- ln wants them),
    true lstat/chmod/utimensat, multi-block blockfs files (currently one data
    block per file), a real mount table, statvfs, users/permissions
    enforcement, and the process/credential machinery real programs assume.

  * **A real disk driver.**  blockfs runs over a RAM-backed bdev0.  Real
    hardware needs an actual block driver (virtio-blk under qemu first, then
    a physical controller) and a buffer cache.

  * **A bootable image.**  Today the kernel + initramfs are handed to qemu
    with `-kernel`.  A real port needs a boot image (a partitioned disk with
    a bootloader / u-boot + an on-disk root filesystem) that OpenSBI or
    firmware loads, not a qemu `-kernel` shortcut.

  * **Native nix (the endgame).**  solnix is a Nix distro; the RISC-V port is
    "real" once it can build and run its own packages -- which needs a native
    toolchain running ON the port, a package manager, and enough of the
    illumos runtime (libc, libnsl, the loader, /system) for nix + its
    dependencies to build.  That is many milestones out; R-P50 is the point
    where the kernel + a real UNMODIFIED coreutils userland + a persistent
    fs + SMP correctness are all proven together.

--------------------------------------------------------------------------
Milestone check: `bash rp51/rp51-milestone-check.sh`
Boot log (canonical serial capture): `rp51/qemu-boot.log` (saved via tee).
