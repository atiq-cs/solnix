# tryit: the solnix.io/tryit browser demo, from source

The page runs TinyEMU (compiled to WebAssembly) booting OpenSBI 1.8.1, the uts riscv64 kernel built
`-DSOLNIX_DEMO`, and a ustar root with dash, sbase and less. Login: `root`, no password.

Build host: x86_64 Linux with nix. `env.sh` (`env.sh` here; run it on the build host from ~/w) puts nixpkgs 08d3a975's tools on PATH:
emscripten 5.0.6, riscv64-none-elf gcc 14.4.0 + newlib 4.5.0, the riscv64-linux gcc for OpenSBI, qemu, chromium.

| step | script | what |
|---|---|---|
| userland | `build-userland.sh` | sysroot, zlib, sbase c546c3a, dash 0.5.12, ncurses 6.5, less 668 (`pkg/` scripts, cross gcc) |
| emulator | `../tinyemu/build.sh native\|wasm` | Bellard's 2019-12-21 + our two patches |
| all the rest | `all.sh <YYYYMMDD>` | kernels + demo init (`build-kernels.sh`), OpenSBI (`build-opensbi.sh`), images (`mk-images.sh`), bundle (`mk-bundle.sh`) |
| checks | `boot-test.py`, `browser-run.sh`, `rates.sh`, `gates.sh`, `checks.sh`, `pii-scan.sh` | see below |

## What the demo build changes, and where

- **Console line discipline (every kernel, not only the demo).** `uts/pty.c` has one more pair, number NPTY,
  whose master is the UART: `pty_cons_poll` feeds received bytes through `ld_in` (ICRNL; 0x08 is taken as
  VERASE as well as 0x7f) and drains output and echo to the SBI console. Opening `/dev/console` gives its
  slave, with the usual cooked termios, a controlling tty and ^C to the foreground group. It is dormant until
  the first open of `/dev/console`, so the gates and the check suites, which never open it, run as before.
  The poll runs from the wait loops (pty, poll, nanosleep), the idle loop, the dispatcher loop and the
  U-mode clock tick, which is how ^C reaches a running foreground program.
- **Session leader exit drops its ctty** (`uproc.c` proc_exit), so the next login can take the console.
- **Quiet console (`-DSOLNIX_DEMO`).** `sbi.c` `kcons_quiet`: the kernel's own console output is not
  printed (boot log, the `[fork]`/`[exec]`/`[elf]`/`[exit]` trace, self-test results), except the SunOS
  banner line. User output goes through `sbi_console_putchar_u` and is never silenced. A trap report
  (a real fault) turns the kernel console back on before printing.
- **Demo init (`uts/user/init.c -DSOLNIX_DEMO`, on the disk as /sbin/init).** No gates: a getty child
  (setsid, open /dev/console as fds 0-2, read the user name, print /etc/motd, exec the shell as `-dash`
  with HOME/PATH/TERM/USER). The embedded init in `user_elfs.h` is built without the flag and unchanged.
- **No PII.** `-ffile-prefix-map` in `build-unix.sh`, `user/build-user.sh`, `user/build-newlibtest.sh` and
  `pkg/solnix-cc`; the committed user ELF arrays in `user_elfs.h` were `--strip-debug`ged
  (`strip-user-elfs.py` checks every PT_LOAD segment and the entry point are unchanged). OpenSBI is built
  outside a nix derivation because nixpkgs' package carries its `/nix/store/...` rpath in the firmware.

## Known limits

- A command killed by ^C looks to dash like `exit 130`, not a signal death (the libc glue's waitpid
  has no WIFSIGNALED), so `sleep 30; echo x` runs the `echo` after ^C.
- No job stop/continue (^Z), as on ptys.
- Only drive0 exists in the bundle, so there is no `/data` disk; the demo init does not touch it.
