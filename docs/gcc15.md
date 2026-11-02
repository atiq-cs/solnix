# GCC 15 on solnix (pkgs.solnix.gcc15)

`pkgs/illumos/gcc15-src.nix` builds GCC 15.3.0 with the illumos patch series as a second compiler. The stdenv compiler is still
gcc 14.3.0 (`gcc-src.nix`); nothing else builds with gcc15 until the switch wave. Measured 2026-11-02 (gcc1). The evidence is banked
in /scratch/solnix-bank/gcc1-20261102/.

## Why 15.3, not 16.2
- 15.3.0 is NixOS 26.05's default gcc. The illumos patch series (omniosorg/gcc il-15_2_0 = OpenIndiana's gcc-15 0001-0039)
  applies to it 39/39 with no fuzz. Note that github.com/illumos/gcc il-15_2_0 is plain upstream 15.2.0 with no patches;
  the series lives on omniosorg/gcc.
- On 16.2.0 the series fails in 4 patches (0008 cxa_atexit specs, 0009 -msave-args in i386.cc, 0027 -G specs, 0031
  -zassert-deflib) and needs fuzz in 11. GCC 16 also rewrote config/sol2.h for Solaris 11.4, with three silent breaks on illumos:
  1. The `-Y P,%R/lib/amd64:%R/usr/lib/amd64` sysroot link path is gone, replaced by `-z sysroot`, which illumos ld rejects. So a
     --with-sysroot gcc would link the build host's libraries.
  2. `-pthread` no longer defines `_REENTRANT`. illumos errno.h then gives the global errno, not `___errno()`.
  3. A fixincludes hack makes int8_t `signed char`, which changes C++ mangling against every gcc 14/15- and clang-built library.
  Nobody has an illumos gcc 16 branch yet.

## The patches (pkgs/illumos/patches/gcc-15)
- 0001-0039: OpenIndiana oi-userland components/developer/gcc-15 at d759189. Same content as omniosorg/gcc il-15_2_0.
- 0040, 0041: OmniOS omnios-build build/gcc15/patches. OI lacks both.
  - 0040 is GCC PR libstdc++/126399, and **gcc15 is unusable for C++ without it.** GCC 15 left `__gthread_trigger` outside the hidden
    visibility region of libgcc/gthr-posix.h, so the program's exported copy sets the program's thread flag and not the
    library's. Then `std::call_once` in a shared object throws `system_error` ("Unknown error"), and `std::mutex::lock()` there does
    nothing. Measured: the from-source nix built with gcc15 died at `nix --version` (gdb watchpoint on libnixstore's
    `__gthread_active_var`: -1 -> 0 inside call_once). Test: `cxx_gthr_pr126399` in the gcc1 test set.
  - 0041 fixes the dragonfly clocale's ctype<char> locale pointer.
- Not taken: OI 0040 / OmniOS 0042 (OmniOS /usr/gcc/N library paths) and OI 1000 (gccgo).
- gcc 14 (gcc-src.nix) carries only one of these patches, TS errno. So switching the stdenv also adds `__illumos__`, libc SSP
  (no libssp.so.0), the .eh_frame_hdr unwinder, -msave-args, -fstrict-calling-conventions, dragonfly C++ locales, and -G = -shared.

## The build: store tools only
stage0 is `srcPkgs.gccWrapper` (gcc 14, the NixOS stage chain). PATH is seedBuildTools, coreutils, findutils, gnupatch and perl from
the store, plus /usr/bin. `--with-as` is the store gas. There is no /usr/gnu, /usr/gcc, host perl or host gas, so a solnix host can
build it. Most of these fixes come from solnix.io infra's dixi trial build (2026-11-02): stage0 = gccWrapper, store perl for
make_sunver.pl, store coreutils for `cp -P`, and the wider RUNPATH rewrite. stage0's dead RUNPATH strings and .la paths are scrubbed,
and install-tools (fixincl, which names the seed sed) is deleted, as nixpkgs does. So the closure holds no gcc 14, seed tools or world.

## The switch (later, the wave6 W0 tier)
`gcc = gcc15` moves every out. Do it in the same wave as a `-std=gnu17` C pin in mk-src-pkg. GCC 15's C23 default breaks 12
packages' sources plus the out-of-gate drivers: the gate's own `sys/systm.h` declares `int nodev(); int nulldev();`. It also flips
configure probes silently, and changes ncurses' installed curses.h (no stdbool), which broke neomutt and tig. The per-package list,
which says what lets each package drop the pin, is in the gcc1 handoff (c23-pin-by-package.tsv).

## aarch64
Not built. richlowe's il-14_3_0-arm64 arm commits on top of 15.3.0 + these 41 patches: 3 of them (0036, 0039, 0045) reject, all in
the Solaris-CRT configure plumbing that GCC 15 removed. The rest apply.
