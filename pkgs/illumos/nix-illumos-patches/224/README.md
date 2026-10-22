# nix-illumos-patches/224 — illumos source fixes for Nix 2.24.15

The patches this directory carries are the complete illumos-specific source
churn needed to build and run upstream Nix 2.24.15 (autotools path) on
x86_64-solaris. Every patch applies with `patch -p1` (or `git apply`) against a
clean Nix 2.24.15 source tree, in numeric order. Discovery and proofs are in
`docs/spike-nix-upgrade-notes.md`; the reproducible build driver is
`scripts/oi-nix224-setup.sh`; the hermetic derivation is `../nix224.nix`.

Modern Nix already partitions its Linux-only code (`platform.mk` sets
`HOST_SOLARIS`/`HOST_UNIX`, so seccomp/namespaces/personality never compile) and
feature-detects statvfs/pipe2/xattr, so the 2.3.16 hazard list collapses to
these seven; 0008 adds the solnix: scheme.

| # | file | what / why |
|---|------|------------|
| 0001 | `src/libutil/terminal.cc` | include `<sys/termios.h>` for `struct winsize`/`TIOCGWINSZ` (illumos does not pull them in via `<sys/ioctl.h>` as Linux does) |
| 0002 | `src/libutil/unix/signals.cc` | exclude `__sun` from the `sigorset` branch (illumos `sigorset` takes the kernel `k_sigset_t`, not glibc's 3-arg form) → use the direct-assignment fallback |
| 0003 | `src/libstore/unix/build/local-derivation-goal.cc` | supply `cfmakeraw()` (absent from illumos libc) and push STREAMS `ptem`/`ldterm` onto the build pty slave before `tcgetattr`/`tcsetattr` (else EINVAL aborts every build) |
| 0004 | `src/libstore/unix/pathlocks.cc` | drop `LOCK_NB` when releasing an flock (illumos rejects `flock(fd, LOCK_UN\|LOCK_NB)` EINVAL; the `~FdLock` unlock threw in a destructor and terminated every build) |
| 0005 | `src/libutil/current-process.cc` | resolve `getSelfExe()` via `/proc/self/path/a.out` under `__sun` (the non-Linux `#else` returned nullopt → "not an absolute path: 'nix'") |
| 0006 | `src/nix/unix/daemon.cc` | illumos has neither `SO_PEERCRED` nor `LOCAL_PEERCRED`; learn the client uid with `getpeerucred()` so `trusted-users` can match |
| 0007 | `src/libstore/gc.cc` | find runtime GC roots through `/proc/<pid>/path/*` under `__sun`, and skip ENAMETOOLONG/EINVAL in `readProcLink` (illumos `/proc/<pid>/cwd` readlinks to 0 bytes, so `nix-store --gc` aborted with "read_symlink: File name too long [/proc/0/cwd]") |
| 0008 | `src/libfetchers/solnix.cc` (new), `fetchers.cc` | NOT an illumos fix: the `solnix:` flake input scheme (`solnix:#x`, `solnix:<branch|tag|commit-prefix>#x`, `solnix:<repo>/<ref>#x`), rewritten to a plain git input on git.solnix.io, so locks are ordinary git locks. It resolves tags and abbreviated commit ids, which a registry entry cannot. Proven 12/12 on Linux (2.24.14) and illumos (this build), with negative controls |

Patch 0003 is the re-forward-port of the 2.3.16 patch-0002 (the pty code moved
from `build.cc` to `local-derivation-goal.cc`). Patch 0004 is new to the modern
codebase. Patches 0001/0002/0005 are one-guard fixes.

## Non-source build-environment tweaks (not patches)

These live in the build driver / derivation, not here, because they are
configure/make invocation details rather than source edits:

- empty `AC_CONFIG_FILES([])` → instantiate `Makefile.config` explicitly with
  `config.status --file=Makefile.config:Makefile.config.in`.
- openssl-3 `.pc` path prepended to `PKG_CONFIG_PATH` (the `/usr` default is
  openssl-1.0, but Nix wants libcrypto ≥ 1.1.1).
- `ax_boost_base.m4` from `developer/build/autoconf-archive` (missing from the
  GitHub archive tarball).
- vendored toml11 header on the include path; `ERROR_SWITCH_ENUM=` to disarm the
  per-file `-Werror=switch-enum` the vendored toml11 trips (upstream's own
  documented override).
- REPL built against GNU readline (`USE_READLINE` + `EDITLINE_LIBS=-lreadline`);
  illumos libedit lacks the symbols Nix's REPL wants.
- `--disable-gc` (Boehm GC not in OI), `--disable-markdown` (lowdown not in OI),
  `--disable-cpuid` (libcpuid not in OI), `--disable-unit-tests`,
  `--disable-doc-gen`.
