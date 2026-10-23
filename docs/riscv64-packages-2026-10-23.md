# riscv64 userland packages built natively on lixr (2026-10-23)

Track rvpkg. Six packages build natively on lixr (Milk-V K3, Bianbu 4.0.7, gcc 15.2)
as static riscv64 binaries and run on the solnix riscv64 kernel (`src/riscv/uts`)
under qemu. Every check has an oracle or a negative control. Building them exposed
three kernel defects and one undecided ABI (§4–§7). None of those were fixed here:
this is a userland track. Where the packages work around them, the workaround is
listed as a **STUB** in the table below, so nobody reads it as a kernel fix.

## Package table

| Package | Version | Verdict | Check in the guest |
|---|---|---|---|
| zlib | 1.3.2 | **REAL** | upstream `test/example` (all 8 result lines); `minigzip -d` of a GNU-gzip file; a bad-CRC control exits 1 |
| sbase (coreutils subset) | git c546c3a | **REAL**, 93 applets | 29 checks byte-compared with the same source built for Linux, plus 2 harness controls |
| dash `/bin/sh` | 0.5.12 | **REAL as a program; a shell session is BLOCKED** by kernel defects 1–3 | script output equals host dash; `-c`; exec; 127; interactive console; pipes and redirects between builtins |
| ed (sbase) | git c546c3a | **REAL** | edit from the console, `w`, read back with `cat` |
| ncurses | 6.5 | **REAL** (static; vt100 and dumb compiled in; no terminfo db) | `newterm(vt100)` test; its escape stream is byte-identical to the same test built for Linux |
| less (pager) | 668 | **REAL** (line-mode keys only: no termios) | page, `G`, `?regex` search with highlight, `q`; absent-pattern control |
| *userland fd table* in glue.c | — | **STUB for kernel defects 1 and 2** | maps user fds to the console or kernel fds ≥3; dash linked without it hangs (control `xfail-novfd-pipe`) |
| *close every kernel fd at `_exit`/`execve`* in glue.c | — | **STUB for kernel defect 1** | the kernel's exit and exec release no pipe refs |
| *signal-number translation* in glue.c | — | **STUB for the open ABI in §7** | `sigtest` passes; the control without translation loses SIGCHLD |
| *one sigreturn VA in every binary* (crt0.S) | — | **STUB for the global `p_sigrestore_va`** (uproc.c) | the kernel keeps one trampoline address for all processes |
| *stat/fstat from lseek; directories = root vnode names* | — | **DERIVED** (no stat syscall) | `fstest` (mkstemp/write/lseek/read) |

The libc is newlib 4.5.0 (the bytes the uts NEWLIBTEST gate links) plus
`libsolnix.a`, the OS port in `src/riscv/pkg/solnix-libc/glue.c`. Every entry is
tagged: 32 REAL (2 "by construction"), 1 REAL-with-limits, 9 DERIVED, 12 STUB,
37 ENOSYS.

**Rates.** `check-all.sh 4`: 6 suites × 4 fresh boots, 57 checks per run including
the controls. **4/4 runs all green, no failures to cluster**
(`logs/check-all-4.log`). The kernel-defect probes (`check-kernel.sh`, §4–§6): run 1
showed all three hangs as documented and the control passed. Runs 2–4 were still
going when this was written (`logs/check-kernel-4.log`).

## 1. Starting point: one premise of the brief did not hold

The rp39–rp54 libc.a and its 26 GNU coreutils were built against **illumos** syscall
numbers (`SYS_open 5`, `SYS_stat 18`), using an xgcc on a node that has since been
wiped. The canonical kernel `src/riscv/uts` uses **Linux riscv** numbers
(`openat 56`, `read 63`) and has no stat, getdents, chdir or getcwd. Those binaries
cannot run on it. This track builds on the uts lineage's real libc, newlib 4.5.0,
which is static ET_EXEC at `0x40010000`, hard-float and medlow
(`docs/riscv64-first-real-binary.md`). Nothing here needed the dynamic loader.

## 2. How it is built and checked

Builds and boots ran on lixr only; floki was used for editing and copying.

* `solnix-cc` drives lixr's gcc 15.2 with `-nostdinc -nostdlib`, the newlib headers,
  `-march=rv64imafdc -mabi=lp64d -mcmodel=medlow`, linked at `0x40010000`.
* `solnix-libc/solnix-pkg.ld` uses the same base and symbols as `uts/user/newlib.ld`,
  but with two PT_LOAD segments (r-x and rw-, both confirmed in the guest `[elf]`
  log). The old single RWX segment made ld warn. dash's configure links with
  `--fatal-warnings`, so it concluded newlib had no `bsearch` or `strtod`.
* Harness: `run-checks.sh` packs a ustar root whose `/sbin/init` is `tests/pkginit.c`
  and boots the uts kernel (built natively with `build-unix.sh`) under
  qemu-system-riscv64 10.2.1. That qemu was unpacked from the Ubuntu ports debs
  (`fetch-qemu.sh`, `qemu-wrap.sh`); nothing was installed on the board, and
  `archive.spacemit.com:443` refuses lixr. A check passes only if **both** the exit
  status and the output (`@` must match, `!` must not, or `%` equals a host oracle)
  are right. Check-name prefixes:
  * `xfail-*` are negative controls and pass only when they fail.
  * `kernel-hang-*` pass only if their expected output appeared **and** the guest
    then hung.
* Before any change, the stock uts boot on lixr passed every gate (TP, SOCK, POLL,
  PORT, FP, FB, MINIWL, NEWLIBTEST).
* Console input: bytes that reach the serial port before `/sbin/init` runs are lost
  (0/4 vs 8/8; pacing made no difference, 6/6 unpaced). So `run-checks.sh` starts
  input only when it sees `RVPKG INIT`. This was a harness bug, not a kernel one.

## 3. Kernel probes used in §4–§6

`tests/kpipeprobe.c` uses **raw `ecall`s**, so the glue fd table is not involved.
Each mode gets its own boot, because a hang ends the boot:

| Mode | What it does | Result |
|---|---|---|
| `ctl` (**control**) | pipe at kernel fds 3/4; child writes and closes; parent reads | `parent read 10 bytes then EOF`. The probe can pass. |
| `conout` | child `dup3(wfd,1)`, closes wfd, `write(1,…)` | `conout-bytes` printed **on the console**, then the parent never gets EOF |
| `execfd` | child `execve`s itself; the new image writes to the inherited fd 4 | `execchild: write(fd 4) = -1`, then no EOF |
| `leak` | child `dup3(wfd,1)`, closes wfd, exits; parent reads | never returns |

## 4. Kernel defect 1: pipe references leak on close(0–2), exit and exec

**Where.** `uts/uproc.c`:
* `proc_close()` returns 0 for `fd <= 2` before reaching `pipe_close()`.
* `proc_exit()` closes no fds.
* `load_elf_into()` (exec) zeroes `p_fd[]` without `pipe_close()`.

`proc_dup2()` *does* `pipe_ref()` when it copies a pipe into slots 0–2, so those
references are taken and never dropped.

**Symptom.** A pipe end that ever sits in fd 0–2 (every shell pipeline puts one
there), or that is still open at exit or exec, is never released. Its reader never
sees EOF and blocks forever. Observed directly with `kpipeprobe leak` (hangs) while
`ctl` reaches EOF. In a package: dash's `s=$(echo sub)` hung forever before the
glue workaround.

**Negative control.** `kpipe-ctl` passes on the same kernel and boot setup. Also,
dash linked against a glue built `-DSOLNIX_NO_VFD` (no fd table, no close-all) hangs
on `echo x | { read y; }`, while the normal build passes (`xfail-novfd-pipe`, 4/4).

**BLOCKING:** pipelines and command substitution that involve an exec'd program. That
blocks a real shell session. The glue's close-all at `_exit` and before `execve`
(STUB) only covers fds the glue knows about. An exec'd program still inherits
nothing.

## 5. Kernel defect 2: fd 0/1/2 are always the console in read/write

**Where.** `uts/syscall.c` `sys_write()` and `sys_read()`: only `fd >= 3` reaches
`proc_fwrite()`/`proc_fread()`. Fds 0–2 go to the UART unconditionally, even after
`dup2` has put a pipe in the slot. `uproc.c` `fd_ready()` (poll) *does* check the
slot first, so poll and read/write disagree about the same fd.

**Symptom.** `kpipeprobe conout`: after `dup3(pipe, 1)` the child's `write(1)`
prints on the console and the pipe gets nothing.

**Negative control.** `kpipe-ctl` writes the same bytes to fd 4 and the parent
receives all 10.

**BLOCKING:** stdout/stdin redirection for any program that does not carry the glue
fd table. With defect 3, that is every exec'd program. Also blocking for a real
shell session.

## 6. Kernel defect 3: exec drops every fd

**Where.** `uts/uproc.c` `load_elf_into()`: the loop "exec starts with a clean fd
table" sets `fd_used = 0` on every slot. POSIX keeps fds across exec unless
FD_CLOEXEC is set.

**Symptom.** `kpipeprobe execfd`: the exec'd image's `write(4, …)` returns -1. In
dash, `n=$(/bin/sbase-box echo inner)` prints `inner` on the console and leaves `n`
empty, and `sbase-box head -n 1 < /etc/words` reads the console instead of the file
(`kernel-limit-exec-stdout`/`-stdin`, 4/4).

**Negative control.** The same exec path with output to the console (fds 0–2 are
implicit) works in every exec check: `dash-exec-external` passes 4/4.

**BLOCKING:** `cmd > file`, `cmd < file`, `a | b` and `$(cmd)` whenever cmd is an
external program. That blocks a real shell session. **No userland workaround is
possible:** the fd table is gone before the new image runs.

**What works today**, so the line is clear: dash runs scripts, builtins, functions,
`$((…))` and control flow. Pipes and redirects work between builtins (inside one
process). External commands run with the console as stdin and stdout.

## 7. Signal numbering: three tables, one recommendation

| Signal | uts kernel (Linux riscv numbering; `uproc.c` defines only INT 2, KILL 9, CHLD 17) | newlib 4.5.0 riscv64 (measured, `solnix-cc -dM -E <signal.h>`) | illumos (`usr/src/uts/common/sys/iso/signal_iso.h`, illumos-gate faf916e60c) |
|---|---|---|---|
| HUP INT QUIT ILL TRAP ABRT | 1 2 3 4 5 6 | 1 2 3 4 5 6 | 1 2 3 4 5 6 |
| EMT | — | 7 | 7 |
| BUS | 7 | 10 | 10 |
| FPE KILL | 8 9 | 8 9 | 8 9 |
| USR1 | 10 | 30 | 16 |
| SEGV | 11 | 11 | 11 |
| USR2 | 12 | 31 | 17 |
| SYS | 31 | 12 | 12 |
| PIPE ALRM TERM | 13 14 15 | 13 14 15 | 13 14 15 |
| CHLD | **17** | **20** | **18** |
| CONT | 18 | 19 | 25 |
| STOP | 19 | 17 | 23 |
| TSTP | 20 | 18 | 24 |
| TTIN TTOU | 21 22 | 21 22 | 26 27 |
| URG | 23 | 16 | 21 |
| XCPU XFSZ | 24 25 | 24 25 | 30 31 |
| VTALRM PROF | 26 27 | 26 27 | 28 29 |
| WINCH | 28 | 28 | 20 |
| IO/POLL | 29 | 23 | 22 |
| PWR | 30 | — | 19 |
| NSIG | 32 (`uproc.c`) | 32 | **74** (`sys/signal.h`; realtime 42–73) |

The three tables agree only on 1–6, 8, 9, 11 and 13–15. On SIGCHLD, the one the
kernel posts on every child exit, all three differ.

**Recommendation.** Make the **illumos numbering** the long-term ABI. solnix is
illumos: the illumos libc port, Rust's `riscv64gc-unknown-illumos` `libc` crate,
and every illumos binary are compiled against it. Keep the newlib glue translating
(STUB) until the kernel moves. The kernel change (not done here) is larger than
renumbering:
* `p_sigpend` is a 64-bit mask and `NSIG` is 32, while illumos needs 74 signals,
  so the pending/handler sets need widening (illumos uses `k_sigset_t`).
* `proc_exit` hard-codes `SIGCHLD` 17.
* The console ^C path posts 2 (unchanged) and `sendsig.c` relies on the same
  numbers.

Once the kernel uses illumos numbers, the glue's `nl2k[]` becomes the newlib→illumos
map and nothing else in the packages changes.

## 8. The OS port layer: other mechanisms, all measured

* `CLOCK_REALTIME` is 1 in newlib; the kernel accepts 0 and 4. The glue translates.
* newlib's libgloss crt0 passes `envp = NULL` and never sets `environ`. `crt0.S`
  derives both from the stack the kernel builds.
* newlib's `mkstemp` `stat()`s `/tmp` first. The glue therefore treats the names in
  the kernel's root vnode (`/ /bin /etc /dev /sbin /var /tmp /data`) as
  directories. Before that, ed failed with `?`.
* newlib's `libc.a` references `regcomp` without shipping it, so POSIX regex and
  `fnmatch` are compiled from newlib's own source into `libsolnix.a`.
* `glue.o` is linked as an object, not from the archive. Otherwise newlib's
  `signal.o` gets pulled in for `raise()` and collides; zlib's configure then
  failed its vsnprintf probe and quietly turned `gzprintf` into a stub.

Smaller kernel limits recorded in the glue:
* `wait4` ignores options (WNOHANG blocks).
* A signal death reads as exit code 128+n (WIFSIGNALED is never true).
* The ramfs has no truncate (O_TRUNC is not honoured) and no unlink, mkdir or
  rename.
* No termios: line-mode console only.
* No getppid or process groups.
* The ustar root caps at **16 files / 2 MiB** (`rootfs.c NDISKFILE`,
  `ROOTFS_MAX_BYTES`). sbase therefore ships as one `sbase-box`, and
  `run-checks.sh` refuses a larger root instead of letting the kernel drop files
  silently.

## 9. Package notes

* **zlib.** The build script asserts configure found `vsnprintf`. My first negative
  control was wrong: corrupting bytes mid-stream leaves upstream `minigzip` exiting
  0 on Linux too (measured). The control now zeroes the trailer CRC; both the Linux
  build and the guest then exit 1.
* **sbase.** 94 of 100 utilities link. `make` is in a subdirectory and is not boxed.
  Six are excluded: cron and logger (syslog), nice and renice (setpriority), touch
  (utimensat, `tm_gmtoff`), tftp (no IP stack). `ls`, `rm`, `mv`, `mkdir`, `find`
  and `du` link but fail ENOSYS: there is no getdents, unlink, rename or mkdir.
* **dash.** `--without-libedit`, plus `wait3` and `killpg` (DERIVED). Its first
  pipeline check was invalid: pkginit split the argument on `|`. pkginit now
  decodes `%7C`.
* **ncurses.** Needed the full Linux termios constant set in the compat header.
  `byte-oracle.py`, with a flipped-byte control, shows 871 vs 870 bytes; the extra
  byte is the CR the serial console adds.
* **less.** `--with-regex=posix`. With no `/dev/tty`, keys come from fd 2 (the
  console). A forward search from the end correctly says "Pattern not found", so
  the check searches backward.

## 10. Still blocked

| Item | Blocked by |
|---|---|
| External commands in pipes, redirects and `$(…)` | kernel defects 1, 2, 3 (§4–§6) |
| Raw-mode keys (arrows, single keystrokes) in less, ed, curses | no termios / tty ioctl |
| ls, rm, mv, mkdir, find, du doing their jobs | no getdents, unlink, rename, mkdir |
| One "session" root with every package plus a terminfo db | rootfs 16-file / 2 MiB cap |
| GNU coreutils from the rp39–rp54 lineage | illumos-numbered libc and a lost toolchain |
| Threads, Rust | no TLS / `__tls_get_addr`; static-only loader |

## 11. Files

* Recipes (floki, uncommitted): `src/riscv/pkg/`
  * toolchain and sysroot: `solnix-cc`, `build-sysroot.sh`,
    `solnix-libc/{crt0.S, glue.c, solnix-pkg.ld, include/}`
  * package builds: `build-{zlib,sbase,dash,ncurses,less}.sh`, `build-all-pkgs.sh`
  * staging and checking: `stage-*.sh`, `run-checks.sh`, `check-all.sh`,
    `check-kernel.sh`, `byte-oracle.py`
  * qemu: `fetch-qemu.sh`, `qemu-wrap.sh`
  * `tests/` (checks, console inputs, test programs, `kpipeprobe.c`; `ttytest*.c` are
    the console-timing probes)
* lixr: sources and `SHA256SUMS` in `~/ws/rvpkg/dl/`; sysroot in
  `~/scratch/rvpkg/sysroot`; binaries in `~/scratch/rvpkg/out`; logs in
  `~/scratch/rvpkg/logs`.
* Bank: `/home/gburd/solnix-bank/riscv/2026-10-23/` (binaries, libraries, logs,
  recipe tarball, `SHA256SUMS`, read back on floki).

Reproduce on lixr:

```sh
bash ~/ws/rvpkg/pkg/fetch-qemu.sh
EXTRA_PKGS="dash ncurses less" bash ~/ws/rvpkg/pkg/build-all-pkgs.sh
bash ~/ws/rvpkg/pkg/check-all.sh 4 && bash ~/ws/rvpkg/pkg/check-kernel.sh 4
```
