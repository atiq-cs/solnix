# riscv64 uts: an interactive ssh session (2026-10-26)

From floki, through lixr's qemu hostfwd, at -smp 8, under a real pty (python `pty.fork`):

    ssh -tt -p 2523 gburd@127.0.0.1
    $ echo X$((6*7))X        ->  X42X
    $ /bin/winsz             ->  33 111      (the client's window size)
    $ sleep 3; echo RC=$?    ->  RC=0
    $ sleep 100; echo RC=$?  ->  ^C, prompt back in 0.05-0.37 s
    $ exit                   ->  ssh rc 0

That is 4 of 4 boots on the final kernel (unix-c3) and the final userland. The wrong key is refused on 4 of 4. The
shell is dash with job control on (`$-` = `smi`). Base HEAD 863cc75; built natively on lixr, run under qemu 10.2.1.

## The four pieces, each with its own test and negative control

| piece | commit | test | negative control |
|---|---|---|---|
| pty pair (/dev/ptmx, /dev/pts/N, illumos ioctls) | 9e0574d | ptytest | HEAD: no /dev/ptmx |
| line discipline (ICANON, ECHO, ONLCR) | 9937550 | ptytest LD cases | unix-e7 fails all 7 |
| ctty, process groups, ISIG, SIGHUP | 863cc75 | ctytest (now also: the leader reads the line after ^C) | unix-a4: no TIOCGSID |
| this change: libc glue, dropbear ptys, the kernel pieces the session needed | this commit | ptyglue, intwait, the ssh proof | see below |

## What this change adds

**libc glue (src/riscv/pkg/solnix-libc):**
- `ioctl()` passes through to the kernel; it was an ENOTTY stub.
- tcgetattr/tcsetattr (TCGETS, then TCSETS/W/F by `optional_actions`), tcgetpgrp/tcsetpgrp, setpgid (154), and
  killpg as kill(-pg). killpg used to signal only the leader pid.
- posix_openpt, grantpt (OWNERPT), unlockpt, ptsname, cfmakeraw, cf*speed (the speed lives in c_cflag & CBAUD),
  ttyname (/dev/pts/N on a slave).
- `open()` now passes O_NOCTTY and O_NONBLOCK to the kernel. Without O_NOCTTY every open of a slave acquired it
  as a ctty.
- chown/chmod/fchownat/fchmodat reach the kernel; only /dev/pts/N is answered.
- `<sys/termios.h>` now has the illumos layout and values (NCCS 19, VMIN = VEOF = 4, CBAUD 017).
  `<sys/ioctl.h>` has the illumos TIOC numbers. `<stdlib.h>` declares the pty functions.
- With the STUB userland fd table (the vfd negative-control build), ioctl maps a program fd to its kernel fd.

**dropbear:** built with `-DUSE_DEV_PTMX=1`. Its configure skips the /dev/ptmx probe when cross-building.

**Kernel (uts):**
- fchownat(54) and fchmodat(53), for /dev/pts/N only and root only. dropbear's pty_setowner hands the slave to
  the user before dropping root. The slave's mode is now stored and reported by stat.
- nanosleep returns EINTR, with the true remainder, when a signal that would act is pending. Before, `sleep 100`
  under ^C died only when the 100 s ran out. The kernel delivers signals on the way back to U-mode, and nanosleep
  never went back.

## Evidence

| check | new | negative control |
|---|---|---|
| ssh -tt proof (prompt, 42, winsz 33x111, sleep 3, ^C under 3 s, exit 0) | unix-c3: 4/4 boots | wrong key refused 4/4 |
| intwait (shell-like ^C: the child dies of SIGINT, waitpid returns, the next line reads) | unix-c3: 2/2, child done in 1 s | unix-c2 (no nanosleep fix): child done in 100 s, FAIL |
| ptyglue (posix_openpt, ptsname, ttyname, canon + ONLCR echo, cfmakeraw, winsize through libc) | 2/2 | the old glue: does not compile (no posix_openpt/grantpt/unlockpt/ptsname) |
| tcgetattr on a slave through libc | PASS | old glue: FAIL (the ENOTTY stub) |
| ptytest, ctytest | 2/2 each on unix-c3 | (their own, as above) |
| check-all at -smp 8 on every package rebuilt against the final glue | 8 suites, 93 checks, 0 failed | |

check-all ran once and caught one real regression before this was final: vfd's STUB build passed program fds
straight to the kernel through the new ioctl. That is fixed (the vk mapping), and check-all was re-run green.
No kernel prints were added. Bank: `~/solnix-bank/riscv/2026-10-26-rvtty3c/`.

## Not done

- **fsync** is still ENOSYS, so dropbear warns once per host-key write. Host-key persistence across boots is
  untested; every proof boot used a fresh /data.
- **shutdown(2) half-close** for `ssh host 'cat > f' < file`.
- **Termios on the console** (only ptys have it).
- **Job stop/continue:** VSUSP, SIGTSTP and SIGTTOU/SIGTTIN are not implemented. dash's `fg` and `bg` have
  nothing to stop.
- **Blocked pty reads and nanosleep spin** in thread_yield. A wakeup on the right channel is the upgrade.
