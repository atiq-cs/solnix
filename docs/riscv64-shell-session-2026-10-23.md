# A real shell session on the riscv64 uts kernel (rvsh, 2026-10-23)

The rvpkg track (7366f59) found three kernel fd defects that blocked a shell
session (`docs/riscv64-packages-2026-10-23.md` §4–§6). This track fixed them in
`src/riscv/uts`, added the filesystem syscalls the sbase tools need (§10),
raised the root-fs cap, and ran a full session in one boot. Everything ran on
lixr under qemu 10.2.1 (`~/scratch/rvpkg/bin/qemu-system-riscv64`). floki was
used for editing and copying only.

The kernel changes (port.c, port.h, rootfs.c, syscall.c, uproc.c) and the harness and glue changes are in the
commit that adds this doc. The bank (`~/solnix-bank/riscv/2026-10-23-rvsh/`, 136/136 sha256 read back) holds the
kernels, the session root, the binaries and every log.

Board builds of the patched tree (lixr, native gcc): `build-k3-payload.sh` compiles and links (`unix-k3.Image`
640608 B). `build-k1-payload.sh` fails to link with `undefined reference to k3_bringup`: that comes from 6ccf127
(startup.c calls the K3 bring-up, which the K1 object list does not include), it is on HEAD before this change, and
startup.c is not touched here.

## Rates on the final kernel (`unix-d7`)

| What | Result | Log (lixr `~/scratch/rvsh/logs/`) |
|---|---|---|
| canonical gates TP SOCK POLL PORT FP FB MINIWL NEWLIBTEST | 8/8 on every boot of every kernel built (d1 x4, d2 x4, d3 x4, d5, d6, d7 x2) | `gates-*.out` |
| check-all, 8 suites, 89 checks/run | 4/4 runs all green: libc 5, zlib 3, sbase 31, dash 16, ncurses 2 (incl. byte oracle), less 3, vfd 3, fs 28 | `check-all-d7x4.out` (runs 1–2 vfd: see §3, check-order bug) |
| kpipe ctl / conout / execfd / leak (raw ecalls, no glue) | 4/4 each | `kernel-d7x4b.out` |
| the session demo | 4/4 boots, 8/8 content markers each | `demo2-{1..4}.log.txt` |

## 1. Defect 1: pipe references leaked (fixed)

**The change.** All of it is in `uts/uproc.c`.
* Two new helpers, `fd_hold()` and `fd_release()`, take and drop a slot's
  object reference: pipe, AF_UNIX socket, event port, fb.
* Every path that empties a slot now goes through `fd_release()`. That covers
  `proc_close` (any slot, 0–2 included), `proc_dup2` onto an open fd,
  `proc_exit` (every fd) and exec.
* `proc_fork` and `proc_dup2` take the new reference with `fd_hold()`. Before
  this, dup2 copied a socket, port or fb slot without taking any reference: a
  latent double release.
* `port.c` gains `p_refs` and `port_hold()`. A forked child's copy of a port fd
  is a second reference: illumos `port_create(3C)` says a port is destroyed on
  last close. Without this, the child's new close-at-exit would have freed the
  parent's port (miniwl forks with a port open).

**Probe.** `kpipeprobe leak`: the child dup3s the write end onto fd 1, closes
it, and exits.
* Before (unix-baseline): the parent never returns, 4/4 boots (`ctl-leak-base.out`).
* After (unix-d1): "parent read 0 bytes then EOF", 4/4 boots (`kernel-d1x4.out`).
* Control: `kpipe-ctl` passes on both kernels.

## 2. Defect 2: fd 0/1/2 were always the console (fixed)

**The change.** In `uts/syscall.c`, `sys_read`/`sys_write` now send any slot
that holds an object (`proc_fd_open`, new in uproc.c) through
`proc_fread`/`proc_fwrite`, fd 0–2 included, exactly as `fd_ready` does for
poll. An empty slot 0–2 is the console tty, readable and writable on all three.
That last detail matters: the first version made an empty fd 2 unreadable, and
less (which reads keys from fd 2) quit; `less-page` in check-all-d5 caught it.
The `fd < 3` guards in proc_fread, proc_fwrite, proc_lseek, proc_ioctl,
proc_mmap and sock_of_fd became slot-based.

**Probe.** `kpipeprobe conout`: the child dup3s the write end onto fd 1 and
calls `write(1)`.
* Before: `conout-bytes` appeared on the console.
* After (unix-d2): "parent read 13 bytes then EOF" and nothing on the
  console, 4/4 (`kernel-d2x4.out`).
* Control: ctl and leak still pass 4/4.

## 3. Defect 3: exec dropped every fd (fixed)

**The change.**
* `load_elf_into` keeps every fd across exec and releases only slots with
  `fd_cloexec` set (POSIX).
* `fd_cloexec` is per slot; dup2 and release clear it.
* New `SYS_fcntl` (25) → `proc_fcntl`: F_DUPFD 0, F_GETFD 1, F_SETFD 2 and
  F_DUPFD_CLOEXEC 1030 (Linux numbering, like the rest of this syscall table).
* openat honours O_CLOEXEC (0x80000) and O_APPEND (0x400). O_APPEND moved into
  the kernel (`fd_append`) because the glue used to emulate it per user fd,
  which cannot survive exec.
* `proc_ioctl` answers TCGETS (0x5401) on an empty fd 0–2, so a glue with no fd
  table of its own can still implement `isatty`.

**Probe.** `kpipeprobe execfd`: the exec'd image writes to the inherited fd 4.
* Before: `write(fd 4) = -1`.
* After (unix-d3): `= 9`, and the parent reads 9 bytes, 4/4 (`kernel-d3x4.out`).

**Correction found along the way.** On d7, execfd showed `write(fd 5)`. The
reason: pkginit's `fopen`'d check list now survives exec (POSIX-correct), so
the probe's pipe moved to fds 4 and 5. pkginit now marks that fd FD_CLOEXEC.
newlib's `"e"` fopen mode only works if libc.a was built with
`_GLIBC_EXTENSION`, so the fix uses `fcntl`.

**dash checks (dash.checks, unix-d3 onward).** All pass 4/4:
* `n=$(/bin/sbase-box echo inner)` sets `n=[inner]`.
* `sbase-box head -n 1 < /etc/words` prints `cherry`.
* `echo a | sbase-box tr a b` prints `b`.
* A three-stage external pipeline gives `8`.
* `grep an /etc/words > /tmp/g; wc -l < /tmp/g` gives `3`.

**THE KEY PROOF.** Dash and sbase-box linked against the glue built
`-DSOLNIX_NO_VFD` (no userland fd table, no close-all, so the kernel's table is
the only one) were run on the same 7 pipe, redirect, `$( )` and `2>` checks
(`novfd.checks`, `logs/novfd-*.out`):
* On unix-d3: 8/8, harness control included.
* On unix-baseline: the first check, the builtin pipeline
  `echo piped | { read x; }`, hangs forever (2 boots), as rvpkg recorded
  (`xfail-novfd-pipe` 4/4). The boot ends there, so the other 6 were never
  reached.

**The STUBs for defects 1–2 were removed, not just marked removable.**
`build-all-pkgs.sh` now builds every package with `GLUE_DEFS=-DSOLNIX_NO_VFD`
by default. This was forced: with the old glue, an exec'd stage of a pipeline
still wrote to the console, and `find /t | sort` hung (§5). The old glue
survives only as the negative control. `build-vfd.sh` links dash-vfd and
sbase-box-vfd against it, and `vfd.checks` requires that `$(prog)` and
`prog < file` FAIL with it (`xfail-vfd-exec-*`) while the builtin pipeline
still passes. Result: 3/3 on runs 3–4 of check-all-d7x4, plus `vfd-d7.out`.

Runs 1–2 of the vfd suite showed "no END" on `vfd-pipe-builtin`. That was my
check-ordering bug, not the kernel. The preceding check runs an old-glue `head`
that reads the console, as designed, and that suite had no console input, so
the boot never reached the pipeline check. The fix was to put the builtin
check first and add `tests/vfd.stdin`.

## 4. The filesystem syscalls added (doc §10)

All use Linux riscv syscall numbers, errno values, and the 128-byte asm-generic
`struct stat`, in `uts/uproc.c` (the namespace block) and `uts/syscall.c`:
* `getcwd` 17, `mkdirat` 34, `unlinkat` 35 (AT_REMOVEDIR 0x200), `renameat` 38
* `chdir` 49, `getdents64` 61, `newfstatat` 79, `fstat` 80
* `openat` 56 now resolves its dirfd and the per-process cwd (`p_cwd`; fork
  copies it, exec keeps it). It honours O_EXCL, O_TRUNC, O_DIRECTORY, O_CLOEXEC
  and O_APPEND, and can open a directory as an fd for getdents.
* exec resolves relative paths against the cwd.

**Where the names live.** There is no vnode tree.
* A name exists if one of three flat tables holds it:
  * the root fs, via `rootfs_path()` in rootfs.c: the fixed top-level dirs,
    ustar files, ustar directory entries, hard links, and the embedded images;
  * the ramfs (now 64 files of 256 KiB);
  * `nsdirs` (64 directories made by mkdir).
* Any proper prefix of a name is a directory.
* A directory left empty by unlink or rename is recorded in `nsdirs`, so it
  survives, as POSIX requires.
* `st_ino` and `d_ino` are a FNV-1a hash of the path, enough for find, du and
  cp's same-file tests.
* A write-open of a read-only root file copies it into the ramfs (copy on
  write) and hides the ustar name, so `echo x >> /etc/nums` works and `ls`
  shows one entry.
* The getdents cursor is a stable slot id, so `rm -r` can unlink entries while
  it lists them.

**Kernel-side NOTEs (recorded in the code):**
* `/data` (SNFS) is reachable by name only: no getdents, unlink or rename there.
* Embedded images are EROFS.
* A listing costs O(names²) string compares. That is fine at a few hundred
  names.

**Glue** (`pkg/solnix-libc/glue.c`):
* These now call the kernel: `stat`, `fstat`, `fstatat`, `opendir`,
  `fdopendir`, `readdir`, `closedir`, `dirfd`, `rewinddir`, `mkdir`, `unlink`,
  `rmdir`, `rename`, `unlinkat`, `renameat`, `openat(dirfd)`, `chdir`, `getcwd`
  and `faccessat`.
* Linux errno 36 and 39 map to newlib's ENAMETOOLONG (91) and ENOTEMPTY (90).
  1–34 are the same in both.
* newlib's libc.a is built without `HAVE_RENAME`, so its `rename()` is
  link+unlink and fails ENOSYS. The glue therefore provides `rename()` itself.
  The first fs run caught this (`mv: Function not implemented`).

**Checks** (`tests/fs.checks`, `stage-fs.sh`): 28/28 on each of 4 runs.
* The oracle is the HOST's sbase (same source, Linux build) over the same
  stage tree. Each mutating check runs the same commands on a host copy of its
  own subtree:
  * `ls`, `ls -R`
  * `find`, `find -type f`, `find -type d -name`
  * the `du -a` path set
  * `mkdir -p`, `rm`, `rm -r`
  * `mv` of a file, `mv` of a directory (the subtree moves)
  * `rmdir`, chained rm/rmdir
* Expectation checks:
  * `du -s` = 4 (one 512-byte block per file)
  * `cd`/`pwd`/`cd ..`
  * a new file via `>`
  * O_TRUNC
  * a copy-on-write append to a root file
  * O_APPEND across exec
* Negative controls, each must fail with the right exit code and message:
  * `rm` of a missing file
  * `ls` of a missing dir
  * `rmdir` of a non-empty dir
  * `rmdir` of a file
  * `mkdir` of an existing name
  * `mkdir` with no parent
  * `cd` to a missing dir
  * `mv` of a missing file
* Two harness xfails: a wrong oracle and a wrong exit.

## 5. Root fs cap raised; the session demo

**The change.** In `rootfs.c`:
* NDISKFILE 16 → 256 and ROOTFS_MAX_BYTES 2 → 8 MiB. The staging buffer is
  allocated at the full cap: 8 MiB of a 512 MiB guest.
* ustar directory entries ('5') are now registered.
* ustar hard links ('1') name an earlier entry's bytes. That is how 100 sbase
  applets are `/bin/ls`, `/bin/rm` and so on, all linked to one `sbase-box`.
* The boot banner lists only the first 16 names.

`run-checks.sh` packs directories too and refuses a root over 256 names or
8 MiB. Set `NDISKFILE=16 ROOTFS_MIB=2` for rvpkg's kernel.

**Session root** (`stage-session.sh`): 116 names, 1.42 MB ustar. It holds:
* sbase-box plus 100 applet links
* dash, less, minigzip (zlib) and curstest (ncurses)
* `/etc/passwd` (root → /bin/dash) and `/etc/words`
* a tic-compiled terminfo dir, `/usr/share/terminfo/{v/vt100,x/xterm,...}`

There is no `/sbin/init`, so the kernel's embedded uts init runs its gates and
then the `/etc/passwd` login.

**Demo** (`demo-session.sh`, one boot): log in as root on the console, then:

    cd /tmp; pwd
    grep an /etc/words | sort | uniq -c | sort -rn > report.txt
    cat report.txt; wc -l report.txt
    less -X report.txt      (page, q)
    ed report.txt           (1p, $a "added by ed", w report.txt, q)
    cat report.txt; ls -l /tmp
    minigzip < report.txt | minigzip -d | head -n 1
    rm report.txt; ls /tmp; ls report.txt   (must fail)

4/4 boots reach the end, and each has all 8 content markers (`demo2-*.log.txt`).
Log on floki: `/scratch/solnix/rvsh/logs/demo-session-1.log.txt`. The one
"terminated by signal 9" in each log is the uts init's own SIGKILL gate, which
runs before login.

**Package bug found by the demo (not a kernel defect).** sbase ed's bare `w`
aborts with `*** buffer overflow detected ***` (SIGABRT), after the file is
written.
* Mechanism: `getfname()` returns `savfname` itself when no name is given, and
  `dowrite()` then calls `strcpy(savfname, fname)` with the two overlapping.
  That is undefined behaviour.
* newlib's `_FORTIFY_SOURCE=3` `__strcpy_chk` aborts on the overlap. The glibc
  host build is not fortified, which is why it passes there.
* The demo uses `w report.txt`. The fix belongs in sbase: skip the copy when
  `fname == savfname`.

## 6. What is left

* **Signals → illumos numbering** (doc §7, step 7): not started, there was no
  time. The work: widen `p_sigpend`/`p_sighand` to 74 (a `k_sigset_t`), make
  SIGCHLD 18 in `proc_exit`, renumber sendsig, and turn the glue's `nl2k[]`
  into the newlib→illumos map.
* **No termios.** The console is line mode, so less, ed and curses get no raw
  keys (doc §10 row 2). `isatty` works now (TCGETS), but tcsetattr is still
  ENOTTY.
* **The console is not a slot object.** F_DUPFD of an empty 0–2 is EBADF, so
  `exec 3>&1` with an unredirected stdout fails. This is a `shortcut:` in
  proc_fcntl.
* **sbase ed** overlapping strcpy, above.
* **No exec from the ramfs**: files written at runtime are data only.
* **Ramfs buffers are fixed at 256 KiB** (kmem large frees leak VA); an
  unlinked slot keeps its buffer for reuse.
* The **rvpkg doc** (`docs/riscv64-packages-2026-10-23.md`) §4–§6 and §10 should
  point here. Its "kernel-limit-*" rows are now dash-exec-* checks that pass.
